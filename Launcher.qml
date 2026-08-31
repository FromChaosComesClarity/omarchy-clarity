import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "LauncherSearch.js" as LauncherSearch

// The library, one keystroke away.
//
// Omarchy is a place where everything opens from a fuzzy list, and until now the game
// library was the exception — it was a window you had to go and find. Type three letters
// here and press Enter and the game starts.
//
// ⚠️ Nothing is launched from inside this file. Enter spawns Cafe Neurotico with
// --play=<id>, and the app does what pressing Play does: the multi-store picker, the
// "which Doom?" and "which engine?" dialogs, the install-state check, the last-played
// write. A launcher in QML that spawned games itself would be a second implementation of
// all of that, correct on the day it was written and wrong by the next release.
//
// ⚠️ Every path comes from ~/.config/cafeneurotico/desktop.json, which the app writes on
// each start. If it is not there, Cafe Neurotico is not installed here and this says so
// rather than guessing at a path that happens to work on one machine.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0

  // The index, as parsed from cn-index. `ready` stays false until a first good read, so
  // the empty state can tell "nothing matches" apart from "nothing loaded".
  property var index: ({ ok: false, error: "", exec: "", games: [], actions: [] })
  property bool ready: false
  property string indexError: ""
  property int total: 0

  readonly property string indexScript:
    decodeURIComponent(Qt.resolvedUrl("scripts/cn-index").toString().replace(/^file:\/\//, ""))

  // Shares the [menu] surface tokens, so a theme that styles the Omarchy menu styles this.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Math.max(Style.space(34), Style.font.body + Style.spacing.md * 2)
  property int cardWidth: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(520), panel.height - Style.gapsOut * 2)

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.rebuild()
    // Re-read on every summon: a game installed since the last one should be playable
    // now, not after a shell restart. The list on screen is the previous index until the
    // new one lands, which is a few milliseconds and never a blank card.
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
    // ⚠️ A failed read keeps the last good index. The database is in WAL mode and a
    // checkpoint mid-read is a busy error, not a library that vanished — dropping the
    // list on the floor would make the launcher flicker empty while a game installs.
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
    var result = LauncherSearch.search(root.index, root.filterText, 60)
    root.total = result.total

    rowModel.clear()
    for (var i = 0; i < result.rows.length; i++) {
      var r = result.rows[i]
      rowModel.append({ rowKind: r.kind, rowId: String(r.id), rowName: r.name, rowBadge: r.badge })
    }

    if (root.selectedIndex >= rowModel.count) root.selectedIndex = Math.max(0, rowModel.count - 1)
    if (root.selectedIndex < 0) root.selectedIndex = 0
    Qt.callLater(function() {
      if (rowModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
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
  }

  function selectPage(delta) {
    if (rowModel.count === 0) return
    var visibleRows = Math.max(1, Math.floor(resultList.height / root.rowHeight))
    var next = root.selectedIndex + delta * visibleRows
    root.selectedIndex = Math.max(0, Math.min(rowModel.count - 1, next))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  // What Enter does, spelled out per row kind:
  //   an installed game  → play it
  //   a game you own but have not installed → open its page, which is where Install is
  //   an action          → run it in the app
  // `openPage` is Shift+Enter on any game: the page rather than the launch, for when you
  // want the description, the achievements or the Doom the mod should run on.
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
    // execDetached with an argv array: the path comes out of a file on disk and a space
    // or a $ in it must never be re-tokenized by a shell.
    Quickshell.execDetached([exec, arg])
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

  // Read once at shell start so the first summon paints a full list rather than an empty
  // card that fills in a moment later. The manifest keeps this plugin loaded for exactly
  // this reason.
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
            root.activate(root.selectedIndex, (event.modifiers & Qt.ShiftModifier) !== 0)
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

        // Header: what you typed on the left, how many matched on the right.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: filterLine
            anchors.left: parent.left
            anchors.right: countLine.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Play something…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: countLine
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.total > 0 ? (root.total + (root.total === 1 ? " result" : " results")) : ""
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          ListView {
            id: resultList
            anchors.fill: parent
            model: rowModel
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: rowModel.count > 0

            delegate: Rectangle {
              required property int index
              required property string rowKind
              required property string rowId
              required property string rowName
              required property string rowBadge

              readonly property bool hasCursor: index === root.selectedIndex

              width: resultList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Text {
                id: nameText
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
                anchors.right: badgeText.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                text: parent.rowName
                color: parent.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              // play / install / action, in the same words the in-app palette uses.
              Text {
                id: badgeText
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                text: parent.rowBadge
                color: parent.hasCursor ? root.selectedText : root.foreground
                opacity: parent.rowBadge === "play" ? 0.9 : 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.small
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.selectedIndex = index
                onClicked: function(mouse) {
                  root.selectedIndex = index
                  root.activate(index, (mouse.modifiers & Qt.ShiftModifier) !== 0)
                }
              }
            }
          }

          // Three different nothings, and they are not the same message: the app was
          // never run here, the library could not be read, or you typed something no
          // game matches.
          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            width: parent.width
            visible: rowModel.count === 0

            Text {
              text: root.ready ? "󰈉" : "󰅶"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.ready
                ? "No matches for “" + root.filterText + "”"
                : (root.indexError !== "" ? root.indexError : "Reading the library…")
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }
        }
      }
    }
  }
}
