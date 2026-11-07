import QtQuick
import qs.Ui
import qs.Commons
import "lib/Icons.js" as Icons

// The bar pill: a note, the song's title, and previous / play-pause / next.
// Left click opens the panel, middle click plays or pauses, right click
// skips, the wheel sets the volume (Shift+wheel seeks).
BarWidget {
  id: root
  moduleName: "stojshic.omatube"

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("stojshic.omatube") : null

  // The service reads its settings from this widget's shell.json entry,
  // and saves new ones back through the shell's plugin API.
  function pushSettings() {
    if (!root.svc) return
    if (typeof root.svc.adoptSettings === "function") root.svc.adoptSettings(root.settings)
    else root.svc.settings = root.settings
    root.svc.shell = root.bar ? root.bar.shell : null
  }
  onSvcChanged: { pushSettings(); injectPanel() }
  onSettingsChanged: { pushSettings(); injectPanel() }
  onBarChanged: { pushSettings(); injectPanel() }
  Component.onCompleted: pushSettings()

  // ---- the shape Bar.findPanelWidget expects (shell summon/hide/toggle)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var p = panelLoader.item
    if (!p) return
    p.bar = root.bar
    p.settings = root.settings
    p.anchorItem = root
    p.hostWidget = root
    p.svc = root.svc
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  readonly property bool hasTrack: svc ? svc.hasTrack : false
  readonly property bool playing: svc ? svc.isPlaying : false
  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property real maxLabelWidth: Number(root.setting("maxLabelWidth", 160)) || 160

  implicitWidth: body.implicitWidth + Style.space(10)
  implicitHeight: barSize

  Row {
    id: body
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: noteIcon
      anchors.verticalCenter: parent.verticalCenter
      text: Icons.note
      color: root.playing ? Color.accent : root.fg
      opacity: root.hasTrack ? 1 : 0.6
      font.family: root.family
      font.pixelSize: Style.font.icon
    }

    Text {
      id: labelText
      visible: root.hasTrack && !root.vertical
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(root.maxLabelWidth, implicitWidth)
      text: root.svc ? root.svc.title : ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.fg
      font.family: root.family
      font.pixelSize: Style.font.body
    }

    Row {
      visible: root.hasTrack && !root.vertical
      anchors.verticalCenter: parent.verticalCenter
      BarIconButton {
        bar: root.bar
        text: Icons.previous
        tooltipText: "Previous"
        slotSize: Math.round(Style.bar.iconSlot * 0.85)
        onPressed: function (b) { if (b === Qt.LeftButton && root.svc) root.svc.previous() }
      }
      BarIconButton {
        bar: root.bar
        text: root.playing ? Icons.pause : Icons.play
        tooltipText: root.playing ? "Pause" : "Play"
        slotSize: Math.round(Style.bar.iconSlot * 0.85)
        onPressed: function (b) { if (b === Qt.LeftButton && root.svc) root.svc.togglePlaying() }
      }
      BarIconButton {
        bar: root.bar
        text: Icons.next
        tooltipText: "Next"
        slotSize: Math.round(Style.bar.iconSlot * 0.85)
        onPressed: function (b) { if (b === Qt.LeftButton && root.svc) root.svc.next() }
      }
    }
  }

  // Clicks and wheel on the note and the title (the buttons take their own).
  MouseArea {
    x: body.x
    width: noteIcon.width + (labelText.visible ? labelText.width + body.spacing : 0) + Style.space(5)
    height: parent.height
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    property real wheelAcc: 0

    onClicked: function (mouse) {
      if (mouse.button === Qt.MiddleButton) { if (root.svc) root.svc.togglePlaying() }
      else if (mouse.button === Qt.RightButton) { if (root.svc) root.svc.next() }
      else root.toggle()
    }
    onWheel: function (wheel) {
      if (!root.svc || !root.hasTrack) return
      var w = Util.wheelSteps(wheelAcc, wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x)
      wheelAcc = w.remainder
      if (w.steps === 0) return
      if (wheel.modifiers & Qt.ShiftModifier) root.svc.seekBy(w.steps * 5)
      else root.svc.nudgeVolume(w.steps)
    }
    onEntered: {
      if (!root.bar) return
      var s = root.svc
      root.bar.showTooltip(root, s && s.hasTrack
        ? s.title + "\nvolume " + s.volume + "%"
        : "OmaTube: nothing playing. Click to search.")
    }
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
