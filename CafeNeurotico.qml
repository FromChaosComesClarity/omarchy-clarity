import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Cafe Neurotico in the bar.
//
// The app is a window you open; this is the part of it that is always there —
// how many games are installed, and whether one is running right now. It only
// watches and pokes, so the bar restarting, the plugin being disabled, or QML
// failing outright costs the icon and nothing else. The library, the launcher
// and every game keep working exactly as before.
//
// ⚠️ The running-game check reads the COMPOSITOR, not the app. Cafe Neurotico
// does not have to be open for a game to be playing — it launches games and
// gets out of the way — so asking the app would give the wrong answer for the
// case this widget exists to show.
BarWidget {
  id: root
  objectName: "cafeNeuroticoWidget"

  readonly property string appimage: setting("appimage", "/home/jose/Games/CNGM/CafeNeurotico.AppImage")
  readonly property string database: setting("database", "/home/jose/.config/grinder/grinder.db")
  readonly property int interval: setting("interval", 3)

  // Qt.resolvedUrl gives a file:// URL; the shell wants a plain path, and the
  // plugin directory is user-named, so the percent-decoding is not optional.
  readonly property string watchScript:
    decodeURIComponent(Qt.resolvedUrl("scripts/cn-watch").toString().replace(/^file:\/\//, ""))

  property int installed: -1        // -1 = not known yet, not "zero games"
  property string playing: ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function apply(raw) {
    var text = String(raw).trim()
    if (text.length === 0) return
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return                        // a partial line is not worth a crash
    }
    // ⚠️ null means "could not read the database", which is not the same as a
    // library with nothing installed. Keeping -1 leaves the label showing the
    // icon alone rather than confidently claiming 0.
    root.installed = (data.installed === null || data.installed === undefined)
      ? -1 : Number(data.installed)
    root.playing = data.playing ? String(data.playing) : ""
  }

  // execArgv and not execDetached: `appimage` comes from user settings, and the
  // argv form keeps a path with a space or a $ in it from being re-tokenized.
  function open(args) {
    Util.execArgv([root.appimage].concat(args || []))
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // Controller when a game is up, coffee cup when it is not — the app is named
    // after the cup, and that distinction is the whole point of the widget.
    // ⚠️ U+F0176 nf-md-coffee, verified by codepoint. The first draft used
    // U+F0150, which renders as a CLOCK — close enough in a code editor to miss,
    // and obvious the moment it reached the bar.
    text: root.playing !== ""
      ? "󰊴 " + root.playing
      : (root.installed >= 0 ? "󰅶 " + root.installed : "󰅶")

    active: root.playing !== ""
    dimmed: root.installed < 0 && root.playing === ""

    tooltipText: root.playing !== ""
      ? "Playing " + root.playing + " — click to open the library"
      : (root.installed < 0
         ? "Cafe Neurotico — cannot read the library database"
         : root.installed + " games installed — click for the library, middle-click for CREMA")

    // Left opens the Manager, middle opens the couch face. Right is left alone:
    // it is the bar's own context menu everywhere else, and taking it here would
    // make this widget the one that behaves differently.
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.open(["--crema"])
      else if (mouseButton === Qt.LeftButton) root.open([])
    }
  }

  Process {
    command: ["bash", root.watchScript, root.database, String(root.interval)]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.apply(line) }
    }
  }
}
