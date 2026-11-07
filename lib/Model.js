.pragma library

// Global hotkeys: registered at runtime with `hyprctl eval`, only into keys
// nobody else holds (see freeKeys). A Hyprland config reload wipes runtime
// binds, so Service.qml re-registers on Hyprland's "configreloaded" event.
//
// Each action's key is user-configurable (see Options.qml); its modifier
// combo defaults to Super+Ctrl+Alt but a capture can widen or narrow it.
// `description` is the one thing that must never change per action: it is
// how unbindLua recognizes a bind as ours regardless of which key it was
// last registered under, so a remap always clears the *old* key too.
var PLUGIN_ID = "stojshic.omatube"

// Bit values match Hyprland's own modmask (as reported by `hyprctl -j binds`),
// so a captured combo round-trips exactly between settings and Hyprland.
var MOD_BITS = [
  { bit: 64, name: "SUPER" },
  { bit: 4, name: "CTRL" },
  { bit: 8, name: "ALT" },
  { bit: 1, name: "SHIFT" }
]
var DEFAULT_MODS = 76 // SUPER + CTRL + ALT

var HOTKEY_ACTIONS = [
  { action: "toggle", label: "Open / close", defaultKey: "O", command: "toggle", description: "OmaTube: open or close" },
  { action: "playPause", label: "Play / pause", defaultKey: "P", command: "playPause", description: "OmaTube: play or pause" },
  { action: "next", label: "Next song", defaultKey: "N", command: "next", description: "OmaTube: next song" },
  { action: "previous", label: "Previous song", defaultKey: "V", command: "previous", description: "OmaTube: previous song" },
  { action: "stop", label: "Stop and quit", defaultKey: "S", command: "stop", description: "OmaTube: stop and quit" }
]

function modsToKeys(mods, key) {
  var names = []
  for (var i = 0; i < MOD_BITS.length; i++) if (mods & MOD_BITS[i].bit) names.push(MOD_BITS[i].name)
  names.push(String(key || "").toUpperCase())
  return names.join(" + ")
}

// Builds the live 5-entry bind list from the "hotkeys" setting (sparse: only
// actions the user remapped carry an entry), falling back to each action's
// own default otherwise.
function globalKeys(hotkeys) {
  var h = hotkeys || {}
  return HOTKEY_ACTIONS.map(function (a) {
    var custom = h[a.action]
    var mods = custom && typeof custom.mods === "number" ? custom.mods : DEFAULT_MODS
    var key = custom && custom.key ? String(custom.key).toUpperCase() : a.defaultKey
    return {
      action: a.action,
      label: a.label,
      mods: mods,
      key: key,
      keys: modsToKeys(mods, key),
      command: a.command,
      description: a.description,
      custom: !!custom
    }
  })
}

// Our keys that nobody else holds, from `hyprctl -j binds`.
function freeKeys(bindsJson, hotkeys) {
  var binds = []
  try { binds = JSON.parse(bindsJson || "[]") } catch (e) { return [] }
  var taken = {}
  for (var i = 0; i < binds.length; i++) {
    var b = binds[i]
    if (!b || String(b.description || "").indexOf("OmaTube:") === 0) continue
    taken[(b.modmask | 0) + ":" + String(b.key || "").toUpperCase()] = true
  }
  return globalKeys(hotkeys).filter(function (k) { return !taken[k.mods + ":" + k.key] })
}

// Lua for `hyprctl eval`: our binds, removed first so a reload or a second
// call never stacks them.
function bindLua(entries, shellBin) {
  var bin = shellBin || "/usr/share/omarchy/bin/omarchy-shell"
  var lua = ""
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var cmd = e.command === "toggle"
      ? bin + " shell toggle " + PLUGIN_ID + " '{}'"
      : bin + " " + PLUGIN_ID + " " + e.command
    lua += "pcall(hl.unbind, [[" + e.keys + "]]); "
    lua += "hl.bind([[" + e.keys + "]], hl.dsp.exec_cmd([[" + cmd + "]]), { description = [[" + e.description + "]] }); "
  }
  return lua
}

// Unbinds whatever Hyprland actually has registered for our actions right
// now, read from its own JSON rather than recomputed from current settings.
// Matched by description, which stays fixed across a remap: this is what
// lets a hotkey that was just changed to a new key still have its *old* key
// combo removed, instead of leaving an orphaned bind behind.
function unbindLua(bindsJson) {
  var binds = []
  try { binds = JSON.parse(bindsJson || "[]") } catch (e) { return "" }
  var known = {}
  for (var i = 0; i < HOTKEY_ACTIONS.length; i++) known[HOTKEY_ACTIONS[i].description] = true
  var lua = ""
  for (var j = 0; j < binds.length; j++) {
    var b = binds[j]
    if (!b || !known[String(b.description || "")]) continue
    lua += "pcall(hl.unbind, [[" + modsToKeys(b.modmask | 0, b.key) + "]]); "
  }
  return lua
}

// One write path for every setting: shell.json stays the only place they
// live, so Omarchy's own settings UI (built from manifest.json's schema)
// edits the same values this plugin's own Options view does.
function mergePendingSettings(incoming, pending) {
  var settings = Object.assign({}, incoming || {})
  var left = {}
  for (var k in pending) {
    if (JSON.stringify(settings[k]) === JSON.stringify(pending[k])) continue
    settings[k] = pending[k]
    left[k] = pending[k]
  }
  return { settings: settings, pending: left }
}
