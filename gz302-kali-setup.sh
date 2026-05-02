#!/usr/bin/env bash
#
# gz302-kali-setup.sh
#
# Automated Kali Linux (KDE) setup for ASUS ROG Flow Z13 (GZ302).
# Replays the exact sequence used to get a working configuration:
#
#   1. Runs th3cavalry/GZ302-Linux-Setup unified installer non-interactively
#      (hardware fixes + z13ctl + display tools, skips optional modules).
#   2. Adds extra suspend-reliability kernel params to GRUB:
#        amd_pmc.enable_stb=1
#        rtc_cmos.use_acpi_alarm=1
#   3. Patches z13ctl-perms.service to tolerate the missing asus-armoury
#      kernel driver (not built into Kali's kernel as of writing).
#   4. Ensures the user is in the 'users' group for unprivileged z13ctl.
#   5. Applies sensible defaults: battery limit 80%, balanced profile.
#
# Run on a fresh Kali KDE install on a GZ302. Requires sudo + network.
# Idempotent — safe to re-run.
#
# Tested:    Kali rolling, KDE Plasma, kernel 6.19.11+kali-amd64
# Hardware:  ASUS ROG Flow Z13 (GZ302) — AMD Ryzen AI MAX+ 395 (Strix Halo)
#
# Optional tweak NOT done by this script (uncomment to enable):
#   For better battery life, change `amd_pstate=guided` to `amd_pstate=active`
#   in /etc/default/grub manually, then run `sudo update-grub`.
#

set -euo pipefail

# ---------- pretty output ----------
if [[ -t 1 ]]; then
    R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; B=$'\033[1;34m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; N=""
fi

