#!/usr/bin/env bash
# Start a throwaway headless GNOME Shell (Wayland, no X11) with ISOLATED
# config/data/runtime dirs, load the LG Monitor Switch extension plus the test
# harness, open the menu, open the settings app and take screenshots.
# Your real GNOME session, dconf database and extensions are not touched.
# Reads real brightness/contrast from the monitor (read-only).
#   tests/shell-harness/run-headless.sh OUTDIR
#   LGM_WRITE_TEST=1 ...  also drag the brightness slider (writes, then restores)
#   LGM_DEMO=1 tests/shell-harness/run-headless.sh OUTDIR   # neutral names/IP for README screenshots
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(realpath -m "${1:-$PWD/harness-out}")"
UUID="lg-monitor-switch@entangledquantum.github.io"
T="$(mktemp -d)"
mkdir -p "$OUT" "$T/config/lg-monitor" "$T/data/gnome-shell/extensions" "$T/run"
chmod 700 "$T/run"
cp -r "$ROOT/linux/extension/$UUID" "$T/data/gnome-shell/extensions/"
cp -r "$ROOT/tests/shell-harness/lgm-test-harness@local" "$T/data/gnome-shell/extensions/"
[ -f "$HOME/.config/lg-monitor/config.ini" ] && cp "$HOME/.config/lg-monitor/config.ini" "$T/config/lg-monitor/"
export XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" XDG_RUNTIME_DIR="$T/run" LGM_HARNESS_OUT="$OUT"
if [ "${LGM_DEMO:-0}" = 1 ]; then
  # Fake home with a fake Deskflow config + a hostname shim, so screenshots
  # show neutral names instead of this machine's.
  D="$T/home/.var/app/org.deskflow.deskflow"
  mkdir -p "$D/config/Deskflow" "$D/data" "$T/bin"
  printf '[core]\ncomputerName=linux-pc\n\n[log]\nfile=%s\nlevel=INFO\ntoFile=true\n\n[server]\nexternalConfigFile=%s\n' \
    "$D/data/deskflow.log" "$D/config/Deskflow/deskflow-server.conf" > "$D/config/Deskflow/Deskflow.conf"
  printf 'section: screens\n\tlinux-pc:\n\twindows-pc:\nend\n' > "$D/config/Deskflow/deskflow-server.conf"
  touch "$D/data/deskflow.log"
  printf '#!/bin/sh\necho 192.168.1.20\n' > "$T/bin/hostname"; chmod +x "$T/bin/hostname"
  export HOME="$T/home" PATH="$T/bin:$PATH"
fi
unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
mkdir -p "$T/data/applications" "$T/data/icons/hicolor/scalable/apps"
cp "$ROOT/assets/lg-monitor-switch.svg" "$T/data/icons/hicolor/scalable/apps/io.github.entangledquantum.LgMonitorSwitch.svg"
/usr/bin/dbus-run-session -- bash -c '
  gsettings set org.gnome.shell enabled-extensions "[\"'"$UUID"'\", \"lgm-test-harness@local\"]"
  gsettings set org.gnome.shell welcome-dialog-last-shown-version "99"
  gsettings set org.gnome.desktop.interface color-scheme prefer-dark
  gsettings set org.gnome.shell disabled-extensions "[\"ding@rastersoft.com\", \"ubuntu-dock@ubuntu.com\"]"
  gsettings set org.gnome.desktop.background picture-options none
  gsettings set org.gnome.desktop.background primary-color "#2b3a55"
  gnome-shell --headless --wayland --no-x11 --virtual-monitor 1400x1700 > "'"$OUT"'/shell.log" 2>&1 &
  SHELL_PID=$!
  sleep 15
  WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland '"$ROOT"'/linux/lg-monitor-settings > "'"$OUT"'/settings.log" 2>&1 &
  sleep 14
  kill $SHELL_PID 2>/dev/null; sleep 1; kill -9 $SHELL_PID 2>/dev/null || true
'
for m in "$T/run/gvfs" "$T/run/doc"; do mountpoint -q "$m" 2>/dev/null && fusermount -uz "$m"; done
rm -rf "$T" 2>/dev/null || true
grep -E "HARNESS|$UUID|JS ERROR|Error" "$OUT/shell.log" | grep -v "^$" || true
