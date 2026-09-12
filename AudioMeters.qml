import QtQuick
import qs.Commons

// Broadcast-style vertical audio meters on a translucent panel: dBFS scale
// (-60..0), green/amber/red zones (-18 alignment, -6 red), LED segments,
// peak-hold markers and a latched clip lamp per channel. Ballistics
// (instant attack, slow fall, hold) are applied by the service.
Item {
  id: root

  // One entry per channel: { level: dBFS, hold: dBFS, clip: bool }.
  property var channels: []
  property bool compact: false

  readonly property real floorDb: -60
  readonly property var marks: compact ? [0, -12, -24, -48] : [0, -6, -12, -18, -24, -36, -48, -60]
  readonly property int channelCount: Math.max(1, channels.length)
  readonly property real barWidth: compact || channelCount > 2 ? 7 : 10
  readonly property real barGap: compact ? 3 : 4
  readonly property real scaleWidth: compact ? 17 : 22
  readonly property real pad: compact ? 6 : 9
  readonly property real labelSize: Math.max(8, Style.font.caption - (compact ? 2 : 1))
  readonly property real segment: compact ? 3 : 4

  function frac(db) { return Math.max(0, Math.min(1, (db - floorDb) / -floorDb)) }
  function zoneColor(db) { return db > -6 ? "#ff453a" : db > -18 ? "#f5c542" : "#34d058" }
  function channelLabel(i) {
    if (channels.length === 1) return "M"
    if (channels.length === 2) return i === 0 ? "L" : "R"
    return String(i + 1)
  }

  implicitWidth: pad * 2 + scaleWidth + channelCount * barWidth + (channelCount - 1) * barGap

  // Zone colours top to bottom; stop positions are 1 - frac(dB) for the
  // fixed -60 dB floor: -6 dB -> 0.1, -18 dB -> 0.3.
  property Gradient zones: Gradient {
    GradientStop { position: 0.0; color: "#ff453a" }
    GradientStop { position: 0.099; color: "#ff453a" }
    GradientStop { position: 0.1; color: "#f5c542" }
    GradientStop { position: 0.299; color: "#f5c542" }
    GradientStop { position: 0.3; color: "#34d058" }
    GradientStop { position: 1.0; color: "#27a146" }
  }

  OverlaySurface {
    anchors.fill: parent
    radius: root.compact ? 8 : 10
    tint: Qt.rgba(0, 0, 0, 0.38)
  }

  Item {
    id: bars
    x: root.pad + root.scaleWidth
    y: root.pad + 8
    width: root.channelCount * root.barWidth + (root.channelCount - 1) * root.barGap
    height: Math.max(20, root.height - y - root.pad - root.labelSize - 6)

    Repeater {
      model: root.channelCount

      delegate: Item {
        id: bar
        required property int index
        readonly property var ch: root.channels[index] || ({ level: root.floorDb, hold: root.floorDb, clip: false })

        x: index * (root.barWidth + root.barGap)
        width: root.barWidth
        height: bars.height

        // Unlit zones show the scale colours dimly, broadcast-meter style.
        Rectangle {
          anchors.fill: parent
          radius: 1.5
          gradient: root.zones
          opacity: 0.16
        }

        Item {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.round(parent.height * root.frac(bar.ch.level))
          clip: true

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: bars.height
            radius: 1.5
            gradient: root.zones
          }
        }

        // LED segment gaps.
        Repeater {
          model: Math.floor(bars.height / root.segment)
          delegate: Rectangle {
            required property int index
            y: bars.height - (index + 1) * root.segment
            width: bar.width
            height: 1
            color: Qt.rgba(0, 0, 0, 0.45)
          }
        }

        Rectangle {
          visible: bar.ch.hold > root.floorDb + 0.5
          y: Math.round((1 - root.frac(bar.ch.hold)) * parent.height) - 1
          width: parent.width
          height: 2
          color: root.zoneColor(bar.ch.hold)
        }

        Rectangle {
          y: -7
          width: parent.width
          height: 4
          radius: 1
          color: bar.ch.clip ? "#ff453a" : Qt.rgba(1, 1, 1, 0.14)
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          y: parent.height + 4
          text: root.channelLabel(bar.index)
          color: Qt.rgba(1, 1, 1, 0.7)
          font.family: Style.font.family
          font.pixelSize: root.labelSize
          font.bold: true
        }
      }
    }
  }

  // dBFS scale with ticks.
  Repeater {
    model: root.marks

    delegate: Item {
      required property var modelData
      x: root.pad
      y: bars.y + Math.round((1 - root.frac(modelData)) * bars.height)
      width: root.scaleWidth

      Text {
        anchors.right: parent.right
        anchors.rightMargin: 5
        anchors.verticalCenter: parent.top
        text: String(modelData)
        color: modelData === -18 ? Qt.rgba(1, 1, 1, 0.85) : Qt.rgba(1, 1, 1, 0.55)
        font.family: Style.font.family
        font.pixelSize: root.labelSize
      }

      Rectangle {
        anchors.right: parent.right
        anchors.rightMargin: 1
        y: 0
        width: 3
        height: 1
        color: Qt.rgba(1, 1, 1, 0.5)
      }
    }
  }
}
