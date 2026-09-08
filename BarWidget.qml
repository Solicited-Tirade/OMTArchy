import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "tirade.nyc-subway"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: panelLoader.item && panelLoader.item.barLabel !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  // Without this, the bar's open-panel indicator mark falls back to just
  // 55% of the slot width (Bar.qml's panelIndicatorExtent default) — a
  // visible gap next to a text label this long. Same convention as the
  // built-in clock widget's BarWidget.qml.
  readonly property real openPanelIndicatorWidth: button.labelWidth

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Bumped from the default Style.font.body (12px): the direction arrow
    // and circled route glyph are small/hard to see at the standard bar
    // text size, and there's no way to size or bold just those characters
    // within one plain-text string (see Model.barText) — this raises the
    // whole label a step, to Style.font.title (14px), rather than none of it.
    fontSize: Style.font.title
    text: panelLoader.item ? panelLoader.item.barLabel : ""
    tooltipText: panelLoader.item ? panelLoader.item.tooltipText : ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
