import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="globe"
//
// Renders a rotating 3D globe (via globe.gl / three.js) using a daylight
// "blue marble" map with terrain relief, so continents, coastlines and
// oceans are clearly readable (the previous near-black texture was not).
// On top of the map:
//   - one pin per country in data-globe-points-value, each showing that
//     country's flag (flagcdn.com) — unchanged from the original design;
//   - "constellation" lights: small glowing dots at the metro hubs in
//     data-globe-lights-value, a few of them softly pulsing, joined to
//     their nearest neighbours by faint animated arcs.
// Decorative — see HomeController#landing_countries / #landing_lights for
// why this isn't backed by live geo-analytics.
//
// Loaded lazily (dynamic import) so the ~150kb three.js dependency never
// blocks the rest of the landing page, and only initialized once the
// globe container actually scrolls into view. Respects
// prefers-reduced-motion by disabling auto-rotate. Falls back silently
// to the <noscript> flag grid (already in the DOM) if the import fails
// for any reason (e.g. offline, ad-blocker) — never throws to the user.
// Textures ship inside the `three-globe` npm package; pinned to the
// version resolved in pnpm-lock.yaml so an upstream change can't swap
// the map out from under us.
const TEXTURE_BASE = "https://unpkg.com/three-globe@2.45.2/example/img"

const LIGHT_COLOR = "#ffe6a3"
const ARC_COLORS = ["rgba(255, 230, 163, 0.05)", "rgba(255, 230, 163, 0.6)"]
const LINK_NEIGHBOURS = 2 // each hub links to its N nearest hubs
const LINK_MAX_DEGREES = 55 // ...but never across an ocean-sized gap

export default class extends Controller {
  static values = { points: Array, lights: Array }

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
    this.resizeObserver?.disconnect()
    this.themeObserver?.disconnect()
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
    const lights = this.lightsValue
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    // A handful of hubs pulse like twinkling stars; staggering the period
    // per hub keeps them from flashing in unison.
    const twinkling = lights
      .filter((_, index) => index % 3 === 0)
      .map((light, index) => ({ ...light, period: 1800 + (index % 5) * 450 }))

    const globe = Globe()
      .width(this.element.clientWidth)
      .height(this.element.clientWidth) // square viewport, easiest for a globe
      .backgroundColor("rgba(0,0,0,0)")
      .globeImageUrl(`${TEXTURE_BASE}/earth-blue-marble.jpg`)
      .bumpImageUrl(`${TEXTURE_BASE}/earth-topology.png`)
      .showAtmosphere(true)
      .atmosphereColor(this.atmosphereColor())
      .atmosphereAltitude(0.2)
      // constellation dots
      .pointsData(lights)
      .pointLat("lat")
      .pointLng("lng")
      .pointColor(() => LIGHT_COLOR)
      .pointAltitude(0.006)
      .pointRadius(0.3)
      .pointResolution(8)
      .pointsMerge(true)
      // constellation lines
      .arcsData(this.buildLinks(lights))
      .arcColor(() => ARC_COLORS)
      .arcAltitudeAutoScale(0.22)
      .arcStroke(0.22)
      .arcDashLength(0.4)
      .arcDashGap(0.7)
      .arcDashAnimateTime(reducedMotion ? 0 : 5000)
      // country flag pins (unchanged)
      .htmlElementsData(points)
      .htmlLat("lat")
      .htmlLng("lng")
      .htmlAltitude(0.02)
      .htmlElement((point) => this.buildPin(point))

    if (!reducedMotion) {
      globe
        .ringsData(twinkling)
        .ringLat("lat")
        .ringLng("lng")
        .ringColor(() => (t) => `rgba(255, 230, 163, ${(1 - t) * 0.7})`)
        .ringMaxRadius(2.4)
        .ringPropagationSpeed(1.1)
        .ringRepeatPeriod((light) => light.period)
    }

    globe(this.element)

    // Relief + a gentle lift on the dark oceans so the map never reads as
    // a black disc, whatever the page theme.
    const material = globe.globeMaterial()
    material.bumpScale = 8
    material.emissive?.set("#0d2a55")
    material.emissiveIntensity = 0.35

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

    // Re-tint the atmosphere when the light/dark toggle (or any theme
    // switch) changes data-theme on <html>.
    this.themeObserver = new MutationObserver(() => {
      globe.atmosphereColor(this.atmosphereColor())
    })
    this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
  }

  // Join each hub to its nearest neighbours (deduplicated) so the dots
  // read as a constellation rather than scattered points.
  buildLinks(lights) {
    const seen = new Set()
    const links = []

    lights.forEach((from, i) => {
      lights
        .map((to, j) => ({ to, j, distance: this.angularDistance(from, to) }))
        .filter(({ j, distance }) => j !== i && distance <= LINK_MAX_DEGREES)
        .sort((a, b) => a.distance - b.distance)
        .slice(0, LINK_NEIGHBOURS)
        .forEach(({ to, j }) => {
          const key = i < j ? `${i}-${j}` : `${j}-${i}`
          if (seen.has(key)) { return }
          seen.add(key)
          links.push({ startLat: from.lat, startLng: from.lng, endLat: to.lat, endLng: to.lng })
        })
    })

    return links
  }

  // Great-circle distance in degrees (haversine).
  angularDistance(a, b) {
    const rad = Math.PI / 180
    const dLat = (b.lat - a.lat) * rad
    const dLng = (b.lng - a.lng) * rad
    const h =
      Math.sin(dLat / 2) ** 2 +
      Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2
    return (2 * Math.asin(Math.min(1, Math.sqrt(h)))) / rad
  }

  atmosphereColor() {
    return this.readCssColor("--color-primary", "#6d5efc")
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
