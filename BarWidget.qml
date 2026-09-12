import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Bar button + quick-config panel. The panel hosts the docked player; all
// pipeline state lives in Service.qml so it survives the panel closing.
//   left click   open/close the panel
//   right click  start/stop the SRT listener
//   middle click start/stop recording
BarWidget {
  id: root
  moduleName: "io.github.chachizr.srt-replay"

  readonly property var srt: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property string status: srt ? srt.status : "idle"

  property bool popupOpen: false
  readonly property bool opened: popupOpen

  onPopupOpenChanged: if (popupOpen && srt) srt.refreshLanAddress()

  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }

  // The bar closes the open panel this way when another bar icon's panel
  // opens; KeyboardPanel reads popoutSwitchClosing back off its owner.
  property bool popoutSwitchClosing: false

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  function pushSettings() { if (srt) srt.applySettings(settings) }
  onSettingsChanged: pushSettings()
  onSrtChanged: pushSettings()

  // shell.json entries are replaced wholesale, so write the full settings set.
  function save(patch) {
    var next = {}
    for (var k in settings) if (k !== "id") next[k] = settings[k]
    for (var p in patch) next[p] = patch[p]
    if (srt) srt.applySettings(next)
    if (bar && bar.shell) bar.shell.updateEntryInline(moduleName, next)
  }

  readonly property string tooltip: !srt ? "SRT Replay: service not loaded"
    : "SRT · " + srt.statusText + (srt.recording ? " · REC " + srt.formatDuration(srt.recordSeconds) : "")
      + (srt.hotkeysArmed && srt.hotkeysBound ? " · clip keys 1 2 3 6 active" : "")

  // Keycap colour: dim while armed-but-idle, accent when the keys are live,
  // urgent if Hyprland didn't take them.
  readonly property color keyTint: !srt ? Color.popups.text
    : srt.hotkeysFailed ? Color.urgent
    : srt.hotkeysArmed && srt.hotkeysBound ? Color.accent
    : Qt.darker(Color.popups.text, 1.5)

  function hotkeyFor(seconds) {
    var map = srt ? srt.hotkeyMap : []
    for (var i = 0; i < map.length; i++) if (map[i][1] === seconds) return map[i][0]
    return ""
  }

  // Minimal keycap: the digit in a small rounded outline with a heavier
  // bottom edge.
  component KeyCap: Item {
    id: cap
    property string key: ""
    property color tint: Color.popups.text

    width: Math.round(Style.font.caption * 1.6)
    height: width

    Rectangle {
      anchors.fill: parent
      radius: 3
      color: "transparent"
      border.width: 1
      border.color: cap.tint
    }

    Rectangle {
      x: 2
      y: cap.height - 2
      width: cap.width - 4
      height: 1
      color: cap.tint
    }

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -1
      text: cap.key
      color: cap.tint
      font.family: Style.font.family
      font.pixelSize: Style.font.caption - 1
      font.bold: true
    }
  }

  implicitWidth: indicator.implicitWidth
  implicitHeight: indicator.implicitHeight

  readonly property color iconColor: srt && srt.recording ? "#ff453a"
    : status === "live" ? Color.accent
    : status === "error" ? (bar ? bar.urgent : Color.urgent)
    : status === "idle" ? Qt.darker(bar ? bar.barForeground : Color.foreground, 1.7)
    : (bar ? bar.barForeground : Color.foreground)

  BarIconButton {
    id: indicator
    anchors.fill: parent
    bar: root.bar
    active: true
    activeColor: root.iconColor
    pressable: false
    iconComponent: Component {
      Icon {
        size: Math.min(width, height)
        name: root.status === "idle" ? "broadcast-off" : root.status === "error" ? "alert" : "broadcast"
        color: root.iconColor
      }
    }

    SequentialAnimation on opacity {
      running: root.srt && (root.srt.recording || root.status === "waiting")
      loops: Animation.Infinite
      onRunningChanged: if (!running) indicator.opacity = 1
      NumberAnimation { to: 0.4; duration: 800; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) { if (root.srt) root.srt.toggleActive() }
      else if (mouse.button === Qt.MiddleButton) { if (root.srt) root.srt.toggleRecord() }
      else root.toggle()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(460))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    // Escape closes the panel. Focused text and number fields handle their
    // own keys first, so typing into them is unaffected.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        readonly property color fg: Color.popups.text
        readonly property color dim: Qt.darker(Color.popups.text, 1.5)

        // Header: title, status, master switch.
        Item {
          width: parent.width
          height: Math.max(titleCol.implicitHeight, masterSwitch.implicitHeight)

          Column {
            id: titleCol
            anchors.left: parent.left
            anchors.right: masterSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "SRT Replay"
              color: column.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              text: root.srt ? root.srt.statusText : "Service not loaded"
              color: root.status === "error" ? Color.urgent : column.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          ToggleSwitch {
            id: masterSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.srt ? root.srt.active : false
            busy: root.srt ? root.srt.stopping : false
            enabled: root.srt !== null
            onToggled: root.srt.toggleActive()
          }
        }

        // Docked player, or a placeholder while it's popped out.
        Item {
          width: parent.width
          height: Math.round(width * 9 / 16)

          PlayerView {
            anchors.fill: parent
            visible: root.srt && !root.srt.poppedOut
            service: root.srt
            claimOutput: root.popupOpen && root.srt !== null && !root.srt.poppedOut
          }

          Rectangle {
            anchors.fill: parent
            visible: root.srt && root.srt.poppedOut
            color: Qt.rgba(0, 0, 0, 0.35)
            radius: Style.cornerRadius

            Column {
              anchors.centerIn: parent
              spacing: Style.space(10)

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(8)

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: "pop-out"
                  size: Style.font.title
                  color: column.fg
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Playing in the floating window"
                  color: column.fg
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
              }

              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Dock back here"
                bordered: true
                foreground: column.fg
                onClicked: root.srt.dock()
              }
            }
          }
        }

        // Clip the last N seconds from the replay buffer.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.srt !== null

          Item {
            width: parent.width
            height: clipTitle.implicitHeight

            Text {
              id: clipTitle
              text: "CLIP LAST"
              color: column.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              anchors.right: parent.right
              text: !root.srt ? ""
                : !root.srt.replayEnabled ? "Replay buffer is off"
                : root.srt.clipping ? "Saving clip…"
                : root.srt.replaySeconds > 0 ? root.srt.replaySeconds + " s buffered"
                : root.srt.active ? "Buffer filling…" : "Buffer empty"
              color: column.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            id: clipRow
            width: parent.width
            spacing: Style.space(6)
            enabled: root.srt && root.srt.replayEnabled && root.srt.replaySeconds > 0
            opacity: enabled ? 1 : 0.5

            Repeater {
              model: [10, 20, 30, 60]

              delegate: Button {
                id: clipButton
                required property int modelData
                width: (clipRow.width - clipRow.spacing * 3) / 4
                text: root.srt ? root.srt.clipLabel(modelData) : ""
                bordered: true
                foreground: column.fg
                tooltipText: "Save the last " + (modelData === 60 ? "minute" : modelData + " seconds")
                onClicked: root.srt.clip(modelData)

                KeyCap {
                  visible: root.srt !== null && root.srt.hotkeysEnabled && root.srt.replayEnabled
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  key: root.hotkeyFor(clipButton.modelData)
                  tint: root.keyTint
                }
              }
            }
          }
        }

        // Quick config. The clip hotkeys toggle shares this header row.
        Item {
          width: parent.width
          height: Math.max(connectionTitle.implicitHeight, hotkeySwitch.implicitHeight)

          Text {
            id: connectionTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "CONNECTION"
            color: column.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Text {
            anchors.right: hotkeySwitch.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: "Hotkeys"
            color: column.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          ToggleSwitch {
            id: hotkeySwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // No keyboard cursor in this panel; skip the ring's reserved padding.
            cursorRing: false
            checked: root.srt ? root.srt.hotkeysEnabled : false
            interactive: root.srt !== null && root.srt.replayEnabled
            onToggled: root.save({ clipHotkeys: root.srt.hotkeysEnabled ? "Off" : "On" })
          }
        }

        Row {
          spacing: Style.space(6)
          enabled: root.srt && !root.srt.recordArmed

          Button {
            text: "Listener"
            selected: root.srt && root.srt.mode === "listener"
            bordered: true
            foreground: column.fg
            onClicked: root.save({ mode: "listener" })
          }

          Button {
            text: "Caller"
            selected: root.srt && root.srt.mode === "caller"
            bordered: true
            foreground: column.fg
            onClicked: root.save({ mode: "caller" })
          }
        }

        Row {
          spacing: Style.space(12)
          enabled: root.srt && !root.srt.recordArmed

          NumberField {
            label: "Port"
            from: 1
            to: 65535
            value: root.srt ? root.srt.port : 9000
            foreground: column.fg
            fieldWidth: Style.space(130)
            field.textFromValue: function(v) { return String(v) }
            onModified: function(v) { root.save({ port: v }) }
          }

          NumberField {
            label: "Latency (ms)"
            from: 20
            to: 8000
            stepSize: 10
            value: root.srt ? root.srt.latency : 120
            foreground: column.fg
            fieldWidth: Style.space(130)
            onModified: function(v) { root.save({ latency: v }) }
          }
        }

        TextField {
          width: parent.width
          visible: root.srt && root.srt.mode === "caller"
          enabled: root.srt && !root.srt.recordArmed
          placeholderText: "Remote host or IP (e.g. 203.0.113.10)"
          text: root.srt ? root.srt.callerHost : ""
          foreground: column.fg
          onEditingFinished: if (text.trim() !== (root.srt ? root.srt.callerHost : "")) root.save({ callerHost: text.trim() })
        }

        // Endpoint to hand to the encoder, with copy.
        Item {
          width: parent.width
          height: copyButton.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.right: copyButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideMiddle
            text: !root.srt ? ""
              : root.srt.mode === "caller" ? "Pulls from " + root.srt.endpoint
              : "Send to " + root.srt.endpoint
            color: column.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            id: copyButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Copy"
            tooltipText: "Copy URL"
            foreground: column.fg
            onClicked: if (root.srt) Quickshell.execDetached(["wl-copy", root.srt.endpoint])
          }
        }

        Text {
          width: parent.width
          visible: root.srt && root.srt.recordArmed
          wrapMode: Text.Wrap
          text: "Connection settings are locked while recording."
          color: column.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(6)

          Button {
            text: "Recordings"
            foreground: column.fg
            onClicked: if (root.srt) Quickshell.execDetached(["sh", "-c", "mkdir -p \"$0\" && xdg-open \"$0\"", root.srt.recordDir])
          }

          Button {
            text: "Clips"
            foreground: column.fg
            onClicked: if (root.srt) Quickshell.execDetached(["sh", "-c", "mkdir -p \"$0\" && xdg-open \"$0\"", root.srt.clipDir])
          }

          Button {
            text: "Snapshots"
            foreground: column.fg
            onClicked: if (root.srt) Quickshell.execDetached(["sh", "-c", "mkdir -p \"$0\" && xdg-open \"$0\"", root.srt.snapshotDir])
          }
        }
      }
    }
  }
}
