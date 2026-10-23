import QtQuick
import qs.Commons

// One leg of a trip-planner result: a route badge plus a two-line summary
// (a primary line — direction/departure — and a dim secondary line —
// arrival or transfer info).
Row {
  id: legRow

  property string route: ""
  property string primaryText: ""
  property string secondaryText: ""
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  spacing: Style.space(10)

  RoutePill {
    id: legPill
    route: legRow.route
    diameter: Style.space(28)
    labelFontFamily: legRow.fontFamily
    labelPixelSize: Style.font.body
    anchors.verticalCenter: parent.verticalCenter
  }

  Column {
    width: Math.max(0, legRow.width - legPill.width - legRow.spacing)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      text: legRow.primaryText
      color: legRow.foreground
      font.family: legRow.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      text: legRow.secondaryText
      color: legRow.dim
      font.family: legRow.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
