// Bespoke icon set for SRT Replay, drawn on a 24x24 grid.
// Each icon is SVG path data split into a stroked part (round caps/joins)
// and a filled part; both use the icon colour.
.pragma library

var icons = {
  "play":            { fill: "M8 5.5 L18.5 12 L8 18.5 Z", stroke: "M8 5.5 L18.5 12 L8 18.5 Z" },
  "pause":           { fill: "M6.5 5 H10 V19 H6.5 Z M14 5 H17.5 V19 H14 Z" },
  "volume-high":     { fill: "M3.5 9 H7 L12 5 V19 L7 15 H3.5 Z",
                       stroke: "M15.5 9 A4 4 0 0 1 15.5 15 M18.2 6.3 A8 8 0 0 1 18.2 17.7" },
  "volume-mid":      { fill: "M3.5 9 H7 L12 5 V19 L7 15 H3.5 Z",
                       stroke: "M15.5 9 A4 4 0 0 1 15.5 15" },
  "volume-low":      { fill: "M3.5 9 H7 L12 5 V19 L7 15 H3.5 Z",
                       stroke: "M15.2 10.4 A2.2 2.2 0 0 1 15.2 13.6" },
  "volume-off":      { fill: "M3.5 9 H7 L12 5 V19 L7 15 H3.5 Z",
                       stroke: "M15.5 9.5 L20.5 14.5 M20.5 9.5 L15.5 14.5" },
  "camera":          { stroke: "M3.5 8 H7.5 L9 5.5 H15 L16.5 8 H20.5 V18.5 H3.5 Z M8.8 13 A3.2 3.2 0 1 0 15.2 13 A3.2 3.2 0 1 0 8.8 13" },
  "stats":           { stroke: "M5 19 V13 M10 19 V6 M15 19 V10 M20 19 V15" },
  "meters":          { stroke: "M6.5 4 H10 V20 H6.5 Z M14 4 H17.5 V20 H14 Z",
                       fill: "M6.5 11 H10 V20 H6.5 Z M14 7.5 H17.5 V20 H14 Z" },
  "fullscreen":      { stroke: "M4 9 V4 H9 M15 4 H20 V9 M20 15 V20 H15 M9 20 H4 V15" },
  "fullscreen-exit": { stroke: "M9 4 V9 H4 M20 9 H15 V4 M15 20 V15 H20 M4 15 H9 V20" },
  "pin":             { stroke: "M8.5 4 H15.5 M10 4 V9.5 L7 13.5 H17 L14 9.5 V4 M12 13.5 V20" },
  "pin-off":         { stroke: "M8.5 4 H15.5 M10 4 V9.5 L7 13.5 H17 L14 9.5 V4 M12 13.5 V20 M4 4 L20 20" },
  "pop-out":         { stroke: "M18.5 13.5 V19.5 H4.5 V5.5 H10.5 M14 4 H20 V10 M20 4 L11.5 12.5" },
  "dock":            { stroke: "M4 5 H20 V19 H4 Z", fill: "M11.5 11.5 H17.5 V16.5 H11.5 Z" },
  "broadcast":       { fill: "M10.4 12 A1.6 1.6 0 1 0 13.6 12 A1.6 1.6 0 1 0 10.4 12",
                       stroke: "M8.6 8.6 A4.8 4.8 0 0 0 8.6 15.4 M15.4 8.6 A4.8 4.8 0 0 1 15.4 15.4 M5.8 5.8 A8.8 8.8 0 0 0 5.8 18.2 M18.2 5.8 A8.8 8.8 0 0 1 18.2 18.2" },
  "broadcast-off":   { fill: "M10.4 12 A1.6 1.6 0 1 0 13.6 12 A1.6 1.6 0 1 0 10.4 12",
                       stroke: "M8.6 8.6 A4.8 4.8 0 0 0 8.6 15.4 M15.4 8.6 A4.8 4.8 0 0 1 15.4 15.4 M5.8 5.8 A8.8 8.8 0 0 0 5.8 18.2 M18.2 5.8 A8.8 8.8 0 0 1 18.2 18.2 M4 4 L20 20" },
  "alert":           { stroke: "M12 4 L21 19.5 H3 Z M12 10 V14",
                       fill: "M11.1 16.9 A0.9 0.9 0 1 0 12.9 16.9 A0.9 0.9 0 1 0 11.1 16.9" }
}

function get(name) {
  return icons[name] || { stroke: "", fill: "" }
}
