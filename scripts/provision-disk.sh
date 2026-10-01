#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/provision-disk.sh /dev/disk/by-id/<target-disk>

What it does:
  - Wipes target disk
  - Creates GPT with:
      1) EFI System Partition (1 GiB, FAT32, unencrypted)
      2) LUKS2 partition (rest of disk)
  - Creates LVM inside LUKS with STIG-oriented split mounts:
      /, /home, /var, /var/log, /var/log/audit, /tmp, /var/tmp, swap
  - Formats and mounts everything under /mnt
  - Runs nixos-generate-config --root /mnt

Notes:
  - This is destructive.
  - Partition sizes are defaults and can be edited in this script.
EOF
}

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: run as root." >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

DISK_INPUT="$1"
DISK="$(readlink -f -- "$DISK_INPUT")"

if [[ ! -b "$DISK" ]]; then
  echo "ERROR: not a block device: $DISK_INPUT" >&2
  exit 1
fi

if [[ "$(lsblk -dn -o TYPE "$DISK")" != "disk" ]]; then
  echo "ERROR: target must be a whole disk, not a partition: $DISK" >&2
  exit 1
fi

if findmnt -rn -S "$DISK" >/dev/null; then
  echo "ERROR: target disk has mounted filesystems. Unmount first: $DISK" >&2
  exit 1
fi

if [[ "$DISK" =~ ^/dev/nvme[0-9]+n[0-9]+$ || "$DISK" =~ ^/dev/mmcblk[0-9]+$ ]]; then
  PARTP="${DISK}p"
else
  PARTP="${DISK}"
fi

EFI_PART="${PARTP}1"
LUKS_PART="${PARTP}2"
CRYPT_NAME="cryptroot"
VG_NAME="vg0"

# Default LV sizes (adjust as needed for your environment)
LV_ROOT="32G"
LV_HOME="16G"
LV_VAR="16G"
LV_VAR_LOG="8G"
LV_VAR_LOG_AUDIT="4G"
LV_TMP="8G"
LV_VAR_TMP="8G"
LV_SWAP="8G"

echo "================================================================"
echo "DANGER: THIS WILL ERASE ALL DATA ON: $DISK"
echo "================================================================"
lsblk "$DISK"
echo
read -r -p "Type EXACT disk path to continue: " confirm_path
if [[ "$confirm_path" != "$DISK" ]]; then
  echo "Aborted: confirmation did not match."
  exit 1
fi
read -r -p "Type YES to permanently destroy data on $DISK: " confirm_yes
if [[ "$confirm_yes" != "YES" ]]; then
  echo "Aborted."
  exit 1
fi

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
cryptsetup close "$CRYPT_NAME" 2>/dev/null || true
vgchange -an "$VG_NAME" 2>/dev/null || true

wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
partprobe "$DISK"
udevadm settle

sgdisk \
  --new=1:1MiB:+1GiB --typecode=1:ef00 --change-name=1:EFI \
  --new=2:0:0 --typecode=2:8309 --change-name=2:CRYPTLVM \
  "$DISK"
partprobe "$DISK"
udevadm settle

mkfs.fat -F 32 -n EFI "$EFI_PART"
cryptsetup luksFormat --type luks2 --batch-mode "$LUKS_PART"
cryptsetup open "$LUKS_PART" "$CRYPT_NAME"

pvcreate "/dev/mapper/$CRYPT_NAME"
vgcreate "$VG_NAME" "/dev/mapper/$CRYPT_NAME"

lvcreate -L "$LV_ROOT" -n root "$VG_NAME"
lvcreate -L "$LV_HOME" -n home "$VG_NAME"
lvcreate -L "$LV_VAR" -n var "$VG_NAME"
lvcreate -L "$LV_VAR_LOG" -n var_log "$VG_NAME"
lvcreate -L "$LV_VAR_LOG_AUDIT" -n var_log_audit "$VG_NAME"
lvcreate -L "$LV_TMP" -n tmp "$VG_NAME"
lvcreate -L "$LV_VAR_TMP" -n var_tmp "$VG_NAME"
lvcreate -L "$LV_SWAP" -n swap "$VG_NAME"

mkfs.ext4 -L nixos-root "/dev/$VG_NAME/root"
mkfs.ext4 -L nixos-home "/dev/$VG_NAME/home"
mkfs.ext4 -L nixos-var "/dev/$VG_NAME/var"
mkfs.ext4 -L nixos-var-log "/dev/$VG_NAME/var_log"
mkfs.ext4 -L nixos-var-log-audit "/dev/$VG_NAME/var_log_audit"
mkfs.ext4 -L nixos-tmp "/dev/$VG_NAME/tmp"
mkfs.ext4 -L nixos-var-tmp "/dev/$VG_NAME/var_tmp"
mkswap -L nixos-swap "/dev/$VG_NAME/swap"

mount "/dev/$VG_NAME/root" /mnt
mkdir -p /mnt/{boot,home,var,tmp}
mount "$EFI_PART" /mnt/boot
mount "/dev/$VG_NAME/home" /mnt/home
mount "/dev/$VG_NAME/var" /mnt/var
mkdir -p /mnt/var/{log,tmp} /mnt/var/log/audit
mount "/dev/$VG_NAME/var_log" /mnt/var/log
mount "/dev/$VG_NAME/var_log_audit" /mnt/var/log/audit
mount "/dev/$VG_NAME/tmp" /mnt/tmp
mount "/dev/$VG_NAME/var_tmp" /mnt/var/tmp
chmod 1777 /mnt/tmp /mnt/var/tmp
swapon "/dev/$VG_NAME/swap"

nixos-generate-config --root /mnt

cat <<EOF

Done.
Mounted new system at /mnt with encrypted LUKS2 + LVM layout.

Next:
  1) Edit /mnt/etc/nixos/configuration.nix to include your STIG modules.
  2) Confirm /mnt/etc/nixos/hardware-configuration.nix looks correct.
  3) Install:
       nixos-install --root /mnt
EOF
