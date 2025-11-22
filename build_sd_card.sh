#!/usr/bin/env bash
# Raspberry Pi kiosk image builder: flashes the official Raspberry Pi OS Lite image,
# applies Wi-Fi/SSH/kiosk settings from .env, and installs a first-boot script that
# upgrades the system, provisions a sudo user with SSH keys, hardens sshd, and sets up VLC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===== LOAD .env =====
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$SCRIPT_DIR/.env"
    set +a
else
    echo "ERROR: .env file not found in $SCRIPT_DIR" >&2
    echo "       Copy env.example to .env and edit it." >&2
    exit 1
fi

# ===== CONFIG (from env, with defaults) =====
IMG_URL="${IMG_URL:-https://downloads.raspberrypi.org/raspios_lite_armhf_latest}"
WORK_DIR="${WORK_DIR:-/tmp/pi-kiosk-setup}"
IMG_XZ="$WORK_DIR/raspios.img.xz"
IMG_IMG="$WORK_DIR/raspios.img"

ROOT_MOUNT="${ROOT_MOUNT:-/mnt/rpi-root}"
BOOT_MOUNT="${BOOT_MOUNT:-/mnt/rpi-boot}"

WIFI_ENABLE="${WIFI_ENABLE:-false}"
WIFI_COUNTRY="${WIFI_COUNTRY:-GB}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PSK="${WIFI_PSK:-}"

ENABLE_SSH="${ENABLE_SSH:-false}"
SUDO_USER="${SUDO_USER:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
CONFIRM_ERASE="${CONFIRM_ERASE:-true}"

# ===== FUNCTIONS =====

error() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || error "Required command '$cmd' not found"
    done
}

detect_partitions() {
    local dev="$1"

    # If device ends in a digit (e.g. /dev/mmcblk0), partitions are /dev/mmcblk0p1, p2...
    if [[ "$dev" =~ [0-9]$ ]]; then
        BOOT_PART="${dev}p1"
        ROOT_PART="${dev}p2"
    else
        BOOT_PART="${dev}1"
        ROOT_PART="${dev}2"
    fi
}

unmount_if_mounted() {
    local mountpoint="$1"
    if mountpoint -q "$mountpoint"; then
        umount "$mountpoint"
    fi
}

cleanup() {
    set +e
    echo "[*] Cleaning up mounts..."
    unmount_if_mounted "$BOOT_MOUNT"
    unmount_if_mounted "$ROOT_MOUNT"
}
trap cleanup EXIT

# ===== MAIN =====

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo)."
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 /dev/sdX_or_/dev/mmcblk0" >&2
    error "Target device must be provided as the first argument."
fi

TARGET_DEV="$1"

if [[ ! -b "$TARGET_DEV" ]]; then
    error "Device '$TARGET_DEV' is not a block device."
fi

echo "[*] Target device: $TARGET_DEV"
echo "    *** WARNING *** This will ERASE ALL DATA on $TARGET_DEV"

if [[ "$CONFIRM_ERASE" == "true" || "$CONFIRM_ERASE" == "TRUE" ]]; then
    read -r -p "Type 'YES' to continue: " confirm
    if [[ "$confirm" != "YES" ]]; then
        error "Aborted by user."
    fi
else
    echo "[*] Skipping interactive erase confirmation because CONFIRM_ERASE=$CONFIRM_ERASE"
fi

require_cmd wget xz dd partprobe mount mkdir ln sync

echo "[*] Preparing work directory: $WORK_DIR"
mkdir -p "$WORK_DIR"

echo "[*] Downloading Raspberry Pi OS image..."
wget -O "$IMG_XZ" "$IMG_URL"

echo "[*] Decompressing image (this may take a while)..."
xz -dk "$IMG_XZ"   # leaves raspios.img and raspios.img.xz

if [[ ! -f "$IMG_IMG" ]]; then
    IMG_IMG_FOUND="$(ls "$WORK_DIR"/*.img 2>/dev/null | head -n1 || true)"
    [[ -n "$IMG_IMG_FOUND" ]] || error "Could not find decompressed .img file"
    IMG_IMG="$IMG_IMG_FOUND"
fi

