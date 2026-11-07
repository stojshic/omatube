import QtQuick
import qs.Ui
import qs.Commons
import "lib/Icons.js" as Icons
import "lib/Model.js" as Model

// The Options view: replaces the panel body in Panel.qml's stage, same spot
// as the queue/results list. Only the gear (BrandCorner) and Esc lead here
// and back — no key letter spent on it. Starts with global hotkeys; more
// rows (sign-in, bar icon visibility, ...) land here later.
Item {
  id: root

  property var svc: null
  property color fg: Color.foreground
  property string family: Style.font.family

  signal backRequested()

  readonly property var hotkeys: root.svc ? root.svc.setting("hotkeys", {}) : {}
  readonly property var entries: Model.globalKeys(root.hotkeys)
  readonly property bool keysEnabled: root.svc ? root.svc.setting("globalKeys", true) : true

  // The one row being recorded, by action id; "" when nothing is recording.
  property string recordingAction: ""
  // Set when a captured combo collides with another of this plugin's own
  // shortcuts, so the row can say why nothing was saved.
  property string recordError: ""

  function startRecording(action) {
    root.recordError = ""
    root.recordingAction = action
  }

  function cancelRecording() {
    root.recordingAction = ""
  }

  // Letters and digits only: enough for a memorable combo, and it sidesteps
  // guessing Hyprland's naming for every named key (space, F-keys, ...).
  function qtKeyToName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    return ""
  }

  function applyCapture(action, mods, key) {
    for (var i = 0; i < root.entries.length; i++) {
      var e = root.entries[i]
      if (e.action !== action && e.mods === mods && e.key === key) {
        root.recordError = "Already used by “" + e.label + "”"
        return
      }
    }
    var next = Object.assign({}, root.hotkeys)
    next[action] = { mods: mods, key: key }
    if (root.svc) root.svc.saveSetting("hotkeys", next)
    root.recordingAction = ""
    root.recordError = ""
  }

  function resetOne(action) {
    var next = Object.assign({}, root.hotkeys)
    delete next[action]
    if (root.svc) root.svc.saveSetting("hotkeys", next)
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(14)

    Row {
      width: parent.width
      spacing: Style.space(8)
      Button {
        iconText: Icons.back
        text: "Options"
        foreground: root.fg
        fontFamily: root.family
        leftAlign: true
        onClicked: root.backRequested()
      }
    }

    Toggle {
      width: parent.width
      label: "Global hotkeys"
      description: "Only binds keys nobody else uses. Customize each one below."
      checked: root.keysEnabled
      foreground: root.fg
      fontFamily: root.family
      onClicked: if (root.svc) root.svc.saveSetting("globalKeys", !checked)
    }

    Column {
      width: parent.width
      spacing: Style.space(8)
      opacity: root.keysEnabled ? 1 : 0.4
      enabled: root.keysEnabled

      Repeater {
        model: root.entries
        delegate: Row {
          id: delegateRow
          required property var modelData
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: Style.space(96)
            anchors.verticalCenter: parent.verticalCenter
            text: delegateRow.modelData.label
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.fg
            font.family: root.family
            font.pixelSize: Style.font.body
          }

          Rectangle {
            id: comboBox
            width: Style.space(170)
            height: Style.space(28)
            radius: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            color: Util.alpha(root.fg, root.recordingAction === delegateRow.modelData.action ? 0.16 : 0.08)
            border.width: root.recordingAction === delegateRow.modelData.action ? 1 : 0
            border.color: Color.accent

            Keys.onPressed: function (event) {
              if (root.recordingAction !== delegateRow.modelData.action) return
              event.accepted = true
              if (event.key === Qt.Key_Escape) { root.cancelRecording(); return }
              var name = root.qtKeyToName(event.key)
              if (!name) return
              var mods = 0
              if (event.modifiers & Qt.ShiftModifier) mods |= 1
              if (event.modifiers & Qt.ControlModifier) mods |= 4
              if (event.modifiers & Qt.AltModifier) mods |= 8
              if (event.modifiers & Qt.MetaModifier) mods |= 64
              // Require at least one modifier: a bare letter is never
              // safe to grab as a *global* shortcut.
              if (mods === 0) return
              root.applyCapture(delegateRow.modelData.action, mods, name)
            }

            Text {
              anchors.centerIn: parent
              text: root.recordingAction === delegateRow.modelData.action ? "Press keys… (Esc)" : delegateRow.modelData.keys
              textFormat: Text.PlainText
              elide: Text.ElideRight
              width: parent.width - Style.space(8)
              horizontalAlignment: Text.AlignHCenter
              color: root.fg
              opacity: root.recordingAction === delegateRow.modelData.action ? 0.7 : 1
              font.family: root.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.recordingAction === delegateRow.modelData.action) { root.cancelRecording(); return }
                root.startRecording(delegateRow.modelData.action)
                comboBox.forceActiveFocus()
              }
            }
          }

          Text {
            visible: delegateRow.modelData.custom
            anchors.verticalCenter: parent.verticalCenter
            text: "Reset"
            textFormat: Text.PlainText
            color: root.fg
            opacity: 0.55
            font.family: root.family
            font.pixelSize: Style.font.caption
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.resetOne(delegateRow.modelData.action)
            }
          }
        }
      }

      Text {
        visible: root.recordError !== ""
        width: parent.width
        text: root.recordError
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Color.accent
        font.family: root.family
        font.pixelSize: Style.font.caption
      }
    }

    Toggle {
      width: parent.width
      label: "Sign in"
      description: "Library, likes and personal radio. Coming soon."
      checked: false
      opacity: 0.5
      enabled: false
      foreground: root.fg
      fontFamily: root.family
    }

    Toggle {
      width: parent.width
      label: "Bar icon visibility"
      description: "Hide the OmaTube icon from the bar. Coming soon."
      checked: false
      opacity: 0.5
      enabled: false
      foreground: root.fg
      fontFamily: root.family
    }
  }
}
