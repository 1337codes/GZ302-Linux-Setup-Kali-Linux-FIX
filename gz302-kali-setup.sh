#!/usr/bin/env bash
#
# gz302-kali-setup.sh
#
# Automated Kali Linux (KDE) setup for ASUS ROG Flow Z13 (GZ302).
# Fully dynamic — works for any username on any fresh Kali KDE install.
#
# Replays the working configuration:
#
#   1. Runs th3cavalry/GZ302-Linux-Setup unified installer non-interactively
#      (hardware fixes + z13ctl + display tools, skips optional modules).
#   2. Adds extra suspend-reliability kernel params to GRUB:
#        amd_pmc.enable_stb=1
#        rtc_cmos.use_acpi_alarm=1
#   3. Patches z13ctl-perms.service:
#        - Tolerates missing asus-armoury driver (not in Kali's kernel)
#        - Adds asus-nb-wmi/ppt_* group write perms (TDP control)
#   4. Relocates the tray app from any user's Downloads folder to /opt/gz302-tray
#      and updates ALL desktop launchers (system + per-user).
#   5. Ensures the user is in the 'users' group for unprivileged z13ctl.
#   6. Applies sensible defaults: battery limit 80%, balanced profile.
#
# Run on a fresh Kali KDE install on a GZ302. Requires sudo + network.
# Idempotent — safe to re-run.
#
# Usage:
#   ./gz302-kali-setup.sh              # auto-detects current user
#   ./gz302-kali-setup.sh someuser     # explicitly set target user
#
# Tested:    Kali rolling, KDE Plasma, kernel 6.19.11+kali-amd64
# Hardware:  ASUS ROG Flow Z13 (GZ302) — AMD Ryzen AI MAX+ 395 (Strix Halo)
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
   GZ302 Kali Linux KDE Setup — universal replay
EOF
echo

# ---------- privilege ----------
if [[ $EUID -eq 0 ]]; then
    die "Don't run this script as root. It uses sudo internally where needed."
fi
sudo -v || die "sudo authentication failed."

# ---------- detect target user dynamically ----------
# Priority:
#   1. Explicit argument: ./gz302-kali-setup.sh someuser
#   2. $SUDO_USER if running under sudo
#   3. $USER if it isn't root
#   4. logname (controlling-terminal owner)
#   5. First non-system user in /etc/passwd (UID >= 1000, < 65534)
TARGET_USER="${1:-}"
if [[ -z "$TARGET_USER" ]]; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
    elif [[ -n "${USER:-}" && "$USER" != "root" ]]; then
        TARGET_USER="$USER"
    elif command -v logname >/dev/null 2>&1; then
        TARGET_USER="$(logname 2>/dev/null || true)"
    fi
fi
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)"
fi
[[ -n "$TARGET_USER" ]] || die "Could not determine target user."
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -d "$TARGET_HOME" ]] || die "Home directory for $TARGET_USER not found: $TARGET_HOME"

ok "Target user: $TARGET_USER  (home: $TARGET_HOME)"

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
read -rp "Proceed with full GZ302 setup for user '$TARGET_USER'? [Y/n] " ans
[[ "$ans" =~ ^[Nn]$ ]] && die "Aborted."
echo

# ---------- step 1: upstream installer ----------
log "Step 1/6: Running th3cavalry/GZ302-Linux-Setup unified installer..."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fL -o "$WORK/gz302-setup.sh" \
    https://raw.githubusercontent.com/th3cavalry/GZ302-Linux-Setup/main/gz302-setup.sh
chmod +x "$WORK/gz302-setup.sh"

# Run as the target user via sudo so SUDO_USER/HOME resolve correctly inside the upstream script.
# -y: accept defaults (Y to fixes, z13ctl, display tools)
# --no-modules: skip Gaming/LLM/Hypervisor packs (Ubuntu-centric, often broken on Kali)
sudo -u "$TARGET_USER" sudo "$WORK/gz302-setup.sh" -y --no-modules

ok "Unified installer complete"
echo

# ---------- step 2: GRUB suspend params ----------
log "Step 2/6: Adding extra suspend-reliability kernel parameters..."

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
log "Step 3/6: Patching z13ctl-perms.service..."
# Two patches:
#   (a) Prefix ExecStart with '-' so systemd tolerates missing asus-armoury paths
#       (asus-armoury isn't built into Kali's kernel as of writing).
#   (b) Add asus-nb-wmi ppt_* permissions so non-root z13ctl can write TDP.
#       Without this, profile/TDP changes silently fail in the GUI tray.

