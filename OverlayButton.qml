import QtQuick
import qs.Commons

// Round translucent overlay button with hover/press feedback and a tooltip.
// `icon` names a vector icon from Icons.js; custom content goes in the
// default slot.
Item {
  id: root

  property string icon: ""
  property real iconSize: Math.round(height * 0.44)
  property color iconColor: "white"
  property bool checked: false
  property color tint: Qt.rgba(0, 0, 0, 0.45)
  property color checkedTint: Qt.rgba(1, 1, 1, 0.28)
  property string tooltip: ""
  property real radius: height / 2
  default property alias content: contentHolder.data

  readonly property alias hovered: mouse.containsMouse
  readonly property alias pressed: mouse.pressed

  signal clicked()
  signal wheelMoved(real delta)

  implicitWidth: 46
  implicitHeight: 46

  property real hoverAmount: mouse.containsMouse ? 1 : 0
  Behavior on hoverAmount { NumberAnimation { duration: 140 } }

  scale: mouse.pressed ? 0.92 : 1.0
  Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

  OverlaySurface {
    anchors.fill: parent
    radius: root.radius
    hover: root.hoverAmount
    press: mouse.pressed ? 1 : 0
    tint: root.checked ? root.checkedTint : root.tint
  }

  Icon {
    anchors.centerIn: parent
    visible: root.icon !== ""
    name: root.icon
    color: root.iconColor
    size: root.iconSize
  }

  Item {
    id: contentHolder
    anchors.fill: parent
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
    onWheel: function(wheel) { root.wheelMoved(wheel.angleDelta.y) }
  }

  Timer {
    id: tipDelay
    interval: 550
    running: mouse.containsMouse && root.tooltip !== ""
  }

  Item {
    readonly property bool shown: mouse.containsMouse && !tipDelay.running && root.tooltip !== ""
    width: tipText.implicitWidth + 18
    height: tipText.implicitHeight + 10
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.mapToItem(null, 0, 0).y > height + 12 ? -height - 8 : root.height + 8
    opacity: shown ? 1 : 0
    visible: opacity > 0
    z: 10
    Behavior on opacity { NumberAnimation { duration: 120 } }

    OverlaySurface {
      anchors.fill: parent
      tint: Qt.rgba(0, 0, 0, 0.7)
    }

    Text {
      id: tipText
      anchors.centerIn: parent
      text: root.tooltip
      color: "white"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
