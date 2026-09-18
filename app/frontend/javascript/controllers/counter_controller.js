import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="counter"
//
// Counts a number up from 0 to data-counter-count-value once the element
// scrolls into view. Respects prefers-reduced-motion by jumping straight
// to the final value instead of animating.
export default class extends Controller {
  static values = {
    count: Number,
    duration: { type: Number, default: 1400 }
  }

  connect() {
    this.hasAnimated = false

    if (!("IntersectionObserver" in window)) {
      this.renderFinal()
      return
    }

    this.observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting && !this.hasAnimated) {
            this.hasAnimated = true
            this.animate()
          }
        })
      },
      { threshold: 0.4 }
    )
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
  }

  animate() {
    const target = this.countValue

    if (target <= 0 || this.prefersReducedMotion()) {
      this.renderFinal()
      return
    }

    const duration = this.durationValue
    const start = performance.now()

    const step = (now) => {
      const progress = Math.min((now - start) / duration, 1)
      const eased = 1 - Math.pow(1 - progress, 3) // ease-out-cubic
      const value = Math.floor(eased * target)

      this.element.textContent = this.format(value)

      if (progress < 1) {
        requestAnimationFrame(step)
      } else {
        this.renderFinal()
      }
    }

    requestAnimationFrame(step)
  }

  renderFinal() {
    this.element.textContent = this.format(this.countValue)
  }

  format(value) {
    return value.toLocaleString()
  }

  prefersReducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }
}