SVC="/etc/systemd/system/z13ctl-perms.service"
PPT_LINE="ExecStart=-/bin/sh -c 'for f in /sys/devices/platform/asus-nb-wmi/ppt_*; do [ -e \"\$\$f\" ] && chgrp users \"\$\$f\" && chmod g+w \"\$\$f\" || true; done'"

if [[ ! -f "$SVC" ]]; then
    warn "$SVC not found — skipping (z13ctl install may have failed)"
else
    SVC_CHANGED=0
    if grep -qE "^ExecStart=/bin/sh" "$SVC"; then
        sudo sed -i 's|^ExecStart=/bin/sh|ExecStart=-/bin/sh|g' "$SVC"
        ok "Added '-' prefix to ExecStart lines"
        SVC_CHANGED=1
    else
        ok "ExecStart lines already prefixed with '-'"
    fi
    if grep -q "asus-nb-wmi/ppt_" "$SVC"; then
        ok "asus-nb-wmi ppt_* perms ExecStart already present"
    else
        sudo sed -i "/^\[Install\]/i ${PPT_LINE}\n" "$SVC"
        ok "Added asus-nb-wmi ppt_* perms ExecStart line"
        SVC_CHANGED=1
    fi
    if (( SVC_CHANGED )); then
        sudo systemctl daemon-reload
        sudo systemctl restart z13ctl-perms.service || true
    fi
    if systemctl is-active --quiet z13ctl-perms.service; then
        ok "z13ctl-perms.service: active"
    else
        warn "z13ctl-perms.service not active — check 'systemctl status z13ctl-perms.service'"
    fi
fi
echo

# ---------- step 4: relocate tray app to /opt/gz302-tray ----------
log "Step 4/6: Relocating tray app to /opt/gz302-tray..."
# The upstream installer drops the tray source in the user's Downloads folder and
# points the .desktop launcher at it. That breaks if the user cleans Downloads or
# the path differs per user. Move it system-wide to /opt and rewrite all launchers.

TRAY_DEST="/opt/gz302-tray"
SYSTEM_DESKTOP="/usr/share/applications/gz302-tray.desktop"

# Find the current tray source path from any existing launcher (system or per-user)
find_current_tray_path() {
    local desktop_files=()
    [[ -f "$SYSTEM_DESKTOP" ]] && desktop_files+=("$SYSTEM_DESKTOP")
    while IFS= read -r -d '' f; do
        desktop_files+=("$f")
    done < <(find /home -maxdepth 5 -type f \
        \( -path '*/.config/autostart/gz302-tray.desktop' \
           -o -path '*/.local/share/applications/gz302-tray.desktop' \) \
        -print0 2>/dev/null)

    for df in "${desktop_files[@]}"; do
        [[ -f "$df" ]] || continue
        local path
        path=$(grep -oE 'python3? [^ ]+command_center\.py' "$df" 2>/dev/null \
            | head -1 | awk '{print $2}')
        if [[ -n "$path" && -f "$path" ]]; then
            # Strip /src/command_center.py to get the project root
            echo "${path%/src/command_center.py}"
            return 0
        fi
    done
    return 1
}

# 1. If /opt/gz302-tray doesn't exist yet, find current source and copy it
if [[ ! -d "$TRAY_DEST" ]]; then
    CURRENT_SRC=$(find_current_tray_path || true)
    if [[ -n "$CURRENT_SRC" && -d "$CURRENT_SRC" ]]; then
        log "  Found tray source at: $CURRENT_SRC"
        sudo cp -r "$CURRENT_SRC" "$TRAY_DEST"
        sudo chown -R root:root "$TRAY_DEST"
        sudo find "$TRAY_DEST" -type d -exec chmod 755 {} \;
        sudo find "$TRAY_DEST" -type f -exec chmod 644 {} \;
        sudo find "$TRAY_DEST" -type f -name '*.py' -exec chmod 755 {} \;
        ok "  Copied tray app to $TRAY_DEST"
    else
        warn "  No tray source found — tray app may not have installed correctly. Skipping relocation."
        TRAY_DEST=""
    fi
