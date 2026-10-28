# Prompt for an AI agent verifying the Windows app

Copy everything below the line into a new AI coding agent session (Claude Code or similar) **on the Windows 11
PC**. The agent knows nothing about earlier work. This prompt is all it gets.

---

You are verifying and, if needed, fixing the **Windows part** of the open-source project **LG Monitor Switch**:
https://github.com/EntangledQuantum/lg-monitor-switch (public). You are on the user's **Windows 11** PC. Work
carefully. The user sits in front of the one shared monitor, and some actions blank their screen.

## 1. The setup (verified facts, trust these)

- One monitor, **LG UltraGear 32GN650** (EDID manufacturer `GSM`, name "LG ULTRAGEAR", reports model GN600,
  MCCS 2.1), shared by two PCs:
  - **Linux PC** (Ubuntu 24.04, GNOME 46) on the monitor's **DisplayPort** input. Ask the user for its LAN IP
    (on Linux, `hostname -I` shows it; the settings app's LAN listener section shows it too).
  - **This Windows 11 PC** on the monitor's **HDMI 2** input. HDMI 1 is unused.
- The user shares keyboard and mouse with **Deskflow**. **Do not touch, configure or change Deskflow in any way.**
- The monitor's OSD has **Auto Input Switch = OFF** (required) and DDC/CI on.
- Brightness = VCP **0x10** (0–100) and contrast = VCP **0x12** (0–100) are standard MCCS. On Linux they read and
  write correctly (originals at the time: brightness 94, contrast 70).
- **Input switching:** the standard VCP **0x60** command is *accepted but ignored* by this monitor, and reading
  0x60 always reports DisplayPort-1 even when HDMI is shown, so it is useless for detecting the input. What works
  is LG's manufacturer side channel: a DDC "Set VCP" packet for register **0xF4** sent with **source address
  0x50** instead of the normal 0x51. Packet: `50 84 03 F4 00 <value> <xor-checksum>`; values DP1=0xD0, DP2=0xD1,
  HDMI1=0x90, HDMI2=0x91. Windows' `dxva2` API can't set the source address, so this app does not send that
  packet from Windows.
- The Linux PC **can send DDC even while the monitor shows Windows**. Verified round trip: Linux sent HDMI 2, waited
  8 s, then sent DP while Windows was on screen, and the screen came back to Linux.
- So **Windows → Linux switching works like this**: the Windows app sends an HTTP request to a small listener on
  the Linux PC (`lg-monitor serve`, port **47320**, header `Authorization: Bearer <token>`), and the Linux PC sends
  the switch packet.

## 2. Safety rules (must follow)

1. **Never write any VCP code other than 0x10 (brightness), 0x12 (contrast) and the input switch.** Never write
   colour preset (0x14), RGB gains (0x16/0x18/0x1A) or anything else, not even "to test". Reading is fine. The C#
   wrapper in `LGMonitor.ps1` (`Ddc.SetVcp`) refuses other codes; do not weaken that.
2. **Every input switch blanks the user's screen** and moves the picture to the other PC. **Before each switch,
   tell the user what will happen and wait for their OK.** Do at most the switch tests listed below. To come back
   to Windows after switching to Linux, the user clicks "Switch to Windows" in the Linux top bar (or runs
   `lg-monitor switch hdmi2` on Linux). Remind them of that first.
3. When you change brightness/contrast to test, **write down the original values first and restore them**.
4. Never commit secrets: not the token, not `%APPDATA%\LGMonitor\config.json`.
5. Don't change Windows security settings, firewall, execution policy (use `-ExecutionPolicy Bypass` per command
   instead) or Deskflow.

## 3. Get the code

```powershell
cd $HOME
git clone https://github.com/EntangledQuantum/lg-monitor-switch.git
cd lg-monitor-switch\windows
```

If `git` is missing, ask the user whether to install Git for Windows (`winget install --id Git.Git -e`), or download
the ZIP from GitHub with their permission.

Files: `LGMonitor.ps1` (the app: WinForms GUI + tray + CLI switches), `Install-LGMonitor.ps1` (installer: Start menu
and optional Startup shortcut, no admin), `LGMonitor.ico`, `config.example.json`. Read `LGMonitor.ps1` fully before
running it.

## 4. Preparation on the Linux PC (the user does this, you guide)

Ask the user to run on the Linux PC (on screen now or over SSH), from the cloned repo if not installed yet:

```bash
cd ~/path/to/lg-monitor-switch/linux && ./install.sh        # skip if already installed
lg-monitor service listener on                               # starts the LAN listener now and at login
systemctl --user status lg-monitor-listener --no-pager       # should be "active (running)"
lg-monitor token                                             # prints the token - the user gives it to you
hostname -I                                                  # first address = Linux IP
```

If the Linux firewall (`ufw`) is active: `sudo ufw allow from 192.168.0.0/16 to any port 47320 proto tcp`.

Don't print the token in logs or commit it. Store it only with `-Configure`.

## 5. Verification steps (run in order, record every result)

Run each command from the `windows` folder with
`powershell -NoProfile -ExecutionPolicy Bypass -File .\LGMonitor.ps1 <args>`.

1. **Environment**: `$PSVersionTable.PSVersion`, `[Environment]::OSVersion`. Note whether you use Windows PowerShell
   5.1 (`powershell.exe`, primary target) or PowerShell 7 (`pwsh`). Test with 5.1, and with pwsh too if it's
   installed.
2. **Compile/list monitors** (read-only): `-ListMonitors`. Expect the LG monitor with a DeviceId containing `GSM`,
   marked `<- selected`, with a brightness reading. If `Add-Type` fails to compile, fix the C# (it must stay C# 5
   compatible for PowerShell 5.1: no `$""` strings, no `?.`, no expression-bodied members).
