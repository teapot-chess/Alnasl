// The colour theme, and the compact layout (at the end). Loaded in <head>
// without defer, so the choice is on <html> before the first paint (no flash
// of the wrong theme), and it keeps working
// across LiveView navigations because it listens on the document.
//
// "system" is the absence of a choice: no data-theme attribute, and the
// stylesheet's prefers-color-scheme query picks paper or night. The choice is
// kept in this browser only; without storage the page simply follows the device.

const KEY = "alnasl-theme"
const BUILT_IN = ["paper", "night", "board", "slate", "contrast"]
// The first version had a light/dark switch; its two values still mean something.
const LEGACY = {light: "paper", dark: "night"}

const root = document.documentElement
const read = () => { try { return localStorage.getItem(KEY) } catch (_e) { return null } }
const write = (value) => { try { localStorage.setItem(KEY, value) } catch (_e) { /* private mode */ } }

// Installed theme packs (Alnasl.ThemePacks): {id: {dark, css}}, from the meta
// tag the root layout puts before this script. Data, read with JSON.parse; a
// page without the tag, or with one that does not parse, has no packs.
const packs = {}
try {
  const meta = document.querySelector('meta[name="alnasl-theme-packs"]')
  for (const pack of JSON.parse((meta && meta.content) || "[]")) {
    if (pack && typeof pack.id === "string" && /^[a-z0-9][a-z0-9-]*$/.test(pack.id) &&
        !BUILT_IN.includes(pack.id) && typeof pack.css === "string" && pack.css.startsWith("/themes/")) {
      packs[pack.id] = pack
    }
  }
} catch (_e) { /* no packs, then */ }

// What may reach data-theme. A stored choice is a string in a browser that
// outlives the theme it names - a pack uninstalled, a theme retired - and an
// unknown one falls back to Match device rather than stamping a name on
// <html> that no stylesheet answers to.
const known = (theme) => BUILT_IN.includes(theme) || Object.hasOwn(packs, theme)

const current = () => root.getAttribute("data-theme") || "system"

// A pack's stylesheet is loaded only while it is the theme: one <link>,
// swapped or removed as the choice changes. `blocking` keeps the first paint
// waiting for it where the browser knows the attribute, so a pack does not
// flash in over Paper. `data-theme-dark` is how app.css tells a dark pack from
// a light one without knowing its name.
const applyPack = (theme) => {
  const pack = Object.hasOwn(packs, theme) ? packs[theme] : null
  let link = document.getElementById("alnasl-theme-pack")

  if (pack) {
    if (!link) {
      link = document.createElement("link")
      link.id = "alnasl-theme-pack"
      link.rel = "stylesheet"
      link.setAttribute("blocking", "render")
      document.head.appendChild(link)
    }
    if (link.getAttribute("href") !== pack.css) link.setAttribute("href", pack.css)
  } else if (link) {
    link.remove()
  }

  if (pack && pack.dark) root.setAttribute("data-theme-dark", "")
  else root.removeAttribute("data-theme-dark")
}

const apply = (value) => {
  const theme = LEGACY[value] || value
  const chosen = known(theme) ? theme : null
  applyPack(chosen)
  if (chosen) root.setAttribute("data-theme", chosen)
  else root.removeAttribute("data-theme")
}

// Which option says so, for a screen reader as well as the eye.
const mark = () => {
  const now = current()
  document.querySelectorAll("[data-theme-opt]").forEach((option) => {
    option.setAttribute("aria-pressed", String(option.dataset.themeOpt === now))
  })
}

apply(read())

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-theme-opt]")
  if (!button) return

  const value = button.dataset.themeOpt
  write(value)
  apply(value)
  mark()

  const picker = button.closest("details")
  if (picker) {
    picker.removeAttribute("open")
    const trigger = picker.querySelector("summary")
    if (trigger) trigger.focus()
  }
})

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return
  const open = document.querySelector("details.theme-picker[open]")
  if (open) {
    open.removeAttribute("open")
    open.querySelector("summary")?.focus()
  }
})

// Another tab changed it.
window.addEventListener("storage", (event) => {
  if (event.key === KEY) { apply(event.newValue); mark() }
})

document.addEventListener("DOMContentLoaded", mark)
window.addEventListener("phx:page-loading-stop", mark)

// The compact layout for a small screen (4 to 7 inches: 800x480, 1024x600,
// 720x720). `data-compact` on <html>, before the first paint like the theme,
// so app.css draws the one-bar frame and the smaller tiles from the start.
// Automatic follows the window's size; "on" (Small screen) and "off" (Large
// screen) are for a panel whose pixels do not say how big it is - a 7-inch
// panel with a desktop's resolution. Kept in this browser only, because it
// is about this screen and nobody else's.
const COMPACT_KEY = "alnasl-compact"
const SMALL = window.matchMedia(
  "(max-height: 620px), (max-width: 760px) and (max-height: 760px) and (min-aspect-ratio: 3/4)"
)

const readCompact = () => {
  try { return localStorage.getItem(COMPACT_KEY) } catch (_e) { return null }
}

const compactChoice = () => {
  const stored = readCompact()
  return stored === "on" || stored === "off" ? stored : "auto"
}

const applyCompact = () => {
  const choice = compactChoice()
  const on = choice === "on" || (choice === "auto" && SMALL.matches)
  if (on) root.setAttribute("data-compact", "")
  else root.removeAttribute("data-compact")
}

const markCompact = () => {
  const now = compactChoice()
  document.querySelectorAll("[data-compact-opt]").forEach((option) => {
    option.setAttribute("aria-pressed", String(option.dataset.compactOpt === now))
  })
}

applyCompact()
SMALL.addEventListener("change", applyCompact)

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-compact-opt]")
  if (!button) return

  const value = button.dataset.compactOpt
  try {
    if (value === "on" || value === "off") localStorage.setItem(COMPACT_KEY, value)
    else localStorage.removeItem(COMPACT_KEY)
  } catch (_e) { /* not kept: this page still changes */ }
  if (value === "on") root.setAttribute("data-compact", "")
  else if (value === "off") root.removeAttribute("data-compact")
  else applyCompact()
  markCompact()
})

window.addEventListener("storage", (event) => {
  if (event.key === COMPACT_KEY) { applyCompact(); markCompact() }
})

document.addEventListener("DOMContentLoaded", markCompact)
window.addEventListener("phx:page-loading-stop", markCompact)
