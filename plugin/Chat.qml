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
  property bool browsing: false
  property string model: ""
  property int streamIndex: -1

  readonly property color bg: Color.menu.background
  readonly property color fg: Color.menu.text
  readonly property color accent: Color.menu.selectedBackground
  readonly property color accentText: Color.menu.selectedText
  readonly property string font: Style.font.menuFamily
  readonly property int pad: Style.space(16)

  // ---------------------------------------------------------- lifecycle

  function open(payloadJson) {
    opened = true
    browsing = false
    if (conn.running) send({ op: "sync" })
    else conn.running = true
    Qt.callLater(() => input.forceActiveFocus())
    return "ok"
  }

  function close() {
    opened = false
  }

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
    messages.append({ role: "user", body: text, md: false })
    input.text = ""
  }

  function onMessage(line) {
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    switch (m.ev) {
    case "snapshot":
      connected = true
      busy = m.busy
      model = m.model || ""
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
        if (m.text) messages.setProperty(streamIndex, "body", m.text)
        messages.setProperty(streamIndex, "md", true)
      }
      streamIndex = -1
      break
    case "tool": messages.append({ role: "tool", body: m.name + (m.detail ? "  " + m.detail : ""), md: false }); break
    case "error": messages.append({ role: "error", body: m.text || "error", md: false }); break
    case "sessions":
      sessions.clear()
      for (var j = 0; j < m.list.length; j++) sessions.append(m.list[j])
      break
    }
  }

  function startReply(text) {
    messages.append({ role: "assistant", body: text, md: false })
    streamIndex = messages.count - 1
  }

  function resume(path) {
    send({ op: "resume", path: path })
    browsing = false
    input.forceActiveFocus()
  }

  function showSessions() {
    browsing = true
    search.text = ""
    send({ op: "sessions", query: "" })
    Qt.callLater(() => search.forceActiveFocus())
  }

  ListModel { id: messages }
  ListModel { id: sessions }

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

  // Socket activation fallback: make sure the daemon is up, then reconnect.
  Process { id: starter; command: ["systemctl", "--user", "start", "omarchy-pi.service"] }
  Timer { id: retry; interval: 800; onTriggered: if (root.opened && !conn.running) conn.running = true }
  Timer { id: searchDebounce; interval: 180; onTriggered: root.send({ op: "sessions", query: search.text }) }

  Shortcut {
    sequence: "Escape"
    enabled: root.opened
    onActivated: root.browsing ? (root.browsing = false, input.forceActiveFocus()) : root.dismiss()
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
      id: card
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.bg
      border.color: Color.menu.border
      border.width: 1
      clip: true

      MouseArea { anchors.fill: parent; onClicked: (root.browsing ? search : input).forceActiveFocus() }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.pad
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
            text: root.browsing ? "sessions" : (root.model || "pi")
            elide: Text.ElideRight
            color: root.fg
            font { family: root.font; pixelSize: Style.font.body; bold: true }
          }
          Pill { visible: root.busy && !root.browsing; label: "stop"; onClicked: root.send({ op: "abort" }) }
          Pill { visible: !root.browsing; label: "sessions"; onClicked: root.showSessions() }
          Pill { visible: !root.browsing; label: "new"; onClicked: root.send({ op: "new" }) }
          Pill { visible: root.browsing; label: "back"; onClicked: { root.browsing = false; input.forceActiveFocus() } }
        }

        // Chat.
        ListView {
          id: chat
          visible: !root.browsing
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
              text: role === "tool" ? "⚙ " + body : role === "error" ? "✕ " + body : (body || "…")
              color: role === "error" ? Color.urgent : root.fg
              opacity: role === "tool" ? 0.55 : 1
              selectionColor: root.accent
              selectedTextColor: root.accentText
              font { family: root.font; pixelSize: role === "assistant" ? Style.font.body : Style.font.bodySmall }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: messages.count === 0
            text: root.connected ? "ask pi anything" : "connecting…"
            color: root.fg
            opacity: 0.4
            font { family: root.font; pixelSize: Style.font.body }
          }
        }

        // Sessions.
        Field {
          visible: root.browsing
          Layout.fillWidth: true
          Layout.preferredHeight: search.implicitHeight + Style.space(18)
          TextInput {
            id: search
            anchors { fill: parent; margins: Style.space(9); leftMargin: Style.space(12); rightMargin: Style.space(12) }
            clip: true
            color: root.fg
            font { family: root.font; pixelSize: Style.font.body }
            onTextChanged: searchDebounce.restart()
            Keys.onReturnPressed: if (sessions.count > 0) root.resume(sessions.get(0).path)
          }
        }

        ListView {
          visible: root.browsing
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(4)
          model: sessions
          delegate: Rectangle {
            required property string path
            required property string name
            required property string cwd
            required property int count
            width: ListView.view.width
            height: col.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: hover.containsMouse ? Util.alpha(root.fg, 0.1) : "transparent"
            Column {
              id: col
              anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(8); rightMargin: Style.space(8) }
              Text { width: parent.width; text: name; elide: Text.ElideRight; color: root.fg; font { family: root.font; pixelSize: Style.font.body } }
              Text { width: parent.width; text: cwd + " · " + count + " msgs"; elide: Text.ElideRight; color: root.fg; opacity: 0.5; font { family: root.font; pixelSize: Style.font.caption } }
            }
            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.resume(path)
            }
          }
        }

        // Composer: wraps and grows up to a cap. Enter sends, Shift+Enter breaks.
        Field {
          visible: !root.browsing
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
              onCursorRectangleChanged: {
                var r = cursorRectangle
                if (r.y < flick.contentY) flick.contentY = r.y
                else if (r.y + r.height > flick.contentY + flick.height) flick.contentY = r.y + r.height - flick.height
              }
              Keys.onPressed: event => {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                  root.submit()
                  event.accepted = true
                }
              }
              Text {
                visible: !input.text
                text: root.busy ? "steer…" : "ask pi…"
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
      anchors.centerIn: parent
      text: parent.label
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
