import QtQuick
import qs.Commons
import qs.Commons as Commons

// Underlined-on-hover accent text link: "Change", "Plan a Trip", "Help",
// "Retry", etc. Enlarges its tap target beyond the painted text via a
// configurable hitMargin, since a caption-size word is a small target on
// its own.
Text {
  id: link

  property real hitMargin: Style.space(4)
  signal activated()

  textFormat: Text.PlainText
  color: Commons.Color.accent
  font.underline: linkArea.containsMouse

  MouseArea {
    id: linkArea
    anchors.fill: parent
    anchors.margins: -link.hitMargin
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: link.activated()
  }
}
