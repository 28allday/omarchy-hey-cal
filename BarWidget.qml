import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the combined HEY panel. Clicking runs the exact same IPC route
// the keybinding uses (omarchy-shell shell toggle …), mirroring how the
// first-party omarchy.menu bar widget summons its panel. Static icon only — no
// polling while the panel is closed, so the bar never hits HEY's API on a timer
// (house convention; an unread badge would have to break it).
BarWidget {
  id: root
  moduleName: "nosignal.hey-cal"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰇮"
    tooltipText: "HEY — mail & agenda"
    foreground: Color.accent
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle nosignal.hey-cal")
    }
  }
}
