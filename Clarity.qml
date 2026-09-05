import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
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

  // ⚠️ Required, not decorative. Bar.moduleWidgets() looks up this widget's sibling
  // instances by this name and returns an empty list for a blank one. Without it
  // `omarchy-shell <id> menu` reaches nothing and appears to do nothing.
  moduleName: "io.github.fromchaoscomesclarity.clarity"
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

  // ── Showing the count ────────────────────────────────────────────────
  // Off by default, and turned on from the menu rather than from the widget's settings
  // schema. A number on the bar is a real cost: it is always there, it is the only widget
  // here whose width changes as you install games, and most of the time you want the mark
  // and nothing else. So it is opt-in, and the way in is one click from where you already are.
  //
  // ⚠️ Not a `setting()` from the manifest schema. Those are read out of shell.json and a
  // widget cannot write them back through `setting()`, so a menu row driving one would have
  // nowhere to save to. Two stores for one preference is worse than one store in the less
  // obvious place. The sibling EmuLatte plugin keeps the same preference the same way.
  //
  // ⚠️ The count is still READ when it is hidden, and still in the tooltip. Hiding it is
  // about the bar being quiet, not about the widget knowing less.
  property bool showCount: false

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/"
  readonly property string prefsPath: stateDir + "clarity-widget.json"

  function loadPrefs(text) {
    try {
      var data = JSON.parse(String(text || "").trim() || "{}")
      root.showCount = data.showCount === true
    } catch (e) {
      root.showCount = false     // an unreadable file is the default, never a crash
    }
  }

  function toggleCount() {
    root.showCount = !root.showCount
    // Written for the next shell start; the peers on other monitors pick it up from the file
    // watch below, which is why nothing is broadcast by hand.
    prefsFile.setText(JSON.stringify({ version: 1, showCount: root.showCount }, null, 2) + "\n")
  }

  Process { id: ensureStateDir; command: ["mkdir", "-p", root.stateDir] }

  FileView {
    id: prefsFile
    path: root.prefsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadPrefs(text())
    // ⚠️ First run: the file does not exist yet, and without this branch the widget would sit
    // on whatever the property was initialised to and never learn otherwise.
    onLoadFailed: root.loadPrefs("")
    // A bar widget is live once per monitor. The write from one instance arrives here as a
    // file change, which is how the other bars follow without any of them talking directly.
    onFileChanged: reload()
  }

  Component.onCompleted: {
    ensureStateDir.running = true
    Qt.callLater(function() { prefsFile.reload() })
  }

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
    { kind: "sep" },
    // The label says what pressing it does, not what the current state is: a row reading
    // "Show the game count" while the count is already showing is the classic way to make a
    // toggle ambiguous. The box on the right carries the state.
    { kind: "item",
      label: root.showCount ? "Hide the game count" : "Show the game count",
      glyph: root.showCount ? "󰄲" : "󰄱",
      act: "toggle-count" },
  ]

  // Called on whichever instance toggleMenuOnFocusedScreen() picks, and by the bar
  // button on its own instance.
  function toggleMenu() { root.menuOpen = !root.menuOpen }

  // ⚠️ PopupCard.close() is the ONLY thing that must set menuOpen from the popup side:
  //
  //     function close() {
  //       if (owner && "close" in owner) owner.close()
  //       else root.open = false            // <- assigns over `open: root.menuOpen`
  //     }
  //
  // Without this function the else branch runs, and assigning to `open` destroys the
  // binding that drives it. The menu then opens exactly once: the focus grab calls
  // close() on the first outside click, the binding dies, and every later click sets
  // menuOpen with nothing listening. Defining close() here is how a PopupCard owner
  // opts out of that, and it is why `owner: root` is set at all.
  function close() { root.menuOpen = false }

  // Which screen a given widget instance is living on.
  function screenNameOf(widget) {
    var win = (widget && widget.QsWindow) ? widget.QsWindow.window : null
    return (win && win.screen) ? String(win.screen.name || "") : ""
  }

  // A bar widget is live once per monitor, so broadcasting the toggle opened a popup on
  // EVERY screen at once. Each PopupCard runs its own HyprlandFocusGrab, and a grab counts
  // the other screen's popup as an outside click, so the grabs cleared one another and the
  // menu shut the instant it opened. Open it on the focused screen alone, and drop any that
  // a previous call left up elsewhere, so the menu never exists twice.
  function toggleMenuOnFocusedScreen() {
    var items = (root.bar && typeof root.bar.moduleWidgets === "function")
      ? root.bar.moduleWidgets(root.moduleName) : []
    if (!items || items.length === 0) items = [root]

    var want = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var target = null
    for (var i = 0; i < items.length; i++)
      if (root.screenNameOf(items[i]) === want) { target = items[i]; break }
    if (!target) target = items[0]

    for (var j = 0; j < items.length; j++)
      if (items[j] !== target && items[j].menuOpen) items[j].menuOpen = false

    target.toggleMenu()
  }

  function runMenuItem(item) {
    if (!item || !item.act) return
    if (item.act === "toggle-count") { root.toggleCount(); return }
    if (item.act === "manager") { root.open([]); return }
    if (item.act === "couch")   { root.open(["--couch"]); return }
    if (item.act === "launcher") {
      // The overlay lives in this plugin, so the shell is asked to toggle it rather than
      // anything being started: spawning would give a second copy of a thing already loaded.
      //
      // ⚠️ Routed through the shell's own CLI, not an injected `shell` object. The bar host
      // does not hand a bar widget a `shell`, so that property stayed null, the guarded call
      // fell straight through, and this one menu row did nothing at all while every other
      // row worked. `omarchy-shell shell toggle` is an IPC call into the already-running
      // shell, the same thing SUPER+CTRL+G is bound to, so it still starts no second copy.
      var pid = (root.manifest && root.manifest.id) || "io.github.fromchaoscomesclarity.clarity"
      if (root.shellRef && typeof root.shellRef.toggle === "function") root.shellRef.toggle(pid, "{}")
      else Util.execArgv(["omarchy-shell", "shell", "toggle", pid])
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
    // ⚠️ The extra room is reserved only when the number is actually there. Widening for a
    // count that is switched off leaves a gap in the bar that reads as a rendering fault.
    //
    // ⚠️ ...but the off branch is the ICON SLOT, never -1. BarIconButton defaults
    // fixedWidth to `vertical ? -1 : slotSize`, and -1 opts out of that into WidgetButton's
    // label path, which sizes from `label.implicitWidth` — zero here, because an icon button
    // carries no text. The widget then comes out at max(12, margin * 2), around ten pixels
    // narrower than every other icon on the bar, and the mark sits crowded against its
    // neighbour. Reproduce BarIconButton's own default instead of disabling it.
    fixedWidth: root.playing !== "" ? -1
              : (root.showCount ? button.slotSize + countMetrics.width + 6
                                : (root.vertical ? -1 : button.slotSize))

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
    text: (root.showCount && root.installed >= 0) ? String(root.installed) : ""
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
        visible: root.showCount && root.installed >= 0
        anchors.verticalCenter: parent.verticalCenter
        text: (root.showCount && root.installed >= 0) ? String(root.installed) : ""
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
    // ⚠️ A bar widget exists once per monitor. The handler must NOT toggle every
    // instance: two popups open at once make their focus grabs cancel each other.
    // It targets the focused screen instead.
  IpcHandler {
    target: (root.manifest && root.manifest.id) || "io.github.fromchaoscomesclarity.clarity"
    function menu(): void { root.toggleMenuOnFocusedScreen() }
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
