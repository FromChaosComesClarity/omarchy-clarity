import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "LauncherSearch.js" as LauncherSearch

// The library, one keystroke away.
//
// Omarchy is a place where everything opens from a fuzzy list, and the game library was the
// exception — it was a window you had to go and find. Type three letters here and press Enter
// and the game starts.
//
// The layout is a launcher on the left and the game on the right: cover, genre, year, how long
// you have played it, and a sentence about it. Not decoration — it is what tells two games
// with similar names apart, and what makes a list of 877 rows feel like a library.
//
// ⚠️ Every colour, font and radius comes from the Omarchy theme tokens (the [menu] surface,
// the same one the Omarchy menu uses), so this follows `omarchy theme set` with no palette of
// its own. Nothing here is hardcoded to look good against one background.
//
// ⚠️ Nothing is launched from inside this file. Enter spawns Cafe Neurotico with --play=<id>,
// and the app does what pressing Play does: the multi-store picker, the "which engine?" and
// "which Doom?" dialogs, the install-state check, the last-played write. A launcher in QML
// that spawned games itself would be a second implementation of all of that, correct on the
// day it was written and wrong by the next release.
//
// ⚠️ Every path comes from ~/.config/cafeneurotico/desktop.json, which the app writes on each
// start. If it is not there, Cafe Neurotico is not installed here and this says so rather
// than guessing at a path that happens to work on one machine.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0

  // The index, as parsed from cn-index. `ready` stays false until a first good read, so the
  // empty state can tell "nothing matches" apart from "nothing loaded".
  property var index: ({ ok: false, error: "", exec: "", games: [], actions: [] })
  property bool ready: false
  property string indexError: ""
  property int total: 0

  readonly property string indexScript:
    decodeURIComponent(Qt.resolvedUrl("scripts/cn-index").toString().replace(/^file:\/\//, ""))
  readonly property string installScript:
    decodeURIComponent(Qt.resolvedUrl("scripts/cn-install").toString().replace(/^file:\/\//, ""))

  // True when the app is not on this machine at all, as opposed to a library that could not
  // be read — the difference between "get it" and "something is wrong".
  readonly property bool appMissing: !root.ready && root.indexError.indexOf("has not been run") !== -1

  // ⚠️ In a terminal, never silently: this downloads ~270 MB and then runs what it fetched.
  // The app itself hands package installs to a terminal for the same reason.
  function runInstaller() {
    root.dismiss()
    var term = Quickshell.env("TERMINAL") || "xdg-terminal-exec"
    Quickshell.execDetached([term, "bash", root.installScript])
  }

  // ── Theme ──────────────────────────────────────────────────────────────────
  // Shares the [menu] surface tokens, so a theme that styles the Omarchy menu styles this.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  property color muted: Color.muted
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(38), Style.font.heading + Style.spacing.controlPaddingY * 3)
  property int footerHeight: Math.max(Style.space(20), Style.font.caption + Style.spacing.sm * 2)
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Math.max(Style.space(30), Style.font.body + Style.spacing.lg * 2)
  property int cardWidth: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(620), panel.height - Style.gapsOut * 2)
  // The art column is sized off the cover, not the card: box art is 2:3 and a pane that does
  // not match it either letterboxes or crops something a person chose to look at.
  property int artWidth: Math.round(Math.min(Style.space(232), cardWidth * 0.26))
  property int artHeight: Math.round(artWidth * 1.5)
  property int previewWidth: artWidth + contentMargin * 2

  // The row under the cursor, as an object, so the preview pane is one binding rather than
  // six lookups into the model.
  property var current: null

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.rebuild()
    // Re-read on every summon: a game installed since the last one should be playable now,
    // not after a shell restart. The list on screen stays the previous index until the new
    // one lands, which is a few milliseconds and never a blank card.
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.fromchaoscomesclarity.cafeneurotico")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    if (indexProc.running) return
    indexProc.running = true
  }

  function applyIndex(raw) {
    var parsed = LauncherSearch.parseIndex(raw)
    // ⚠️ A failed read keeps the last good index. The database is in WAL mode and a checkpoint
    // mid-read is a busy error, not a library that vanished — dropping the list on the floor
    // would make the launcher flicker empty while a game installs.
    if (!parsed.ok) {
      root.indexError = parsed.error
      if (!root.ready) root.index = parsed
      return
    }
    root.indexError = ""
    root.index = parsed
    root.ready = true
    if (root.opened) root.rebuild()
  }

  function rebuild() {
    var result = LauncherSearch.search(root.index, root.filterText, 80)
    root.total = result.total

    rowModel.clear()
    for (var i = 0; i < result.rows.length; i++) {
      var r = result.rows[i]
      rowModel.append({
        rowKind: r.kind, rowId: String(r.id), rowName: r.name, rowBadge: r.badge,
        rowCover: r.cover || "", rowBlurb: r.blurb || "", rowGenre: r.genre || "",
        rowYear: r.year || "", rowStore: r.store || "", rowPlaytime: r.playtime || 0,
      })
    }

    if (root.selectedIndex >= rowModel.count) root.selectedIndex = Math.max(0, rowModel.count - 1)
    if (root.selectedIndex < 0) root.selectedIndex = 0
    syncCurrent()
    Qt.callLater(function() {
      if (rowModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function syncCurrent() {
    root.current = (root.selectedIndex >= 0 && root.selectedIndex < rowModel.count)
      ? rowModel.get(root.selectedIndex) : null
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.rebuild()
  }

  function select(delta) {
    if (rowModel.count === 0) return
    root.selectedIndex = (root.selectedIndex + delta + rowModel.count) % rowModel.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    syncCurrent()
  }

  function selectPage(delta) {
    if (rowModel.count === 0) return
    var visibleRows = Math.max(1, Math.floor(resultList.height / root.rowHeight))
    var next = root.selectedIndex + delta * visibleRows
    root.selectedIndex = Math.max(0, Math.min(rowModel.count - 1, next))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    syncCurrent()
  }

  // What Enter does, spelled out per row kind:
  //   an installed game → play it
  //   a game you own but have not installed → open its page, which is where Install is
  //   an action → run it in the app
  // `openPage` is Shift+Enter on any game: the page rather than the launch, for when you want
  // the description, the achievements or the Doom the mod should run on.
  function activate(indexInModel, openPage) {
    if (indexInModel < 0 || indexInModel >= rowModel.count) return
    var row = rowModel.get(indexInModel)
    var exec = String(root.index.exec || "")
    if (exec === "") return
    var arg
    if (row.rowKind === "action") arg = "--action=" + row.rowId
    else if (openPage || row.rowBadge !== "play") arg = "--game=" + row.rowId
    else arg = "--play=" + row.rowId
    root.dismiss()
    // execDetached with an argv array: the path comes out of a file on disk and a space or a $
    // in it must never be re-tokenized by a shell.
    Quickshell.execDetached([exec, arg])
  }

  // ⚠️ A local path becomes a URL, and a library is full of titles with spaces, apostrophes
  // and the occasional #. encodeURI leaves # alone — where it would be read as a fragment and
  // silently truncate the path — so it is escaped by hand.
  function fileUrl(path) {
    if (!path) return ""
    return "file://" + encodeURI(String(path)).replace(/#/g, "%23")
  }

  function playtimeLabel(minutes) {
    if (!minutes || minutes < 1) return ""
    if (minutes < 60) return minutes + " min played"
    var hours = minutes / 60
    return (hours < 10 ? hours.toFixed(1) : Math.round(hours)) + " h played"
  }

  // Store strings come out of the library as "Steam, GOG" — the launcher wants the shape of
  // the line, not the full inventory.
  function metaLine(row) {
    if (!row) return ""
    var bits = []
    if (row.rowGenre) bits.push(row.rowGenre)
    if (row.rowYear) bits.push(row.rowYear)
    if (row.rowStore) bits.push(row.rowStore)
    return bits.join("  ·  ")
  }

  ListModel { id: rowModel }

  Process {
    id: indexProc
    command: ["python3", root.indexScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyIndex(text)
    }
  }

  // Read once at shell start so the first summon paints a full list rather than an empty card
  // that fills in a moment later. The manifest keeps this plugin loaded for exactly this.
  Component.onCompleted: refresh()

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "cafeneurotico-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.selectPage(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.selectPage(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (rowModel.count === 0 && root.appMissing) root.runInstaller()
            else root.activate(root.selectedIndex, (event.modifiers & Qt.ShiftModifier) !== 0)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ── Header: the cup, what you typed, and how much it matched ──────────
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: mark
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            // U+F0176 nf-md-coffee, verified by codepoint — the same mark the bar widget
            // wears, so the overlay is recognisably the same app.
            text: "󰅶"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            id: filterLine
            anchors.left: mark.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: countLine.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Play something…"
            color: root.filterText ? root.foreground : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          // A caret, because a line of text with no cursor does not read as somewhere you can
          // type. It blinks only while the card is open, so it costs nothing when it is not.
          Rectangle {
            id: caret
            anchors.left: filterLine.left
            anchors.leftMargin: Math.min(filterLine.contentWidth + Style.space(2),
                                         filterLine.width - Style.space(2))
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(1, Style.space(1))
            height: Style.font.heading
            color: root.accent
            visible: root.filterText.length > 0
            SequentialAnimation on opacity {
              running: root.opened
              loops: Animation.Infinite
              NumberAnimation { to: 0.15; duration: 520; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1.0;  duration: 520; easing.type: Easing.InOutQuad }
            }
          }

          Text {
            id: countLine
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.total > 0 ? (root.total + (root.total === 1 ? " result" : " results")) : ""
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(1, Style.space(1))
            color: root.foreground
            opacity: 0.12
          }
        }

        // ── Body: the list, and the game it is pointing at ───────────────────
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          ListView {
            id: resultList
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: preview.visible ? preview.left : parent.right
            anchors.rightMargin: preview.visible ? Style.spacing.xxl : 0
            model: rowModel
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: rowModel.count > 0
            spacing: Math.max(1, Style.space(1))

            delegate: Item {
              id: rowItem
              required property int index
              required property string rowKind
              required property string rowId
              required property string rowName
              required property string rowBadge

              readonly property bool hasCursor: index === root.selectedIndex

              width: resultList.width
              height: root.rowHeight

              Rectangle {
                anchors.fill: parent
                radius: root.cornerRadius
                color: rowItem.hasCursor ? root.selectedBackground : "transparent"
                Behavior on color { ColorAnimation { duration: 90 } }
              }

              // The cursor, as a bar rather than a full-width slab: it reads at a glance from
              // across the room and does not fight the row's own text for contrast.
              Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(2, Style.space(2))
                height: rowItem.hasCursor ? parent.height - Style.space(8) : 0
                radius: width
                color: root.accent
                Behavior on height { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
              }

              Text {
                id: nameText
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.right: badge.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.rowName
                color: rowItem.hasCursor ? root.selectedText : root.foreground
                opacity: rowItem.rowBadge === "install" && !rowItem.hasCursor ? 0.72 : 1
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              // play / install / action — a pill for the one you can act on right now, plain
              // dim text for the rest, so the eye finds what is playable without reading.
              Rectangle {
                id: badge
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: badgeText.implicitWidth + Style.spacing.lg * 2
                height: badgeText.implicitHeight + Style.spacing.xs * 2
                radius: height / 2
                color: rowItem.rowBadge === "play" ? root.accent : "transparent"
                opacity: rowItem.rowBadge === "play" ? (rowItem.hasCursor ? 1 : 0.82) : 1

                Text {
                  id: badgeText
                  anchors.centerIn: parent
                  text: rowItem.rowBadge
                  color: rowItem.rowBadge === "play" ? root.background : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) {
                  root.selectedIndex = rowItem.index
                  root.syncCurrent()
                }
                onClicked: function(mouse) {
                  root.selectedIndex = rowItem.index
                  root.syncCurrent()
                  root.activate(rowItem.index, (mouse.modifiers & Qt.ShiftModifier) !== 0)
                }
              }
            }
          }

          // The list does not stop at a row boundary, so without this it ends on a sliced
          // one and reads as a rendering fault rather than as more to scroll to.
          Rectangle {
            anchors.left: resultList.left
            anchors.right: resultList.right
            anchors.bottom: resultList.bottom
            height: root.rowHeight
            visible: resultList.visible && resultList.contentHeight > resultList.height
            gradient: Gradient {
              GradientStop { position: 0.0; color: "transparent" }
              GradientStop { position: 1.0; color: root.background }
            }
          }

          // A hairline between the two halves: the preview belongs to the row the cursor is
          // on, and a shared edge says that more quietly than a gap does.
          Rectangle {
            anchors.right: preview.left
            anchors.rightMargin: Style.spacing.lg
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.max(1, Style.space(1))
            visible: preview.visible
            color: root.foreground
            opacity: 0.1
          }

          // ── The game itself ──────────────────────────────────────────────
          Item {
            id: preview
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: root.previewWidth
            visible: rowModel.count > 0 && root.current !== null && root.cardWidth > Style.space(620)
            opacity: root.current ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }

            // ⚠️ Anchors, not a Column. A Column is as tall as its children, so a long
            // description simply ran past the bottom of the card and through the footer.
            // Here the art and the three label lines take what they need from the top and
            // the blurb is given exactly the space that is left, clipped to it.
            Item {
              id: previewBody
              anchors.fill: parent
              anchors.leftMargin: (parent.width - root.artWidth) / 2
              anchors.rightMargin: (parent.width - root.artWidth) / 2

              // Cover art, rounded with the same MultiEffect mask the shell's own image
              // picker uses — a Rectangle's radius does not clip its children.
              Item {
                id: artFrame
                anchors.top: parent.top
                anchors.left: parent.left
                width: root.artWidth
                height: root.artHeight
                visible: root.current !== null && root.current.rowKind === "game"

                Rectangle {
                  id: artMask
                  anchors.fill: parent
                  radius: root.cornerRadius > 0 ? root.cornerRadius * 2 : Style.space(6)
                  visible: false
                  layer.enabled: true
                }

                Rectangle {
                  anchors.fill: parent
                  radius: artMask.radius
                  color: root.foreground
                  opacity: 0.05
                }

                Image {
                  id: art
                  anchors.fill: parent
                  source: root.current && root.current.rowCover ? root.fileUrl(root.current.rowCover) : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  smooth: true
                  visible: status === Image.Ready
                  sourceSize.width: root.artWidth * 2
                  layer.enabled: true
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: artMask
                    maskThresholdMin: 0.3
                    maskSpreadAtMin: 0.3
                  }
                }

                // No cover is common enough (a custom install, a fan game) that it needs to
                // look deliberate rather than broken.
                Text {
                  anchors.centerIn: parent
                  visible: art.status !== Image.Ready
                  text: "󰅶"
                  color: root.foreground
                  opacity: 0.25
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                }

                Rectangle {
                  anchors.fill: parent
                  radius: artMask.radius
                  color: "transparent"
                  border.width: Math.max(1, Style.space(1))
                  border.color: root.foreground
                  opacity: 0.14
                }
              }

              Text {
                id: previewTitle
                anchors.top: artFrame.visible ? artFrame.bottom : parent.top
                anchors.topMargin: Style.spacing.xl
                anchors.left: parent.left
                anchors.right: parent.right
                text: root.current ? root.current.rowName : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                id: previewMeta
                anchors.top: previewTitle.bottom
                anchors.topMargin: Style.spacing.sm
                anchors.left: parent.left
                anchors.right: parent.right
                visible: text !== ""
                text: root.current && root.current.rowKind === "game"
                  ? root.metaLine(root.current)
                  : (root.current ? "Runs in Cafe Neurotico" : "")
                color: root.accent
                opacity: 0.85
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                id: previewPlaytime
                anchors.top: previewMeta.visible ? previewMeta.bottom : previewTitle.bottom
                anchors.topMargin: previewMeta.visible ? Style.spacing.xs : Style.spacing.sm
                anchors.left: parent.left
                anchors.right: parent.right
                visible: text !== ""
                text: root.current ? root.playtimeLabel(root.current.rowPlaytime) : ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.top: previewPlaytime.visible ? previewPlaytime.bottom : previewMeta.bottom
                anchors.topMargin: Style.spacing.lg
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: text !== ""
                clip: true
                text: root.current && root.current.rowKind === "game" ? root.current.rowBlurb : ""
                color: root.foreground
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                lineHeight: 1.3
              }
            }
          }

          // Three different nothings, and they are not the same message: the app was never run
          // here, the library could not be read, or you typed something no game matches.
          Column {
            anchors.centerIn: parent
            spacing: Style.spacing.xl
            width: parent.width
            visible: rowModel.count === 0

            Text {
              text: root.ready ? "󰈉" : "󰅶"
              color: root.foreground
              opacity: 0.3
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.ready
                ? "Nothing matches “" + root.filterText + "”"
                : (root.appMissing
                   ? "Cafe Neurotico is not installed here"
                   : (root.indexError !== "" ? root.indexError : "Reading the library…"))
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              width: parent.width
            }

            // ⚠️ Knowing the app is missing and only saying so is a dead end. This offers the
            // next step — and says what it will do, because 270 MB and an executable are not
            // things to start without telling someone.
            Text {
              visible: root.appMissing
              text: "Press ⏎ to fetch it — about 270 MB, in a terminal you can watch"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }
        }

        // ── Footer: what the keys do ─────────────────────────────────────────
        Item {
          width: parent.width
          height: root.footerHeight

          Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(1, Style.space(1))
            color: root.foreground
            opacity: 0.12
          }

          Text {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            text: "↑↓ move    ⏎ play    ⇧⏎ open page    esc close"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: root.index.version ? "cafe neurotico " + root.index.version : "cafe neurotico"
            color: root.muted
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
