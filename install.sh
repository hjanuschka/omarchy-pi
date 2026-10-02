#!/usr/bin/env bash
# Install omarchy-pi: daemon deps, systemd user service, Omarchy plugin, keybind.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
node="$(command -v node)"
plugin_id="hjanuschka.omarchy-pi"
plugins_dir="$HOME/.config/omarchy/plugins"
bindings="$HOME/.config/hypr/bindings.lua"

(cd "$here/daemon" && npm install --silent)

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/omarchy-pi.service" <<EOF
[Unit]
Description=omarchy-pi agent daemon (pi SDK, ~/.pi config)

[Service]
ExecStart=$node $here/daemon/server.mjs
WorkingDirectory=%h
Environment=PATH=$PATH
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now omarchy-pi.service
systemctl --user restart omarchy-pi.service

mkdir -p "$plugins_dir"
ln -sfn "$here/plugin" "$plugins_dir/$plugin_id"
omarchy-shell -q shell rescanPlugins
omarchy plugin enable "$plugin_id" >/dev/null

if ! grep -q "$plugin_id" "$bindings"; then
  cat >> "$bindings" <<EOF

-- omarchy-pi: floating chat with the persistent pi daemon.
hl.unbind("SUPER + SHIFT + SPACE")
o.bind("SUPER + SHIFT + SPACE", "Pi chat", "omarchy-shell shell toggle $plugin_id")
EOF
fi
hyprctl reload >/dev/null
omarchy restart shell >/dev/null
echo "omarchy-pi installed. Super+Shift+Space to chat."
