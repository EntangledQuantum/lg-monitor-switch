#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove LG Monitor Switch for the current user.
#   ./uninstall.sh            keep ~/.config/lg-monitor (config + token)
#   ./uninstall.sh --purge    remove it too
set -uo pipefail

APP_ID="io.github.entangledquantum.LgMonitorSwitch"
UUID="lg-monitor-switch@entangledquantum.github.io"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/lg-monitor"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

for unit in lg-monitor-listener.service lg-monitor-deskflow.service; do
  systemctl --user disable --now "$unit" 2>/dev/null
  rm -f "$UNITS/$unit"
done
systemctl --user daemon-reload 2>/dev/null

gnome-extensions disable "$UUID" 2>/dev/null
/usr/bin/python3 - "$UUID" <<'PY'
import ast, subprocess, sys
uuid = sys.argv[1]
raw = subprocess.run(["gsettings", "get", "org.gnome.shell", "enabled-extensions"],
                     capture_output=True, text=True).stdout.strip()
cur = [] if raw.startswith("@as") or not raw else ast.literal_eval(raw)
if uuid in cur:
    cur.remove(uuid)
    subprocess.run(["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(cur)])
PY
rm -rf "$DATA/gnome-shell/extensions/$UUID"
rm -f "$HOME/.local/bin/lg-monitor" "$HOME/.local/bin/lg-monitor-settings" \
      "$DATA/applications/$APP_ID.desktop" \
      "$DATA/icons/hicolor/scalable/apps/$APP_ID.svg" \
      "$DATA/icons/hicolor/symbolic/apps/$APP_ID-symbolic.svg"
rm -rf "${XDG_RUNTIME_DIR:-/tmp}/lg-monitor-$(id -u)"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$CONF"
  echo "Removed configuration and token ($CONF)."
else
  echo "Kept $CONF (use --purge to remove the config and token)."
fi
echo "Autostart entries removed (systemd user units disabled and deleted)."
echo "LG Monitor Switch removed. Restart GNOME Shell (X11: Alt+F2, r) or log out to drop the top bar menu."
