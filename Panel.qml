import QtQuick
import qs.Ui
import qs.Commons
import "lib/Icons.js" as Icons

// The panel: now playing (cover, time, controls, volume), a search field,
// and one list below it — the queue, or search results after a search.
// Enter in the field searches; Up/Down + Enter plays a row; Esc goes from
// results back to the queue, then closes.
Panel {
  id: root
  moduleName: "io.github.stojshic.omatube"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var svc: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  property bool showResults: false
  property int cursor: -1
  property string flash: ""
  readonly property var rows: showResults ? (svc ? svc.results : []) : (svc ? svc.queue : [])

  onOpenedChanged: {
    if (!opened) return
    if (svc) { svc.connectSoon(3); svc.refreshQueue() }
    cursor = -1
    Qt.callLater(function () {
      field.forceActiveFocus()
      if (!root.showResults && root.svc && root.svc.playlistPos >= 0) list.positionViewAtIndex(root.svc.playlistPos, ListView.Center)
    })
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function") return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function say(text) { root.flash = text; flashTimer.restart() }
  Timer { id: flashTimer; interval: 3000; onTriggered: root.flash = "" }

  Connections {
    target: root.svc
    function onLastErrorChanged() { if (root.svc.lastError) { root.say(root.svc.lastError); root.svc.lastError = "" } }
    function onResultsChanged() { root.showResults = true; root.cursor = root.svc.results.length ? 0 : -1 }
  }

  function activate(index) {
    var row = rows[index]
    if (!row || !svc) return
    if (showResults) {
      svc.play(row.videoId)
      say("Starting " + row.label + "…")
      showResults = false
    } else {
      svc.jumpTo(index)
    }
  }

  function move(d) {
    if (!rows.length) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + d))
    list.positionViewAtIndex(cursor, ListView.Contain)
    if (field.activeFocus) keys.forceActiveFocus()
  }

  function back() {
    if (showResults) { showResults = false; cursor = -1; field.text = "" }
    else root.close()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: field
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(Style.space(520))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      blocked: field.activeFocus
      onMoveRequested: function (dx, dy) { if (dy !== 0) root.move(dy) }
      onActivateRequested: root.activate(root.cursor)
      onCloseRequested: root.back()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === " ") { if (root.svc) root.svc.togglePlaying() }
        else if (t === "/") field.forceActiveFocus()
      }

      // The app's name, small and quiet, in the top right corner.
      Row {
        id: brand
        anchors.top: parent.top
        anchors.right: parent.right
        z: 1
        spacing: Style.space(4)
        opacity: 0.45
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: Icons.note
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.family
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "OmaTube"
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.family
          font.pixelSize: Style.font.caption
        }
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(10)

        // ---- now playing
        Row {
          width: parent.width
          spacing: Style.space(12)
          Rectangle {
            width: Style.space(72); height: width
            radius: Style.space(8)
            color: Util.alpha(root.fg, 0.08)
            clip: true
            Image {
              anchors.fill: parent
              source: root.svc ? root.svc.thumb : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              visible: status === Image.Ready
            }
            Text {
              anchors.centerIn: parent
              visible: !(root.svc && root.svc.thumb)
              text: Icons.note
              color: root.fg
              opacity: 0.5
              font.family: root.family
              font.pixelSize: Style.font.display
            }
          }
          Column {
            width: parent.width - Style.space(84)
            spacing: Style.space(6)
            Text {
              // Clear of the name in the corner.
              width: parent.width - brand.width - Style.space(8)
              text: root.svc && root.svc.hasTrack ? root.svc.title
                : root.svc && root.svc.starting ? "Starting…" : "Nothing playing — search below"
              elide: Text.ElideRight
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            // progress
            Item {
              width: parent.width
              height: Style.space(14)
              visible: root.svc && root.svc.hasTrack
              Rectangle {
                id: track
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - clockText.width - Style.space(8)
                height: Style.space(4)
                radius: height / 2
                color: Util.alpha(root.fg, 0.15)
                Rectangle {
                  width: parent.width * (root.svc ? root.svc.progress : 0)
                  height: parent.height
                  radius: parent.radius
                  color: Color.accent
                }
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(5)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: function (m) {
                    if (!root.svc || root.svc.duration <= 0) return
                    var target = Math.max(0, Math.min(1, m.x / track.width)) * root.svc.duration
                    root.svc.seekBy(target - root.svc.position)
                  }
                }
              }
              Text {
                id: clockText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.svc ? Icons.clock(root.svc.position) + " / " + Icons.clock(root.svc.duration) : ""
                color: root.fg
                opacity: 0.7
                font.family: root.family
                font.pixelSize: Style.font.caption
              }
            }
            // controls
            Row {
              spacing: Style.space(4)
              visible: root.svc && root.svc.hasTrack
              Repeater {
                model: [
                  { icon: Icons.previous, tip: "Previous", act: "previous" },
                  { icon: root.svc && root.svc.isPlaying ? Icons.pause : Icons.play, tip: "Play/pause (space)", act: "togglePlaying" },
                  { icon: Icons.next, tip: "Next", act: "next" },
                  { icon: Icons.power, tip: "Stop and quit mpv", act: "stop" }
                ]
                delegate: Rectangle {
                  required property var modelData
                  width: Style.space(30); height: width
                  radius: width / 2
                  color: ctl.containsMouse ? Util.alpha(root.fg, 0.12) : "transparent"
                  Text {
                    anchors.centerIn: parent
                    text: modelData.icon
                    color: root.fg
                    font.family: root.family
                    font.pixelSize: Style.font.iconLarge
                  }
                  MouseArea {
                    id: ctl
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.svc) root.svc[modelData.act]()
                  }
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Style.space(8)
                text: Icons.volume + " " + (root.svc ? root.svc.volume : 0) + "%"
                color: root.fg
                opacity: 0.7
                font.family: root.family
                font.pixelSize: Style.font.body
                MouseArea {
                  anchors.fill: parent
                  onWheel: function (w) { if (root.svc) root.svc.nudgeVolume(w.angleDelta.y > 0 ? 1 : -1) }
                }
              }
            }
          }
        }

        // ---- search
        TextField {
          id: field
          width: parent.width
          placeholderText: Icons.search + "  Search YouTube Music  (Enter)"
          foreground: root.fg
          font.family: root.family
          font.pixelSize: Style.font.body
          onAccepted: { if (root.svc) root.svc.search(text) }
          Keys.onEscapePressed: function (e) { root.back(); e.accepted = true }
          Keys.onDownPressed: function (e) { keys.forceActiveFocus(); root.move(1); e.accepted = true }
        }

        Text {
          width: parent.width
          text: root.flash !== "" ? root.flash
            : root.svc && root.svc.searching ? "Searching…"
            : root.showResults ? "Results — Enter plays a song with its radio, Esc back to the queue"
            : root.rows.length && root.svc && !root.svc.connected ? "Queue (player off) — Enter plays from a song"
            : root.rows.length ? "Queue — Enter jumps to a song" : ""
          elide: Text.ElideRight
          color: root.fg
          opacity: 0.6
          font.family: root.family
          font.pixelSize: Style.font.caption
        }

        // ---- the list
        ListView {
          id: list
          width: parent.width
          height: parent.height - y
          clip: true
          model: root.rows
          boundsBehavior: Flickable.StopAtBounds
          delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool playingRow: !root.showResults && root.svc && index === root.svc.playlistPos
            width: list.width
            height: Style.space(30)
            radius: Style.space(6)
            color: index === root.cursor ? Util.alpha(Color.accent, 0.18)
              : rowMouse.containsMouse ? Util.alpha(root.fg, 0.07) : "transparent"
            Text {
              anchors.left: parent.left
              anchors.right: dur.left
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: (playingRow ? Icons.play + " " : "") + modelData.label
              elide: Text.ElideRight
              textFormat: Text.PlainText
              color: playingRow ? Color.accent : root.fg
              font.family: root.family
              font.pixelSize: Style.font.body
              font.bold: playingRow
            }
            Text {
              id: dur
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.seconds ? Icons.clock(modelData.seconds) : ""
              color: root.fg
              opacity: 0.5
              font.family: root.family
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.cursor = index; root.activate(index) }
            }
          }
        }
      }
    }
  }
}
