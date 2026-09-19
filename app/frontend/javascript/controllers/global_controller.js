import { Controller } from "@hotwired/stimulus"
import { turboStream } from "../utils/helpers"
import { Zealot } from "./zealot"

const DRAWER_OPEN_VALUE = "open"
const DRAWER_CLOSED_VALUE = "closed"

// Per-browser light/dark choice made with the navbar toggle. Overrides the
// account/site appearance until the user saves a new appearance on their
// profile page (see clearStoredAppearance). Also read by the inline script
// in layouts/application.html.slim — keep the key in sync.
const APPEARANCE_STORAGE_KEY = "zealot-appearance"

export default class extends Controller {
  static targets = ["drawer"]
  
  static values = {
    drawerStatusKey: String,
    appearance: String,
    themes: Object
  }

  connect() {
    if (this.isInitialized) { return }

    const documentReadyHandler = this.handleDocumentReady.bind(this)
    document.addEventListener("turbo:load", documentReadyHandler)

    // Initialize drawer state
    this.autoSwitchDrawerByDevice()
    window.addEventListener("resize", this.autoSwitchDrawerByDevice.bind(this))

    this.isInitialized = true
  }

  autoSwitchDrawerByDevice() {
    if (!this.hasDrawerTarget) return
    // Tailwind md: 768px, lg: 1024px
    const width = window.innerWidth
    if (width >= 1024) {
      // width above lg, drawer open
      this.drawerTarget.checked = true
      this.setDrawerStatus(DRAWER_OPEN_VALUE)
    } else {
      // else，drawer close
      this.drawerTarget.checked = false
      this.setDrawerStatus(DRAWER_CLOSED_VALUE)
    }
  }

  previewTheme(event) {
    const theme = event.target.value
    Zealot.log("Previewing theme:", theme)
    if (theme) {
      document.documentElement.setAttribute("data-theme", theme)
    }
  }

  switchAppearanceMode() {
    const appearance = document.documentElement.getAttribute("data-theme")
    if (!appearance) { return }

    this.setZealotThemeMode()
    this.setGoodJobThemeMode()
  }

  setZealotThemeMode() {
    const appearance = this.effectiveAppearance()
    const lightTheme = this.themesValue.light
    const darkTheme = this.themesValue.dark

    Zealot.log(`Fetching theme: ${appearance}, light: ${lightTheme}, dark: ${darkTheme}`)
    let activeTheme = null
    if (appearance === "auto") {
      activeTheme = Zealot.isDarkMode ? darkTheme : lightTheme
    } else if (appearance === "dark") {
      activeTheme = darkTheme
    } else if (appearance === "light") {
      activeTheme = lightTheme
    } 

    if (activeTheme) {
      Zealot.log(`Setting theme to: ${activeTheme}`)
      document.documentElement.setAttribute("data-theme", activeTheme)
      this.syncThemeMode(appearance)
    } else {
      console.log("Unknown appearance mode:", appearance)
    }
  }

  // Navbar light/dark toggle. Flips between the user's configured light
  // and dark themes and remembers the choice in this browser.
  toggleTheme() {
    const nextMode = this.currentMode() === "dark" ? "light" : "dark"

    try {
      localStorage.setItem(APPEARANCE_STORAGE_KEY, nextMode)
    } catch (error) {
      // Storage blocked (private mode etc.): the switch still applies for
      // this page view, it just won't persist.
      Zealot.log("Unable to persist appearance", error)
    }

    this.setZealotThemeMode()
    this.setGoodJobThemeMode()
  }

  // Called when the profile "appearance" form is submitted, so the
  // preference the user just saved isn't shadowed by an older toggle.
  clearStoredAppearance() {
    try {
      localStorage.removeItem(APPEARANCE_STORAGE_KEY)
    } catch (error) {
      Zealot.log("Unable to clear stored appearance", error)
    }
  }

  // The toggle's saved choice if there is one, otherwise the appearance
  // configured for the account / site.
  effectiveAppearance() {
    return this.storedAppearance() || this.appearanceValue
  }

  storedAppearance() {
    try {
      const stored = localStorage.getItem(APPEARANCE_STORAGE_KEY)
      return stored === "light" || stored === "dark" ? stored : null
    } catch (error) {
      return null
    }
  }

  currentMode() {
    const mode = document.documentElement.getAttribute("data-mode")
    if (mode === "light" || mode === "dark") { return mode }

    const appearance = this.effectiveAppearance()
    return appearance === "auto" ? (Zealot.isDarkMode ? "dark" : "light") : appearance
  }

  // Keeps <html data-mode="light|dark"> in step with the applied theme;
  // the navbar toggle's sun/moon icon (layout.css) keys off it.
  syncThemeMode(appearance) {
    const mode = appearance === "auto" ? (Zealot.isDarkMode ? "dark" : "light") : appearance
    document.documentElement.setAttribute("data-mode", mode)
  }

  setGoodJobThemeMode() {
    localStorage.setItem("good_job-theme", this.effectiveAppearance())
  }

  handleDocumentReady() {
    try {
      this.switchAppearanceMode()
    } catch (error) {
      console.error("GlobalController initialization error:", error)
    }
  }

  switchDrawer() {
    const storedStatus = this.getDrawerStatus()
    const isDrawerOpen = storedStatus === DRAWER_OPEN_VALUE
    this.drawerTarget.checked = isDrawerOpen
  }

  storeDrawerStatus() {
    const isDrawerOpen = this.drawerTarget.checked;
    const value = isDrawerOpen ? DRAWER_OPEN_VALUE : DRAWER_CLOSED_VALUE
    this.setDrawerStatus(value)
  }

  setDrawerStatus(value) {
    localStorage.setItem(this.drawerStatusKeyValue, value)
    document.cookie = `${this.drawerStatusKeyValue}=${value}; path=/; max-age=31536000; SameSite=Lax`
  }

  getDrawerStatus() {
    const local = localStorage.getItem(this.drawerStatusKeyValue)
    if (local) { return local }
    
    const cookie = document.cookie
      .split("; ")
      .find((row) => row.startsWith(`${this.drawerStatusKeyValue}=`))
    return cookie ? cookie.split("=")[1] : DRAWER_OPEN_VALUE
  }

  showSponsorModal() {
    turboStream("/modals/sponsor")
  }
} 
