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
  property string title: ""
  property string model: ""
  property string thinking: ""
  property int streamIndex: -1
  property bool replying: false         // the streaming reply has visible text
  property bool stick: true             // follow new output until the user scrolls up
  property string pickKind: ""          // "" = chat, else "sessions" | "models" | "folders"
  property bool newMenuOpen: false
  property var commands: []
  property var recent: []

  readonly property color bg: Color.menu.background
  readonly property color fg: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color userBubble: Qt.tint(bg, Util.alpha(accent, 0.16))
  readonly property color botBubble: Qt.tint(bg, Util.alpha(fg, 0.06))
  readonly property string font: Style.font.menuFamily
  readonly property int radius: Style.space(14)

  readonly property string slashQuery: /^\/\S*$/.test(input.text) ? input.text.slice(1).toLowerCase() : ""
  readonly property bool slashing: pickKind === "" && /^\/\S*$/.test(input.text) && completions.count > 0
  onCommandsChanged: refreshCompletions()

  // ---------------------------------------------------------- lifecycle

  function open(payloadJson) {
    opened = true
    pickKind = ""
    newMenuOpen = false
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
    if (text[0] !== "/") append("user", text, "", Date.now())
    stick = true
    input.text = ""
  }

  function append(role, body, html, ts) {
    messages.append({ role: role, body: body, html: html || "", ts: ts || Date.now() })
  }

  function onMessage(line) {
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    switch (m.ev) {
    case "snapshot":
      connected = true
      busy = m.busy
      title = m.title || ""
      model = m.model || ""
      thinking = m.thinking || ""
      messages.clear()
      stick = true
      streamIndex = -1
      replying = false
      for (var i = 0; i < m.messages.length; i++) {
        var msg = m.messages[i]
        append(msg.role, msg.text, msg.html, msg.ts)
      }
      if (m.partial !== null && m.partial !== undefined) startReply(m.partial, m.partialHtml)
      break
    case "busy": busy = m.value; break
    case "start": startReply("", ""); break
    case "delta":
      if (streamIndex < 0) startReply("", "")
      messages.setProperty(streamIndex, "body", messages.get(streamIndex).body + m.text)
      replying = true
      break
    case "html":
      if (streamIndex >= 0) messages.setProperty(streamIndex, "html", m.html)
      break
    case "end":
      if (streamIndex >= 0) {
        if (m.text) {
          messages.setProperty(streamIndex, "body", m.text)
          messages.setProperty(streamIndex, "html", m.html || "")
          messages.setProperty(streamIndex, "ts", m.ts || Date.now())
        } else {
          messages.remove(streamIndex)   // tool-only turn
        }
      }
      streamIndex = -1
      replying = false
      break
    case "tool": note("tool", m.name + (m.detail ? "  " + m.detail : "")); break
    case "info": note("info", m.text); break
    case "error": note("error", m.text || "error"); break
    case "commands": commands = m.list; break
    case "recent": recent = m.list; break
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

  // Notes go before a streaming reply so the reply stays last.
  function note(role, body) {
    var item = { role: role, body: body, html: "", ts: Date.now() }
    if (streamIndex >= 0) { messages.insert(streamIndex, item); streamIndex++ }
    else messages.append(item)
  }

  function startReply(text, html) {
    append("assistant", text, html, Date.now())
    streamIndex = messages.count - 1
    replying = text.length > 0
  }

  // ---------------------------------------------------------- picker

  function openPicker(kind, query) {
    newMenuOpen = false
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

  readonly property var pickerHints: ({
    sessions: "search chats, or type a name for a new one…",
    models: "search models…",
    folders: "search folders, or type a path like ~/lab/…",
  })

  // ---------------------------------------------------------- slash completion

  function refreshCompletions() {
    completions.clear()
    if (!/^\/\S*$/.test(input.text)) return
    var q = input.text.slice(1).toLowerCase()
    var starts = [], contains = []
    for (var i = 0; i < commands.length; i++) {
      var n = commands[i].name.toLowerCase()
      if (n.indexOf(q) === 0) starts.push(commands[i])
      else if (q && n.indexOf(q) > 0) contains.push(commands[i])
    }
    var all = starts.concat(contains).slice(0, 8)
    for (var j = 0; j < all.length; j++) completions.append(all[j])
    completionList.currentIndex = 0
  }

  function complete() {
    input.text = "/" + completions.get(Math.max(0, completionList.currentIndex)).name + " "
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
  Process { id: copier }
  Timer { id: retry; interval: 800; onTriggered: if (root.opened && !conn.running) conn.running = true }
  Timer { id: searchDebounce; interval: 150; onTriggered: root.send({ op: "pick", kind: root.pickKind, query: search.text }) }

  Shortcut {
    sequence: "Escape"
    enabled: root.opened
    onActivated: {
      if (root.newMenuOpen) root.newMenuOpen = false
      else if (root.pickKind) root.closePicker()
      else if (root.slashing) input.text = ""
      else root.dismiss()
    }
  }

  // ---------------------------------------------------------- surface

  PanelWindow {
    visible: root.opened
    anchors { bottom: true; right: true }
    margins { bottom: Style.gapsOut + Style.space(12); right: Style.gapsOut + Style.space(12) }
    implicitWidth: Style.space(460)
    implicitHeight: Style.space(620)
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
      border.color: Util.alpha(root.fg, 0.15)
      border.width: 1
      clip: true

      MouseArea {
        anchors.fill: parent
        onClicked: { root.newMenuOpen = false; (root.pickKind ? search : input).forceActiveFocus() }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(10)

        // ------------------------------------------------------- header
        // Every Text here is width-bounded: an unbounded Text in a RowLayout
        // takes its full implicit width and pushes the card wider.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Rectangle {
            Layout.preferredWidth: Style.space(8); Layout.preferredHeight: Style.space(8)
            radius: width / 2
            color: !root.connected ? Color.urgent : root.busy ? root.accent : Util.alpha(root.fg, 0.3)
          }
          Text {
            Layout.fillWidth: true
            text: root.pickKind || root.title || "pi"
            elide: Text.ElideRight
            color: root.fg
            font { family: root.font; pixelSize: Style.font.body; bold: true }
          }
          Pill { visible: root.busy && !root.pickKind; label: "stop"; onClicked: root.send({ op: "abort" }) }
          Pill {
            visible: !root.pickKind
            shrinks: true
            Layout.maximumWidth: Style.space(160)
            label: root.model + (root.thinking && root.thinking !== "off" ? " · " + root.thinking : "")
            onClicked: root.openPicker("models", "")
          }
          Pill { visible: !root.pickKind; label: "chats"; onClicked: root.openPicker("sessions", "") }

          // Split button: "new" starts a try-style chat, the chevron offers more.
          Rectangle {
            id: newButton
            visible: !root.pickKind
            Layout.preferredHeight: Style.space(24)
            Layout.preferredWidth: newLabel.implicitWidth + chevron.implicitWidth + Style.space(30)
            Layout.minimumWidth: newLabel.implicitWidth + chevron.implicitWidth + Style.space(30)
            radius: height / 2
            color: root.accent
            Text {
              id: newLabel
              anchors { left: parent.left; leftMargin: Style.space(10); verticalCenter: parent.verticalCenter }
              text: "new"
              color: root.bg
              font { family: root.font; pixelSize: Style.font.caption; bold: true }
            }
            Rectangle {
              x: newLabel.x + newLabel.width + Style.space(5)
              width: 1; height: parent.height * 0.5
              anchors.verticalCenter: parent.verticalCenter
              color: Util.alpha(root.bg, 0.5)
            }
            Text {
              id: chevron
              anchors { right: parent.right; rightMargin: Style.space(8); verticalCenter: parent.verticalCenter }
              text: "▾"
              color: root.bg
              font { family: root.font; pixelSize: Style.font.caption }
            }
            MouseArea {
              anchors { left: parent.left; top: parent.top; bottom: parent.bottom; right: chevron.left; rightMargin: Style.space(2) }
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.newMenuOpen = false; root.send({ op: "new", name: "" }) }
            }
            MouseArea {
              anchors { right: parent.right; top: parent.top; bottom: parent.bottom; left: chevron.left; leftMargin: -Style.space(4) }
              cursorShape: Qt.PointingHandCursor
              onClicked: root.newMenuOpen = !root.newMenuOpen
            }
          }
          Pill { visible: !!root.pickKind; label: "back"; onClicked: root.closePicker() }
        }

        // Quick switch: the current chat plus the most recent others.
        RowLayout {
          visible: !root.pickKind && root.recent.length > 0
          Layout.fillWidth: true
          spacing: Style.space(5)
          Repeater {
            model: root.recent
            delegate: Rectangle {
              required property var modelData
              Layout.fillWidth: true
              Layout.preferredWidth: 1                   // equal shares of the row
              Layout.preferredHeight: Style.space(24)
              radius: height / 2
              color: modelData.current ? Util.alpha(root.accent, 0.18)
                : chipArea.containsMouse ? Util.alpha(root.fg, 0.12) : Util.alpha(root.fg, 0.05)
              border.color: modelData.current ? Util.alpha(root.accent, 0.6) : "transparent"
              Text {
                anchors { fill: parent; leftMargin: Style.space(8); rightMargin: Style.space(8) }
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                text: modelData.title
                elide: Text.ElideRight
                color: modelData.current ? root.accent : root.fg
                font { family: root.font; pixelSize: Style.font.caption; bold: modelData.current }
              }
              MouseArea {
                id: chipArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.send({ op: "resume", path: modelData.path })
              }
            }
          }
        }

        // ------------------------------------------------------- chat
        ListView {
          id: chat
          visible: !root.pickKind
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(6)
          model: messages
          onCountChanged: if (root.stick) Qt.callLater(positionViewAtEnd)
          onContentHeightChanged: if (root.stick) positionViewAtEnd()
          onContentYChanged: if (moving || wheel.active) root.stick = atYEnd
          FastWheel { id: wheel; view: chat }

          delegate: Item {
            id: row
            required property int index
            required property string role
            required property string body
            required property string html
            required property real ts
            readonly property bool mine: role === "user"
            readonly property bool bubble: role === "user" || role === "assistant"
            readonly property bool system: role === "info" || role === "error"
            readonly property int maxBubble: Math.round(width * (mine ? 0.82 : 0.94))
            readonly property int pad: Style.space(10)

            width: ListView.view.width
            height: bubble ? bubbleRect.height + Style.space(4)
                  : system ? sysPill.height + Style.space(6)
                  : toolText.implicitHeight

            // Natural (unwrapped) width of the content, to size short bubbles.
            Text {
              id: measure
              visible: false
              textFormat: row.html ? Text.RichText : Text.PlainText
              text: row.html || row.body
              font { family: root.font; pixelSize: Style.font.body }
            }

            Rectangle {
              id: bubbleRect
              visible: row.bubble
              anchors.right: row.mine ? parent.right : undefined
              anchors.left: row.mine ? undefined : parent.left
              width: row.html.indexOf("<table") >= 0 ? row.maxBubble
                : Math.min(row.maxBubble, Math.max(Style.space(64), Math.max(measure.implicitWidth, stamp.implicitWidth) + row.pad * 2))
              height: content.implicitHeight + stamp.implicitHeight + row.pad * 1.6
              color: row.mine ? root.userBubble : root.botBubble
              radius: root.radius
              bottomRightRadius: row.mine ? Style.space(4) : root.radius
              bottomLeftRadius: row.mine ? root.radius : Style.space(4)

              TextEdit {
                id: content
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: row.pad; topMargin: row.pad * 0.8 }
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                textFormat: row.html ? TextEdit.RichText : TextEdit.PlainText
                text: row.html || row.body || (row.index === root.streamIndex ? "" : "…")
                color: root.fg
                selectionColor: Util.alpha(root.accent, 0.35)
                font { family: root.font; pixelSize: Style.font.body }
                onLinkActivated: link => Qt.openUrlExternally(link)
                HoverHandler { cursorShape: content.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
              }

              Text {
                id: stamp
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: row.pad; bottomMargin: row.pad * 0.5 }
                text: Qt.formatTime(new Date(row.ts), "HH:mm")
                color: root.fg
                opacity: 0.45
                font { family: root.font; pixelSize: Style.font.caption }
              }

              // Copy the raw markdown of a reply.
              Rectangle {
                visible: !row.mine && bubbleHover.hovered && row.body.length > 0
                anchors { left: parent.left; bottom: parent.bottom; leftMargin: row.pad; bottomMargin: row.pad * 0.4 }
                width: copyText.implicitWidth + Style.space(12); height: copyText.implicitHeight + Style.space(4)
                radius: height / 2
                color: Util.alpha(root.fg, copyArea.containsMouse ? 0.15 : 0.07)
                Text { id: copyText; anchors.centerIn: parent; text: "copy"; color: root.fg; opacity: 0.7; font { family: root.font; pixelSize: Style.font.caption } }
                MouseArea {
                  id: copyArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { copier.command = ["wl-copy", row.body]; copier.running = true; copyText.text = "copied" }
                }
              }
              HoverHandler { id: bubbleHover }
            }

            // Tool calls: one dim monospace line.
            Text {
              id: toolText
              visible: row.role === "tool"
              width: parent.width
              leftPadding: Style.space(6)
              text: "⚙ " + row.body
              elide: Text.ElideRight
              color: root.fg
              opacity: 0.45
              font { family: "monospace"; pixelSize: Style.font.caption }
            }

            // Info / error: centered pill.
            Rectangle {
              id: sysPill
              visible: row.system
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.min(parent.width * 0.9, sysText.implicitWidth + Style.space(20))
              height: sysText.implicitHeight + Style.space(8)
              radius: height / 2
              color: row.role === "error" ? Util.alpha(Color.urgent, 0.14) : Util.alpha(root.fg, 0.06)
              Text {
                id: sysText
                anchors { fill: parent; leftMargin: Style.space(10); rightMargin: Style.space(10) }
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                text: row.body
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 4
                elide: Text.ElideRight
                color: row.role === "error" ? Color.urgent : root.fg
                opacity: row.role === "error" ? 1 : 0.6
                font { family: root.font; pixelSize: Style.font.caption }
              }
            }
          }

          // Typing indicator while the agent works without visible text.
          footer: Item {
            width: ListView.view ? ListView.view.width : 0
            height: dots.visible ? dots.height + Style.space(8) : 0
            Rectangle {
              id: dots
              visible: root.busy && !root.replying
              y: Style.space(6)
              width: Style.space(54); height: Style.space(30)
              radius: root.radius
              bottomLeftRadius: Style.space(4)
              color: root.botBubble
              Row {
                anchors.centerIn: parent
                spacing: Style.space(5)
                Repeater {
                  model: 3
                  delegate: Rectangle {
                    required property int index
                    width: Style.space(6); height: width; radius: width / 2
                    color: root.fg
                    opacity: 0.25
                    SequentialAnimation on opacity {
                      running: dots.visible
                      loops: Animation.Infinite
                      PauseAnimation { duration: index * 160 }
                      NumberAnimation { to: 0.8; duration: 320 }
                      NumberAnimation { to: 0.25; duration: 320 }
                      PauseAnimation { duration: (2 - index) * 160 }
                    }
                  }
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            width: parent.width * 0.8
            spacing: Style.space(6)
            visible: messages.count === 0 && !root.busy
            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "π"
              color: root.accent
              font { family: root.font; pixelSize: Style.font.displayLarge }
            }
            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              text: root.connected ? "ask pi anything\n/ for commands" : "connecting…"
              color: root.fg
              opacity: 0.45
              font { family: root.font; pixelSize: Style.font.body }
            }
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
          FastWheel { view: completionList }
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
            Text {
              visible: !search.text
              text: root.pickerHints[root.pickKind] || ""
              color: root.fg
              opacity: 0.4
              font: search.font
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
          FastWheel { view: pickList }
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
              Text { width: parent.width; text: subtitle; elide: Text.ElideMiddle; color: root.fg; opacity: 0.5; font { family: root.font; pixelSize: Style.font.caption } }
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
          Layout.preferredHeight: Math.min(Style.space(150), input.implicitHeight + Style.space(20))
          radius: root.radius
          Flickable {
            id: flick
            anchors { fill: parent; margins: Style.space(10); leftMargin: Style.space(14); rightMargin: Style.space(14) }
            clip: true
            contentWidth: width
            contentHeight: input.implicitHeight
            FastWheel { view: flick }
            TextEdit {
              id: input
              width: flick.width
              wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
              color: root.fg
              selectionColor: Util.alpha(root.accent, 0.35)
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
                text: root.busy ? "steer…" : "message"
                color: root.fg
                opacity: 0.4
                font: input.font
              }
            }
          }
        }
      }

      // New-chat menu, dropped from the split button's chevron.
      Rectangle {
        visible: root.newMenuOpen
        z: 10
        x: card.width - width - Style.space(14)
        y: Style.space(14) + Style.space(30)
        width: Style.space(190)
        height: menuCol.implicitHeight + Style.space(8)
        radius: Style.cornerRadius
        color: root.bg
        border.color: Util.alpha(root.fg, 0.18)
        Column {
          id: menuCol
          anchors { fill: parent; margins: Style.space(4) }
          MenuItem { label: "new chat"; hint: "~/lab/chatty/<date>-…"; onClicked: root.send({ op: "new", name: "" }) }
          MenuItem { label: "new in folder…"; hint: "pick any directory"; onClicked: root.openPicker("folders", "") }
        }
      }
    }
  }

  // Qt's default wheel handling animates fixed steps, which feels sluggish with
  // high-resolution mice and touchpads. Apply pixel deltas 1:1 (the device
  // supplies its own momentum); classic wheels get a fixed step per notch.
  component FastWheel: WheelHandler {
    required property Flickable view
    readonly property bool active: activeTimer.running
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * Style.space(90)
      var max = view.originY + Math.max(0, view.contentHeight - view.height)
      view.cancelFlick()
      view.contentY = Math.max(view.originY, Math.min(max, view.contentY - dy))
      activeTimer.restart()
    }
    property Timer activeTimer: Timer { interval: 150 }
  }

  component MenuItem: Rectangle {
    property string label
    property string hint
    signal clicked
    width: parent.width
    height: Style.space(40)
    radius: Style.cornerRadius
    color: itemArea.containsMouse ? Util.alpha(root.fg, 0.1) : "transparent"
    Column {
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(10); rightMargin: Style.space(10) }
      Text { width: parent.width; text: label; elide: Text.ElideRight; color: root.fg; font { family: root.font; pixelSize: Style.font.body } }
      Text { width: parent.width; text: hint; elide: Text.ElideRight; color: root.fg; opacity: 0.5; font { family: root.font; pixelSize: Style.font.caption } }
    }
    MouseArea {
      id: itemArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { root.newMenuOpen = false; parent.clicked() }
    }
  }

  component Pill: Rectangle {
    property string label
    property bool shrinks: false          // only the model chip may elide
    signal clicked
    Layout.preferredHeight: Style.space(24)
    Layout.preferredWidth: Math.ceil(pillText.implicitWidth) + Style.space(18) + 2
    Layout.minimumWidth: shrinks ? Style.space(48) : Math.ceil(pillText.implicitWidth) + Style.space(18) + 2
    radius: height / 2
    color: Util.alpha(root.fg, pillArea.containsMouse ? 0.16 : 0.07)
    Text {
      id: pillText
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(9); rightMargin: Style.space(9) }
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
    color: Util.alpha(root.fg, 0.05)
    border.color: Util.alpha(root.fg, 0.14)
    border.width: 1
  }
}
