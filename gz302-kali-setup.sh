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
#        rtc_cmos.use_acpi_alarm=1
#      NOTE: amd_pmc.enable_stb=1 is intentionally NOT added — it causes the
#      amd_pmc driver to fail probe with -ENOMEM on Strix Halo (Smart Trace
#      Buffer alloc fails). The suspend hook works fine without it.
#   3. Patches z13ctl-perms.service:
#        - Tolerates missing asus-armoury driver (not in Kali's kernel)
#        - Adds asus-nb-wmi/ppt_* group write perms (TDP control)
#   4. Relocates the tray app from any user's Downloads folder to /opt/gz302-tray
#      and updates ALL desktop launchers (system + per-user). Re-syncs /opt
#      from a fresher Downloads source when one is detected.
#   5. Installs two resume-time hooks in /usr/lib/systemd/system-sleep/:
#        aaa-gz302-input-fast.sh — re-authorizes keyboard/touchpad/lightbar
#          USB devices at the START of post-resume so the lock screen is
#          responsive within ~1s of wake (instead of ~11s).
#        gz302-bluetooth.sh — resets HCI and restarts bluetoothd on
#          resume so BT mice/devices reconnect cleanly (MT7925 fix).
#      Also cleans up any stray .patch/.bak files in the system-sleep
#      directory left over from older versions.
#   6. Ensures the user is in the 'users' group for unprivileged z13ctl.
#   7. Applies sensible defaults: battery limit 80%, balanced profile.
#   8. Installs Z13 RGB Control GUI (PyQt6 app) to /opt/z13-rgb-control/
#      if z13rgb.py and z13rgb.desktop are present alongside this script.
#   8. Installs Z13 RGB Control GUI (PyQt6 app for keyboard + lightbar RGB).
#      Looks for sibling 'z13_rgb_control.py' next to this script. If found,
#      installs to /opt/z13-rgb-control/ with a KDE menu launcher.
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

# ---------- result tracking (for accurate final summary) ----------
DEFAULTS_APPLIED=0
TRAY_RELOCATED=0
GROUP_ADDED=0
SVC_PATCHED=0
GRUB_CHANGED=0
BT_HOOK_INSTALLED=0
RGB_GUI_INSTALLED=0
RGB_GUI_INSTALLED=0

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

# Keep sudo creds fresh in the background while the script runs
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ---------- detect target user dynamically ----------
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
log "Step 1/8: Running th3cavalry/GZ302-Linux-Setup unified installer..."

