import QtQuick
import QtMultimedia
import qs.Commons

// The video surface with its translucent overlay controls and stats HUD.
// Used twice: docked inside the bar popup, and inside the pop-out
// FloatingWindow.
FocusScope {
  id: root

  property var service: null
  property bool floating: false
  property var hostWindow: null
  // Docked views claim the player only while their popup is open.
  property bool claimOutput: floating

  readonly property alias videoOutput: video
  readonly property var s: service
  readonly property bool live: s ? s.status === "live" : false
  readonly property bool compact: width < 520
  readonly property real buttonSize: compact ? 38 : 46
  readonly property string textFont: Style.font.family

  property bool pointerActive: true
  readonly property bool controlsShown: !live || !s.wantPlay || pointerActive || s.keepControls
    || controlHover.hovered || topHover.hovered || statsHover.hovered

  // Show the controls briefly whenever playback goes live, then let them hide
  // even if the pointer never touches the player.
  onLiveChanged: if (live) poke()

  function registerOutput() {
    if (!s || floating) return
    if (claimOutput) s.dockOutput = video
    else if (s.dockOutput === video) s.dockOutput = null
  }

  onClaimOutputChanged: registerOutput()
  onServiceChanged: registerOutput()
  Component.onCompleted: {
    registerOutput()
    poke()
  }
  Component.onDestruction: if (s && s.dockOutput === video) s.dockOutput = null

  function poke() {
    root.pointerActive = true
    idle.restart()
  }

  Timer {
    id: idle
    interval: 2600
    onTriggered: root.pointerActive = false
  }

  // ------------------------------------------------------------ stage
  Rectangle {
    id: stage
    anchors.fill: parent
    color: "#050506"

    Item {
      id: frame
      readonly property real aspect: video.sourceRect.width > 0 && video.sourceRect.height > 0
        ? video.sourceRect.width / video.sourceRect.height : 16 / 9
      width: Math.min(parent.width, parent.height * aspect)
      height: width / aspect
      anchors.centerIn: parent

      VideoOutput {
        id: video
        anchors.fill: parent
        fillMode: VideoOutput.Stretch
      }

      Image {
        anchors.fill: parent
        source: root.s ? root.s.frozenFrame : ""
        visible: source.toString() !== ""
        fillMode: Image.Stretch
      }
    }

    Column {
      anchors.centerIn: parent
      spacing: 10
      visible: !root.live
      width: parent.width - 40

      Icon {
        anchors.horizontalCenter: parent.horizontalCenter
        name: !root.s || root.s.status === "idle" ? "broadcast-off" : root.s.status === "error" ? "alert" : "broadcast"
        color: root.s && root.s.status === "error" ? "#ff6b6b" : Qt.rgba(1, 1, 1, 0.55)
        size: root.compact ? 34 : 52
        SequentialAnimation on opacity {
          running: root.s && root.s.status === "waiting"
          loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
        }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: !root.s ? "" : root.s.status === "idle" ? "SRT is off"
          : root.s.status === "error" ? root.s.error
          : root.s.status === "stalled" ? "Connected, but no data is arriving"
          : root.s.mode === "caller" ? "Connecting…" : "Waiting for a sender"
        color: "white"
        font.family: root.textFont
        font.pixelSize: root.compact ? Style.font.subtitle : Style.font.heading
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        visible: root.s && root.s.active && !root.live
        text: root.s ? root.s.endpoint : ""
        color: Qt.rgba(1, 1, 1, 0.6)
        font.family: root.textFont
        font.pixelSize: Style.font.body
      }
    }
  }

  // ------------------------------------------------------------ pointer
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: root.floating && root.s && root.s.fullscreen && !root.controlsShown
      ? Qt.BlankCursor : Qt.ArrowCursor
    onPositionChanged: root.poke()
    onEntered: root.poke()
    onExited: root.pointerActive = false
    onPressed: {
      root.forceActiveFocus()
      if (root.floating && root.hostWindow && !(root.s && root.s.fullscreen))
        root.hostWindow.startSystemMove()
    }
    onDoubleClicked: if (root.s) root.s.toggleFullscreen()
  }

  Rectangle {
    id: flash
    anchors.fill: parent
    color: "white"
    opacity: 0
    NumberAnimation on opacity { id: flashAnim; running: false; from: 0.55; to: 0; duration: 380; easing.type: Easing.OutQuad }
  }

  Connections {
    target: root.s
    function onSnapshotTaken() { if (root.visible && (root.floating ? root.s.poppedOut : !root.s.poppedOut)) flashAnim.restart() }
  }

  // ------------------------------------------------------------ audio meters
  // Monitoring, not a control: stays up while the overlay auto-hides.
  AudioMeters {
    // Appears once the first audio window has been measured.
    visible: root.s && root.s.showMeters && root.s.active && root.s.meterChannels.length > 0
    channels: root.s ? root.s.meterChannels : []
    compact: root.compact
    width: implicitWidth
    anchors.left: parent.left
    anchors.leftMargin: root.compact ? 10 : 16
    anchors.top: parent.top
    anchors.topMargin: root.compact ? 44 : 56
    anchors.bottom: parent.bottom
    anchors.bottomMargin: root.compact ? 10 : 16
  }

  // ------------------------------------------------------------ overlay
  Item {
    id: overlay
    anchors.fill: parent
    anchors.margins: root.compact ? 10 : 16
    opacity: root.controlsShown ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    // Status + recording chips, top-left.
    Row {
      spacing: 8
      anchors.left: parent.left
      anchors.top: parent.top

      Item {
        width: statusRow.implicitWidth + 22
        height: root.compact ? 26 : 30

        OverlaySurface {
          anchors.fill: parent
        }

        Row {
          id: statusRow
          anchors.centerIn: parent
          spacing: 7

          Rectangle {
            width: 8; height: 8; radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: !root.s ? "#888" : root.s.status === "live" ? "#34d058"
              : root.s.status === "waiting" || root.s.status === "stalled" ? "#f5a524"
              : root.s.status === "error" ? "#ff453a" : "#8e8e93"
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: !root.s ? "" : root.s.status === "live"
              ? "LIVE" + (root.s.resolution ? "  " + root.s.resolution : "")
              : root.s.status === "waiting" ? (root.s.mode === "caller" ? "CALLING " : "WAITING :") + (root.s.mode === "caller" ? root.s.callerHost + ":" + root.s.port : root.s.port)
              : root.s.status.toUpperCase()
            color: "white"
            font.family: root.textFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 0.6
          }
        }
      }

      Item {
        visible: root.s && root.s.recordArmed
        width: recRow.implicitWidth + 22
        height: root.compact ? 26 : 30

        OverlaySurface {
          anchors.fill: parent
          tint: Qt.rgba(0.45, 0.04, 0.04, 0.55)
        }

        Row {
          id: recRow
          anchors.centerIn: parent
          spacing: 7

          Rectangle {
            width: 8; height: 8; radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: "#ff453a"
            SequentialAnimation on opacity {
              running: root.s && root.s.recording
              loops: Animation.Infinite
              NumberAnimation { to: 0.25; duration: 650 }
              NumberAnimation { to: 1.0; duration: 650 }
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.s && root.s.recording ? "REC " + root.s.formatDuration(root.s.recordSeconds) : "REC ARMED"
            color: "white"
            font.family: root.textFont
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }

    // Window controls, top-right.
    Row {
      id: topRow
      spacing: 8
      anchors.right: parent.right
      anchors.top: parent.top

      HoverHandler { id: topHover }

      OverlayButton {
        width: root.buttonSize * 0.8; height: width
        icon: "meters"
        checked: root.s && root.s.showMeters
        tooltip: "Audio meters (V)"
        onClicked: root.s.toggleMeters()
      }

      OverlayButton {
        width: root.buttonSize * 0.8; height: width
        icon: "stats"
        checked: root.s && root.s.showStats
        tooltip: "Stats (I)"
        onClicked: root.s.toggleStats()
      }

      OverlayButton {
        visible: root.floating
        width: root.buttonSize * 0.8; height: width
        icon: root.s && root.s.pinned ? "pin" : "pin-off"
        checked: root.s && root.s.pinned
        tooltip: root.s && root.s.pinned ? "Unpin from all workspaces" : "Pin to all workspaces"
        onClicked: root.s.togglePin()
      }

      OverlayButton {
        width: root.buttonSize * 0.8; height: width
        icon: root.floating ? "dock" : "pop-out"
        tooltip: root.floating ? "Dock back into the panel" : "Pop out"
        onClicked: root.floating ? root.s.dock() : root.s.popOut()
      }
    }

    // Stats HUD.
    Item {
      visible: root.s && root.s.showStats
      anchors.right: parent.right
      anchors.top: topRow.bottom
      anchors.topMargin: 10
      width: statsGrid.implicitWidth + 28
      height: statsGrid.implicitHeight + 22

      HoverHandler { id: statsHover }

      OverlaySurface {
        anchors.fill: parent
        radius: 12
        tint: Qt.rgba(0, 0, 0, 0.6)
      }

      Column {
        id: statsGrid
        anchors.centerIn: parent
        width: root.compact ? 196 : 236
        spacing: 3

        Repeater {
          model: !root.s ? [] : [
            ["Video", [root.s.videoCodec, root.s.resolution].join(" ").trim() || "—"],
            ["Frame rate", root.s.fps ? root.s.fps + " fps" : "—"],
            ["Decode / render", root.s.connected ? root.s.decodeFps + " / " + root.s.renderFps + " fps" : "—"],
            ["Hitches", String(root.s.hitches)],
            ["Audio", root.s.audioInfo || "—"],
            ["Bitrate", root.s.connected ? root.s.mbps.toFixed(2) + " Mb/s" : "—"],
            ["RTT", root.s.connected ? root.s.rttMs.toFixed(1) + " ms" : "—"],
            ["Lost / dropped", root.s.lostTotal + " / " + root.s.dropTotal],
            ["Buffer", root.s.connected ? Math.round(root.s.bufMs) + " / " + Math.round(root.s.tsbpdMs) + " ms" : "—"],
            ["Session", root.s.connected ? root.s.formatDuration(root.s.sessionSeconds) : "—"],
            ["Mode", root.s.mode + " :" + root.s.port + " · " + root.s.latency + " ms"]
          ]

          delegate: Item {
            required property var modelData
            width: statsGrid.width
            height: statLabel.implicitHeight

            Text {
              id: statLabel
              anchors.left: parent.left
              text: parent.modelData[0]
              color: Qt.rgba(1, 1, 1, 0.6)
              font.family: root.textFont
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              anchors.left: statLabel.right
              anchors.leftMargin: 12
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideLeft
              text: parent.modelData[1]
              color: "white"
              font.family: root.textFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
      }
    }

    // Transport, bottom-centre.
    Row {
      spacing: root.compact ? 8 : 12
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom

      HoverHandler { id: controlHover }

      OverlayButton {
        width: root.buttonSize; height: width
        anchors.verticalCenter: parent.verticalCenter
        icon: root.s && root.s.active && root.s.wantPlay ? "pause" : "play"
        tooltip: !root.s || !root.s.active ? "Start listening" : root.s.wantPlay ? "Pause preview (Space)" : "Resume live (Space)"
        onClicked: root.s.togglePlay()
      }

      OverlayButton {
        id: recButton
        width: root.buttonSize * 1.2; height: width
        anchors.verticalCenter: parent.verticalCenter
        checked: root.s && root.s.recordArmed
        checkedTint: Qt.rgba(0.6, 0.06, 0.05, 0.55)
        tooltip: root.s && root.s.recordArmed ? "Stop recording (R)" : "Record to MKV (R)"
        onClicked: root.s.toggleRecord()

        Rectangle {
          anchors.centerIn: parent
          readonly property bool armed: root.s && root.s.recordArmed
          width: armed ? recButton.width * 0.32 : recButton.width * 0.38
          height: width
          radius: armed ? width * 0.22 : width / 2
          color: "#ff453a"
          Behavior on width { NumberAnimation { duration: 160 } }
          Behavior on radius { NumberAnimation { duration: 160 } }
        }
      }

      Item {
        id: audioGroup
        width: muteButton.width + (volumeOpen ? volumeTrack.width + 8 : 0)
        height: root.buttonSize
        anchors.verticalCenter: parent.verticalCenter
        readonly property bool volumeOpen: audioHover.hovered || volumeMouse.pressed
        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        HoverHandler { id: audioHover }

        OverlayButton {
          id: muteButton
          width: root.buttonSize; height: width
          icon: !root.s || root.s.muted || root.s.volume === 0 ? "volume-off"
            : root.s.volume < 0.34 ? "volume-low" : root.s.volume < 0.67 ? "volume-mid" : "volume-high"
          checked: root.s && root.s.muted
          tooltip: "Mute (M) · scroll for volume"
          onClicked: root.s.toggleMute()
          onWheelMoved: function(delta) { root.s.setVolume(root.s.volume + (delta > 0 ? 0.05 : -0.05)) }
        }

        Item {
          id: volumeTrack
          width: root.compact ? 84 : 110
          height: 24
          x: muteButton.width + 8
          anchors.verticalCenter: parent.verticalCenter
          opacity: audioGroup.volumeOpen ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 160 } }

          OverlaySurface {
            anchors.fill: parent
          }

          Rectangle {
            x: 5
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height - 10
            radius: height / 2
            width: Math.max(height, (parent.width - 10) * (root.s && !root.s.muted ? root.s.volume : 0))
            color: Qt.rgba(1, 1, 1, 0.85)
          }

          MouseArea {
            id: volumeMouse
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            function setFrom(mx) { root.s.setVolume((mx - 5) / (width - 10)) }
            onPressed: function(mouse) { setFrom(mouse.x) }
            onPositionChanged: function(mouse) { if (pressed) setFrom(mouse.x) }
            onWheel: function(wheel) { root.s.setVolume(root.s.volume + (wheel.angleDelta.y > 0 ? 0.05 : -0.05)) }
          }
        }
      }

      OverlayButton {
        width: root.buttonSize; height: width
        anchors.verticalCenter: parent.verticalCenter
        icon: "camera"
        enabled: root.live
        opacity: enabled ? 1 : 0.45
        tooltip: "Snapshot PNG (S)"
        onClicked: root.s.snapshot()
      }

      OverlayButton {
        width: root.buttonSize; height: width
        anchors.verticalCenter: parent.verticalCenter
        icon: root.s && root.s.fullscreen ? "fullscreen-exit" : "fullscreen"
        tooltip: root.s && root.s.fullscreen ? "Exit fullscreen (F)" : "Fullscreen (F)"
        onClicked: root.s.toggleFullscreen()
      }
    }
  }

  // ------------------------------------------------------------ keys
  Keys.onPressed: function(event) {
    if (!root.s) return
    var handled = true
    switch (event.key) {
    case Qt.Key_Space: root.s.togglePlay(); break
    case Qt.Key_R: root.s.toggleRecord(); break
    case Qt.Key_M: root.s.toggleMute(); break
    case Qt.Key_S: root.s.snapshot(); break
    case Qt.Key_I: root.s.toggleStats(); break
    case Qt.Key_V: root.s.toggleMeters(); break
    case Qt.Key_F: root.s.toggleFullscreen(); break
    case Qt.Key_Up: root.s.setVolume(root.s.volume + 0.05); break
    case Qt.Key_Down: root.s.setVolume(root.s.volume - 0.05); break
    case Qt.Key_Escape:
      if (root.s.fullscreen) root.s.toggleFullscreen()
      else if (root.floating) root.s.dock()
      else handled = false
      break
    default: handled = false
    }
    if (handled) {
      root.poke()
      event.accepted = true
    }
  }
}
