import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "lib/Model.js" as Model

// Service.qml — one per shell. Talks to mpv's JSON IPC socket directly for
// everything the player knows (state, controls), and runs the CLI
// (bin/omatube) only for what needs YouTube Music: search, and starting a
// song with its radio. No bridge and no browser: when mpv is not running,
// nothing of OmaTube is.
Item {
  id: root

  // Pushed by the bar widget: the shell's plugin API (settings writes go
  // through it) and this widget's entry in shell.json.
  property var shell: null
  property var settings: ({})
  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  // Settings store: one write path for every setting. shell.json stays the
  // only place they live, so Omarchy's own plugin settings UI (built from
  // manifest.json's schema) edits the same values the Options view does.
  function saveSetting(key, value) {
    var change = {}
    change[key] = value
    root.writeSettings(change)
  }
  function writeSettings(changes) {
    root.pendingSettings = Object.assign({}, root.pendingSettings, changes)
    pendingSettingsTimer.restart()
    var next = Object.assign({}, root.settings, changes)
    root.settings = next
    if (root.shell && typeof root.shell.updateEntryInline === "function") root.shell.updateEntryInline(root.pluginId, next)
  }
  // The bar widget hands its shell.json entry over here (after every change
  // of it). Writes of ours it does not carry yet stay (a stale echo of an
  // earlier write must not undo a later one); after a few seconds whatever
  // shell.json says wins.
  property var pendingSettings: ({})
  function adoptSettings(incoming) {
    var r = Model.mergePendingSettings(incoming, root.pendingSettings)
    root.pendingSettings = r.pending
    root.settings = r.settings
  }
  Timer { id: pendingSettingsTimer; interval: 5000; onTriggered: root.pendingSettings = ({}) }

  readonly property string pluginId: "stojshic.omatube"

  readonly property string cli: Qt.resolvedUrl("bin/omatube").toString().replace(/^file:\/\//, "")
  readonly property string sockPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omatube/mpv.sock"

  // ---- player state, from mpv
  readonly property bool connected: sock !== null && sock.connected
  property bool idle: true
  property bool paused: false
  property string title: ""
  property real position: 0
  property real duration: 0
  property int volume: 100
  property int playlistPos: -1
  property int playlistCount: 0
  readonly property bool hasTrack: connected && !idle && title !== ""
  readonly property bool isPlaying: hasTrack && !paused
  readonly property real progress: duration > 0 ? Math.min(1, position / duration) : 0

  // ---- lookups, from the CLI
  property var queue: []
  property var results: []
  property bool searching: false
  property bool starting: false
  property string lastError: ""

  readonly property var current: playlistPos >= 0 && playlistPos < queue.length ? queue[playlistPos] : null
  readonly property string thumb: current ? current.thumb : ""

  // ------------------------------------------------------------------ mpv socket

  // A new Socket per try: a Quickshell Socket that failed once never
  // connects again (learned in Solfa).
  property var sock: null
  property int triesLeft: 0
  property int nextId: 1
  property var pending: ({})

  function connectSoon(tries) { root.triesLeft = Math.max(root.triesLeft, tries) }

  function retry() {
    if (root.connected) { root.triesLeft = 0; return }
    if (root.sock !== null) root.sock.destroy()
    root.triesLeft--
    root.sock = socketComponent.createObject(root, { path: root.sockPath })
  }

  Timer {
    interval: 400
    repeat: true
    running: root.triesLeft > 0 && !root.connected
    triggeredOnStart: true
    onTriggered: root.retry()
  }

  Component {
    id: socketComponent
    Socket {
      connected: true
      parser: SplitParser { onRead: data => root.onMessage(data) }
    }
  }

  function send(args, callback) {
    if (!root.connected) return
    var id = root.nextId++
    if (callback) root.pending[id] = callback
    root.sock.write(JSON.stringify({ command: args, request_id: id }) + "\n")
    root.sock.flush()
  }

  readonly property var observed: ["idle-active", "pause", "media-title", "duration", "volume", "playlist-pos", "playlist-count"]

  // Watched here, not on the Socket: a Socket declared `connected: true`
  // starts out true, so its own change signal never fires on connect.
  onConnectedChanged: connected ? onConnected() : onDisconnected()

  function onConnected() {
    for (var i = 0; i < observed.length; i++) send(["observe_property", i + 1, observed[i]])
    refreshQueue()
  }

  function onDisconnected() {
    // mpv quit (stop, or it crashed): back to nothing playing.
    root.idle = true
    root.title = ""
    root.position = 0
    root.duration = 0
    root.playlistPos = -1
    root.playlistCount = 0
    root.pending = ({})
  }

  function onMessage(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.event === "property-change") { apply(msg.name, msg.data); return }
    if (msg.request_id !== undefined && root.pending[msg.request_id]) {
      var cb = root.pending[msg.request_id]
      delete root.pending[msg.request_id]
      cb(msg.error === "success", msg.data)
    }
  }

  function apply(name, value) {
    if (name === "idle-active") root.idle = value !== false
    else if (name === "pause") root.paused = value === true
    else if (name === "media-title") root.title = value ? String(value) : ""
    else if (name === "duration") root.duration = Number(value) || 0
    else if (name === "volume") root.volume = Math.round(Number(value) || 0)
    else if (name === "playlist-pos") root.playlistPos = value === null || value === undefined ? -1 : value
    else if (name === "playlist-count") { root.playlistCount = Number(value) || 0; refreshQueue() }
  }

  // The clock: asked once a second while a song plays (observing time-pos
  // would push many times a second).
  Timer {
    interval: 1000
    repeat: true
    running: root.isPlaying
    onTriggered: root.send(["get_property", "time-pos"], function (ok, v) { if (ok) root.position = Number(v) || 0 })
  }

  // ------------------------------------------------------------------ controls

  function togglePlaying() { send(["cycle", "pause"]) }
  function next() { send(["playlist-next", "force"]) }
  function previous() { send(["playlist-prev", "force"]) }
  // A queue row: a jump while mpv runs; while it is off (powered off from
  // the panel), the saved queue is started again from that song.
  function jumpTo(index) {
    if (root.connected) {
      send(["set_property", "playlist-pos", index])
      send(["set_property", "pause", false])
      return
    }
    root.starting = true
    run(["play", "--from-queue", String(index)], function (code, out, err) {
      root.starting = false
      if (code !== 0) { root.lastError = failure(code, err); return }
      connectSoon(10)
    })
  }
  function setVolume(v) { send(["set_property", "volume", Math.max(0, Math.min(100, Math.round(v)))]) }
  function nudgeVolume(steps) { setVolume(root.volume + steps * 5) }
  function seekBy(seconds) { send(["seek", seconds, "relative"]) }
  function stop() { send(["quit"]) }

  // ------------------------------------------------------------------ global keys

  // OmaTube's own shortcuts, registered at runtime and only where the key
  // is free; a Hyprland config reload wipes them, so they come back after
  // one. The last bare program name run through Hyprland's exec (a PATH
  // lookup, sh -c): resolved once, with an absolute fallback so a session
  // without OMARCHY_PATH set still gets an absolute path, never a name.
  readonly property string omarchyShellBin: {
    var p = Quickshell.env("OMARCHY_PATH")
    return p ? (p + "/bin/omarchy-shell") : "/usr/share/omarchy/bin/omarchy-shell"
  }
  readonly property bool wantKeys: root.setting("globalKeys", true)
  // Re-synced whenever any action's key combo changes (Options.qml writes
  // here through saveSetting), not just on enable/disable.
  readonly property string hotkeysJson: JSON.stringify(root.setting("hotkeys", {}))
  property bool keysRegistered: false
  property string lastBindsJson: ""
  onWantKeysChanged: root.syncKeys()
  onHotkeysJsonChanged: root.syncKeys()

  // The plugin can be removed or disabled without warning (Omarchy just
  // destroys this Item): unbind OmaTube's own keys so they are not left
  // dangling in Hyprland's config.
  Component.onDestruction: {
    if (root.keysRegistered && root.lastBindsJson) {
      var off = Model.unbindLua(root.lastBindsJson)
      if (off) Quickshell.execDetached(["/usr/bin/hyprctl", "eval", off])
    }
  }

  // Always clears whatever Hyprland currently has bound for us (by live
  // modmask+key, matched via description — see Model.unbindLua) before
  // binding the current settings back, if wanted. That single order makes
  // enable, disable, and remapping one action's key all the same path: a
  // remap's old key never lingers because unbind reads Hyprland's live
  // state rather than recomputing the old combo from settings.
  Process {
    id: bindsProc
    command: ["/usr/bin/hyprctl", "-j", "binds"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.lastBindsJson = text
        var lua = Model.unbindLua(text)
        if (root.wantKeys) {
          lua += Model.bindLua(Model.freeKeys(text, root.setting("hotkeys", {})), root.omarchyShellBin)
          root.keysRegistered = true
        } else {
          root.keysRegistered = false
        }
        if (lua) Quickshell.execDetached(["/usr/bin/hyprctl", "eval", lua])
      }
    }
  }

  function syncKeys() {
    if (bindsProc.running) return
    bindsProc.running = true
  }

  Timer {
    id: keysTimer
    interval: 400
    onTriggered: root.syncKeys()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") { root.keysRegistered = false; keysTimer.restart() }
    }
  }

  Timer {
    // After the settings arrive from the bar widget.
    interval: 1500
    running: true
    onTriggered: root.syncKeys()
  }

  // ------------------------------------------------------------------ IPC

  IpcHandler {
    target: root.pluginId

    function toggle(): void { if (root.shell) root.shell.toggle(root.pluginId, "{}") }
    function open(): void { if (root.shell) root.shell.summon(root.pluginId, "{}") }
    function close(): void { if (root.shell) root.shell.hide(root.pluginId) }
    function playPause(): void { root.togglePlaying() }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function stop(): void { root.stop() }
  }

  // ------------------------------------------------------------------ the CLI

  Component {
    id: runComponent
    Process {
      id: proc
      property var done: null
      property int code: -1
      property bool exitedFlag: false
      property bool outDone: false
      function finish() {
        if (!exitedFlag || !outDone) return
        if (done) done(code, out.text, err.text)
        proc.destroy()
      }
      stdout: StdioCollector { id: out; onStreamFinished: { proc.outDone = true; proc.finish() } }
      stderr: StdioCollector { id: err }
      onExited: function (exitCode) { proc.code = exitCode; proc.exitedFlag = true; proc.finish() }
    }
  }

  function run(args, done) {
    var p = runComponent.createObject(root, { command: [root.cli].concat(args), done: done })
    p.running = true
  }

  function failure(code, err) {
    var lines = String(err || "").trim().split("\n")
    return lines[lines.length - 1].replace(/^omatube: /, "") || ("exit " + code)
  }

  function search(query) {
    var q = String(query || "").trim()
    if (!q) return
    root.searching = true
    run(["search", "--json", q], function (code, out, err) {
      root.searching = false
      if (code !== 0) { root.lastError = failure(code, err); return }
      try { root.results = JSON.parse(out) } catch (e) { root.lastError = "odd search reply" }
    })
  }

  function play(videoId) {
    if (!videoId) return
    root.starting = true
    run(["play", "--id", videoId], function (code, out, err) {
      root.starting = false
      if (code !== 0) { root.lastError = failure(code, err); return }
      connectSoon(10)
      refreshQueue()
    })
  }

  function refreshQueue() {
    run(["queue", "--json"], function (code, out) {
      if (code !== 0) return
      try { root.queue = JSON.parse(out) } catch (e) { /* keep the old one */ }
    })
  }

  // mpv may already be running (from the CLI, or a shell restart).
  Component.onCompleted: connectSoon(2)
}
