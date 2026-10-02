#!/usr/bin/env bash
# Install omarchy-pi: daemon deps, systemd user service, Omarchy plugin, and
# (only with your consent) a keybinding.
#
#   ./install.sh                                    # asks before touching bindings.lua
#   OMARCHY_PI_KEY="SUPER + SHIFT + SPACE" ./install.sh  # bind without asking
#   OMARCHY_PI_KEY=none ./install.sh                # never touch bindings.lua
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
plugin_id="hjanuschka.omarchy-pi"
plugins_dir="$HOME/.config/omarchy/plugins"
bindings="$HOME/.config/hypr/bindings.lua"
default_key="SUPER + SHIFT + SPACE"
key="${OMARCHY_PI_KEY:-}"

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

# bindings.lua is user configuration: only edit it when asked to.
if [[ -z "$key" && -t 0 && -f "$bindings" ]] && ! grep -q "$plugin_id" "$bindings"; then
  read -r -p "Bind $default_key to the chat in $bindings? This replaces Omarchy's 'Toggle top bar' on that combo. [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] && key="$default_key"
fi
if [[ -n "$key" && "$key" != "none" && -f "$bindings" ]] && ! grep -q "$plugin_id" "$bindings"; then
  cat >> "$bindings" <<EOF

-- omarchy-pi: floating chat with the persistent pi daemon.
hl.unbind("$key")
o.bind("$key", "Pi chat", "omarchy-shell shell toggle $plugin_id")
EOF
  hyprctl reload >/dev/null
fi

omarchy restart shell >/dev/null 2>&1 || true
if grep -qs "$plugin_id" "$bindings"; then
  echo "omarchy-pi installed. Use your binding to open the chat."
else
  echo "omarchy-pi installed. Open it with: omarchy-shell shell toggle $plugin_id"
  echo "To bind a key, add to $bindings:"
  echo "  o.bind(\"$default_key\", \"Pi chat\", \"omarchy-shell shell toggle $plugin_id\")"
fi