3. **Read levels** (read-only): `-Get`. Compare with the monitor OSD.
4. **Brightness write**: note the original, then `-SetBrightness <original-20>`, check visually and with `-Get`,
   then restore with `-SetBrightness <original>`.
5. **Contrast write**: same with `-SetContrast`. Restore.
6. **Configure + connectivity** (no switch): `-Configure -LinuxHost <ip> -Token <token>`, then `-TestLinux`.
   Expect `Linux listener OK (version 1.0.0); brightness …, contrast …`.
   Also check the rejections: a wrong token must give 401. Run this temporary test directly, don't save it:
   `Invoke-RestMethod http://<ip>:47320/v1/ping -Headers @{Authorization='Bearer wrong'}` → error 401.
7. **GUI**: run without arguments. A window with Brightness/Contrast sliders, "Switch to Linux", Settings…,
   Refresh, plus a tray icon. Check: values load on start; dragging a slider changes the monitor after ~0.3 s (then
   restore); Settings… dialog shows host/port/token (masked)/monitor list and "Test connection" says
   Connected; closing the window hides it to the tray; tray menu works; "Exit" quits. Take a screenshot of the
   window (Win+Shift+S or `Add-Type`/`System.Drawing` screen capture) and save it as `docs/images/windows-app.png`.
8. **Switch to Linux, CLI** (blanks the Windows screen, so ask first). Explain: "The monitor will switch to the
   Linux PC. To come back, click the monitor icon in the Linux top bar → Switch to Windows." Then
   `-SwitchToLinux`. Expected output: `Linux switched the monitor to dp1.`, and the user confirms Linux is on
   screen. Wait until the user has switched back to Windows.
9. **Switch to Linux, GUI button** (ask first again). Click "Switch to Linux". Same expectation. Wait for the user to
   switch back.
10. **Installer**: `.\Install-LGMonitor.ps1 -Startup`. Check the Start menu entry "LG Monitor Switch" opens the app
    with no console window left open. Check `shell:startup` contains the shortcut. Optionally test
    `-Uninstall` and reinstall.
11. **Optional / informational**: `-SwitchToLinux -Method ddc60` sends standard VCP 0x60 = 0x0F. It is expected to
    do **nothing** on this monitor. Only run it if the user agrees (it might blank the screen if it does work).
    Report what happened.

## 6. Troubleshooting

- **`unable to connect` / timeout**: the listener isn't running (`systemctl --user status lg-monitor-listener` on
  Linux), wrong IP, the PCs are on different networks, or a firewall. Windows outbound HTTP is normally allowed;
  on Linux check `sudo ufw status`. Test with `Test-NetConnection <ip> -Port 47320`.
- **401**: token mismatch. Get it again with `lg-monitor token`; no spaces.
- **403**: the Windows PC's address isn't private (e.g. VPN). The Linux `[listener] allow = any` option exists, but
  ask the user first.
- **DDC/CI read/write failed**: wrong monitor selected (`-ListMonitors`, then `-Configure -MonitorIndex N`),
  DDC/CI off in the OSD, or a dock/adapter/KVM that blocks DDC. Some GPUs need a moment after wake-up; retry.
- **Screen jumps back on its own after a switch**: Auto Input Switch is ON in the OSD. Ask the user to turn it off.
- **Wrong display index / several monitors**: auto-pick uses `monitor_match` (`GSM`) against the DeviceId. If two
  LG monitors are present, set `monitor_index`.
- **GUI doesn't start, or starts and exits**: run from a console without `-WindowStyle Hidden` to see errors; check
  STA (the script relaunches itself with `-STA` if needed); a second instance shows "already running".
- **Proxy**: if a system proxy intercepts LAN HTTP, `Invoke-RestMethod` may fail; check
  `netsh winhttp show proxy` and the Internet Options proxy bypass for local addresses.

## 7. Deskflow note

On Linux there is an *optional* Deskflow auto-switch (switches the input when the cursor changes PC). **A Windows
version is planned but not implemented, so don't build it now.** If the Linux Deskflow auto-switch is on, the user
should not also use the Windows "Switch to Linux" button heavily, because both sides could fight over the input.
Mention this in your report if you see it enabled. Don't change Deskflow.

## 8. Fixing bugs

- Keep changes minimal and in the existing style. Windows code is `windows/LGMonitor.ps1` and
  `windows/Install-LGMonitor.ps1`. If behaviour changes, update `README.md` (Windows section) too.
- Never add writes to VCP codes other than 0x10, 0x12, 0x60 (the 0x60 path stays optional, not the default).
- Re-run the affected verification steps after each fix.
- Commit and push to the same repo (the user's GitHub account must be logged in. Check `gh auth status` or
  `git push` credentials; if push is not possible, open a PR from a fork or give the user a patch file):
  ```powershell
  git checkout -b windows-verification
  git add windows/ docs/ README.md
  git commit -m "Windows: <what you fixed>"
  git push -u origin windows-verification
  gh pr create --fill     # or push to main if the user prefers
  ```
  Check `git diff --cached` for secrets before committing. `config.json` is git-ignored.

## 9. Report back

Give the user a short report:

- Windows / PowerShell versions used.
- A table of steps 1–11: pass/fail, plus the **exact** output or observation (values read, values written and
  restored, HTTP results, what the screen did).
- Bugs found and how you fixed them (commit hashes / PR link).
- Anything not tested and why.
- Whether `docs/images/windows-app.png` was added.
- Confirm that the original brightness/contrast were restored and the monitor ended on the input the user wants.
