import { Controller } from "@hotwired/stimulus"

// Task 40h-c / 40s-d: sends the chosen file straight to the staging bucket, so the bytes never reach Render.
//
//   1. POST   <sessionUrl>               -> { id, upload_url, method, headers }   (Zealot opens an upload)
//   2. PUT    upload_url  (the file)     -> the staging bucket                    (progress is shown here)
//   3. POST   <sessionUrl>/<id>/finalize -> { id, state }                         (Zealot checks what arrived)
//
// A large file (Task 40s-c, RELEASE_UPLOAD_MULTIPART_ENABLED) is opened in parts instead: the session answers
// `{ id, multipart: true, part_size, part_count, expires_at }` with no `upload_url`, and step 2 becomes
//
//   2a. POST  <sessionUrl>/<id>/parts  { parts: [1, 2, 3, 4] } -> { parts: [{ part_number, url, method, headers }] }
//   2b. PUT   each part's url (a slice of the file, no extra header), PART_CONCURRENCY at a time
//   2c. a part that fails is sent again (MAX_PART_RETRIES times) with a freshly signed URL
//   2d. GET   <sessionUrl>/<id>/parts   -> { uploaded: [...], missing: [...] }    (resume, see below)
//
// Resume: the session id of a multipart upload is kept in localStorage, keyed by the console URL, the file's
// name, size and last-modified time, and the form options. Choosing the same file again after a dropped
// connection, a closed tab or a refresh asks GET .../parts which parts the bucket already holds and sends only
// the missing ones. Browsers cannot keep the File itself, so the person has to choose it again; the name, size
// and last-modified time are what say it is the same file (Zealot's finalize checks the total size, not the bytes).
// If Zealot no longer knows the upload (409, 404) the id is forgotten and a new upload is opened.
//
// The controller only runs when the form carries `data-controller="direct-upload"`, which the form helper adds
// only while `ReleaseUploadSession.enabled?` is true. With no file chosen it does nothing, so the normal form
// submit (and its usual validation message) still happens.
//
// Not verified in a browser or against the staging bucket. The logic was run in Node against stand-ins for
// XMLHttpRequest, fetch, localStorage and the Zealot doors (see the Task 40s-d entry in handover.md).

const OPTION_KEYS = [
  "hold", "play_store_target", "changelog", "branch", "git_commit", "ci_url", "release_type", "custom_fields", "devices"
]

const PART_CONCURRENCY = 3 // parts in flight at once
const SIGN_BATCH = 4 // part numbers signed per request (Zealot's limit is 10)
const MAX_PART_RETRIES = 4 // after the first try, each with a new signature
const RETRY_DELAY_MS = 1000 // times the attempt number
const FINALIZE_ROUNDS = 2 // times finalize may hand back missing parts to send again
const SAVED_PREFIX = "zealot.directUpload:"
const SAVED_MAX_AGE_MS = 5.5 * 60 * 60 * 1000 // Zealot keeps a multipart upload open for 6 hours

class UploadError extends Error {
  constructor(message, { status = null, data = {} } = {}) {
    super(message)
    this.status = status
    this.data = data
  }

  // A failure that may go away by itself: no answer at all, or a 5xx.
  get retryable() {
    return this.status === null || this.status >= 500
  }

  // Zealot refused the request itself (not a network problem): asking again with the same id will not help.
  get refused() {
    return this.status !== null && this.status >= 400 && this.status < 500
  }
}

export default class extends Controller {
  static targets = ["file", "submit", "status", "progress", "message", "done"]

  static values = {
    sessionUrl: String,
    messages: Object
  }

  async submit(event) {
    const file = this.hasFileTarget ? this.fileTarget.files[0] : null
    if (!file) return

    event.preventDefault()
    if (this.busy) return

    this.busy = true
    this.lock(true)
    this.hideDone()
    this.show("opening", 0)

    try {
      await this.upload(file)
      this.finish()
    } catch (error) {
      this.fail(error, file)
    } finally {
      this.busy = false
    }
  }

  async upload(file) {
    const resumed = await this.resume(file)
    if (resumed && resumed.finished) {
      this.forget(file)
      return
    }

    const session = resumed ? resumed.session : await this.openSession(file)
    if (session.multipart) {
      if (!resumed) this.remember(file, session)
      const numbers = resumed ? resumed.missing : this.allParts(session.part_count)
      await this.sendParts(session, file, numbers)
    } else {
      await this.send(session, file)
    }

    this.show("finishing", 100)
    await this.finalize(session, file)
    this.forget(file)
  }

