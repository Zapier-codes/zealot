import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="modal"
export default class extends Controller {
  connect() {
    this.element.showModal()

    // Task 20c: 20a made the frame re-render this same dialog in place on
    // a failed submission instead of eating the response, but a silent
    // in-place swap is easy to miss — especially in a modal the user is
    // already looking at. Turbo Frame replaces the whole <dialog
    // data-controller="modal"> node (not just its contents), so connect()
    // fires again for the error re-render exactly as it does for a fresh
    // open, with SimpleForm's error markup already present in the DOM at
    // that point. Shake the box when that's the case.
    if (this.hasErrors()) this.shake()
  }

  disconnect() {
    this.clear()
  }

  // Bug fix (Task 20a): this used to run unconditionally on
  // turbo:submit-end, so a failed (validation-error) submission closed
  // and removed the dialog just as fast as a successful one — the
  // in-frame error re-render from the controller never had a chance to
  // be seen. turbo:submit-end's event.detail.success is false for a
  // failed submission (including a 4xx/5xx response); only clear the
  // modal when the submission actually succeeded, or when close() is
  // called directly (e.g. the dialog's own close button, no event).
  close(event) {
    if (event && event.detail && event.detail.success === false) return

    this.clear()
  }

  clear() {
    // this.modal.hide()
    this.element.remove()
  }

  // Task 20c helpers ---------------------------------------------------

  // SimpleForm (config/initializers/simple_form_daisyui.rb) puts
  // `d-alert-error` on the error_notification summary (when a form calls
  // f.error_notification) and `d-input-error` on every invalid field
  // regardless — checking both catches every one of the ~10 modal forms
  // sharing this controller, whether or not they render the summary.
  hasErrors() {
    return this.element.querySelector(".d-alert-error, .d-input-error") !== null
  }

  shake() {
    const box = this.element.querySelector(".d-modal-box")
    if (!box) return

    box.classList.add("shake-error")
    box.addEventListener("animationend", () => box.classList.remove("shake-error"), { once: true })
  }
}