echo "[*] Writing image to $TARGET_DEV using dd (this may take a while)..."
dd if="$IMG_IMG" of="$TARGET_DEV" bs=4M conv=fsync status=progress

echo "[*] Informing kernel of partition table changes..."
partprobe "$TARGET_DEV" || true
sleep 5

detect_partitions "$TARGET_DEV"
echo "[*] Detected partitions:"
echo "    Boot: $BOOT_PART"
echo "    Root: $ROOT_PART"

[[ -b "$BOOT_PART" ]] || error "Boot partition '$BOOT_PART' not found"
[[ -b "$ROOT_PART" ]] || error "Root partition '$ROOT_PART' not found"

echo "[*] Creating mount points..."
mkdir -p "$ROOT_MOUNT" "$BOOT_MOUNT"

echo "[*] Mounting root partition..."
mount "$ROOT_PART" "$ROOT_MOUNT"

echo "[*] Mounting boot partition..."
mount "$BOOT_PART" "$BOOT_MOUNT"

# ---- Optional Wi-Fi configuration (from .env) ----

if [[ "$WIFI_ENABLE" == "true" || "$WIFI_ENABLE" == "TRUE" ]]; then
    [[ -n "$WIFI_SSID" ]] || error "WIFI_ENABLE=true but WIFI_SSID is empty in .env"
    [[ -n "$WIFI_PSK" ]] || error "WIFI_ENABLE=true but WIFI_PSK is empty in .env"

    echo "[*] Writing Wi-Fi configuration to boot partition (wpa_supplicant.conf)..."
    cat > "$BOOT_MOUNT/wpa_supplicant.conf" <<EOF
country=$WIFI_COUNTRY
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PSK"
}
EOF
    sync
else
    echo "[*] Wi-Fi configuration disabled (WIFI_ENABLE=$WIFI_ENABLE)."
fi

# ---- Optional SSH enable ----

if [[ "$ENABLE_SSH" == "true" || "$ENABLE_SSH" == "TRUE" ]]; then
    [[ -n "$SUDO_USER" ]] || error "ENABLE_SSH=true but SUDO_USER is empty in .env"
    [[ -n "$SSH_PUBLIC_KEY" ]] || error "ENABLE_SSH=true but SSH_PUBLIC_KEY is empty in .env"
    echo "[*] Enabling SSH on first boot (creating ssh flag file)..."
    touch "$BOOT_MOUNT/ssh"
    sync
else
    echo "[*] SSH provisioning disabled (ENABLE_SSH=$ENABLE_SSH)."
fi

echo "[*] Writing kiosk first-boot configuration to /boot/kiosk_env..."
cat > "$BOOT_MOUNT/kiosk_env" <<EOF
ENABLE_SSH=${ENABLE_SSH@Q}
SUDO_USER=${SUDO_USER@Q}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY@Q}
EOF
sync

# ---- Customize filesystem on the Pi image ----

echo "[*] Creating /videos directory on Pi filesystem..."
mkdir -p "$ROOT_MOUNT/videos"

# Boot-time kiosk script on the Pi
KIOSK_SCRIPT_PATH="$ROOT_MOUNT/usr/local/sbin/kiosk-boot.sh"
echo "[*] Installing kiosk boot script at $KIOSK_SCRIPT_PATH"

mkdir -p "$(dirname "$KIOSK_SCRIPT_PATH")"

cat > "$KIOSK_SCRIPT_PATH" << 'EOF'
#!/bin/bash
set -euo pipefail

VIDEOS_DIR="/videos"
SETUP_FLAG="/boot/SETUP_DONE"
CONFIG_FILE="/boot/kiosk_env"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1091
    . "$CONFIG_FILE"
fi

ENABLE_SSH="${ENABLE_SSH:-false}"
SUDO_USER="${SUDO_USER:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"

mkdir -p "$VIDEOS_DIR"

