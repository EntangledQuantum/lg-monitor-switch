#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build a system-wide .deb of LG Monitor Switch (Linux part only).
#
#   packaging/build-deb.sh          -> dist/lg-monitor-switch_<version>_all.deb
#
# The .deb installs to /usr (CLI, settings app, GNOME extension, icons,
# systemd user units). Per-user state (config, token, which features are on)
# still lives in ~/.config/lg-monitor, exactly as with linux/install.sh.
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="io.github.entangledquantum.LgMonitorSwitch"
UUID="lg-monitor-switch@entangledquantum.github.io"
VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$ROOT/linux/lg-monitor")"
PKG="lg-monitor-switch"
OUT="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/${PKG}_${VERSION}_all"

install -d "$D/DEBIAN" "$D/usr/bin" "$D/usr/share/applications" \
  "$D/usr/share/icons/hicolor/scalable/apps" "$D/usr/share/icons/hicolor/symbolic/apps" \
  "$D/usr/share/gnome-shell/extensions/$UUID/icons" "$D/usr/lib/systemd/user" \
  "$D/usr/lib/modules-load.d" "$D/usr/share/doc/$PKG"

install -m 755 "$ROOT/linux/lg-monitor" "$ROOT/linux/lg-monitor-settings" "$D/usr/bin/"
install -m 644 "$ROOT/linux/$APP_ID.desktop" "$D/usr/share/applications/"
install -m 644 "$ROOT/assets/lg-monitor-switch.svg" "$D/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg"
install -m 644 "$ROOT/assets/lg-monitor-switch-symbolic.svg" "$D/usr/share/icons/hicolor/symbolic/apps/$APP_ID-symbolic.svg"
install -m 644 "$ROOT/linux/extension/$UUID/"{metadata.json,extension.js,stylesheet.css} \
  "$D/usr/share/gnome-shell/extensions/$UUID/"
install -m 644 "$ROOT/linux/extension/$UUID/icons/"*.svg "$D/usr/share/gnome-shell/extensions/$UUID/icons/"
for unit in "$ROOT"/linux/systemd/*.service; do
  sed 's|%h/.local/bin/lg-monitor|/usr/bin/lg-monitor|' "$unit" > "$D/usr/lib/systemd/user/$(basename "$unit")"
  chmod 644 "$D/usr/lib/systemd/user/$(basename "$unit")"
done
echo i2c-dev > "$D/usr/lib/modules-load.d/$PKG.conf"
install -m 644 "$ROOT/README.md" "$ROOT/linux/config.example.ini" "$D/usr/share/doc/$PKG/"
install -m 644 "$ROOT/LICENSE" "$D/usr/share/doc/$PKG/copyright"

SIZE="$(du -sk "$D/usr" | cut -f1)"
cat > "$D/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: utils
Priority: optional
Architecture: all
Depends: python3, ddcutil, i2c-tools, python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1
Recommends: gnome-shell (>= 46)
Installed-Size: $SIZE
Maintainer: LG Monitor Switch contributors <https://github.com/EntangledQuantum/lg-monitor-switch/issues>
Homepage: https://github.com/EntangledQuantum/lg-monitor-switch
Description: Brightness, contrast and input switching for LG UltraGear monitors
 GNOME top bar menu and settings app to change brightness and contrast over
 DDC/CI and switch the monitor input between two computers, using LG's 0xF4
 side channel. Optional LAN listener (for the Windows app) and optional
 Deskflow auto-switch, both off by default.
EOF

cat > "$D/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
  modprobe i2c-dev 2>/dev/null || true
  command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
  echo "LG Monitor Switch installed. As your normal user (not root), run:"
  echo "    lg-monitor top-bar on"
  echo "then restart GNOME Shell (X11: Alt+F2, r, Enter; Wayland: log out and back in)."
fi
exit 0
EOF
cat > "$D/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
exit 0
EOF
chmod 755 "$D/DEBIAN/postinst" "$D/DEBIAN/postrm"

install -d "$OUT"
fakeroot dpkg-deb --build --root-owner-group "$D" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "$OUT/${PKG}_${VERSION}_all.deb"
