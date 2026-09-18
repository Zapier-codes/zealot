import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="globe"
//
// Renders a rotating 3D globe (via globe.gl / three.js) with one pin per
// country in data-globe-points-value, each pin showing that country's
// flag (flagcdn.com) and code. Decorative — see HomeController#landing_countries
// for why this isn't backed by live geo-analytics.
//
// Loaded lazily (dynamic import) so the ~150kb three.js dependency never
// blocks the rest of the landing page, and only initialized once the
// globe container actually scrolls into view. Respects
// prefers-reduced-motion by disabling auto-rotate. Falls back silently
// to the <noscript> flag grid (already in the DOM) if the import fails
// for any reason (e.g. offline, ad-blocker) — never throws to the user.
export default class extends Controller {
  static values = { points: Array }

  connect() {
    this.initialized = false

    if (!("IntersectionObserver" in window)) {
      this.init()
      return
    }

    this.observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting && !this.initialized) {
            this.initialized = true
            this.init()
          }
        })
      },
      { threshold: 0.2 }
    )
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    this.globe?._destructor?.()
  }

  async init() {
    let Globe
    try {
      ({ default: Globe } = await import("globe.gl"))
    } catch (error) {
      // Leave the <noscript> flag grid visible as a fallback — flip its
      // display back on since CSS hides it whenever JS is running.
      this.element.classList.add("landing-globe-failed")
      console.error("[globe] failed to load globe.gl", error)
      return
    }

    const points = this.pointsValue
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    const globe = Globe()
      .width(this.element.clientWidth)
      .height(this.element.clientWidth) // square viewport, easiest for a globe
      .backgroundColor("rgba(0,0,0,0)")
      .showAtmosphere(true)
      .atmosphereColor(this.readCssColor("--color-primary", "#6d5efc"))
      .atmosphereAltitude(0.18)
      .globeImageUrl("https://unpkg.com/three-globe/example/img/earth-dark.jpg")
      .htmlElementsData(points)
      .htmlLat("lat")
      .htmlLng("lng")
      .htmlAltitude(0.02)
      .htmlElement((point) => this.buildPin(point))

    globe(this.element)

    const controls = globe.controls()
    controls.enableZoom = false
    controls.autoRotate = !reducedMotion
    controls.autoRotateSpeed = 0.6

    globe.pointOfView({ lat: 20, lng: 10, altitude: 2.2 }, 0)

    this.globe = globe
    this.resizeObserver = new ResizeObserver(() => {
      globe.width(this.element.clientWidth)
      globe.height(this.element.clientWidth)
    })
    this.resizeObserver.observe(this.element)
  }

  buildPin(point) {
    const wrap = document.createElement("div")
    wrap.className = "landing-globe-pin"
    wrap.title = point.name

    const flag = document.createElement("img")
    flag.className = "landing-globe-pin-flag"
    flag.src = `https://flagcdn.com/24x18/${point.code.toLowerCase()}.png`
    flag.width = 20
    flag.height = 15
    flag.alt = point.code
    flag.loading = "lazy"

    const dot = document.createElement("span")
    dot.className = "landing-globe-pin-dot"

    wrap.appendChild(dot)
    wrap.appendChild(flag)
    return wrap
  }

  readCssColor(variable, fallback) {
    const value = getComputedStyle(document.documentElement).getPropertyValue(variable)
    return value?.trim() || fallback
  }
}
