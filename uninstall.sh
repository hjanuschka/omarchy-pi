#!/usr/bin/env bash
# Remove the omarchy-pi service, plugin link, and keybind. Chats are kept:
# workspaces stay in ~/lab/chatty and sessions in ~/.pi/agent/sessions.
set -euo pipefail

plugin_id="hjanuschka.omarchy-pi"
plugins_dir="$HOME/.config/omarchy/plugins"
bindings="$HOME/.config/hypr/bindings.lua"

systemctl --user disable --now omarchy-pi.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/omarchy-pi.service"
systemctl --user daemon-reload

omarchy plugin disable "$plugin_id" >/dev/null 2>&1 || true
[[ -L "$plugins_dir/$plugin_id" ]] && rm "$plugins_dir/$plugin_id"

if [[ -f "$bindings" ]] && grep -q "$plugin_id" "$bindings"; then
  # Drop the block install.sh appended (comment, unbind, bind).
  python3 - "$bindings" "$plugin_id" <<'EOF'
import re, sys
path, pid = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(r"\n-- omarchy-pi: floating chat[^\n]*\n(hl\.unbind\([^\n]*\)\n)?o\.bind\([^\n]*" + re.escape(pid) + r"[^\n]*\)\n", "\n", text)
open(path, "w").write(text)
EOF
  hyprctl reload >/dev/null
fi

omarchy restart shell >/dev/null 2>&1 || true
rm -f "${XDG_RUNTIME_DIR:-/tmp}/omarchy-pi.sock"
echo "omarchy-pi removed (chats and sessions kept)."