  openSession(file) {
    const body = { ...this.formOptions(), filename: file.name, size: file.size }
    if (file.type) body.content_type = file.type
    return this.requestJson("POST", this.sessionUrlValue, body)
  }

  // Only the form fields Zealot accepts for an upload (ReleaseUploadSession::FORM_OPTION_KEYS). Blank values are
  // left out. The checkbox's hidden "0" comes before the checked "1", so the later entry wins.
  formOptions() {
    const options = {}
    for (const [name, value] of new FormData(this.element)) {
      const match = /^release\[(\w+)\]$/.exec(name)
      if (!match || !OPTION_KEYS.includes(match[1])) continue
      if (typeof value !== "string" || value === "") continue

      options[match[1]] = value
    }
    return options
  }

  async requestJson(method, url, body) {
    const headers = { "Accept": "application/json", "X-CSRF-Token": this.csrfToken() }
    const init = { method, credentials: "same-origin", headers }
    if (body !== undefined) {
      headers["Content-Type"] = "application/json"
      init.body = JSON.stringify(body)
    }

    let response
    try {
      response = await fetch(url, init)
    } catch (_error) {
      throw new UploadError(this.message("failed"))
    }

    let data = {}
    try {
      data = await response.json()
    } catch (_error) {
      data = {}
    }

    if (!response.ok) throw new UploadError(data.error || this.message("failed"), { status: response.status, data })
    return data
  }

  // ---- one PUT (files under the multipart threshold) -------------------------------------------------------

  // XMLHttpRequest, not fetch, because only it reports upload progress.
  send(session, file) {
    return new Promise((resolve, reject) => {
      const request = new XMLHttpRequest()
      request.open(session.method || "PUT", session.upload_url)
      Object.entries(session.headers || {}).forEach(([name, value]) => request.setRequestHeader(name, value))

      request.upload.onprogress = (event) => {
        if (event.lengthComputable) this.show("sending", Math.round((event.loaded / event.total) * 100))
      }
      request.onload = () => {
        if (request.status >= 200 && request.status < 300) resolve()
        else reject(new UploadError(this.message("send_failed")))
      }
      request.onerror = () => reject(new UploadError(this.message("send_failed")))
      request.onabort = () => reject(new UploadError(this.message("send_failed")))
      request.send(file)
    })
  }

  // ---- parts (Task 40s-d) ----------------------------------------------------------------------------------

  allParts(count) {
    return Array.from({ length: count }, (_value, index) => index + 1)
  }

  // Bytes in part `number`: every part is part_size long except the last, which is what is left.
  partLength(session, file, number) {
    const start = (number - 1) * session.part_size
    return Math.max(0, Math.min(start + session.part_size, file.size) - start)
  }

  // Sends the parts in `numbers`, PART_CONCURRENCY at a time. Part URLs are signed SIGN_BATCH at a time, just
  // before they are needed. The first failure stops every part still in flight and is the error that is thrown.
  async sendParts(session, file, numbers) {
    const held = file.size - numbers.reduce((sum, number) => sum + this.partLength(session, file, number), 0)
    const run = {
      session, file, failed: false, signing: null,
      queue: [...numbers], buffer: [], requests: new Set(), inflight: new Map(), completed: held
    }

    this.report(run)
    const workers = Array.from({ length: Math.min(PART_CONCURRENCY, numbers.length) }, () =>
      this.worker(run).catch((error) => {
        this.stop(run)
        throw error
      })
    )
    await Promise.all(workers)
  }

  async worker(run) {
    for (;;) {
      const part = await this.takePart(run)
      if (!part) return

      await this.sendPart(run, part)
    }
  }

  // The next signed part: from the buffer, else sign the next batch (one signing call at a time).
  async takePart(run) {
    for (;;) {
      if (run.failed) return null
      if (run.buffer.length) return run.buffer.shift()
      if (!run.queue.length) return null
      if (run.signing) {
        await run.signing
        continue
      }

      const numbers = run.queue.splice(0, SIGN_BATCH)
      run.signing = this.signParts(run.session, numbers)
        .then((parts) => { run.buffer.push(...parts) })
        .finally(() => { run.signing = null })
      await run.signing
    }
  }

