import QtQuick
import qs.Commons

// Icon-only tap target: a single glyph (⇅, ✕, ⏱, ...) with an enlarged
// invisible hit area, no hover/underline state. For a plain clickable
// label with hover feedback, use TextLink instead.
Text {
  id: iconText

  property real hitMargin: Style.space(6)
  signal activated()

  textFormat: Text.PlainText

  MouseArea {
    anchors.fill: parent
    anchors.margins: -iconText.hitMargin
    cursorShape: Qt.PointingHandCursor
    onClicked: iconText.activated()
  }
}