WORK=$(mktemp -d)
# Cleanup trap accounts for files that the upstream installer chowns to root
cleanup() {
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    sudo rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

curl -fL -o "$WORK/gz302-setup.sh" \
    https://raw.githubusercontent.com/th3cavalry/GZ302-Linux-Setup/main/gz302-setup.sh
chmod +x "$WORK/gz302-setup.sh"

# Just sudo — SUDO_USER is preserved automatically and points at TARGET_USER.
# -y: accept defaults
# --no-modules: skip Gaming/LLM/Hypervisor packs (Ubuntu-centric, often broken on Kali)
sudo "$WORK/gz302-setup.sh" -y --no-modules

ok "Unified installer complete"
echo

# ---------- step 2: GRUB suspend params ----------
log "Step 2/8: Adding extra suspend-reliability kernel parameters..."

GRUB_FILE="/etc/default/grub"
EXTRA_PARAMS=("rtc_cmos.use_acpi_alarm=1")
# Params we actively REMOVE if found (known-bad on Strix Halo)
BAD_PARAMS=("amd_pmc.enable_stb=1")

if ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
    warn "  GRUB_CMDLINE_LINUX_DEFAULT line not found in $GRUB_FILE"
    warn "  Please add the following params manually then run 'sudo update-grub':"
    for p in "${EXTRA_PARAMS[@]}"; do echo "      $p"; done
else
    # Remove any known-bad params that might be present from older runs
    for bp in "${BAD_PARAMS[@]}"; do
        if grep -q "$bp" "$GRUB_FILE"; then
            # Escape regex metacharacters in the param for sed
            esc=$(printf '%s' "$bp" | sed 's/[][\.\*\^\$\/]/\\&/g')
            sudo sed -i "s/ ${esc}//g; s/${esc} //g; s/${esc}//g" "$GRUB_FILE"
            warn "  Removed known-bad param: $bp"
            GRUB_CHANGED=1
        fi
    done

    for p in "${EXTRA_PARAMS[@]}"; do
        if grep -q "$p" "$GRUB_FILE"; then
            ok "  $p already present"
        else
            sudo sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\")(.*)(\")|\1\2 ${p}\3|" "$GRUB_FILE"
            # Verify the param was actually inserted
            if grep -q "$p" "$GRUB_FILE"; then
                ok "  $p added"
                GRUB_CHANGED=1
            else
                warn "  Failed to insert $p (regex didn't match) — add manually"
            fi
        fi
    done

    if (( GRUB_CHANGED )); then
        log "Regenerating GRUB config..."
        sudo update-grub
        ok "GRUB updated"
    else
        ok "GRUB already up to date"
    fi
fi
echo

# ---------- step 3: patch z13ctl-perms.service ----------
log "Step 3/8: Patching z13ctl-perms.service..."

SVC="/etc/systemd/system/z13ctl-perms.service"
PPT_LINE="ExecStart=-/bin/sh -c 'for f in /sys/devices/platform/asus-nb-wmi/ppt_*; do [ -e \"\$\$f\" ] && chgrp users \"\$\$f\" && chmod g+w \"\$\$f\" || true; done'"

if [[ ! -f "$SVC" ]]; then
    warn "$SVC not found — skipping (z13ctl install may have failed)"
else
    SVC_LOCAL_CHANGED=0
    if grep -qE "^ExecStart=/bin/sh" "$SVC"; then
        sudo sed -i 's|^ExecStart=/bin/sh|ExecStart=-/bin/sh|g' "$SVC"
        ok "Added '-' prefix to ExecStart lines"
        SVC_LOCAL_CHANGED=1
    else
        ok "ExecStart lines already prefixed with '-'"
    fi
    if grep -q "asus-nb-wmi/ppt_" "$SVC"; then
        ok "asus-nb-wmi ppt_* perms ExecStart already present"
    else
        sudo sed -i "/^\[Install\]/i ${PPT_LINE}\n" "$SVC"
        # Verify the line was inserted
        if grep -q "asus-nb-wmi/ppt_" "$SVC"; then
            ok "Added asus-nb-wmi ppt_* perms ExecStart line"
            SVC_LOCAL_CHANGED=1
        else
            warn "Failed to insert ppt_* ExecStart line — add manually with 'systemctl edit --full z13ctl-perms.service'"
        fi
    fi
    if (( SVC_LOCAL_CHANGED )); then
        sudo systemctl daemon-reload
        sudo systemctl restart z13ctl-perms.service || true
        SVC_PATCHED=1
    fi
    if systemctl is-active --quiet z13ctl-perms.service; then
        ok "z13ctl-perms.service: active"
    else
        warn "z13ctl-perms.service not active — check 'systemctl status z13ctl-perms.service'"
    fi
fi
echo

# ---------- step 4: relocate tray app to /opt/gz302-tray ----------
log "Step 4/8: Relocating tray app to /opt/gz302-tray..."

TRAY_DEST="/opt/gz302-tray"
SYSTEM_DESKTOP="/usr/share/applications/gz302-tray.desktop"

# Find tray source path from any existing launcher (system or per-user)
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
            echo "${path%/src/command_center.py}"
            return 0
        fi
    done
    return 1
}

# Always sync /opt with the latest Downloads source if one exists
CURRENT_SRC=$(find_current_tray_path || true)

if [[ -n "$CURRENT_SRC" && -d "$CURRENT_SRC" && "$CURRENT_SRC" != "$TRAY_DEST" ]]; then
    log "  Found tray source at: $CURRENT_SRC"
    if [[ -d "$TRAY_DEST" ]]; then
        log "  Refreshing existing $TRAY_DEST..."
        sudo rm -rf "$TRAY_DEST"
    fi
    sudo cp -r "$CURRENT_SRC" "$TRAY_DEST"
    sudo chown -R root:root "$TRAY_DEST"
    sudo find "$TRAY_DEST" -type d -exec chmod 755 {} \;
    sudo find "$TRAY_DEST" -type f -exec chmod 644 {} \;
    sudo find "$TRAY_DEST" -type f -name '*.py' -exec chmod 755 {} \;
    ok "  Synced tray app to $TRAY_DEST"
    TRAY_RELOCATED=1
elif [[ -d "$TRAY_DEST" && -f "$TRAY_DEST/src/command_center.py" ]]; then
    ok "  $TRAY_DEST already current"
    TRAY_RELOCATED=1
else
    warn "  No tray source found — tray app may not have installed correctly. Skipping."
    TRAY_DEST=""
fi

