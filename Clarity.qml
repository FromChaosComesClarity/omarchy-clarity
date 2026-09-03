import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Clarity in the bar.
//
// The app is a window you open; this is the part of it that is always there ,
// how many games are installed, and whether one is running right now. It only
// watches and pokes, so the bar restarting, the plugin being disabled, or QML
// failing outright costs the icon and nothing else. The library, the launcher
// and every game keep working exactly as before.
//
// ⚠️ The running-game check reads the COMPOSITOR, not the app. Clarity
// does not have to be open for a game to be playing, it launches games and
// gets out of the way, so asking the app would give the wrong answer for the
// case this widget exists to show.
BarWidget {
  id: root
  objectName: "clarityWidget"

  // ⚠️ Both paths default to empty on purpose: the app writes its own location and its
  // database path to ~/.config/clarity/desktop.json on every start, and the backend
  // reads them there. A setting is an override for an unusual install, never the normal
  // way this finds the app, a hardcoded path works on exactly one machine.
  readonly property string appimageOverride: setting("appimage", "")
  readonly property string databaseOverride: setting("database", "")
  readonly property int interval: setting("interval", 3)

  // Where the app actually is: the override if one was set, otherwise whatever the
  // running backend last read out of the descriptor.
  readonly property string appimage: appimageOverride !== "" ? appimageOverride : reportedExec

  // Injected by the bar host when these properties exist, the same pair the overlay half
  // of this plugin is handed. `shell` is how the launcher overlay gets toggled.
  property var shellRef: null
  property var shell: null
  property var manifest: null
  onShellChanged: root.shellRef = shell

  // Qt.resolvedUrl gives a file:// URL; the shell wants a plain path, and the
  // plugin directory is user-named, so the percent-decoding is not optional.
  readonly property string watchScript:
    decodeURIComponent(Qt.resolvedUrl("scripts/clarity-watch").toString().replace(/^file:\/\//, ""))

  property int installed: -1        // -1 = not known yet, not "zero games"
  property string playing: ""
  property string reportedExec: ""
  property bool menuOpen: false

  // One click from the bar to everything the app does. The launcher is an overlay in this
  // same plugin, so it is toggled through the shell rather than spawned; the rest are the
  // app's own deeplinks, which is why this list needs no knowledge of what they do.
  readonly property var menuItems: [
    { kind: "item", label: "Open the library",   glyph: "󰌱", act: "manager" },
    { kind: "item", label: "Find a game…",       glyph: "󰍉", act: "launcher" },
    { kind: "item", label: "Play on the couch",  glyph: "󰊴", act: "couch" },
    { kind: "sep" },
    { kind: "item", label: "Manage storage",     glyph: "󰋊", act: "action:manage-storage" },
    { kind: "item", label: "Control Panel",      glyph: "󰒓", act: "action:control-panel" },
  ]

  // Named so broadcast("toggleMenu") can find it on every instance.
  function toggleMenu() { root.menuOpen = !root.menuOpen }

  function runMenuItem(item) {
    if (!item || !item.act) return
    if (item.act === "manager") { root.open([]); return }
    if (item.act === "couch")   { root.open(["--couch"]); return }
    if (item.act === "launcher") {
      // The overlay lives in this plugin, so ask the shell to toggle it rather than
      // starting anything, spawning would give a second copy of a thing already loaded.
      if (root.shellRef && typeof root.shellRef.toggle === "function")
        root.shellRef.toggle((root.manifest && root.manifest.id) || "io.github.fromchaoscomesclarity.clarity", "{}")
      return
    }
    if (item.act.indexOf("action:") === 0) { root.open(["--action=" + item.act.slice(7)]); return }
  }

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
    root.reportedExec = data.exec ? String(data.exec) : ""
  }

  // execArgv and not execDetached: `appimage` is a path read off disk, and the argv form
  // keeps one with a space or a $ in it from being re-tokenized by a shell.
  function open(args) {
    if (root.appimage === "") return      // not installed here, or never run: do nothing
    Util.execArgv([root.appimage].concat(args || []))
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // Controller glyph when a game is up; the app's own mark when it is not. That
    // distinction is the whole point of the widget.
    //
    // The mark is DRAWN rather than shipped as an image, for two reasons a bar widget
    // cares about: it inherits `foreground`, so it follows the Omarchy theme like every
    // other icon on the bar, and it stays crisp at any bar height instead of resampling
    // a fixed-size raster.
    //
    // BarIconButton centres its label on top of the icon slot, so the two cannot both
    // show. The count therefore lives inside the icon component beside the mark, and
    // fixedWidth is widened to make room for it.
    iconComponent: root.playing !== "" ? null : markWithCount
    text: root.playing !== "" ? "󰊴 " + root.playing : ""
    fixedWidth: root.playing !== "" ? -1 : (button.slotSize + countMetrics.width + 6)

    active: root.playing !== ""
    dimmed: root.installed < 0 && root.playing === ""

    tooltipText: root.playing !== ""
      ? "Playing " + root.playing + ", click to open the library"
      : (root.installed < 0
         ? (root.appimage === ""
            ? "Clarity is not installed, press ⏎ in the launcher to fetch it"
            : "Clarity: cannot read the library database")
         : root.installed + " games installed, click for the menu, middle-click for Couch Mode")

    // Left opens the menu, everything the app can do from the bar is one click away
    // rather than one click plus a window. Middle still jumps straight to Couch Mode, because
    // someone sitting down does not want a menu first. Right is left alone: it is the
    // bar's own context menu everywhere else, and taking it here would make this widget
    // the one that behaves differently.
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.open(["--couch"])
      else if (mouseButton === Qt.LeftButton) root.menuOpen = !root.menuOpen
    }
  }

  // Text metrics for the count, so fixedWidth reserves exactly the room it needs.
  TextMetrics {
    id: countMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: root.installed >= 0 ? String(root.installed) : ""
  }

  Component {
    id: markWithCount
    Row {
      spacing: 6
      anchors.centerIn: parent

      // The aperture: one open ring with the focal dot at its centre.
      Canvas {
        id: mark
        width: button.opticalSize
        height: button.opticalSize
        anchors.verticalCenter: parent.verticalCenter
        property color ink: button.active && button.useActiveColor ? button.activeColor : button.foreground
        onInkChanged: requestPaint()
        onWidthChanged: requestPaint()
        onPaint: {
          const ctx = getContext("2d")
          ctx.reset()
          const cx = width / 2, cy = height / 2
          const r  = width * 0.29        // ring radius
          const w  = width * 0.11        // stroke weight, the app icon's ratio
          ctx.strokeStyle = ink
          ctx.lineWidth = w
          ctx.lineCap = "round"
          ctx.beginPath()
          // 52 degrees round to 308, clockwise in canvas coords, so the gap lands right.
          ctx.arc(cx, cy, r, 52 * Math.PI / 180, 308 * Math.PI / 180, false)
          ctx.stroke()
          ctx.beginPath()
          ctx.fillStyle = ink
          ctx.arc(cx, cy, width * 0.066, 0, Math.PI * 2)
          ctx.fill()
        }
      }

      Text {
        visible: root.installed >= 0
        anchors.verticalCenter: parent.verticalCenter
        text: root.installed >= 0 ? String(root.installed) : ""
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }
  }

  // ── The menu ───────────────────────────────────────────────────────────────
  // Built on the shell's own PopupCard, so it dismisses, positions and themes exactly like
  // every other bar popup on the desktop rather than being this plugin's own idea of one.
  PopupCard {
    id: menu
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.menuOpen
    padding: Style.space(8)
    contentWidth: menu.fittedContentWidth(Style.space(248))
    contentHeight: menu.fittedContentHeight(menuColumn.implicitHeight, Style.space(420))
    onVisibleChanged: if (!visible) root.menuOpen = false

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(2)

      // What is playing, when something is. It is the reason to glance at this widget,
      // so it leads, and it is a label, not a row you can press.
      Item {
        width: parent.width
        height: root.playing !== "" ? nowPlaying.implicitHeight + Style.space(10) : 0
        visible: root.playing !== ""
        Column {
          id: nowPlaying
          width: parent.width
          spacing: 2
          Text {
            text: "NOW PLAYING"
            color: Color.popups.text
            opacity: 0.5
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
          }
          Text {
            width: parent.width
            text: root.playing
            color: Color.accent
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }
      }

      Rectangle {
        width: parent.width
        height: Math.max(1, Style.space(1))
        color: Color.popups.text
        opacity: 0.14
        visible: root.playing !== ""
      }

      Repeater {
        model: root.menuItems
        delegate: Rectangle {
          required property var modelData
          required property int index
          width: menuColumn.width
          height: modelData.kind === "sep"
            ? Math.max(1, Style.space(1)) + Style.space(8)
            : Math.max(Style.space(28), rowLabel.implicitHeight + Style.space(12))
          color: rowMouse.containsMouse && modelData.kind !== "sep"
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)
            : "transparent"
          radius: Style.cornerRadius

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: Math.max(1, Style.space(1))
            color: Color.popups.text
            opacity: 0.14
            visible: modelData.kind === "sep"
          }

          Text {
            id: rowLabel
            visible: modelData.kind !== "sep"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.right: rowGlyph.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label || ""
            color: rowMouse.containsMouse ? Color.accent : Color.popups.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            id: rowGlyph
            visible: modelData.kind !== "sep"
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.glyph || ""
            color: rowMouse.containsMouse ? Color.accent : Color.popups.text
            opacity: rowMouse.containsMouse ? 1 : 0.55
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: modelData.kind !== "sep"
            hoverEnabled: true
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              root.menuOpen = false
              root.runMenuItem(modelData)
            }
          }
        }
      }
    }
  }

  // Bindable from a key, and the only way to drive the menu without a mouse:
  //   omarchy-shell io.github.fromchaoscomesclarity.clarity menu
  // ⚠️ A bar widget exists once per monitor, so the handler toggles through broadcast()
  // rather than this instance alone, otherwise the menu opens on whichever screen the
  // shell happened to instantiate first.
  IpcHandler {
    target: (root.manifest && root.manifest.id) || "io.github.fromchaoscomesclarity.clarity"
    function menu(): void { root.broadcast("toggleMenu") }
    function library(): void { root.open([]) }
    function couch(): void { root.open(["--couch"]) }
    function playing(): string { return root.playing }
    function installed(): string { return String(root.installed) }
  }

  Process {
    command: ["bash", root.watchScript, root.databaseOverride, String(root.interval)]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.apply(line) }
    }
  }
}
