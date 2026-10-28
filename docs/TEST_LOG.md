# Test log (Linux, 2026-10-29)

Machine: Ubuntu 24.04, kernel 7.0, GNOME Shell 46.0 on X11, ddcutil 1.4.1, i2c-tools, /usr/bin/python3 3.12.3,
GTK 4.14 / libadwaita 1.5. Monitor: LG UltraGear 32GN650 on DisplayPort (Linux) and HDMI 2 (Windows 11 PC).
Deskflow 1.27.0 (Flatpak) installed and running; it was only *read* (settings file), never modified.

## Facts established before the code was written (manual tests)

| Test | Result |
|---|---|
| `ddcutil detect --brief` | Display 1 on `/dev/i2c-6`, monitor `GSM:LG ULTRAGEAR:…`; capabilities report model GN600, MCCS 2.1 |
| `ddcutil getvcp 10 12` | brightness 94, contrast 70 |
| `ddcutil setvcp 60 0x11` / `0x12` | accepted, **no effect** |
| `ddcutil getvcp 60` | always `0x0f` (DisplayPort-1), even while HDMI was on screen |
| `i2ctransfer -y 6 w7@0x37 0x50 0x84 0x03 0xf4 0x00 0x91 0xdc` | monitor switched to HDMI 2 (Windows), confirmed visually by the user |
| same, then 8 s later `… 0xd0 0x9d` from Linux while Windows was shown | screen came back to Linux, confirmed visually by the user |
| while switched away | `/dev/i2c-6` present; X still reports the DP output connected |

## Automated tests

`/usr/bin/python3 -m unittest discover -s tests -v` → **24 tests, OK** (no hardware access). Covered:
packet bytes and checksums (match the verified packets above), input name parsing, `ddcutil detect`/`getvcp`
parsing, 0–100 validation, refusal to write any VCP other than 0x10/0x12, LAN listener over real HTTP on
127.0.0.1 with a fake backend (auth 401, unknown endpoints 404, bad values 400, oversize body 413, switch input
allow-list), client address policy, the Deskflow `AutoSwitcher` (delay, cancel when the cursor returns,
restart on bouncing, cooldown, unmapped screens, already-on-target, manual-switch sync, `jump` lines), and the
log follower (partial lines, truncation).

`node --check` on both extension files: OK.

## CLI on the real monitor

| Command | Result |
|---|---|
| `lg-monitor packet` | `dp1 0x50 0x84 0x03 0xf4 0x00 0xd0 0x9d` … `hdmi2 0x50 0x84 0x03 0xf4 0x00 0x91 0xdc` |
| `lg-monitor detect` | `/dev/i2c-6` |
| `lg-monitor get` | `brightness 94` / `contrast 70` (0.68 s) |
| `lg-monitor set-brightness 60`, `get` | 60 / 70 |
| first version: `set-contrast 50` via plain `ddcutil setvcp` (with verification) | **"Verification failed for feature 12"**, next read returned `VCP 10 ERR` |
| investigation: 3× `setvcp 12 50 --noverify` + read-backs | 2 of 3 writes applied, 1 **silently dropped** (rc 0, value unchanged) |
| 16 write+read-back cycles (0.15 s gap) | 15 OK, 1 read returned nothing |
| → fix: write `--noverify`, wait 120 ms, read back, retry ×3; reads retry ×3 | |
| 8 alternating `set-contrast`/`set-brightness` with the fix | all applied, 1.1–2.0 s each |
| `set-brightness 101`, `set-contrast abc`, `set-brightness -1`, `switch hdmi3` | all rejected with an error, nothing written |
| restore | `brightness 94` / `contrast 70` |

## GNOME Shell extension

The running X11 session needs a shell restart to load a new extension, so the extension was tested in a
**throwaway headless GNOME Shell 46** (`tests/shell-harness/run-headless.sh`: Wayland, isolated
config/data/runtime dirs and D-Bus, the real session untouched) with a test-only harness extension:

