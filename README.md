# GZ302 Kali KDE Setup

Production-grade replay kit for the **ASUS ROG Flow Z13 (GZ302)** — AMD Ryzen AI MAX+ 395 (Strix Halo) — running Kali Linux with KDE Plasma.

One command on a fresh install gets you to a fully tuned working state: hardware fixes applied, suspend rock solid (~1 second resume responsiveness), Bluetooth peripherals reconnect cleanly after wake, RGB control via dedicated GUI, and sensible power defaults. Fully dynamic — works for any username, any home directory. Idempotent — safe to re-run.

> ⚠️ **Internal microphone does NOT work on Kali — wait for kernel fix.**
> The built-in mic array routes through AMD ACP 7.0 and needs the
> `snd_sof_amd_acp70` kernel module, which is **not built into Kali's
> kernel** as of writing. There is **no userland workaround** — this is
> a kernel build option (`CONFIG_SND_SOC_SOF_AMD_ACP70=m`) that has to
> be enabled upstream. Until then, use a USB / Bluetooth / 3.5 mm
> headset mic. Verify status after kernel updates with:
> ```sh
> modinfo snd_sof_amd_acp70
> ```
> The day that stops saying *"Module not found"*, the internal mics
> will start working.

## Files in this kit

| File | Purpose | Required? |
|---|---|---|
| `gz302-kali-setup.sh` | Main orchestrator — runs all 8 steps | **Yes** |
| `z13rgb.py` | Z13 RGB Control GUI (PyQt6) | Optional* |
| `z13rgb.desktop` | KDE menu / desktop launcher | Optional* |
| `README.md` | This file | — |

\* If `z13rgb.py` (and optionally `z13rgb.desktop`) is present in the same folder as `gz302-kali-setup.sh`, the GUI gets installed in step 8. If absent, that step is skipped with a warning — every other step still runs.

## Usage

Drop **all four files in the same folder**, then:

```sh
chmod +x gz302-kali-setup.sh
./gz302-kali-setup.sh                 # auto-detects current user
./gz302-kali-setup.sh someuser        # or pass an explicit username
sudo reboot
```

After reboot, the Z13 is fully configured. The **GZ302 Dashboard** tray icon appears in your KDE Plasma panel automatically, and a **Z13 RGB Control** shortcut is on your desktop and in your KDE app menu.

## What it does (8 steps)

