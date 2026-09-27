.pragma library

// Nerd Font (Material Design) glyphs, the ones Solfa checked are present in
// the Nerd Fonts Omarchy ships.
var play = String.fromCodePoint(0xF040A)
var pause = String.fromCodePoint(0xF03E4)
var next = String.fromCodePoint(0xF04AD)
var previous = String.fromCodePoint(0xF04AE)
var note = String.fromCodePoint(0xF075A)
var volume = String.fromCodePoint(0xF057E)
var search = String.fromCodePoint(0xF0349)
var power = String.fromCodePoint(0xF0425)

function clock(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var m = Math.floor(s / 60)
  var r = s % 60
  return m + ":" + (r < 10 ? "0" : "") + r
}
