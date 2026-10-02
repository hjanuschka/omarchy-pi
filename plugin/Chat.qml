import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Thin floating client for the omarchy-pi daemon. The daemon owns the agent;
// this overlay only renders its JSONL events, so hiding it never stops a run.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-pi.sock"
  property bool opened: false
  property bool connected: false
  property bool busy: false
  property string workspace: ""
  property string model: ""
  property string thinking: ""
  property int streamIndex: -1
  property string pickKind: ""          // "" = chat, else "sessions" | "models"
  property var commands: []

  readonly property color bg: Color.menu.background
  readonly property color fg: Color.menu.text
  readonly property color accent: Color.menu.selectedBackground
  readonly property color accentText: Color.menu.selectedText
  readonly property string font: Style.font.menuFamily

  // Slash completion: active while the composer holds "/word" with no space.
  readonly property string slashQuery: /^\/\S*$/.test(input.text) ? input.text.slice(1).toLowerCase() : ""
  readonly property bool slashing: pickKind === "" && /^\/\S*$/.test(input.text) && completions.count > 0
  onSlashQueryChanged: refreshCompletions()
  onCommandsChanged: refreshCompletions()

  // ---------------------------------------------------------- lifecycle

  function open(payloadJson) {
    opened = true
    pickKind = ""
    if (conn.running) send({ op: "sync" })
    else conn.running = true
    Qt.callLater(() => input.forceActiveFocus())
    return "ok"
  }

  function close() { opened = false }

  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || "hjanuschka.omarchy-pi")
  }

  // ---------------------------------------------------------- protocol

  function send(msg) {
    if (conn.running) conn.write(JSON.stringify(msg) + "\n")
  }

  function submit() {
    var text = input.text.trim()
    if (!text) return
    send({ op: "prompt", text: text })
    if (text[0] !== "/") messages.append({ role: "user", body: text, md: false })
    input.text = ""
  }

  function onMessage(line) {
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    switch (m.ev) {
    case "snapshot":
      connected = true
      busy = m.busy
      workspace = m.title || m.workspace || ""
      model = m.model || ""
      thinking = m.thinking || ""
      messages.clear()
      streamIndex = -1
      for (var i = 0; i < m.messages.length; i++)
        messages.append({ role: m.messages[i].role, body: m.messages[i].text, md: m.messages[i].role === "assistant" })
      if (m.partial !== null && m.partial !== undefined) startReply(m.partial)
      break
    case "busy": busy = m.value; break
    case "start": startReply(""); break
    case "delta":
      if (streamIndex < 0) startReply("")
      messages.setProperty(streamIndex, "body", messages.get(streamIndex).body + m.text)
      break
    case "end":
      if (streamIndex >= 0) {
        var text = m.text || messages.get(streamIndex).body
        if (text) {
          messages.setProperty(streamIndex, "body", text)
          messages.setProperty(streamIndex, "md", true)
        } else {
          messages.remove(streamIndex)   // tool-only turn
        }
      }
      streamIndex = -1
      break
    case "tool": note("tool", m.name + (m.detail ? "  " + m.detail : "")); break
    case "info": note("info", m.text); break
    case "error": note("error", m.text || "error"); break
    case "commands": commands = m.list; break
    case "view": openPicker(m.kind, m.query || ""); break
    case "pick":
      if (m.kind !== pickKind) break
      picks.clear()
      for (var j = 0; j < m.items.length; j++)
        picks.append({ title: m.items[j].title, subtitle: m.items[j].subtitle, action: JSON.stringify(m.items[j].action) })
      pickList.currentIndex = 0
      break
    }
  }

  // Notes are inserted before a streaming reply so the reply stays last.
  function note(role, body) {
    if (streamIndex >= 0) { messages.insert(streamIndex, { role: role, body: body, md: false }); streamIndex++ }
    else messages.append({ role: role, body: body, md: false })
  }

  function startReply(text) {
    messages.append({ role: "assistant", body: text, md: false })
    streamIndex = messages.count - 1
  }

  // ---------------------------------------------------------- picker

  function openPicker(kind, query) {
    pickKind = kind
    picks.clear()
    search.text = query
    send({ op: "pick", kind: kind, query: query })
    Qt.callLater(() => search.forceActiveFocus())
  }

  function closePicker() {
    pickKind = ""
    input.forceActiveFocus()
  }

  function choose(index) {
    if (index < 0 || index >= picks.count) return
    send(JSON.parse(picks.get(index).action))
    closePicker()
  }

  // ---------------------------------------------------------- slash completion

  function refreshCompletions() {
    completions.clear()
    if (!/^\/\S*$/.test(input.text)) return
    var q = slashQuery
    var starts = [], contains = []
    for (var i = 0; i < commands.length; i++) {
      var c = commands[i]
      var n = c.name.toLowerCase()
      if (n.indexOf(q) === 0) starts.push(c)
      else if (q && n.indexOf(q) > 0) contains.push(c)
    }
    var all = starts.concat(contains).slice(0, 8)
    for (var j = 0; j < all.length; j++) completions.append(all[j])
    completionList.currentIndex = 0
  }

  function complete() {
    var c = completions.get(Math.max(0, completionList.currentIndex))
    input.text = "/" + c.name + " "
    input.cursorPosition = input.text.length
  }

  ListModel { id: messages }
  ListModel { id: picks }
  ListModel { id: completions }

  Process {
    id: conn
    command: ["socat", "-", "UNIX-CONNECT:" + root.socketPath]
    stdinEnabled: true
    stdout: SplitParser { splitMarker: "\n"; onRead: line => root.onMessage(line) }
    onStarted: root.send({ op: "sync" })
    onExited: {
      root.connected = false
      if (root.opened) { starter.running = true; retry.start() }
    }
  }

  // Make sure the daemon is up, then reconnect.
  Process { id: starter; command: ["systemctl", "--user", "start", "omarchy-pi.service"] }
  Timer { id: retry; interval: 800; onTriggered: if (root.opened && !conn.running) conn.running = true }
  Timer { id: searchDebounce; interval: 150; onTriggered: root.send({ op: "pick", kind: root.pickKind, query: search.text }) }

  Shortcut {
    sequence: "Escape"
    enabled: root.opened
    onActivated: {
      if (root.pickKind) root.closePicker()
      else if (root.slashing) input.text = ""
      else root.dismiss()
    }
  }

  // ---------------------------------------------------------- surface

  PanelWindow {
    visible: root.opened
    anchors { bottom: true; right: true }
    margins { bottom: Style.gapsOut + Style.space(12); right: Style.gapsOut + Style.space(12) }
    implicitWidth: Style.space(440)
    implicitHeight: Style.space(580)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-pi"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.bg
      border.color: Color.menu.border
      border.width: 1
      clip: true

      MouseArea { anchors.fill: parent; onClicked: (root.pickKind ? search : input).forceActiveFocus() }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.space(10)

        // Header. Every Text here is width-bounded: an unbounded Text in a
        // RowLayout takes its full implicit width and pushes the card wider.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Rectangle {
            Layout.preferredWidth: Style.space(8); Layout.preferredHeight: Style.space(8)
            radius: width / 2
            color: !root.connected ? Color.urgent : root.busy ? root.accentText : Util.alpha(root.fg, 0.35)
          }
          Text {
            Layout.fillWidth: true
            text: root.pickKind || root.workspace || "pi"
            elide: Text.ElideMiddle
            color: root.fg
            font { family: root.font; pixelSize: Style.font.body; bold: true }
          }
          Pill { visible: root.busy && !root.pickKind; label: "stop"; onClicked: root.send({ op: "abort" }) }
          Pill {
            visible: !root.pickKind
            Layout.maximumWidth: Style.space(170)
            label: root.model + (root.thinking && root.thinking !== "off" ? " · " + root.thinking : "")
            onClicked: root.openPicker("models", "")
          }
          Pill { visible: !root.pickKind; label: "chats"; onClicked: root.openPicker("sessions", "") }
          Pill { visible: !root.pickKind; label: "new"; onClicked: root.send({ op: "new", name: "" }) }
          Pill { visible: !!root.pickKind; label: "back"; onClicked: root.closePicker() }
        }

        // ------------------------------------------------------- chat
        ListView {
          id: chat
          visible: !root.pickKind
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(10)
          model: messages
          onCountChanged: Qt.callLater(positionViewAtEnd)
          onContentHeightChanged: if (atYEnd || root.busy) positionViewAtEnd()

          delegate: Item {
            required property string role
            required property string body
            required property bool md
            width: ListView.view.width
            height: role === "user" ? bubble.height : line.implicitHeight

            Rectangle {
              id: bubble
              visible: role === "user"
              anchors.right: parent.right
              width: Math.min(parent.width * 0.85, userText.implicitWidth + Style.space(20))
              height: userText.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: root.accent
              Text {
                id: userText
                anchors { fill: parent; margins: Style.space(7); leftMargin: Style.space(10); rightMargin: Style.space(10) }
                text: body
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: root.accentText
                font { family: root.font; pixelSize: Style.font.body }
              }
            }

            TextEdit {
              id: line
              visible: role !== "user"
              width: parent.width
              readOnly: true
              selectByMouse: true
              wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
              textFormat: md ? TextEdit.MarkdownText : TextEdit.PlainText
              text: ({ tool: "⚙ ", info: "• ", error: "✕ " }[role] || "") + (body || "…")
              color: role === "error" ? Color.urgent : root.fg
              opacity: role === "tool" || role === "info" ? 0.55 : 1
              selectionColor: root.accent
              selectedTextColor: root.accentText
              font { family: root.font; pixelSize: role === "assistant" ? Style.font.body : Style.font.bodySmall }
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: messages.count === 0
            text: root.connected ? "ask pi anything · / for commands" : "connecting…"
            color: root.fg
            opacity: 0.4
            font { family: root.font; pixelSize: Style.font.body }
          }
        }

        // Slash completions, docked above the composer.
        ListView {
          id: completionList
          visible: root.slashing
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(contentHeight, Style.space(200))
          clip: true
          model: completions
          highlightMoveDuration: 0
          delegate: Item {
            required property int index
            required property string name
            required property string description
            width: ListView.view.width
            height: Style.space(26)
            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: index === completionList.currentIndex ? Util.alpha(root.fg, 0.1) : "transparent"
            }
            Text {
              id: cmdName
              x: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width * 0.45)
              text: "/" + name
              elide: Text.ElideRight
              color: root.fg
              font { family: root.font; pixelSize: Style.font.body; bold: true }
            }
            Text {
              x: cmdName.x + cmdName.width + Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - x - Style.space(8)
              text: description
              elide: Text.ElideRight
              color: root.fg
              opacity: 0.5
              font { family: root.font; pixelSize: Style.font.caption }
            }
          }
        }

        // ------------------------------------------------------- picker
        Field {
          visible: !!root.pickKind
          Layout.fillWidth: true
          Layout.preferredHeight: search.implicitHeight + Style.space(18)
          TextInput {
            id: search
            anchors { fill: parent; margins: Style.space(9); leftMargin: Style.space(12); rightMargin: Style.space(12) }
            clip: true
            color: root.fg
            font { family: root.font; pixelSize: Style.font.body }
            onTextChanged: if (root.pickKind) searchDebounce.restart()
            Keys.onPressed: event => {
              if (event.key === Qt.Key_Down) { pickList.incrementCurrentIndex(); event.accepted = true }
              else if (event.key === Qt.Key_Up) { pickList.decrementCurrentIndex(); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.choose(pickList.currentIndex); event.accepted = true }
            }
          }
        }

        ListView {
          id: pickList
          visible: !!root.pickKind
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(2)
          model: picks
          highlightMoveDuration: 0
          delegate: Rectangle {
            required property int index
            required property string title
            required property string subtitle
            width: ListView.view.width
            height: col.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: index === pickList.currentIndex || hover.containsMouse ? Util.alpha(root.fg, 0.1) : "transparent"
            Column {
              id: col
              anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(8); rightMargin: Style.space(8) }
              Text { width: parent.width; text: title; elide: Text.ElideRight; color: root.fg; font { family: root.font; pixelSize: Style.font.body } }
              Text { width: parent.width; text: subtitle; elide: Text.ElideRight; color: root.fg; opacity: 0.5; font { family: root.font; pixelSize: Style.font.caption } }
            }
            MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.choose(index) }
          }
        }

        // ------------------------------------------------------- composer
        // Wraps and grows up to a cap. Enter sends, Shift+Enter breaks,
        // Tab completes a slash command.
        Field {
          visible: !root.pickKind
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(Style.space(150), input.implicitHeight + Style.space(18))
          Flickable {
            id: flick
            anchors { fill: parent; margins: Style.space(9); leftMargin: Style.space(12); rightMargin: Style.space(12) }
            clip: true
            contentWidth: width
            contentHeight: input.implicitHeight
            TextEdit {
              id: input
              width: flick.width
              wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
              color: root.fg
              selectionColor: root.accent
              selectedTextColor: root.accentText
              font { family: root.font; pixelSize: Style.font.body }
              onTextChanged: root.refreshCompletions()
              onCursorRectangleChanged: {
                var r = cursorRectangle
                if (r.y < flick.contentY) flick.contentY = r.y
                else if (r.y + r.height > flick.contentY + flick.height) flick.contentY = r.y + r.height - flick.height
              }
              Keys.onPressed: event => {
                var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                if (root.slashing && event.key === Qt.Key_Down) { completionList.incrementCurrentIndex(); event.accepted = true }
                else if (root.slashing && event.key === Qt.Key_Up) { completionList.decrementCurrentIndex(); event.accepted = true }
                else if (root.slashing && (event.key === Qt.Key_Tab || enter)) {
                  // Enter on an exact match runs it; otherwise it completes.
                  var picked = completions.get(Math.max(0, completionList.currentIndex)).name
                  if (enter && input.text === "/" + picked) root.submit()
                  else root.complete()
                  event.accepted = true
                }
                else if (enter && !(event.modifiers & Qt.ShiftModifier)) { root.submit(); event.accepted = true }
              }
              Text {
                visible: !input.text
                text: root.busy ? "steer…" : "ask pi… ( / for commands )"
                color: root.fg
                opacity: 0.4
                font: input.font
              }
            }
          }
        }
      }
    }
  }

  component Pill: Rectangle {
    property string label
    signal clicked
    Layout.preferredHeight: Style.space(22)
    Layout.preferredWidth: pillText.implicitWidth + Style.space(16)
    radius: height / 2
    color: Util.alpha(root.fg, pillArea.containsMouse ? 0.18 : 0.08)
    Text {
      id: pillText
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(8); rightMargin: Style.space(8) }
      horizontalAlignment: Text.AlignHCenter
      text: parent.label
      elide: Text.ElideRight
      color: root.fg
      font { family: root.font; pixelSize: Style.font.caption }
    }
    MouseArea { id: pillArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
  }

  component Field: Rectangle {
    radius: Style.cornerRadius
    color: Util.alpha(root.fg, 0.06)
    border.color: Util.alpha(root.fg, 0.18)
    border.width: 1
  }
}
