import QtQuick

// Plain translucent surface for the player overlay: a dark, see-through
// rounded panel with a hairline edge. No shaders or backdrop sampling, so it
// costs nothing beyond an ordinary rectangle.
Rectangle {
  id: root

  property real hover: 0
  property real press: 0
  property color tint: Qt.rgba(0, 0, 0, 0.45)

  radius: height / 2
  color: Qt.rgba(tint.r, tint.g, tint.b, Math.min(1, tint.a + 0.12 * hover + 0.1 * press))
  border.width: 1
  border.color: Qt.rgba(1, 1, 1, 0.16 + 0.14 * hover)
}
