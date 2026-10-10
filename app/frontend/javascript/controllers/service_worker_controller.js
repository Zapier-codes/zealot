import { Controller } from "@hotwired/stimulus"

// Z-P23 (Play Console parity): register the service worker so the console is installable and opens
// offline. Deliberately tiny and inert when unsupported: no service worker in the browser (or the page
// served over plain http, where registration is refused) means this does nothing and the console works
// exactly as before. The file the worker runs is rendered by PwaController, so its URL is a data value
// rather than a hard-coded path.
export default class extends Controller {
  static values = { url: String }

  connect() {
    if (!("serviceWorker" in navigator) || !this.hasUrlValue) return

    window.addEventListener("load", () => {
      navigator.serviceWorker.register(this.urlValue, { scope: "/" }).catch(() => {
        // A refused registration is not an error worth surfacing: the console is fully usable without it.
      })
    })
  }
}
