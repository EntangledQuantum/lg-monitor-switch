# DDC/CI notes for the LG UltraGear 32GN650

## DDC/CI in one paragraph

DDC/CI runs over the I²C lines of the video cable. The monitor answers at 7-bit address **0x37**. The host writes
packets that start with a *source address* byte, followed by `0x80 | length`, the payload and a checksum. The
checksum is the XOR of the destination address byte (`0x37 << 1 = 0x6E`) and every byte before the checksum. The
standard host source address is **0x51**. MCCS defines VCP codes such as 0x10 brightness, 0x12 contrast and 0x60
input source.

## Standard commands we use

| VCP | Meaning | Read | Write |
|---|---|---|---|
| 0x10 | Brightness 0–100 | yes | yes |
| 0x12 | Contrast 0–100 | yes | yes |

Linux: `ddcutil --bus N getvcp 10 12 --brief` returns `VCP 10 C 94 100` (current 94, max 100).
`lg-monitor` writes with `ddcutil --noverify setvcp`, waits ~120 ms, reads the value back and retries up to 3
times. ddcutil's own verification read back too early on this monitor, and the monitor sometimes drops a write
without reporting an error (seen during testing, see TEST_LOG.md).

Windows: `GetVCPFeatureAndVCPFeatureReply` / `SetVCPFeature` from `dxva2.dll` on the physical-monitor handle.

## Why VCP 0x60 is not used

`ddcutil setvcp 60 0x11` / `0x12` is acknowledged by the 32GN650 and then ignored. `getvcp 60` always returns
`0x0f` (DisplayPort-1), whichever input is on screen. So 0x60 can't switch the input or report it. lg-monitor
never reads the "current input" from the monitor; it remembers the last input it switched to
(`$XDG_RUNTIME_DIR/lg-monitor-UID/state.json`).

## LG side channel: register 0xF4 with source address 0x50

```
byte  0     1     2     3     4     5        6
      0x50  0x84  0x03  0xF4  0x00  <value>  <checksum>
      src   len   SetVCP reg  hi    lo
```

| Input | value | full packet |
|---|---|---|
| DisplayPort 1 | 0xD0 | `50 84 03 F4 00 D0 9D` |
| DisplayPort 2 | 0xD1 | `50 84 03 F4 00 D1 9C` |
| HDMI 1 | 0x90 | `50 84 03 F4 00 90 DD` |
| HDMI 2 | 0x91 | `50 84 03 F4 00 91 DC` |

Checksum example for HDMI 2: `6E ^ 50 ^ 84 ^ 03 ^ F4 ^ 00 ^ 91 = DC`.

Sent on Linux with i2c-tools (the 7 bytes are written to slave 0x37; the kernel adds the address byte):

```bash
i2ctransfer -y 6 w7@0x37 0x50 0x84 0x03 0xf4 0x00 0x91 0xdc   # HDMI 2
i2ctransfer -y 6 w7@0x37 0x50 0x84 0x03 0xf4 0x00 0xd0 0x9d   # DisplayPort
```

`lg-monitor packet` prints these without touching the hardware. The bus number is never hard-coded: it is detected
with `ddcutil detect --brief` (EDID manufacturer `GSM`, model containing `LG ULTRAGEAR`) and cached, or set with
`[monitor] bus = N`.

Values and the source-address trick come from
[MonitorInputWizzard](https://github.com/lunat1q/monitorinputwizzard) (LG UltraGear table).

### Sending from a computer that is not on screen

The Linux PC is connected over DisplayPort. Its DDC/CI channel keeps working while the monitor shows HDMI 2: the
I²C bus stays present, X still reports the output as connected, and the switch-back packet is accepted. This was
verified (TEST_LOG.md). That's why Windows → Linux goes through the Linux PC:

```
Windows app ──HTTP (token)──▶ lg-monitor listener on Linux ──I²C 0x50/0xF4──▶ monitor ──▶ DisplayPort
```

### Options on Windows itself

- `dxva2` `SetVCPFeature` always uses source address 0x51, so it can't send the 0xF4 side channel. It *can* send
  VCP 0x60 (the app's optional `switch_method = ddc60`), but the 32GN650 ignores that.
- NVIDIA NVAPI `NvAPI_I2CWrite` gives raw I²C access on NVIDIA GPUs and can send the exact packet. That is what
  MonitorInputWizzard does. AMD ADL has something similar. Not implemented here, to keep the Windows app free of
  dependencies.

## Deskflow log lines

The Deskflow server logs (level INFO, so Deskflow's log level must be Info or more detailed) one of these whenever the cursor changes screen:

```
[2026-10-29T10:00:00] INFO: switch from "linux-pc" to "windows-pc" at 1919,540
[2026-10-29T10:00:00] INFO: jump from "windows-pc" to "linux-pc" at 960,540
```

`lg-monitor deskflow-watch` matches `(switch|jump) from "A" to "B"`, maps screen B to an input, and switches after
`delay` seconds unless another line arrives first. Logic: `AutoSwitcher` in `linux/lg-monitor`, unit-tested in
`tests/test_lg_monitor.py`.

It reads Deskflow's *Log to file* output, found through Deskflow's own settings file (read-only:
`~/.var/app/org.deskflow.deskflow/config/Deskflow/Deskflow.conf` for the Flatpak, `~/.config/Deskflow/Deskflow.conf`
for native/AppImage builds; keys `[log] toFile`, `file`, `level`). If both exist, the one belonging to the running
Deskflow process is used (a Flatpak process is recognised by its `app-flatpak-` cgroup). A Flatpak can only write
inside `~/.var/app/org.deskflow.deskflow/`. If its configured path is outside the sandbox, the most recently
modified `*.log` inside that folder is followed instead, and the user is told the exact path to set.

Re-detection (`DeskflowWatcher` in `linux/lg-monitor`):

- The watcher stats lg-monitor's `config.ini`, Deskflow's `Deskflow.conf` files and Deskflow's server config on
  every loop iteration (0.25 s). Only when one of them changes does it re-run detection and switch to another log
  file if needed, so there is no periodic re-scanning while things work.
- While no usable log file exists (file missing, *Log to file* off, Flatpak path outside the sandbox), it retries
  detection every 7 s and follows the user journal as a last resort. It stops retrying once a file is found.
- Log rotation and truncation are handled by the file follower (it finishes the old file, then reads the new one
  from the top).
- Health is written to `$XDG_RUNTIME_DIR/lg-monitor-UID/deskflow-watch.json` (source, path, last cursor event,
  last switch) and shown by `lg-monitor deskflow-info` and the settings app.
