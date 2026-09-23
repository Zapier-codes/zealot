import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="modal"
export default class extends Controller {
  connect() {
    this.element.showModal()
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
}
