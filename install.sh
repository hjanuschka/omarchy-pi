#!/usr/bin/env bash
# Install omarchy-pi: daemon deps, systemd user service, Omarchy plugin, keybind.
#
#   ./install.sh                                   # bind Super+Shift+Space
#   OMARCHY_PI_KEY="SUPER + ALT + P" ./install.sh  # pick another binding
#   OMARCHY_PI_KEY=none ./install.sh               # leave bindings.lua alone
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
plugin_id="hjanuschka.omarchy-pi"
plugins_dir="$HOME/.config/omarchy/plugins"
bindings="$HOME/.config/hypr/bindings.lua"
key="${OMARCHY_PI_KEY:-SUPER + SHIFT + SPACE}"

die() { echo "omarchy-pi: $*" >&2; exit 1; }

node="$(command -v node)" || die "node >= 22.19 is required"
"$node" -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=19)?0:1)' \
  || die "node >= 22.19 is required (found $("$node" --version))"
command -v socat >/dev/null || die "socat is required (sudo pacman -S socat)"
command -v pi >/dev/null || echo "omarchy-pi: note: pi CLI not found; the daemon still uses ~/.pi, but set up auth with pi first"

(cd "$here/daemon" && npm install --silent --omit=dev --no-bin-links)

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
systemctl --user enable omarchy-pi.service >/dev/null 2>&1
systemctl --user restart omarchy-pi.service

# Installed via `omarchy plugin add` the repo already lives in the plugins
# dir; from a clone elsewhere, link it in.
if [[ "$here" != "$plugins_dir/$plugin_id" ]]; then
  mkdir -p "$plugins_dir"
  ln -sfn "$here" "$plugins_dir/$plugin_id"
fi
omarchy-shell -q shell rescanPlugins
omarchy plugin enable "$plugin_id" >/dev/null

if [[ "$key" != "none" && -f "$bindings" ]] && ! grep -q "$plugin_id" "$bindings"; then
  cat >> "$bindings" <<EOF

-- omarchy-pi: floating chat with the persistent pi daemon.
hl.unbind("$key")
o.bind("$key", "Pi chat", "omarchy-shell shell toggle $plugin_id")
EOF
  hyprctl reload >/dev/null
fi

omarchy restart shell >/dev/null 2>&1 || true
if [[ "$key" != "none" ]]; then echo "omarchy-pi installed. $key to chat."; else echo "omarchy-pi installed."; fi
