# omarchy-pi

A small floating pi chat for Omarchy, backed by a long-lived pi SDK daemon.

```
Super+Shift+Space -> plugin/Chat.qml --socat--> $XDG_RUNTIME_DIR/omarchy-pi.sock -> daemon/server.mjs (pi SDK)
```

- `daemon/server.mjs`: one `AgentSessionRuntime` with default services, so it
  loads your `~/.pi/agent` settings, auth, models, skills, extensions, prompts,
  and AGENTS.md (plus the CLI's built-in codemode/tool-search/MCP). Runs as the
  `omarchy-pi` systemd user service; the panel closing never stops a run.
- `plugin/`: thin Omarchy overlay that renders the daemon's JSONL events.

Panel: Enter sends (steers while busy), Shift+Enter newline, Esc hides,
`sessions` searches every pi session (full text) and resumes one, `new` starts
a fresh thread, `stop` aborts.

Install: `./install.sh` (npm deps, systemd unit, plugin symlink, keybind).
Logs: `journalctl --user -u omarchy-pi -f`.
