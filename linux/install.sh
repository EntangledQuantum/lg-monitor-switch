#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install LG Monitor Switch for the current user (no root needed).
#
#   ./install.sh                  install CLI, settings app, GNOME extension
#   ./install.sh --with-listener  ...and enable the LAN listener service
#
# Nothing here touches Deskflow. The Deskflow auto-switch is OFF by default and
# can only be enabled from the settings app.
set -euo pipefail
umask 022   # files must stay readable by GNOME Shell etc. even with a strict user umask

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_ID="io.github.entangledquantum.LgMonitorSwitch"
UUID="lg-monitor-switch@entangledquantum.github.io"
BIN="$HOME/.local/bin"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/lg-monitor"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
EXT_DIR="$DATA/gnome-shell/extensions/$UUID"

WITH_LISTENER=0
for arg in "$@"; do
  case "$arg" in
    --with-listener) WITH_LISTENER=1 ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }

SUDO_HINTS=()

bold "Checking requirements"
missing_pkgs=()
command -v ddcutil >/dev/null || missing_pkgs+=(ddcutil)
command -v i2ctransfer >/dev/null || [ -x /usr/sbin/i2ctransfer ] || missing_pkgs+=(i2c-tools)
[ -x /usr/bin/python3 ] || missing_pkgs+=(python3)
if ! /usr/bin/python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")' 2>/dev/null; then
  missing_pkgs+=(python3-gi gir1.2-adw-1)
