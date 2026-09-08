import QtQuick
import qs.Commons
import "Model.js" as Model

// Circular route badge: MTA line color fill, bold route letter/number
// label. Covers this plugin's static (non-interactive) route badges — the
// arrivals list, trip planner, trip detail header, and the all-routes
// "which lines serve this stop" row, including that row's "not currently
// running" blink (crossfades to a warning glyph on blinkPhase rather than
// swapping instantly). The two interactive picker pills (browse-by-line,
// station search results) have hover/selection/click behavior different
// enough from each other and from this to stay inline in Panel.qml rather
// than forcing a shared component with a much larger property surface.
Rectangle {
  id: pill

  // Empty route ("") renders a plain, label-less circle in emptyColor —
  // the trip-detail header badge's "no train selected yet" fallback.
  property string route: ""
  property color emptyColor: "gray"
  property real diameter: Style.space(26)
  property string labelFontFamily: Style.font.family
  property int labelPixelSize: Style.font.bodySmall
  // false dims the badge and enables the blink crossfade below (the
  // all-routes row's "not running right now" state); blinkPhase drives
  // which of the two faces is currently showing.
  property bool running: true
  property bool blinkPhase: false

  width: diameter
  height: diameter
  radius: width / 2
  color: route === "" ? emptyColor : Model.routeColor(route)
  opacity: running ? 1.0 : 0.55

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: pill.route !== ""
    text: pill.route
    color: Model.routeTextColor(pill.route)
    font.family: pill.labelFontFamily
    font.pixelSize: pill.labelPixelSize
    font.bold: true
    opacity: pill.running || !pill.blinkPhase ? 1.0 : 0.0
    Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: pill.route !== "" && !pill.running
    text: "⚠"
    color: Model.routeTextColor(pill.route)
    font.family: pill.labelFontFamily
    font.pixelSize: pill.labelPixelSize
    font.bold: true
    opacity: !pill.running && pill.blinkPhase ? 1.0 : 0.0
    Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }
  }
}
