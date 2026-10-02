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

Every chat gets its own dated workspace (a la [tobi/try](https://github.com/tobi/try)):
`~/lab/chatty/2026-10-02-redis-pool`, which is also the agent's cwd. Override
the root with `OMARCHY_PI_ROOT`.

Panel:
- Enter sends (steers while busy), Shift+Enter newline, Esc hides/backs out.
- `/` autocompletes every command: built-ins, your extension commands,
  `/skill:*`, and prompt templates. Tab/Enter completes, Up/Down selects.
- Built-ins: `/model [query]`, `/thinking [level]`, `/new [name]`,
  `/sessions [query]`, `/compact [instructions]`, `/name <name>`.
- Chat bubbles with timestamps; replies are markdown rendered by the daemon
  (marked + highlight.js, colors from the current Omarchy theme), with copy.
- Five chips under the header switch between recent chats in one click.
- `new` starts a try-style chat; its chevron offers `new in folder…`, a fuzzy
  folder picker over zoxide + past session dirs (type `~/…` to browse).
- Model pill: fuzzy model picker. `chats`: fuzzy + recency + full-text search
  over every pi session, ending in `+ new: <query>`. `new`: fresh workspace.

Install: `./install.sh` (npm deps, systemd unit, plugin symlink, keybind).
Logs: `journalctl --user -u omarchy-pi -f`.
