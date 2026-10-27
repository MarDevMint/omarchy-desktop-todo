import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Desktop lists.
//
// Every `*.md` file in ~/.local/share/omarchy/todo/ is one card (see
// TodoCard.qml for the file format). Cards sit top-left on the Bottom
// layer: above the wallpaper, below every window. They take keyboard focus
// only on demand (click an input); Escape hands it back.
//
// Mouse:  "+" new list · right-click colors / delete · double-click title rename
//         right-click the input: cut / copy / paste / select all
//         copy icon on a task: copy its text
//         drag any empty part of a card: move that card (position is
//         saved per card in ~/.local/state/omarchy/settings/todo-position.json)
//
// IPC:    omarchy-shell todo add "text"   (first list)
//         omarchy-shell todo toggle       (show / hide)
//         omarchy-shell todo focus        (jump to the first input)
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string listDir: home + "/.local/share/omarchy/todo"
  readonly property string legacyFile: home + "/.local/share/omarchy/todo.md"

  property var files: []
  property bool scanned: false
  property bool shown: true
  property bool grabFocus: false

  // Lists sort by creation time encoded in the name (todo-<ms>.md); the
  // original todo.md always comes first.
  function order(path) {
    var m = path.match(/-(\d+)\.md$/)
    return m ? Number(m[1]) : 0
  }

  // Coalesce bursts (create, trash, a card losing its file) into one scan;
  // a request that lands mid-scan waits for it to finish.
  function rescan() { rescanTimer.restart() }

  Timer {
    id: rescanTimer
    interval: 150
    onTriggered: if (scan.running) restart(); else scan.running = true
  }

  function newList() {
    create.command = ["sh", "-c", "printf '# NOTES\\n' > \"$1\"", "_",
                      listDir + "/todo-" + Date.now() + ".md"]
    create.running = true
  }

  function deleteList(path) {
    if (files.length <= 1) return
    trash.command = ["gio", "trash", path]
    trash.running = true
  }

  // Card positions (layer-shell margins) by file name, restored at start,
  // saved on drop. Cards never moved fall back to a row from the top-left.
  property var positions: ({})
  readonly property string posFile: home + "/.local/state/omarchy/settings/todo-position.json"

  FileView {
    id: posView
    path: root.posFile
    printErrors: false
    onLoaded: {
      try {
        var p = JSON.parse(text())
        root.positions = (typeof p.x === "number") ? {} : p   // old single-widget format
      } catch (e) {}
    }
  }

  function savePosition(name, x, y) {
    var p = Object.assign({}, root.positions)
    p[name] = { x: x, y: y }
    root.positions = p
    posView.setText(JSON.stringify(p) + "\n")
  }

  // Night from the clock, alongside the dark-theme check in TodoCard; same
  // hours as the evening/morning theme timers.
  readonly property int nightStart: 18
  readonly property int nightEnd: 7
  property bool clockNight: false
  function updateClock() { var h = new Date().getHours(); clockNight = h >= nightStart || h < nightEnd }
  Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.updateClock() }

  property var cardItems: ({})
  function firstCard() { return root.files.length ? root.cardItems[root.files[0]] || null : null }

  // Ensure the directory exists, migrate the single-file version, seed a
  // first list, then print every list path.
  Process {
    id: scan
    running: true
    command: ["sh", "-c",
      "mkdir -p \"$1\"\n" +
      "[ -f \"$2\" ] && [ ! -e \"$1/todo.md\" ] && mv \"$2\" \"$1/todo.md\"\n" +
      "ls \"$1\"/*.md >/dev/null 2>&1 || printf '# TODO\\n' > \"$1/todo.md\"\n" +
      "ls -1 \"$1\"/*.md",
      "_", root.listDir, root.legacyFile]
    stdout: StdioCollector {
      onStreamFinished: {
        var paths = text.split("\n").filter(p => p.length)
        paths.sort((a, b) => root.order(a) - root.order(b))
        // Reassigning an equal list would rebuild every card (and drop
        // whatever is being typed), so only publish real changes.
        if (paths.join("\n") !== root.files.join("\n")) root.files = paths
        root.scanned = true
      }
    }
  }

  // Lists added or removed outside the cards (file manager, editor, a file
  // that comes back) trigger a rescan. Only a trigger: the scan stays the
  // source of truth. Starts after the first scan has created the folder.
  FolderListModel {
    folder: root.scanned ? "file://" + root.listDir : ""
    nameFilters: ["*.md"]
    showDirs: false
    onCountChanged: root.rescan()
  }

  Process { id: create; onExited: root.rescan() }
  Process { id: trash; onExited: root.rescan() }

  IpcHandler {
    target: "todo"
    function add(text: string): void { var c = root.firstCard(); if (c) c.addTask(text) }
    function toggle(): void { root.shown = !root.shown }
    function focus(): void {
      root.shown = true
      root.grabFocus = true
      var c = root.firstCard()
      if (c) c.focusInput()
    }
  }

  // One window per card, so each one drags on its own.
  Variants {
    model: root.files

    PanelWindow {
      id: window
      required property string modelData
      readonly property string name: modelData.split("/").pop()
      readonly property int index: root.files.indexOf(modelData)
      readonly property int edge: Math.max(Style.gapsOut * 2, Style.spacing.huge)
      readonly property int gap: Style.spacing.huge
      readonly property int cardWidth: Style.space(300)
      readonly property var saved: root.positions[name]
      property int posX: saved ? saved.x : edge + index * (cardWidth + gap)
      property int posY: saved ? saved.y : edge

      visible: root.shown
      screen: Quickshell.screens.length ? Quickshell.screens[0] : null
      color: "transparent"
      WlrLayershell.namespace: "m-todo"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: root.grabFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
      exclusionMode: ExclusionMode.Ignore

      anchors { top: true; left: true }
      margins { top: posY; left: posX }

      implicitWidth: cardWidth
      implicitHeight: Math.max(1, card.implicitHeight)

      // Underneath the card: presses on its empty areas fall through to it
      // and drag this window. Each move shifts the margins by the pointer's
      // offset from the press point, which the moving window keeps under it.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real pressX: 0
        property real pressY: 0
        onPressed: mouse => { pressX = mouse.x; pressY = mouse.y }
        onPositionChanged: mouse => {
          var sw = window.screen ? window.screen.width : 1920
          var sh = window.screen ? window.screen.height : 1080
          window.posX = Math.max(0, Math.min(sw - window.width, window.posX + Math.round(mouse.x - pressX)))
          window.posY = Math.max(0, Math.min(sh - window.height, window.posY + Math.round(mouse.y - pressY)))
        }
        onReleased: root.savePosition(window.name, window.posX, window.posY)
      }

      TodoCard {
        id: card
        path: window.modelData
        width: window.cardWidth
        canDelete: root.files.length > 1
        clockNight: root.clockNight
        onAddListRequested: root.newList()
        onDeleteRequested: root.deleteList(path)
        onFileMissing: root.rescan()
        onFocusReleased: root.grabFocus = false
        Component.onCompleted: { var c = Object.assign({}, root.cardItems); c[window.modelData] = card; root.cardItems = c }
      }
    }
  }
}