# Rewrite all gz302-tray.desktop files to point at /opt
if [[ -n "$TRAY_DEST" && -f "$TRAY_DEST/src/command_center.py" ]]; then
    NEW_EXEC="python3 ${TRAY_DEST}/src/command_center.py"

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
                # Verify
                if grep -q "^${new_exec_line}\$" "$df"; then
                    ok "  Rewrote: $df"
                else
                    warn "  Failed to rewrite $df"
                fi
            fi
        fi
    done

    # Clean up stray copies — but only directories that really contain the tray app
    while IFS= read -r -d '' stray; do
        if [[ "$stray" != "$TRAY_DEST" && -f "$stray/src/command_center.py" ]]; then
            warn "  Removing stray tray source: $stray"
            sudo rm -rf "$stray"
        fi
    done < <(find /home -maxdepth 4 -type d -name 'command-center' -print0 2>/dev/null)
fi
echo

# ---------- step 5: bluetooth resume hook + input-fast hook ----------
log "Step 5/8: Installing resume-time hooks (Bluetooth + input-fast)..."
# Two sibling hooks installed alongside the upstream gz302-reset.sh.
# systemd-sleep runs hooks alphabetically, so naming matters:
#   aaa-gz302-input-fast.sh  (runs first — re-authorizes USB input ASAP)
#   gz302-bluetooth.sh       (resets BT stack on resume)
#   gz302-reset.sh           (upstream, untouched)
#
# Without aaa-gz302-input-fast.sh, the lock screen on resume is
# unresponsive for ~11s while the upstream hook does housekeeping.
# With it, the keyboard/touchpad/lightbar are re-authorized within ~1s.

BT_HOOK="/usr/lib/systemd/system-sleep/gz302-bluetooth.sh"
INPUT_HOOK="/usr/lib/systemd/system-sleep/aaa-gz302-input-fast.sh"

# Bluetooth hook
sudo tee "$BT_HOOK" >/dev/null <<'INNER'
#!/bin/sh
# Restart Bluetooth stack on resume to fix BT mouse / device reconnect issues
# on Strix Halo (MT7925) after suspend or hibernation.
case "$1/$2" in
    post/suspend|post/hibernate|post/hybrid-sleep|post/suspend-then-hibernate)
        # Wait for kernel to bring HCI back up
        sleep 2
        # Reset HCI controller (clears stale ACL connections)
        if command -v hciconfig >/dev/null 2>&1; then
            hciconfig hci0 reset 2>/dev/null || true
        elif command -v btmgmt >/dev/null 2>&1; then
            btmgmt power off 2>/dev/null || true
            sleep 1
            btmgmt power on 2>/dev/null || true
        fi
        # Restart daemon — auto-reconnects trusted devices
        systemctl restart bluetooth.service 2>/dev/null || true
        logger -t gz302-bt "Bluetooth stack reset after $2"
        ;;
esac
exit 0
INNER
sudo chmod +x "$BT_HOOK"
[[ -x "$BT_HOOK" ]] && ok "  Bluetooth resume hook: $BT_HOOK"

# Input-fast hook — re-authorizes ASUS keyboard/touchpad/lightbar USB
# devices at the very start of post-resume. Filename starts with 'aaa-'
# so systemd-sleep sorts it before the slow upstream hook.
sudo tee "$INPUT_HOOK" >/dev/null <<'INNER'
#!/bin/sh
# GZ302 input-fast hook — runs BEFORE gz302-reset.sh on resume.
#
# Re-authorizes the ASUS USB devices (keyboard / touchpad / lightbar)
# at the very start of post-resume so the lock screen becomes responsive
# within ~1s of wake instead of ~11s.
#
# The upstream gz302-reset.sh still runs after this and re-does the
# same USB reset; that's fine and idempotent. We just front-run it.
#
# Filename starts with 'aaa-' so systemd-sleep sorts it first.

