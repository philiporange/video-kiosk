## Video Kiosk SD Card Builder

This project flashes a Raspberry Pi OS Lite image and prepares a kiosk that auto-plays videos with VLC. Configuration is driven by a `.env` file (see `env.example`).

### Prerequisites
- Run on a Linux host with `wget`, `xz`, `dd`, `partprobe`, `mount`, `mkdir`, `ln`, and `sync`.
- You must run the script as `root` (e.g. via `sudo`).
- `.env` must exist in the repo root (copy from `env.example` and edit).

### Key Settings
- `IMG_URL`, `WORK_DIR`, `ROOT_MOUNT`, `BOOT_MOUNT`, `CONFIRM_ERASE`
- Wi-Fi: `WIFI_ENABLE`, `WIFI_COUNTRY`, `WIFI_SSID`, `WIFI_PSK`
- SSH: `ENABLE_SSH`, `SUDO_USER`, `SSH_PUBLIC_KEY`

### What the script does
1. Downloads and decompresses the Pi OS Lite image.
2. Writes it to the target block device (wiping it).
3. Configures Wi-Fi (optional) and enables SSH (optional) on first boot.
4. Installs a kiosk first-boot script that:
   - Updates and upgrades packages, installs VLC.
   - Creates the configured sudo user, installs the provided SSH public key, and hardens sshd.
   - Marks setup complete and reboots.
   - On subsequent boots, loops all videos in `/videos` with `cvlc` fullscreen.

### Usage
```bash
sudo ./build_sd_card.sh /dev/sdX   # or /dev/mmcblk0
```
The script will prompt for confirmation unless `CONFIRM_ERASE=false`. After completion, insert the SD card into the Pi; first boot performs setup and reboots, subsequent boots run the video loop.