configure_ssh_user() {
    if [[ -z "$SUDO_USER" ]]; then
        echo "[kiosk-boot] ERROR: SUDO_USER is empty; cannot configure SSH user."
        exit 1
    fi
    if [[ -z "$SSH_PUBLIC_KEY" ]]; then
        echo "[kiosk-boot] ERROR: SSH_PUBLIC_KEY is empty; cannot configure authorized_keys."
        exit 1
    fi

    if id "$SUDO_USER" >/dev/null 2>&1; then
        echo "[kiosk-boot] User $SUDO_USER already exists; ensuring sudo access and SSH key."
    else
        echo "[kiosk-boot] Creating sudo user '$SUDO_USER'..."
        adduser --disabled-password --gecos "" "$SUDO_USER"
    fi

    usermod -aG sudo "$SUDO_USER"

    SSH_DIR="/home/$SUDO_USER/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    printf '%s\n' "$SSH_PUBLIC_KEY" > "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    chown -R "$SUDO_USER":"$SUDO_USER" "$SSH_DIR"
}

harden_ssh() {
    echo "[kiosk-boot] Applying SSH hardening..."
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/010-kiosk-hardening.conf <<'CONF'
PasswordAuthentication no
PermitRootLogin no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
# Restrict SSH to the provisioned sudo user
AllowUsers __SUDO_USER__
CONF

    local sanitized_user="${SUDO_USER//\\/\\\\}"
    sanitized_user="${sanitized_user//\//\\/}"
    sanitized_user="${sanitized_user//&/\\&}"
    sed -i "s/__SUDO_USER__/$sanitized_user/g" /etc/ssh/sshd_config.d/010-kiosk-hardening.conf

    if systemctl list-unit-files | grep -q '^ssh\\.service'; then
        systemctl restart ssh || true
    elif systemctl list-unit-files | grep -q '^sshd\\.service'; then
        systemctl restart sshd || true
    fi
}

if [ ! -f "$SETUP_FLAG" ]; then
    echo "[kiosk-boot] First boot: updating system and installing VLC..."

    export DEBIAN_FRONTEND=noninteractive

    # Update and upgrade system
    apt-get update
    apt-get -y full-upgrade

    # Install VLC
    apt-get -y install vlc

    if [[ "$ENABLE_SSH" == "true" || "$ENABLE_SSH" == "TRUE" ]]; then
        echo "[kiosk-boot] SSH provisioning enabled; configuring user and server..."
        configure_ssh_user
        harden_ssh
    else
        echo "[kiosk-boot] SSH provisioning skipped (ENABLE_SSH=$ENABLE_SSH)."
    fi

    touch "$SETUP_FLAG"
    sync

    echo "[kiosk-boot] Setup complete, rebooting..."
    sleep 2
    reboot
    exit 0
fi

echo "[kiosk-boot] Setup already done. Starting VLC loop..."

if compgen -G "$VIDEOS_DIR/*" > /dev/null; then
    # Use cvlc (console VLC) to play all files in /videos in fullscreen, looped
    exec /usr/bin/cvlc --fullscreen --loop --no-video-title-show "$VIDEOS_DIR"/*
else
    echo "[kiosk-boot] No videos found in $VIDEOS_DIR"
    echo "[kiosk-boot] Waiting indefinitely. Add files to the /videos directory."
    sleep infinity
fi
EOF

chmod +x "$KIOSK_SCRIPT_PATH"

# Systemd service to call kiosk-boot.sh on every boot
KIOSK_SERVICE_PATH="$ROOT_MOUNT/etc/systemd/system/kiosk-boot.service"
echo "[*] Installing systemd service at $KIOSK_SERVICE_PATH"

mkdir -p "$ROOT_MOUNT/etc/systemd/system"

cat > "$KIOSK_SERVICE_PATH" << 'EOF'
[Unit]
Description=Raspberry Pi video kiosk setup and player
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/kiosk-boot.sh
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
echo "[*] Enabling kiosk-boot.service..."
mkdir -p "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants"
ln -sf ../kiosk-boot.service \
    "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants/kiosk-boot.service"

sync

echo "[*] All modifications done. Unmounting..."
umount "$BOOT_MOUNT"
umount "$ROOT_MOUNT"

echo "[*] SD card is ready."
echo "    - First boot: Pi will import Wi-Fi config (if provided), enable SSH (if requested),"
echo "      update, install VLC, set /boot/SETUP_DONE, then reboot."
echo "    - Subsequent boots: Pi will auto-run VLC fullscreen, looping all files in /videos."
