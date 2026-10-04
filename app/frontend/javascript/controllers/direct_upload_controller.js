import { Controller } from "@hotwired/stimulus"

// Task 40h-c: sends the chosen file straight to the staging bucket, so the bytes never reach Render.
//
//   1. POST   <sessionUrl>               -> { id, upload_url, method, headers }   (Zealot opens an upload)
//   2. PUT    upload_url  (the file)     -> the staging bucket                    (progress is shown here)
//   3. POST   <sessionUrl>/<id>/finalize -> { id, state }                         (Zealot checks what arrived)
//
// The controller only runs when the form carries `data-controller="direct-upload"`, which the form helper adds
// only while `ReleaseUploadSession.enabled?` is true. With no file chosen it does nothing, so the normal form
// submit (and its usual validation message) still happens.
//
// Not verified: nothing here has been run in a browser or against the staging bucket.

const OPTION_KEYS = [
  "hold", "play_store_target", "changelog", "branch", "git_commit", "ci_url", "release_type", "custom_fields", "devices"
]

class UploadError extends Error {}

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
      const session = await this.openSession(file)
      await this.send(session, file)
      this.show("finishing", 100)
      await this.postJson(`${this.sessionUrlValue}/${session.id}/finalize`, {})
      this.finish()
    } catch (error) {
      this.fail(error)
    } finally {
      this.busy = false
    }
  }

  openSession(file) {
    const body = { ...this.formOptions(), filename: file.name, size: file.size }
    if (file.type) body.content_type = file.type
    return this.postJson(this.sessionUrlValue, body)
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

  async postJson(url, body) {
    const response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify(body)
    })

    let data = {}
    try {
      data = await response.json()
    } catch (_error) {
      data = {}
    }

    if (!response.ok) throw new UploadError(data.error || this.message("failed"))
    return data
  }

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

  finish() {
    this.show("done", 100)
    if (this.hasDoneTarget) this.doneTarget.classList.remove("hidden")
  }

  fail(error) {
    const text = error instanceof UploadError ? error.message : this.message("failed")
    this.setMessage(text)
    if (this.hasProgressTarget) this.progressTarget.classList.add("hidden")
    this.lock(false)
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
