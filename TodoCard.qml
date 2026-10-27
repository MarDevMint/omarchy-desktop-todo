import QtQuick
import QtQuick.Controls as QQC
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Palette.js" as Palette

// One list on the desktop, backed by one Markdown file:
//
//   # TODO
//   <!-- color: mint -->
//   - [ ] open task
//   - [x] finished task
//
// The heading is the card title, the comment holds the color ("theme" when
// absent). Any other line is kept as-is; the card only rewrites what it owns.
BorderSurface {
  id: card

  required property string path
  property bool canDelete: true

  signal addListRequested()
  signal deleteRequested()
  signal focusReleased()

  readonly property var taskPattern: /^(\s*[-*]\s+\[)([ xX])(\]\s?)(.*)$/
  readonly property var titlePattern: /^#\s+(.*)$/
  readonly property var colorPattern: /^<!--\s*color:\s*([\w-]+)\s*-->$/

  property var lines: []
  property var tasks: []          // [{ line, done, text }]
  property string title: "TODO"
  property string colorId: "theme"
  property bool menuOpen: false
  property bool editMenuOpen: false
  property bool confirmDelete: false
  readonly property int doneCount: tasks.filter(t => t.done).length

  // ------------------------------------------------------------ colors
  //
  // Theme: the popup palette. Pastel: tinted paper with ink derived from
  // the swatch itself, so text keeps contrast on any theme.
  readonly property var swatch: Palette.find(colorId)
  readonly property bool themed: swatch === null
  // Dark themes or night hours flip pastels: deep tinted paper, pastel ink.
  property bool clockNight: false
  readonly property bool night: clockNight || (0.2126 * Color.background.r + 0.7152 * Color.background.g + 0.0722 * Color.background.b) < 0.5
  readonly property color paper: themed ? Util.alpha(Color.popups.background, 0.92)
                                 : Util.alpha(night ? swatch.night : swatch.color, 0.95)
  readonly property color ink: themed ? Color.foreground : night ? Qt.lighter(swatch.color, 1.08) : Qt.darker(swatch.color, 3.6)
  readonly property color accent: themed ? Color.accent : night ? swatch.color : Qt.darker(swatch.color, 1.9)
  readonly property color dim: Util.alpha(ink, 0.6)
  readonly property color edge: themed ? Color.popups.border : night ? Qt.darker(swatch.color, 1.6) : Qt.darker(swatch.color, 1.3)

  function focusInput() { input.forceActiveFocus() }

  // ------------------------------------------------------------ clipboard

  property int copiedLine: -1

  function copyTask(lineIndex, text) {
    Util.execArgv(["wl-copy", "--", text])
    copiedLine = lineIndex
    copiedTimer.restart()
  }

  Timer { id: copiedTimer; interval: 1200; onTriggered: card.copiedLine = -1 }

  // ------------------------------------------------------------ storage
  //
  // Writes wait until the file has loaded: a card that never read its file,
  // or lost it, must not overwrite it with an empty list. Tasks added before
  // then (IPC at startup) queue in `pending`.

  property bool ready: false
  property var pending: []

  signal fileMissing()

  function parse(text) {
    var ls = text.length ? text.replace(/\r?\n$/, "").split(/\r?\n/) : []
    var ts = []
    var t = "TODO"
    var c = "theme"
    var seenTitle = false
    var seenColor = false
    for (var i = 0; i < ls.length; i++) {
      var m = ls[i].match(taskPattern)
      if (m) { ts.push({ line: i, done: m[2] !== " ", text: m[4] }); continue }
      var h = ls[i].match(titlePattern)
      if (h && !seenTitle) { t = h[1].trim() || "TODO"; seenTitle = true; continue }
      var k = ls[i].match(colorPattern)
      if (k && !seenColor) { c = k[1]; seenColor = true }
    }
    lines = ls
    tasks = ts
    title = t
    colorId = c
  }

  function save(ls) {
    if (!ready) return
    var text = ls.join("\n") + (ls.length ? "\n" : "")
    parse(text)
    file.setText(text)
  }

  // Replace the first line matching `pattern`, or insert `value` at `at`.
  function upsert(ls, pattern, value, at) {
    for (var i = 0; i < ls.length; i++) {
      if (ls[i].match(pattern) && !ls[i].match(taskPattern)) { ls[i] = value; return ls }
    }
    ls.splice(at, 0, value)
    return ls
  }

  function addTask(text) {
    // One task is one line: pasted line breaks become spaces.
    var entry = String(text || "").replace(/\s*[\r\n]+\s*/g, " ").trim()
    if (!entry.length) return
    if (!ready) { pending.push(entry); return }
    // New tasks join the open ones: after the last open task, else before
    // the first finished one, else at the end.
    var open = tasks.filter(t => !t.done)
    var at = open.length ? open[open.length - 1].line + 1
           : tasks.length ? tasks[0].line
           : lines.length
    var ls = lines.slice()
    ls.splice(at, 0, "- [ ] " + entry)
    save(ls)
  }

  function toggleTask(lineIndex) {
    var ls = lines.slice()
    var m = ls[lineIndex] && ls[lineIndex].match(taskPattern)
    if (!m) return
    ls[lineIndex] = m[1] + (m[2] === " " ? "x" : " ") + m[3] + m[4]
    save(ls)
  }

  function removeTask(lineIndex) {
    var ls = lines.slice()
    if (!(ls[lineIndex] || "").match(taskPattern)) return
    ls.splice(lineIndex, 1)
    save(ls)
  }

  function clearDone() {
    save(lines.filter(l => {
      var m = l.match(taskPattern)
      return !(m && m[2] !== " ")
    }))
  }

  function rename(name) {
    var n = String(name || "").trim()
    if (!n.length || n === title) return
    save(upsert(lines.slice(), titlePattern, "# " + n, 0))
  }

  function setColor(id) {
    var ls = lines.slice()
    if (id === "theme") {
      ls = ls.filter(l => !l.match(colorPattern))
    } else {
      // A new color comment goes right under the title (or on top).
      var titleAt = ls.findIndex(l => titlePattern.test(l))
      ls = upsert(ls, colorPattern, "<!-- color: " + id + " -->", titleAt + 1)
    }
    save(ls)
  }

  FileView {
    id: file
    path: card.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      card.parse(text())
      card.ready = true
      var queued = card.pending
      card.pending = []
      queued.forEach(t => card.addTask(t))
    }
    // Keep showing the last good content, but stop writing until the file
    // is back; the service rescans and drops the card if it is gone.
    onLoadFailed: {
      card.ready = false
      card.fileMissing()
    }
    onSaveFailed: reload()
  }

  // ------------------------------------------------------------- surface

  implicitWidth: Style.space(300)
  implicitHeight: column.implicitHeight + contentTopInset + contentBottomInset
  color: paper
  borderSpec: themed
    ? Border.localOrSurfaceSpec("popups", "border", edge, edge, Math.max(1, Style.space(2)))
    : Border.flat(edge, Math.max(1, Style.space(2)))
  padding: Style.spacing.popupPadding
  radius: Style.cornerRadius

  Behavior on color { ColorAnimation { duration: 160 } }

  onMenuOpenChanged: {
    if (menuOpen) editMenuOpen = false
    else confirmDelete = false
  }

  onEditMenuOpenChanged: if (editMenuOpen) menuOpen = false

  // Right-click on the input opens the edit actions, anywhere else the
  // card menu. One handler so the two never open together.
  TapHandler {
    acceptedButtons: Qt.RightButton
    onTapped: eventPoint => {
      if (input.contains(input.mapFromItem(card, eventPoint.position))) {
        input.forceActiveFocus()
        card.editMenuOpen = !card.editMenuOpen
      } else {
        card.menuOpen = !card.menuOpen
      }
    }
  }

  Column {
    id: column
    x: card.contentLeftInset
    y: card.contentTopInset
    width: card.width - card.contentLeftInset - card.contentRightInset
    spacing: Style.spacing.rowGap

    // Header: title (double-click to rename), clear-done, new list.
    Item {
      width: parent.width
      height: Math.max(titleText.implicitHeight, plus.implicitHeight)

      Text {
        id: titleText
        visible: !titleEdit.visible
        anchors.left: parent.left
        anchors.right: clear.visible ? clear.left : plus.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: card.title.toUpperCase()
        elide: Text.ElideRight
        color: card.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        font.letterSpacing: 1

        MouseArea {
          anchors.fill: parent
          onDoubleClicked: {
            titleEdit.text = card.title
            titleEdit.visible = true
            titleEdit.forceActiveFocus()
            titleEdit.selectAll()
          }
        }
      }

      TextInput {
        id: titleEdit
        visible: false
        anchors.fill: titleText
        verticalAlignment: TextInput.AlignVCenter
        color: card.accent
        selectionColor: Util.alpha(card.accent, 0.3)
        selectedTextColor: card.ink
        font: titleText.font
        maximumLength: 40
        function finish(commit) {
          if (!visible) return
          if (commit) card.rename(text)
          visible = false
          card.focusReleased()
        }
        onAccepted: finish(true)
        onActiveFocusChanged: if (!activeFocus) finish(true)
        Keys.onEscapePressed: finish(false)
      }

      Text {
        id: clear
        anchors.right: plus.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        visible: card.doneCount > 0
        text: "clear done"
        color: clearArea.containsMouse ? card.ink : card.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        MouseArea {
          id: clearArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: card.clearDone()
        }
      }

      Text {
        id: plus
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "+"
        color: plusArea.containsMouse ? card.accent : card.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
        MouseArea {
          id: plusArea
          anchors.fill: parent
          anchors.margins: -Style.spacing.sm
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: card.addListRequested()
        }
      }
    }

    // Right-click menu: color swatches and delete, inline so it never
    // leaves the card's own surface.
    Item {
      visible: card.menuOpen
      width: parent.width
      height: menuColumn.implicitHeight

      Column {
        id: menuColumn
        width: parent.width
        spacing: Style.spacing.md

        Flow {
          width: parent.width
          spacing: Style.spacing.md

          // "Theme" chip: follows the active Omarchy theme.
          Rectangle {
            readonly property bool active: card.themed
            height: Style.space(18)
            width: themeLabel.implicitWidth + Style.spacing.lg * 2
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: Color.popups.background
            border.width: active ? Math.max(2, Style.space(2)) : 1
            border.color: active ? card.ink : Util.alpha(card.ink, 0.35)

            Text {
              id: themeLabel
              anchors.centerIn: parent
              text: "Theme"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { card.setColor("theme"); card.menuOpen = false }
            }
          }

          Repeater {
            model: Palette.SWATCHES

            delegate: Rectangle {
              required property var modelData
              readonly property bool active: card.colorId === modelData.id
              height: Style.space(18)
              width: height
              radius: Style.cornerRadius > 0 ? height / 2 : 0
              color: card.night ? modelData.night : modelData.color
              border.width: active ? Math.max(2, Style.space(2)) : 1
              border.color: active ? card.ink : card.night ? modelData.color : Qt.darker(modelData.color, 1.3)

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { card.setColor(parent.modelData.id); card.menuOpen = false }
              }
            }
          }
        }

        Text {
          visible: card.canDelete
          text: card.confirmDelete ? "Click again to delete this list" : "Delete list"
          color: deleteArea.containsMouse || card.confirmDelete ? Color.urgent : card.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          MouseArea {
            id: deleteArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (card.confirmDelete) card.deleteRequested()
              else card.confirmDelete = true
            }
          }
        }
      }
    }

    TextField {
      id: input
      width: parent.width
      foreground: card.ink
      accent: card.accent
      placeholderText: "Add a task…"
      QQC.ContextMenu.menu: null    // replaced by the inline edit actions below
      onAccepted: { card.addTask(text); text = "" }
      onActiveFocusChanged: if (!activeFocus) { card.editMenuOpen = false; card.focusReleased() }
      Keys.onEscapePressed: {
        if (card.editMenuOpen) { card.editMenuOpen = false; return }
        text = ""; focus = false
      }
    }

    // Edit actions for the input, inline like the card menu: captions that
    // dim when they don't apply.
    Flow {
      visible: card.editMenuOpen
      width: parent.width
      spacing: Style.spacing.lg

      Repeater {
        model: [
          { label: "cut",        enabled: input.selectedText.length > 0, run: () => input.cut() },
          { label: "copy",       enabled: input.selectedText.length > 0, run: () => input.copy() },
          { label: "paste",      enabled: input.canPaste,                run: () => input.paste() },
          { label: "select all", enabled: input.text.length > 0,         run: () => input.selectAll() }
        ]

        delegate: Text {
          required property var modelData
          text: modelData.label
          color: !modelData.enabled ? Util.alpha(card.ink, 0.3)
               : actionArea.containsMouse ? card.accent : card.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          MouseArea {
            id: actionArea
            anchors.fill: parent
            anchors.margins: -Style.spacing.xs
            enabled: parent.modelData.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              parent.modelData.run()
              input.forceActiveFocus()
              if (parent.modelData.label !== "select all") card.editMenuOpen = false
            }
          }
        }
      }
    }

    Repeater {
      model: card.tasks

      delegate: Item {
        id: row
        required property var modelData
        width: column.width
        height: Math.max(label.implicitHeight, box.height) + Style.spacing.xs * 2

        HoverHandler { id: rowHover }

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: -Style.spacing.sm
          anchors.rightMargin: -Style.spacing.sm
          radius: Style.cornerRadius
          color: rowHover.hovered ? Util.alpha(card.ink, 0.08) : "transparent"
        }

        // Checkbox, drawn so it follows the palette on any font.
        Rectangle {
          id: box
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.topMargin: Style.spacing.xs + (fontMetrics.height - height) / 2
          width: Style.space(13); height: width
          radius: Style.cornerRadius > 0 ? Style.space(3) : 0
          color: row.modelData.done ? card.accent : "transparent"
          border.width: Math.max(1, Style.space(1.5))
          border.color: row.modelData.done ? card.accent : card.dim

          Text {
            anchors.centerIn: parent
            visible: row.modelData.done
            text: "✓"
            color: card.paper
            font.pixelSize: parent.width * 0.85
            font.bold: true
          }
        }

        Text {
          id: label
          anchors.left: box.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: copy.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: row.modelData.text
          wrapMode: Text.Wrap
          color: row.modelData.done ? card.dim : card.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.strikeout: row.modelData.done
          FontMetrics { id: fontMetrics; font: label.font }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: card.toggleTask(row.modelData.line)
        }

        // Copy the task text; shows a check for a moment once copied.
        Text {
          id: copy
          readonly property bool copied: card.copiedLine === row.modelData.line
          anchors.right: remove.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          opacity: rowHover.hovered || copied ? 1 : 0
          text: copied ? "✓" : "󰆏"
          color: copied || copyArea.containsMouse ? card.accent : card.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          Behavior on opacity { NumberAnimation { duration: 120 } }
          MouseArea {
            id: copyArea
            anchors.fill: parent
            anchors.margins: -Style.spacing.sm
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: card.copyTask(row.modelData.line, row.modelData.text)
          }
        }

        Text {
          id: remove
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          opacity: rowHover.hovered ? 1 : 0
          text: "✕"
          color: removeArea.containsMouse ? Color.urgent : card.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          Behavior on opacity { NumberAnimation { duration: 120 } }
          MouseArea {
            id: removeArea
            anchors.fill: parent
            anchors.margins: -Style.spacing.sm
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: card.removeTask(row.modelData.line)
          }
        }
      }
    }
  }
}
