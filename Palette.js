.pragma library

// Pastel swatches for desktop lists. "theme" is not listed here: it means
// "follow the active Omarchy theme" and is resolved by the card itself.
// Soft, low-saturation tones so any wallpaper/theme combination stays calm.
// "night" is the dark-theme paper: the same hue, deep and muted, with the
// pastel itself used as ink.
var SWATCHES = [
  { id: "rose",     color: "#f2c4ce", night: "#3b2a2f" },
  { id: "peach",    color: "#f6d3b3", night: "#3d3026" },
  { id: "butter",   color: "#f3e6a8", night: "#38341f" },
  { id: "mint",     color: "#c3e5cc", night: "#24352a" },
  { id: "sky",      color: "#bfdaee", night: "#22303c" },
  { id: "lavender", color: "#d6cbef", night: "#2e2a3d" },
  { id: "stone",    color: "#dcd7cf", night: "#33312d" }
]

function find(id) {
  for (var i = 0; i < SWATCHES.length; i++)
    if (SWATCHES[i].id === id) return SWATCHES[i]
  return null
}
