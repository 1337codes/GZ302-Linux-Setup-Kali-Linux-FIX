# GZ302 Kali KDE Setup

One-shot replay script for getting Kali Linux (KDE) working cleanly on the **ASUS ROG Flow Z13 (GZ302)** — AMD Ryzen AI MAX+ 395 (Strix Halo).

## Usage

```sh
chmod +x gz302-kali-setup.sh
./gz302-kali-setup.sh                 # auto-detects current user
./gz302-kali-setup.sh someuser        # or pass an explicit username
sudo reboot
```

Idempotent — safe to re-run.

## What it does

1. Runs the upstream [th3cavalry/GZ302-Linux-Setup](https://github.com/th3cavalry/GZ302-Linux-Setup) unified installer (hardware fixes + z13ctl + display tools, no optional modules).
2. Adds extra suspend-reliability kernel params: `amd_pmc.enable_stb=1`, `rtc_cmos.use_acpi_alarm=1`.
3. Patches `z13ctl-perms.service`:
   - Tolerates the missing `asus-armoury` driver (not in Kali's kernel).
   - Adds `users`-group write perms on `asus-nb-wmi/ppt_*` so TDP/profile changes work without sudo.
4. Relocates the tray app from any user's Downloads folder to `/opt/gz302-tray` and rewrites every desktop launcher (system + per-user).
5. Adds the user to the `users` group for unprivileged `z13ctl` access.
6. Sets sensible defaults: 80% battery limit, balanced profile.

## Requirements

- Kali Linux (rolling), KDE Plasma
- Kernel 6.14+ (6.17+ recommended)
- ASUS ROG Flow Z13 (GZ302)
- Network + sudo

## Upstream

For docs, hardware research, and issue tracker, see the source project:
**[github.com/th3cavalry/GZ302-Linux-Setup](https://github.com/th3cavalry/GZ302-Linux-Setup)**
