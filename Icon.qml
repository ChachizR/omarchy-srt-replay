import QtQuick
import QtQuick.Shapes
import "Icons.js" as Icons

// Vector icon from Icons.js, drawn on a 24x24 grid and scaled to `size`.
// Uses Qt's curve renderer for antialiased edges without multisampling.
Item {
  id: root

  property string name: ""
  property color color: "white"
  property real size: 24
  property real strokeWidth: 2

  readonly property var spec: Icons.get(name)

  implicitWidth: size
  implicitHeight: size

  Shape {
    width: 24
    height: 24
    scale: root.size / 24
    transformOrigin: Item.TopLeft
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeColor: root.spec.stroke ? root.color : "transparent"
      strokeWidth: root.strokeWidth
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: root.spec.stroke || "" }
    }

    ShapePath {
      strokeColor: "transparent"
      fillColor: root.spec.fill ? root.color : "transparent"
      PathSvg { path: root.spec.fill || "" }
    }
  }
}