```
HARNESS extension state=1 error=                 (1 = ENABLED)
HARNESS indicator=true
HARNESS brightness=94 contrast=70 switch="Switch to Windows" status=""
HARNESS drag brightness 94 -> 80                 (slider set to 70, 75, 80 % in quick succession)
HARNESS after drag: {"switch_target": "hdmi2", "switch_label": "Windows", "brightness": 80, "contrast": 70}
HARNESS restoring brightness 94                  (lg-monitor get afterwards: 94 / 70)
```

The screenshots in `docs/images/` come from this harness (`LGM_DEMO=1` swaps in neutral screen names and IP).
In the real session `install.sh` added the UUID to `enabled-extensions`. **Not verified in the user's live
session yet** (needs Alt+F2 `r` or a re-login).

## Settings app

Started in the same headless shell: all groups render, the monitor is detected (`LG ULTRAGEAR on /dev/i2c-6 —
brightness 94, contrast 70`), Deskflow found (flatpak) with both screens listed, and the log-file status explains
that Deskflow's *Log to file* is off and which path to use.

## LAN listener (real backend, 127.0.0.1:47399, then the systemd unit on 0.0.0.0:47320)

```
no token:  401          bad token: 401
ping:      {"ok": true, "version": "1.0.0"}
status:    {"ok": true, "brightness": 94, "contrast": 70}
bad value: {"ok": false, "error": "value must be an integer 0-100"}
bad path:  {"ok": false, "error": "unknown endpoint"}
bad input: {"ok": false, "error": "input must be one of: home, dp1, dp2, hdmi1, hdmi2"}
set 70:    {"ok": true, "brightness": 70}   status → 70/70
set 94:    {"ok": true, "brightness": 94}   contrast 70 → status 94/70
via LAN IP (systemd unit): ping OK, status 94/70
```

## Autostart / services

| Step | `is-enabled` listener / deskflow | `is-active` |
|---|---|---|
| `service listener on`, `service deskflow on` | enabled / enabled | active / active |
| `autostart off` | disabled / disabled | active / active (keep running this session) |
| `autostart on` | enabled / enabled | active / active |
| `systemctl --user restart` both | | active / active |
| both `off` | disabled / disabled | inactive / inactive |

A first version restarted every running unit on each change and hit systemd's start limit (`start-limit-hit`);
fixed so only the changed unit is touched. Deskflow watcher journal at start: "Deskflow's 'Log to file' is off …",
"watching the user journal", "mapping: (empty)". Both services were left **off** (opt-in) and autostart **on**.
`uninstall.sh` → files, units and the extension entry removed, config kept; `install.sh` afterwards restores all.
**A reboot test was not possible here; the user should reboot or log out/in once to confirm.**

## Deskflow watcher (dry run, simulated log lines, no real switches)

Config `delay = 2`, `cooldown = 1`, mapping `linux-pc = dp1`, `windows-pc = hdmi2`:

```
04:33:05 cursor -> windows-pc: schedule
04:33:07 switching monitor to hdmi2                (after the 2 s delay)
04:33:08 cursor -> linux-pc: schedule
04:33:08 cursor -> windows-pc: cancel             (cursor came back within 0.7 s → nothing)
04:33:11 cursor -> linux-pc: schedule
04:33:13 switching monitor to dp1
         'client "windows-pc" has disconnected'   (ignored)
```

## Final input round trip (once, through the installed code)

```
04:41:09 lg-monitor switch hdmi2   → "switched to HDMI 2", rc=0, state {"input": "hdmi2", "origin": "cli"}
         sleep 8; /dev/i2c-6 still present
04:41:18 lg-monitor switch dp      → "switched to DisplayPort", rc=0, state {"input": "dp1"}
         lg-monitor get            → brightness 94 / contrast 70 (DDC fine after returning)
```

The commands succeeded. Whether the picture actually flipped and came back during this run was not watched by
the agent. The same packets were confirmed visually by the user earlier.

## Not tested here

- The Windows app (no Windows machine). See `docs/WINDOWS_VERIFICATION_PROMPT.md`.
- The extension inside the user's live X11 session (needs a GNOME Shell restart).
- Deskflow auto-switch with real Deskflow log output (needs *Log to file* turned on by the user).
- Reboot / fresh-login autostart.
- GNOME 47/48 (declared in metadata, uses only APIs unchanged since 46).