case "$1" in
    post)
        for dev in /sys/bus/usb/devices/*; do
            [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ] || continue
            vid=$(cat "$dev/idVendor" 2>/dev/null)
            pid=$(cat "$dev/idProduct" 2>/dev/null)
            [ "$vid" = "0b05" ] || continue
            case "$pid" in
                1a30|18c6)
                    # Toggle authorize — fastest possible re-enumeration
                    echo 0 > "$dev/authorized" 2>/dev/null || true
                    echo 1 > "$dev/authorized" 2>/dev/null || true
                    logger -t gz302-input-fast "Re-authorized USB device $(basename "$dev") (pid=$pid)"
                    ;;
            esac
        done
        ;;
esac
exit 0
INNER
sudo chmod +x "$INPUT_HOOK"
[[ -x "$INPUT_HOOK" ]] && ok "  Input-fast resume hook: $INPUT_HOOK"

# Clean up stray patcher files from older script versions if any exist —
# systemd-sleep runs everything executable in this directory, so leftover
# .patch / .bak files cause harmless but noisy errors at every suspend.
for stray in /usr/lib/systemd/system-sleep/gz302-reset.sh.patch \
             /usr/lib/systemd/system-sleep/gz302-reset.sh.bak; do
    if [[ -e "$stray" ]]; then
        sudo rm -f "$stray"
        warn "  Removed stray file from system-sleep/: $stray"
    fi
done

if [[ -x "$BT_HOOK" && -x "$INPUT_HOOK" ]]; then
    BT_HOOK_INSTALLED=1
fi
echo

# ---------- step 6: group membership ----------
log "Step 6/8: Ensuring user '$TARGET_USER' is in 'users' group..."

if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx users; then
    ok "$TARGET_USER already in 'users'"
else
    sudo usermod -aG users "$TARGET_USER"
    warn "$TARGET_USER added to 'users' — log out and back in (or reboot) for it to take effect"
    GROUP_ADDED=1
fi
echo

# ---------- step 7: defaults ----------
log "Step 7/8: Applying sensible z13ctl defaults..."

# Find z13ctl binary directly (more robust than relying on PATH propagation)
Z13CTL=""
for cand in /usr/local/bin/z13ctl /usr/bin/z13ctl /usr/sbin/z13ctl; do
    [[ -x "$cand" ]] && Z13CTL="$cand" && break
done
if [[ -z "$Z13CTL" ]]; then
    Z13CTL=$(sudo -u "$TARGET_USER" -i bash -c 'command -v z13ctl' 2>/dev/null || true)
fi

if (( GROUP_ADDED )); then
    warn "Group membership not yet active in this session — skipping defaults."
    warn "After reboot, run as $TARGET_USER:"
    echo "    z13ctl batterylimit --set 80"
    echo "    z13ctl profile --set balanced"
elif [[ -n "$Z13CTL" && -x "$Z13CTL" ]]; then
    if sudo -u "$TARGET_USER" "$Z13CTL" batterylimit --set 80 \
       && sudo -u "$TARGET_USER" "$Z13CTL" profile --set balanced; then
        ok "Battery limit: 80%, Profile: balanced"
        DEFAULTS_APPLIED=1
    else
        warn "Some defaults failed to apply — try after reboot"
    fi
else
    warn "z13ctl binary not found — skipping defaults. Re-run after reboot."
fi
echo

# ---------- step 8: install Z13 RGB Control GUI ----------
log "Step 8/8: Installing Z13 RGB Control GUI..."
# Looks for sibling z13rgb.py and z13rgb.desktop next to this script.
# If found, installs to /opt/z13-rgb-control/ and creates a KDE menu launcher.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RGB_SRC="${SCRIPT_DIR}/z13rgb.py"
RGB_DESKTOP_SRC="${SCRIPT_DIR}/z13rgb.desktop"
RGB_DEST_DIR="/opt/z13-rgb-control"
RGB_DEST="${RGB_DEST_DIR}/z13rgb.py"
RGB_DESKTOP="/usr/share/applications/z13rgb.desktop"

if [[ ! -f "$RGB_SRC" ]]; then
    warn "z13rgb.py not found next to this script — skipping RGB GUI."
    warn "  Place z13rgb.py and z13rgb.desktop in the same directory and re-run."
else
    # Ensure PyQt6 is installed (usually already from the tray app step)
    if ! python3 -c 'import PyQt6.QtWidgets' 2>/dev/null; then
        log "  Installing PyQt6..."
        sudo apt-get install -y python3-pyqt6 python3-pyqt6.qtsvg \
            >/dev/null 2>&1 || warn "  PyQt6 install failed — GUI may not run"
    fi

    sudo mkdir -p "$RGB_DEST_DIR"
    sudo cp "$RGB_SRC" "$RGB_DEST"
    sudo chmod 755 "$RGB_DEST"
    sudo chown root:root "$RGB_DEST"
    ok "  Installed $RGB_DEST"

    # Install the .desktop launcher: prefer the sibling file if present,
    # otherwise generate a minimal one inline.
    if [[ -f "$RGB_DESKTOP_SRC" ]]; then
        sudo cp "$RGB_DESKTOP_SRC" "$RGB_DESKTOP"
    else
        sudo tee "$RGB_DESKTOP" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Z13 RGB Control
Comment=Keyboard and lightbar RGB control for ASUS ROG Flow Z13
Exec=python3 ${RGB_DEST}
Icon=preferences-desktop-color
Terminal=false
Categories=Settings;HardwareSettings;
Keywords=RGB;keyboard;lightbar;ASUS;ROG;Z13;lighting;
StartupNotify=true
StartupWMClass=z13rgb
EOF
    fi
    sudo chmod 644 "$RGB_DESKTOP"
    ok "  Installed launcher: $RGB_DESKTOP"

    # Drop a desktop shortcut for the target user (KDE Plasma reads ~/Desktop)
    USER_DESKTOP_DIR="${TARGET_HOME}/Desktop"
    USER_SHORTCUT="${USER_DESKTOP_DIR}/z13rgb.desktop"
    if [[ -d "$USER_DESKTOP_DIR" ]]; then
        sudo cp "$RGB_DESKTOP" "$USER_SHORTCUT"
        sudo chown "$TARGET_USER:$TARGET_USER" "$USER_SHORTCUT"
        sudo chmod 755 "$USER_SHORTCUT"
        # KDE/Plasma needs the file marked as trusted ("KDE Trusted") to
        # launch without a confirmation dialog. Sets metadata via gio if
        # available, falls back to the legacy KDE attribute.
        if command -v gio >/dev/null 2>&1; then
            sudo -u "$TARGET_USER" gio set "$USER_SHORTCUT" \
                "metadata::trusted" true 2>/dev/null || true
        fi
        # Also set executable bit (Plasma checks this)
        ok "  Desktop shortcut: $USER_SHORTCUT"
    else
        warn "  ${USER_DESKTOP_DIR} not found — skipping desktop shortcut"
    fi

    # Refresh KDE menu cache (best effort)
    if command -v update-desktop-database >/dev/null 2>&1; then
        sudo update-desktop-database -q 2>/dev/null || true
    fi

    RGB_GUI_INSTALLED=1
fi
echo
{
    echo "${G}┌──────────────────────────────────────────────────────────┐"
    echo "│              GZ302 Kali Setup Complete                   │"
    echo "└──────────────────────────────────────────────────────────┘${N}"
    echo
    printf "  %-28s %s\n" "User:"                    "$TARGET_USER"
    printf "  %-28s %s\n" "Hardware fixes:"          "applied (GPU/audio/input/OLED/suspend)"
    printf "  %-28s %s\n" "z13ctl + display tools:"  "installed"
    printf "  %-28s %s\n" "GRUB suspend params:"     "$([[ $GRUB_CHANGED -eq 1 ]] && echo "added (reboot needed)" || echo "already present")"
    printf "  %-28s %s\n" "z13ctl-perms.service:"    "$([[ $SVC_PATCHED -eq 1 ]] && echo "patched & restarted" || echo "already patched")"
    printf "  %-28s %s\n" "Tray app at /opt:"        "$([[ $TRAY_RELOCATED -eq 1 ]] && echo "yes" || echo "skipped (no source)")"
    printf "  %-28s %s\n" "Resume hooks (input+BT):" "$([[ $BT_HOOK_INSTALLED -eq 1 ]] && echo "installed" || echo "FAILED — install manually")"
    printf "  %-28s %s\n" "Z13 RGB Control GUI:"     "$([[ $RGB_GUI_INSTALLED -eq 1 ]] && echo "installed (KDE menu)" || echo "skipped (no .py file alongside)")"
    printf "  %-28s %s\n" "User in 'users' group:"   "$([[ $GROUP_ADDED -eq 1 ]] && echo "added (relogin needed)" || echo "yes")"
    printf "  %-28s %s\n" "Defaults (battery 80%, balanced):" "$([[ $DEFAULTS_APPLIED -eq 1 ]] && echo "applied" || echo "skipped (re-run after reboot)")"
    echo

    if (( GRUB_CHANGED )) || (( GROUP_ADDED )); then
        echo "${Y}REBOOT REQUIRED${N} for kernel params and/or group membership:"
        echo "    sudo reboot"
        echo
    fi

    echo "Smoke test after reboot:"
    echo "    cat /proc/cmdline                                    # kernel params"
    echo "    systemctl status z13ctl-perms.service                # active (exited)"
    echo "    z13ctl status                                        # current state"
    echo "    grep ^Exec /usr/share/applications/gz302-tray.desktop # /opt path"
    echo "    systemctl suspend                                    # then wake & check:"
    echo "    journalctl -b -t gz302-reset                         # confirm hook ran"
    echo "    journalctl -b -t gz302-bt                            # confirm BT hook ran"
    echo "    journalctl -b -t gz302-input-fast                    # confirm input-fast hook ran"
    echo
    echo "If a tray process is still running from the old path, restart it:"
    echo "    pkill -f command_center.py"
    echo "    nohup python3 /opt/gz302-tray/src/command_center.py >/dev/null 2>&1 &"
    echo "    disown"
    echo "(Or just log out + back in — autostart handles it.)"
}