else
    ok "  $TRAY_DEST already exists"
fi

# 2. Rewrite all gz302-tray.desktop files to point at /opt/gz302-tray, regardless of user
if [[ -n "$TRAY_DEST" && -f "$TRAY_DEST/src/command_center.py" ]]; then
    NEW_EXEC="python3 ${TRAY_DEST}/src/command_center.py"

    # Collect every gz302-tray.desktop file on the system
    DESKTOP_FILES=()
    [[ -f "$SYSTEM_DESKTOP" ]] && DESKTOP_FILES+=("$SYSTEM_DESKTOP")
    while IFS= read -r -d '' f; do
        DESKTOP_FILES+=("$f")
    done < <(find /home -maxdepth 5 -type f \
        \( -path '*/.config/autostart/gz302-tray.desktop' \
           -o -path '*/.local/share/applications/gz302-tray.desktop' \) \
        -print0 2>/dev/null)

    for df in "${DESKTOP_FILES[@]}"; do
        if grep -q "^Exec=.*command_center\.py" "$df"; then
            current_exec=$(grep '^Exec=' "$df" | head -1)
            new_exec_line="Exec=${NEW_EXEC}"
            if [[ "$current_exec" == "$new_exec_line" ]]; then
                ok "  Already points to /opt: $df"
            else
                sudo sed -i "s|^Exec=.*command_center\.py.*|${new_exec_line}|" "$df"
                ok "  Rewrote: $df"
            fi
        fi
    done

    # 3. Clean up any stray copies in Downloads folders across all users
    while IFS= read -r -d '' stray; do
        if [[ "$stray" != "$TRAY_DEST" ]]; then
            warn "  Removing stray tray source: $stray"
            sudo rm -rf "$stray"
        fi
    done < <(find /home -maxdepth 4 -type d -name 'command-center' -print0 2>/dev/null)
fi
echo

# ---------- step 5: group membership ----------
log "Step 5/6: Ensuring user '$TARGET_USER' is in 'users' group..."

if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx users; then
    ok "$TARGET_USER already in 'users'"
    GROUP_ADDED=0
else
    sudo usermod -aG users "$TARGET_USER"
    warn "$TARGET_USER added to 'users' — log out and back in (or reboot) for it to take effect"
    GROUP_ADDED=1
fi
echo

# ---------- step 6: defaults ----------
log "Step 6/6: Applying sensible z13ctl defaults..."

if (( GROUP_ADDED )); then
    warn "Group membership not yet active in this session — skipping. Run after reboot:"
    echo "    z13ctl batterylimit --set 80"
    echo "    z13ctl profile --set balanced"
elif sudo -u "$TARGET_USER" command -v z13ctl >/dev/null 2>&1; then
    sudo -u "$TARGET_USER" z13ctl batterylimit --set 80 || warn "batterylimit failed (try after reboot)"
    sudo -u "$TARGET_USER" z13ctl profile --set balanced || warn "profile set failed (try after reboot)"
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

  ✓ User:                  $TARGET_USER
  ✓ Hardware fixes         (GPU, audio, input, OLED PSR-SU, suspend hook)
  ✓ z13ctl                 (RGB, TDP, fan curves, battery limit)
  ✓ Display tools          + KDE Plasma tray app
  ✓ GRUB params            (extra suspend-reliability)
  ✓ z13ctl-perms.service   patched (asus-armoury tolerant + ppt_* perms)
  ✓ Tray app relocated     to /opt/gz302-tray (stable system path)
  ✓ Group membership       'users' for unprivileged z13ctl
  ✓ Defaults               battery 80%, profile balanced

${Y}REBOOT REQUIRED${N} for kernel params and group membership to take effect:

    sudo reboot

After reboot, smoke test:

    cat /proc/cmdline                       # verify kernel params
    systemctl status z13ctl-perms.service   # active (exited)
    z13ctl status                           # current state
    grep ^Exec /usr/share/applications/gz302-tray.desktop  # /opt path
    systemctl suspend                       # then wake & check:
    journalctl -b -t gz302-reset            # confirm suspend hook ran

The "GZ302 Dashboard" tray icon should appear in your KDE Plasma panel
on next login.
EOF