fi
if ((${#missing_pkgs[@]})); then
  warn "missing packages: ${missing_pkgs[*]}"
  SUDO_HINTS+=("sudo apt install ${missing_pkgs[*]}")
else
  ok "ddcutil, i2c-tools, python3 + GTK4/libadwaita found"
fi

if ! ls /dev/i2c-* >/dev/null 2>&1; then
  warn "no /dev/i2c-* devices: the i2c-dev kernel module is not loaded"
  SUDO_HINTS+=("sudo modprobe i2c-dev" "echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf")
else
  ok "i2c-dev loaded"
fi

if getent group i2c >/dev/null; then
  if id -nG | tr ' ' '\n' | grep -qx i2c; then
    ok "$USER is in group i2c"
  elif id -nG "$USER" | tr ' ' '\n' | grep -qx i2c; then
    warn "$USER is in group i2c, but this login session started before that - log out and back in"
    echo "  (until then the desktop session's device ACL usually grants access anyway)"
  else
    warn "$USER is not in group i2c (needed for /dev/i2c-* access outside the desktop session)"
    SUDO_HINTS+=("sudo usermod -aG i2c $USER   # then log out and back in")
  fi
else
  warn "group i2c does not exist (ddcutil normally creates it)"
  SUDO_HINTS+=("sudo groupadd --system i2c" "sudo usermod -aG i2c $USER" \
    "echo 'KERNEL==\"i2c-[0-9]*\", GROUP=\"i2c\", MODE=\"0660\"' | sudo tee /etc/udev/rules.d/60-i2c.rules" \
    "sudo udevadm control --reload && sudo udevadm trigger")
fi

bold "Installing files"
install -d "$BIN" "$CONF" "$UNITS" "$DATA/applications" \
  "$DATA/icons/hicolor/scalable/apps" "$DATA/icons/hicolor/symbolic/apps"
install -m 755 "$HERE/lg-monitor" "$BIN/lg-monitor"
install -m 755 "$HERE/lg-monitor-settings" "$BIN/lg-monitor-settings"
ok "CLI -> $BIN/lg-monitor, settings app -> $BIN/lg-monitor-settings"

if [ ! -f "$CONF/config.ini" ]; then
  install -m 644 "$HERE/config.example.ini" "$CONF/config.ini"
  ok "config -> $CONF/config.ini"
else
  ok "keeping existing $CONF/config.ini"
fi

install -m 644 "$ROOT/assets/lg-monitor-switch.svg" "$DATA/icons/hicolor/scalable/apps/$APP_ID.svg"
install -m 644 "$ROOT/assets/lg-monitor-switch-symbolic.svg" "$DATA/icons/hicolor/symbolic/apps/$APP_ID-symbolic.svg"
sed "s|^Exec=lg-monitor-settings|Exec=$BIN/lg-monitor-settings|" \
  "$HERE/$APP_ID.desktop" > "$DATA/applications/$APP_ID.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" 2>/dev/null || true
ok "desktop entry + icons"

install -m 644 "$HERE/systemd/lg-monitor-listener.service" "$UNITS/"
install -m 644 "$HERE/systemd/lg-monitor-deskflow.service" "$UNITS/"
systemctl --user daemon-reload || true
ok "systemd user units installed (not enabled unless you opt in)"

rm -rf "$EXT_DIR"
install -d "$EXT_DIR/icons"
install -m 644 "$HERE/extension/$UUID/"{metadata.json,extension.js,stylesheet.css} "$EXT_DIR/"
install -m 644 "$HERE/extension/$UUID/icons/"*.svg "$EXT_DIR/icons/"
ok "GNOME Shell extension -> $EXT_DIR"

# Enable the extension. gnome-extensions only knows extensions the running
# shell has loaded, so for a fresh install also add it to the gsettings list.
if gnome-extensions enable "$UUID" 2>/dev/null; then
  ok "extension enabled"
else
  /usr/bin/python3 - "$UUID" <<'PY'
import ast, subprocess, sys
uuid = sys.argv[1]
raw = subprocess.run(["gsettings", "get", "org.gnome.shell", "enabled-extensions"],
                     capture_output=True, text=True).stdout.strip()
cur = [] if raw.startswith("@as") else ast.literal_eval(raw or "[]")
if uuid not in cur:
    cur.append(uuid)
    subprocess.run(["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(cur)], check=True)
PY
  ok "extension added to enabled-extensions (loads after a GNOME Shell restart)"
  NEED_RESTART=1
fi

bold "Background services"
if ((WITH_LISTENER)); then
  "$BIN/lg-monitor" service listener on >/dev/null
  PORT="$(sed -n 's/^port *= *\([0-9]*\).*/\1/p' "$CONF/config.ini" | head -1)"
  PORT="${PORT:-47320}"
  ok "LAN listener enabled on TCP port $PORT (starts at login)"
  echo "  Linux host for the Windows app: $(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "  Token for the Windows app:      run  $BIN/lg-monitor token"
  echo "  If ufw is active:  sudo ufw allow from 192.168.0.0/16 to any port $PORT proto tcp"
else
  # Re-apply whatever was enabled before (re-install / upgrade); a fresh
  # install has everything off.
  "$BIN/lg-monitor" autostart apply >/dev/null && ok "services match the config (LAN listener and Deskflow auto-switch are opt-in)"
fi

bold "Checking the monitor"
if "$BIN/lg-monitor" detect; then
  "$BIN/lg-monitor" get || true
else
  warn "monitor not reachable yet - see the troubleshooting section of README.md"
fi

if "$BIN/lg-monitor" deskflow-info 2>/dev/null | grep -q '"installed": true'; then
  echo
  echo "Deskflow detected. Automatic input switching when the cursor changes computer is OFF;"
  echo "you can turn it on in the settings app (LG Monitor Switch → Deskflow auto-switch)."
fi

echo
if ((${#SUDO_HINTS[@]})); then
  bold "Run these commands yourself (they need sudo):"
  printf '  %s\n' "${SUDO_HINTS[@]}"
  echo
fi
if [ "${NEED_RESTART:-0}" = 1 ]; then
  if [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
    bold "Restart GNOME Shell to load the top bar menu: press Alt+F2, type r, press Enter."
  else
    bold "Log out and back in to load the top bar menu (Wayland cannot restart GNOME Shell in place)."
  fi
fi
bold "Done. Open 'LG Monitor Switch' from the app grid for settings."