  async signParts(session, numbers) {
    const url = `${this.sessionUrlValue}/${session.id}/parts`
    for (let attempt = 0; ; attempt++) {
      try {
        const data = await this.requestJson("POST", url, { parts: numbers })
        return data.parts
      } catch (error) {
        if (!(error instanceof UploadError) || !error.retryable || attempt >= MAX_PART_RETRIES) throw error
        await this.pause(RETRY_DELAY_MS * (attempt + 1))
      }
    }
  }

  // One part, tried again with a new signature each time it fails.
  async sendPart(run, part) {
    const { session, file } = run
    const start = (part.part_number - 1) * session.part_size
    const blob = file.slice(start, start + this.partLength(session, file, part.part_number))

    let signed = part
    for (let attempt = 0; ; attempt++) {
      try {
        await this.putPart(run, signed, blob)
        return
      } catch (error) {
        if (run.failed) throw error
        if (attempt >= MAX_PART_RETRIES) throw new UploadError(this.message("send_failed"))

        await this.pause(RETRY_DELAY_MS * (attempt + 1))
        if (run.failed) throw error
        const [fresh] = await this.signParts(session, [part.part_number])
        signed = fresh
      }
    }
  }

  putPart(run, signed, blob) {
    return new Promise((resolve, reject) => {
      const number = signed.part_number
      const request = new XMLHttpRequest()
      run.requests.add(request)
      const settle = () => {
        run.requests.delete(request)
        run.inflight.delete(number)
      }

      request.open(signed.method || "PUT", signed.url)
      Object.entries(signed.headers || {}).forEach(([name, value]) => request.setRequestHeader(name, value))

      request.upload.onprogress = (event) => {
        if (!event.lengthComputable) return

        run.inflight.set(number, event.loaded)
        this.report(run)
      }
      request.onload = () => {
        settle()
        if (request.status >= 200 && request.status < 300) {
          run.completed += blob.size
          this.report(run)
          resolve()
        } else {
          reject(new UploadError(this.message("send_failed")))
        }
      }
      request.onerror = () => {
        settle()
        reject(new UploadError(this.message("send_failed")))
      }
      request.onabort = request.onerror
      request.send(blob)
    })
  }

  stop(run) {
    run.failed = true
    run.requests.forEach((request) => request.abort())
  }

  // Progress from the bytes sent: whole parts done plus what each part in flight has sent so far.
  report(run) {
    let sent = run.completed
    run.inflight.forEach((loaded) => { sent += loaded })
    const percent = run.file.size > 0 ? Math.min(100, Math.floor((sent / run.file.size) * 100)) : 100
    this.show("sending", percent)
  }

