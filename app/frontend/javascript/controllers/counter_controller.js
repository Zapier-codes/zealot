import { Controller } from "@hotwired/stimulus"

// [threshold, suffix] pairs, largest first. Mirrors HomeHelper::COMPACT_UNITS
// (app/helpers/home_helper.rb) — keep the two in sync so the animated
// counter settles on exactly what the server rendered for no-JS visitors.
const COMPACT_UNITS = [
  [1_000_000_000, "B"],
  [1_000_000, "M"]
]

// Connects to data-controller="counter"
//
// Counts a number up from 0 to data-counter-count-value once the element
// scrolls into view. Respects prefers-reduced-motion by jumping straight
// to the final value instead of animating.
//
// With data-counter-compact-value="true" (used for the big "apps" /
// "releases" totals) the number counts up as plain digits and, the moment
// it reaches a million, switches to shorthand with a "+" — 1M+, 1.2M+ …
// 10M+ — so we never render a wall of zeros. The final value always ends
// in "+" because these totals are "at least" figures (baseline + live).
export default class extends Controller {
  static values = {
    count: Number,
    duration: { type: Number, default: 3000 },
    compact: { type: Boolean, default: false }
  }

  connect() {
    this.hasAnimated = false

    if (!("IntersectionObserver" in window)) {
      this.renderFinal()
      return
    }

    // The server renders the final value (so no-JS / crawlers see the
    // real number). Once JS is running, reset to zero right away so the
    // count-up visibly starts from 0 instead of flashing final → 0.
    if (this.countValue > 0 && !this.prefersReducedMotion()) {
      this.element.textContent = this.format(0)
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
    if (this.frame) { cancelAnimationFrame(this.frame) }
  }

  animate() {
    const target = this.countValue

    if (target <= 0 || this.prefersReducedMotion()) {
      this.renderFinal()
      return
    }

    // Big compact totals get a longer run so the plain-digit phase and
    // the "M+" phase are both actually readable.
    const duration = this.compactValue ? this.durationValue * 1.5 : this.durationValue
    const start = performance.now()

    const step = (now) => {
      const progress = Math.min((now - start) / duration, 1)
      const eased = 1 - Math.pow(1 - progress, 3) // ease-out-cubic
      const value = Math.floor(eased * target)

      this.element.textContent = this.format(value)

      if (progress < 1) {
        this.frame = requestAnimationFrame(step)
      } else {
        this.renderFinal()
      }
    }

    this.frame = requestAnimationFrame(step)
  }

  renderFinal() {
    this.element.textContent = this.format(this.countValue, { final: true })
  }

  format(value, { final = false } = {}) {
    if (!this.compactValue) { return value.toLocaleString() }

    const unit = COMPACT_UNITS.find(([threshold]) => value >= threshold)

    // Below a million: plain digits while counting; the closing "+" only
    // appears on the settled value.
    if (!unit) { return final ? `${value.toLocaleString()}+` : value.toLocaleString() }

    // Truncate (never round) to one decimal so the "+" can't overstate.
    const [threshold, symbol] = unit
    const tenths = Math.floor(value / (threshold / 10))
    const whole = Math.floor(tenths / 10)
    const tenth = tenths % 10

    return `${tenth === 0 ? whole : `${whole}.${tenth}`}${symbol}+`
  }

  prefersReducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }
}
