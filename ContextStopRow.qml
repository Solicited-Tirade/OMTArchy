import QtQuick
import qs.Commons

// One row of the "you are here" context strip: a small dot plus a station
// name, dimmed since it's a neighboring stop rather than the tracked one.
Item {
  id: row

  property string label: ""
  property color dotColor: "gray"
  property color textColor: "gray"
  property string fontFamily: Style.font.family
  property int pixelSize: Style.font.bodySmall
  property real dotDiameter: Style.space(6)

  height: Style.space(28)

  Row {
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    Rectangle {
      width: row.dotDiameter
      height: row.dotDiameter
      radius: width / 2
      color: row.dotColor
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: row.label
      color: row.textColor
      font.family: row.fontFamily
      font.pixelSize: row.pixelSize
    }
  }
}