  pause(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds))
  }

  // Finalize. For an upload in parts, Zealot may answer 422 `parts_incomplete` with the parts to send again
  // (a part R2 does not hold at the right size); those are sent and finalize is asked again.
  async finalize(session, file) {
    const url = `${this.sessionUrlValue}/${session.id}/finalize`
    for (let round = 0; ; round++) {
      try {
        await this.requestJson("POST", url, {})
        return
      } catch (error) {
        const missing = error instanceof UploadError && error.data && error.data.code === "parts_incomplete" ? error.data.missing : null
        if (!session.multipart || !Array.isArray(missing) || missing.length === 0 || round >= FINALIZE_ROUNDS) throw error

        await this.sendParts(session, file, missing)
        this.show("finishing", 100)
      }
    }
  }

  // ---- resume ----------------------------------------------------------------------------------------------

  // null when there is nothing to resume; `{ finished: true }` when Zealot already holds the finished upload;
  // else `{ session, missing }`. A transient failure (no answer, 5xx) is thrown and the saved id is kept, so the
  // person can try again.
  async resume(file) {
    const saved = this.recall(file)
    if (!saved) return null

    try {
      const listing = await this.requestJson("GET", `${this.sessionUrlValue}/${saved.id}/parts`)
      if (!this.matchesPlan(file, listing)) {
        this.forget(file)
        return null
      }

      const session = { id: saved.id, multipart: true, part_size: listing.part_size, part_count: listing.part_count }
      const missing = listing.missing
      if (missing.length < listing.part_count) {
        const held = file.size - missing.reduce((sum, number) => sum + this.partLength(session, file, number), 0)
        this.show("resuming", Math.floor((held / file.size) * 100))
      }
      return { session, missing }
    } catch (error) {
      if (!(error instanceof UploadError) || !error.refused) throw error

      // Zealot no longer takes parts for this id. A 409 can mean it was completed after all: finalize says so.
      if (error.status === 409 && (await this.alreadyFinalized(saved))) return { finished: true }

      this.forget(file)
      return null
    }
  }

  async alreadyFinalized(saved) {
    try {
      await this.requestJson("POST", `${this.sessionUrlValue}/${saved.id}/finalize`, {})
      return true
    } catch (_error) {
      return false
    }
  }

  matchesPlan(file, listing) {
    return Number.isInteger(listing.part_size) && listing.part_size > 0 &&
      Number.isInteger(listing.part_count) && Array.isArray(listing.missing) &&
      Math.ceil(file.size / listing.part_size) === listing.part_count
  }

  // ---- the saved session id --------------------------------------------------------------------------------

  storageKey(file) {
    return SAVED_PREFIX + JSON.stringify([this.sessionUrlValue, file.name, file.size, file.lastModified, this.formOptions()])
  }

  recall(file) {
    try {
      const key = this.storageKey(file)
      const raw = window.localStorage.getItem(key)
      if (!raw) return null

      const saved = JSON.parse(raw)
      if (this.stale(saved)) {
        window.localStorage.removeItem(key)
        return null
      }
      return saved
    } catch (_error) {
      return null
    }
  }

  remember(file, session) {
    try {
      this.prune()
      const saved = { id: session.id, savedAt: Date.now(), expiresAt: session.expires_at || null }
      window.localStorage.setItem(this.storageKey(file), JSON.stringify(saved))
    } catch (_error) {
      // No storage (private mode, quota): the upload still works, it just cannot be resumed.
    }
  }

  forget(file) {
    try {
      window.localStorage.removeItem(this.storageKey(file))
    } catch (_error) {
      // nothing to forget
    }
  }

  stale(saved) {
    if (!saved || !saved.id || typeof saved.savedAt !== "number") return true
    if (Date.now() - saved.savedAt > SAVED_MAX_AGE_MS) return true
    return Boolean(saved.expiresAt) && Date.parse(saved.expiresAt) < Date.now()
  }

  // Drops saved ids Zealot has already closed, so the list does not grow.
  prune() {
    const storage = window.localStorage
    for (let index = storage.length - 1; index >= 0; index--) {
      const key = storage.key(index)
      if (!key || !key.startsWith(SAVED_PREFIX)) continue

      let saved = null
      try {
        saved = JSON.parse(storage.getItem(key))
      } catch (_error) {
        saved = null
      }
      if (this.stale(saved)) storage.removeItem(key)
    }
  }

  // ---- the page --------------------------------------------------------------------------------------------

  finish() {
    this.show("done", 100)
    if (this.hasDoneTarget) this.doneTarget.classList.remove("hidden")
  }

  fail(error, file) {
    const text = error instanceof UploadError ? error.message : this.message("failed")
    this.setMessage(text)
    if (this.hasProgressTarget) this.progressTarget.classList.add("hidden")
    this.lock(false)

    // Zealot refused this upload id: do not offer it again. A dropped connection keeps it, so the next try resumes.
    const keep = error instanceof UploadError && error.data && error.data.code === "parts_incomplete"
    if (error instanceof UploadError && error.refused && !keep) this.forget(file)
  }

  show(key, percent) {
    if (this.hasStatusTarget) this.statusTarget.classList.remove("hidden")
    if (this.hasProgressTarget) {
      this.progressTarget.classList.remove("hidden")
      this.progressTarget.value = percent
    }
    this.setMessage(this.message(key, percent))
  }

  setMessage(text) {
    if (this.hasStatusTarget) this.statusTarget.classList.remove("hidden")
    if (this.hasMessageTarget) this.messageTarget.textContent = text
  }

  hideDone() {
    if (this.hasDoneTarget) this.doneTarget.classList.add("hidden")
  }

  lock(locked) {
    if (this.hasSubmitTarget) this.submitTarget.disabled = locked
    if (this.hasFileTarget) this.fileTarget.disabled = locked
  }

  message(key, percent = 0) {
    const text = this.messagesValue[key] || ""
    return text.replace("{percent}", percent)
  }

  csrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']")
    return meta ? meta.content : ""
  }
}