1. **Runs the upstream [th3cavalry/GZ302-Linux-Setup](https://github.com/th3cavalry/GZ302-Linux-Setup) unified installer** (hardware fixes + `z13ctl` + display tools; skips Gaming/LLM/Hypervisor optional modules — they're Ubuntu-centric and break on Kali).

2. **Tunes GRUB kernel parameters.** Adds `rtc_cmos.use_acpi_alarm=1` for ACPI wake reliability. Actively removes `amd_pmc.enable_stb=1` if present from earlier runs — that param crashes the `amd_pmc` driver probe on Strix Halo with `-ENOMEM`.

3. **Patches `z13ctl-perms.service`** so it survives Kali's reduced kernel feature set:
   - Tolerates the missing `asus-armoury` driver.
   - Adds `users` group write permissions on `/sys/devices/platform/asus-nb-wmi/ppt_*` so TDP and profile changes actually work without sudo.

4. **Relocates the tray app to `/opt/gz302-tray/`** and rewrites every `gz302-tray.desktop` launcher (system + per-user). Re-syncs `/opt` if the upstream installer drops a fresh copy in `~/Downloads`. Cleans up stray copies. Survives Downloads-folder cleanup.

5. **Installs two resume-time hooks** in `/usr/lib/systemd/system-sleep/`:
   - `aaa-gz302-input-fast.sh` — re-authorizes keyboard/touchpad/lightbar USB devices at the *start* of post-resume so the lock screen accepts your password within ~1 second of wake. Without this, the upstream hook's housekeeping leaves the keyboard unbound for ~11 seconds. The `aaa-` prefix forces alphabetical-first execution by `systemd-sleep`.
   - `gz302-bluetooth.sh` — resets the HCI controller and restarts `bluetoothd` on resume so BT mice/devices reconnect cleanly (Strix Halo MT7925 fix).
   - Cleans up stray `.patch` / `.bak` files in the system-sleep directory left over from older script versions (they cause harmless but noisy errors at every suspend).

6. **Adds the user to the `users` group** for unprivileged `z13ctl` access.

7. **Applies sensible defaults**: 80% battery charge limit, balanced power profile.

8. **Installs the Z13 RGB Control GUI** (if `z13rgb.py` is present alongside the script):
   - Copies to `/opt/z13-rgb-control/z13rgb.py` (root-owned, world-readable).
   - Installs `/usr/share/applications/z13rgb.desktop` for the KDE menu.
   - Drops a launcher on the target user's desktop (`~/Desktop/z13rgb.desktop`) marked KDE-trusted via `gio metadata::trusted` so it launches without a confirmation dialog.
   - Runs `update-desktop-database` to refresh KDE's app cache.

## Z13 RGB Control GUI

A standalone PyQt6 window for full RGB control — independent tabs for **Keyboard** and **Lightbar** so each device can run its own mode/color/brightness simultaneously. Aesthetic: dark cyberpunk-tactical with cyan accents to match the rest of the Z13 ecosystem.

**Modes:** Static · Breathe · Color Cycle · Rainbow · Strobe
**Brightness:** Off / Low / Medium / High
**Speed:** Slow / Normal / Fast (animated modes only)
**Colors:** Primary + Secondary (Breathe uses both); full Qt color picker.

Live preview — every change applies after a 250 ms debounce. The "Turn Keyboard / Lightbar Off" button is a proper toggle: one click off, one click back on (restores the previous brightness). The big "ALL LIGHTING OFF" bar at the bottom kills both devices instantly via `z13ctl off`. Status bar at the bottom shows the exact `z13ctl` command result for each action.

The app shells out to `z13ctl` for every change — it doesn't poke `/dev/hidraw*` directly. That keeps it forward-compatible with z13ctl updates.

**Launch from:**
- KDE menu / Krunner — search "Z13 RGB"
- Double-click the desktop icon
- Direct: `python3 /opt/z13-rgb-control/z13rgb.py`

## Requirements

- Kali Linux (rolling), KDE Plasma
- Kernel **6.14+** (6.17+ strongly recommended for native input/audio support)
- ASUS ROG Flow Z13 (**GZ302**)
- Network access + sudo
- PyQt6 (auto-installed by the upstream tray-app step; reused by the RGB GUI)

## Smoke tests after reboot

```sh
cat /proc/cmdline                                       # should NOT contain amd_pmc.enable_stb=1
systemctl status z13ctl-perms.service                   # active (exited)
z13ctl status                                           # shows current TDP/profile/battery
ls -la /opt/gz302-tray /opt/z13-rgb-control            # both directories present
ls -la ~/Desktop/z13rgb.desktop                        # desktop shortcut owned by you
pgrep -af command_center.py                            # tray autostarted by KDE
systemctl suspend                                      # then wake and...
journalctl -b -t gz302-input-fast --no-pager           # input hook fired (~1s after wake)
journalctl -b -t gz302-bt --no-pager                   # BT hook fired
journalctl -b -t gz302-reset --no-pager                # full upstream hook ran clean
```

## Known limitations (kernel-side, not script-related)

| Component | Status | Workaround |
|---|---|---|
| Internal microphone array | ❌ Not working — needs `snd_sof_amd_acp70` kernel module | USB / Bluetooth / 3.5 mm headset mic |
| Speaker calibration firmware (CS35L41) | ⚠️ Default firmware in use — sound works, calibrated tuning doesn't | None needed; cosmetic dmesg warnings only |
| `asus-armoury` firmware-attributes interface | ❌ Not in Kali's kernel build — affects boot-sound, panel-overdrive, and Armoury Crate button toggles | None — script handles gracefully, all other `z13ctl` features work |

All three are upstream kernel/firmware issues that will resolve as Strix Halo support matures in the Debian/Kali kernel package. No action needed on your end beyond keeping the system updated.

## Troubleshooting

**RGB GUI shows "z13ctl not found"** — `z13ctl` install failed in step 1, or the user isn't in the `users` group yet. Re-run the script and log out / in once.

**Off button doesn't turn things back on** — fixed in latest `z13rgb.py`. If `/opt/z13-rgb-control/z13rgb.py` is older, copy the latest version from your kit there and restart the GUI.

**Lock screen still slow on resume** — verify the input-fast hook is in place and executable: `ls -la /usr/lib/systemd/system-sleep/aaa-gz302-input-fast.sh`. Confirm it fires at wake: `journalctl -b -t gz302-input-fast`.

**`gz302-reset.sh.patch` appears in suspend errors** — leftover from an older script run. Remove with `sudo rm -f /usr/lib/systemd/system-sleep/gz302-reset.sh.patch /usr/lib/systemd/system-sleep/gz302-reset.sh.bak`. Latest script auto-cleans these.

## Upstream

Source project for the underlying hardware-fix installer and `z13ctl`:
**[github.com/th3cavalry/GZ302-Linux-Setup](https://github.com/th3cavalry/GZ302-Linux-Setup)**