log()  { echo "${B}[*]${N} $*"; }
ok()   { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
err()  { echo "${R}[-]${N} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- banner ----------
cat <<'EOF'
   ██████╗ ███████╗██████╗  ██████╗ ██████╗
  ██╔════╝ ╚══███╔╝╚════██╗██╔═████╗╚════██╗
  ██║  ███╗  ███╔╝  █████╔╝██║██╔██║ █████╔╝
  ██║   ██║ ███╔╝   ╚═══██╗████╔╝██║██╔═══╝
  ╚██████╔╝███████╗██████╔╝╚██████╔╝███████╗
   ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚══════╝
   GZ302 Kali Linux KDE Setup — replay script
EOF
echo

# ---------- privilege ----------
if [[ $EUID -eq 0 ]]; then
    die "Don't run this script as root. It uses sudo internally where needed."
fi
sudo -v || die "sudo authentication failed."

# Identify the human user (handles being run with or without sudo wrapping)
TARGET_USER="${SUDO_USER:-$USER}"
[[ "$TARGET_USER" == "root" ]] && TARGET_USER="$(logname 2>/dev/null || echo "$USER")"

# ---------- sanity checks ----------
log "Running sanity checks..."

[[ -f /etc/os-release ]] || die "/etc/os-release not found."
# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "kali" ]]; then
    warn "This script targets Kali Linux. Detected: ${ID:-unknown}"
    read -rp "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
fi
ok "Distribution: ${PRETTY_NAME:-$ID}"

KVER=$(uname -r)
KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2 | grep -oE '^[0-9]+' || echo 0)
if (( KMAJOR < 6 )) || (( KMAJOR == 6 && KMINOR < 14 )); then
    die "Kernel ${KVER} is too old. Requires 6.14+ (6.17+ recommended)."
fi
ok "Kernel: ${KVER}"

# Best-effort hardware sniff
if command -v dmidecode >/dev/null 2>&1; then
    PROD=$(sudo dmidecode -s system-product-name 2>/dev/null || true)
    if [[ -n "$PROD" && ! "$PROD" =~ GZ302 ]]; then
        warn "System product '$PROD' doesn't look like a GZ302."
        read -rp "Continue anyway? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
    elif [[ -n "$PROD" ]]; then
        ok "Hardware: $PROD"
    fi
fi

if ! curl -fsI https://raw.githubusercontent.com >/dev/null 2>&1; then
    die "No connectivity to GitHub. Check your network."
fi
ok "Network reachable"

echo
read -rp "Proceed with full GZ302 setup? [Y/n] " ans
[[ "$ans" =~ ^[Nn]$ ]] && die "Aborted."
echo

# ---------- step 1: upstream installer ----------
log "Step 1/5: Running th3cavalry/GZ302-Linux-Setup unified installer..."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fL -o "$WORK/gz302-setup.sh" \
    https://raw.githubusercontent.com/th3cavalry/GZ302-Linux-Setup/main/gz302-setup.sh
chmod +x "$WORK/gz302-setup.sh"

# -y: accept all defaults (Y to fixes, z13ctl, display tools)
# --no-modules: skip Gaming/LLM/Hypervisor packs (Ubuntu-centric, often broken on Kali)
sudo "$WORK/gz302-setup.sh" -y --no-modules

ok "Unified installer complete"
echo

# ---------- step 2: GRUB suspend params ----------
log "Step 2/5: Adding extra suspend-reliability kernel parameters..."

GRUB_FILE="/etc/default/grub"
GRUB_CHANGED=0
EXTRA_PARAMS=("amd_pmc.enable_stb=1" "rtc_cmos.use_acpi_alarm=1")

for p in "${EXTRA_PARAMS[@]}"; do
    if grep -q "$p" "$GRUB_FILE"; then
        ok "  $p already present"
    else
        sudo sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\")(.*)(\")|\1\2 ${p}\3|" "$GRUB_FILE"
        ok "  $p added"
        GRUB_CHANGED=1
    fi
done

if (( GRUB_CHANGED )); then
    log "Regenerating GRUB config..."
    sudo update-grub
    ok "GRUB updated"
else
    ok "GRUB already up to date"
fi
echo

# ---------- step 3: patch z13ctl-perms.service ----------
log "Step 3/5: Patching z13ctl-perms.service for missing asus-armoury driver..."

SVC="/etc/systemd/system/z13ctl-perms.service"
if [[ ! -f "$SVC" ]]; then
    warn "$SVC not found — skipping (z13ctl install may have failed)"
elif grep -qE "^ExecStart=/bin/sh" "$SVC"; then
    # Prefix every ExecStart=/bin/sh with '-' so systemd tolerates non-zero exits
    # (the firmware-attributes paths don't exist on Kali's kernel build)
    sudo sed -i 's|^ExecStart=/bin/sh|ExecStart=-/bin/sh|g' "$SVC"
    ok "Added '-' prefix to ExecStart lines"
    sudo systemctl daemon-reload
    sudo systemctl restart z13ctl-perms.service || true
    if systemctl is-active --quiet z13ctl-perms.service; then
        ok "z13ctl-perms.service: active"
    else
        warn "z13ctl-perms.service still not active — run 'systemctl status z13ctl-perms.service'"
    fi
else
    ok "z13ctl-perms.service already patched"
fi
echo

# ---------- step 4: group membership ----------
log "Step 4/5: Ensuring user '$TARGET_USER' is in 'users' group..."

if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx users; then
    ok "$TARGET_USER already in 'users'"
    GROUP_ADDED=0
else
    sudo usermod -aG users "$TARGET_USER"
    warn "$TARGET_USER added to 'users' — log out and back in (or reboot) for it to take effect"
    GROUP_ADDED=1
fi
echo

# ---------- step 5: defaults ----------
log "Step 5/5: Applying sensible z13ctl defaults..."

if (( GROUP_ADDED )); then
    warn "Group membership not yet active in this session — skipping. Run after reboot:"
    echo "    z13ctl batterylimit --set 80"
    echo "    z13ctl profile --set balanced"
elif command -v z13ctl >/dev/null 2>&1; then
    z13ctl batterylimit --set 80 || warn "batterylimit failed (try after reboot)"
    z13ctl profile --set balanced || warn "profile set failed (try after reboot)"
    ok "Battery limit: 80%, Profile: balanced"
else
    warn "z13ctl not on PATH — re-run defaults manually after reboot"
fi
echo

# ---------- summary ----------
cat <<EOF
${G}┌──────────────────────────────────────────────────────────┐
│              GZ302 Kali Setup Complete                   │
└──────────────────────────────────────────────────────────┘${N}

  ✓ Hardware fixes (GPU, audio, input, OLED PSR-SU, suspend hook)
  ✓ z13ctl installed (RGB, TDP, fan curves, battery limit)
  ✓ Display tools + KDE Plasma tray app
  ✓ GRUB extra suspend-reliability parameters
  ✓ z13ctl-perms.service patched
  ✓ User '$TARGET_USER' in 'users' group
  ✓ Defaults: battery 80%, profile balanced

${Y}REBOOT REQUIRED${N} for kernel params and group membership to take effect:

    sudo reboot

After reboot, smoke test:

    cat /proc/cmdline                   # verify kernel params
    systemctl status z13ctl-perms.service  # should be active (exited)
    z13ctl status                       # current state
    systemctl suspend                   # then wake & check:
    journalctl -b -t gz302-reset        # confirm suspend hook ran

The "GZ302 Dashboard" tray icon should appear in your KDE Plasma panel
automatically on next login.
EOF
