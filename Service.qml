import QtQuick
import Quickshell
import Quickshell.Io

// Service.qml — one per shell. Talks to mpv's JSON IPC socket directly for
// everything the player knows (state, controls), and runs the CLI
// (bin/omatube) only for what needs YouTube Music: search, and starting a
// song with its radio. No bridge and no browser: when mpv is not running,
// nothing of OmaTube is.
Item {
  id: root

  property var shell: null
  property var settings: ({})

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
