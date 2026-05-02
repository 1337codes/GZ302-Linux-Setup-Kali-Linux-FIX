# GZ302 Kali KDE Setup

One-shot replay script for getting Kali Linux (KDE) working cleanly on the **ASUS ROG Flow Z13 (GZ302)** — AMD Ryzen AI MAX+ 395 (Strix Halo).

Fully dynamic: works for any username, any home directory. Idempotent — safe to re-run.

> ⚠️ **Internal microphone does NOT work on Kali — wait for kernel fix.**
> The built-in mic array routes through AMD ACP 7.0 and needs the
> `snd_sof_amd_acp70` kernel module, which is **not built into Kali's
> kernel** as of writing. There is **no userland workaround** — this is a
> kernel build option (`CONFIG_SND_SOC_SOF_AMD_ACP70=m`) that has to be
> enabled upstream. Until then, use a USB / Bluetooth / 3.5 mm headset mic.
> Verify status after kernel updates with:
> ```sh
> modinfo snd_sof_amd_acp70
> ```
> The day that stops saying *"Module not found"*, the internal mics will
> start working.

## Usage

```sh
chmod +x gz302-kali-setup.sh
./gz302-kali-setup.sh                 # auto-detects current user
./gz302-kali-setup.sh someuser        # or pass an explicit username
sudo reboot
```

## What it does

1. Runs the upstream [th3cavalry/GZ302-Linux-Setup](https://github.com/th3cavalry/GZ302-Linux-Setup) unified installer (hardware fixes + z13ctl + display tools, no optional modules).
2. Adds extra suspend-reliability kernel param: `rtc_cmos.use_acpi_alarm=1`. Removes the known-bad `amd_pmc.enable_stb=1` if present from earlier runs (it crashes `amd_pmc` probe on Strix Halo).
3. Patches `z13ctl-perms.service`:
   - Tolerates the missing `asus-armoury` driver (not in Kali's kernel).
   - Adds `users`-group write perms on `asus-nb-wmi/ppt_*` so TDP/profile changes work without sudo.
4. Relocates the tray app from any user's Downloads folder to `/opt/gz302-tray` and rewrites every desktop launcher (system + per-user). Re-syncs `/opt` from a fresh source if the upstream installer drops a newer copy.
5. Installs a Bluetooth resume hook (`/usr/lib/systemd/system-sleep/gz302-bluetooth.sh`) — resets HCI and restarts `bluetoothd` on resume so BT mice/devices reconnect cleanly after suspend/hibernate (fixes flaky MT7925 BT on Strix Halo).
6. Adds the user to the `users` group for unprivileged `z13ctl` access.
7. Sets sensible defaults: 80% battery limit, balanced profile.

## Requirements

- Kali Linux (rolling), KDE Plasma
- Kernel 6.14+ (6.17+ recommended)
- ASUS ROG Flow Z13 (GZ302)
- Network + sudo

## Known limitations (not script-related, kernel-side)

| Component | Status | Workaround |
|---|---|---|
| Internal microphone array | ❌ Not working — needs `snd_sof_amd_acp70` kernel module | USB / Bluetooth / 3.5 mm headset mic |
| Speaker calibration firmware (CS35L41) | ⚠️ Default firmware in use — sound works, calibrated tuning doesn't | None needed; cosmetic dmesg warnings only |
| `asus-armoury` firmware-attributes | ❌ Not built into Kali's kernel — affects boot-sound / panel-overdrive / Armoury Crate button toggles in `z13ctl` | None — script handles gracefully, all other z13ctl features work |

All three are upstream kernel issues that will resolve themselves as Strix Halo support matures in the Debian/Kali kernel build. No action needed on your end beyond keeping the system updated.

## Upstream

For docs, hardware research, and issue tracker, see the source project:
**[github.com/th3cavalry/GZ302-Linux-Setup](https://github.com/th3cavalry/GZ302-Linux-Setup)**
