#!/bin/bash
# install-touchpad-fix.sh
#
# Installs the ELAN0642/SYNA2392 touchpad ACPI override fix on a FydeOS
# dual-boot install (Lenovo 300w Gen 3). Downloads the pre-built
# acpi_override.img, places it on the FYDEOS-DUAL-BOOT partition, and
# patches the real EFI/fydeos/grub.cfg to load it alongside
# dual_boot_ramfs.cpio.
#
# Safe to re-run: it detects whether the grub.cfg entries are already
# patched and skips them if so (useful after a FydeOS update wipes the
# edit).
#
# Run as root (sudo) from a FydeOS shell (crosh -> shell -> sudo su).

set -euo pipefail

OVERRIDE_URL="https://github.com/afyijcd/Fixing-the-Touchpad-on-FydeOS-Dual-Boot-Lenovo-300w-Gen-3-/raw/refs/heads/main/acpi_override.img"
PERSIST_DIR="/mnt/stateful_partition/unencrypted/acpi-fix"
OVERRIDE_LOCAL="${PERSIST_DIR}/acpi_override.img"

log()  { echo "[touchpad-fix] $*"; }
die()  { echo "[touchpad-fix] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must be run as root (sudo)."

mkdir -p "$PERSIST_DIR"

# ---------------------------------------------------------------------
# 1. Download the override archive (idempotent: skip if already present
#    and looks valid).
# ---------------------------------------------------------------------
need_download=1
if [ -f "$OVERRIDE_LOCAL" ]; then
  magic=$(head -c 6 "$OVERRIDE_LOCAL" 2>/dev/null || true)
  if [ "$magic" = "070701" ]; then
    log "acpi_override.img already present and looks valid, skipping download."
    need_download=0
  else
    log "existing acpi_override.img looks invalid, re-downloading."
  fi
fi

if [ "$need_download" -eq 1 ]; then
  fetch_bin=""
  if command -v curl >/dev/null 2>&1; then
    fetch_bin="curl"
  elif command -v wget >/dev/null 2>&1; then
    fetch_bin="wget"
  else
    die "neither curl nor wget is available; cannot download acpi_override.img."
  fi

  log "downloading acpi_override.img..."
  if [ "$fetch_bin" = "curl" ]; then
    curl -fL --retry 3 -o "${OVERRIDE_LOCAL}.tmp" "$OVERRIDE_URL"
  else
    wget -q --tries=3 -O "${OVERRIDE_LOCAL}.tmp" "$OVERRIDE_URL"
  fi

  magic=$(head -c 6 "${OVERRIDE_LOCAL}.tmp" 2>/dev/null || true)
  [ "$magic" = "070701" ] || die "downloaded file does not look like a valid newc cpio archive (bad magic)."

  mv "${OVERRIDE_LOCAL}.tmp" "$OVERRIDE_LOCAL"
  log "downloaded and verified acpi_override.img ($(stat -c%s "$OVERRIDE_LOCAL") bytes)."
fi

# ---------------------------------------------------------------------
# 2. Find the physical disk, the real EFI System Partition, and the
#    FYDEOS-DUAL-BOOT partition.
# ---------------------------------------------------------------------
log "locating physical disk..."
disk=""
for candidate in /dev/nvme0n1 /dev/sda /dev/mmcblk0; do
  if [ -b "$candidate" ] && cgpt show "$candidate" >/dev/null 2>&1; then
    disk="$candidate"
    break
  fi
done
[ -n "$disk" ] || die "could not auto-detect the physical disk. Edit this script and set 'disk' manually."
log "using disk: $disk"

part_num_for_label() {
  # Prints the partition number matching a given GPT label on $disk.
  # cgpt show lines look like:
  #   2048     4677632       1  Label: "EFI system partition"
  # i.e. the partition number ($3) and the Label: text are on the SAME
  # line, so we just string-match the quoted label and print field 3.
  cgpt show "$disk" | awk -v label="$1" '
    $0 ~ ("Label: \"" label "\"") { print $3; exit }
  '
}

esp_part=$(part_num_for_label "EFI system partition")
[ -n "$esp_part" ] || esp_part=$(part_num_for_label "EFI System Partition")
[ -n "$esp_part" ] || esp_part=$(part_num_for_label "EFI-SYSTEM")
[ -n "$esp_part" ] || die "could not find the EFI system partition via cgpt. Check 'cgpt show $disk' manually."

dualboot_part=$(part_num_for_label "FYDEOS-DUAL-BOOT")
[ -n "$dualboot_part" ] || die "could not find the FYDEOS-DUAL-BOOT partition via cgpt. Check 'cgpt show $disk' manually."

# nvme devices need a 'p' before the partition number, sd/mmc do not
if [[ "$disk" == *nvme* ]] || [[ "$disk" == *mmcblk* ]]; then
  esp_dev="${disk}p${esp_part}"
  dualboot_dev="${disk}p${dualboot_part}"
else
  esp_dev="${disk}${esp_part}"
  dualboot_dev="${disk}${dualboot_part}"
fi

log "real ESP: $esp_dev   FYDEOS-DUAL-BOOT: $dualboot_dev"

esp_mnt="${PERSIST_DIR}/realesp"
db_mnt="${PERSIST_DIR}/dualboot"
mkdir -p "$esp_mnt" "$db_mnt"

cleanup() {
  umount "$esp_mnt" 2>/dev/null || true
  umount "$db_mnt" 2>/dev/null || true
}
trap cleanup EXIT

mount_rw_or_die() {
  local dev="$1" mnt="$2"
  if mountpoint -q "$mnt"; then
    return 0
  fi
  if ! mount "$dev" "$mnt" 2>/tmp/mount_err.$$; then
    cat /tmp/mount_err.$$ >&2
    rm -f /tmp/mount_err.$$
    die "failed to mount $dev. Have you run 00-prepare-devmode.sh and enabled Developer Mode first?"
  fi
  rm -f /tmp/mount_err.$$
  if ! touch "${mnt}/.write-test" 2>/dev/null; then
    umount "$mnt" 2>/dev/null || true
    die "$dev mounted but is read-only. Run 00-prepare-devmode.sh first (Developer Mode + disable rootfs verification), reboot, then re-run this script."
  fi
  rm -f "${mnt}/.write-test"
}

mount_rw_or_die "$esp_dev" "$esp_mnt"
mount_rw_or_die "$dualboot_dev" "$db_mnt"

grub_cfg="${esp_mnt}/EFI/fydeos/grub.cfg"
[ -f "$grub_cfg" ] || die "grub.cfg not found at expected path: $grub_cfg"

[ -d "${db_mnt}/boot" ] || die "boot/ folder not found on FYDEOS-DUAL-BOOT partition."

# ---------------------------------------------------------------------
# 3. Copy the override into the dual-boot partition's boot/ folder.
# ---------------------------------------------------------------------
cp "$OVERRIDE_LOCAL" "${db_mnt}/boot/acpi_override.img"
log "copied acpi_override.img to ${dualboot_dev}:/boot/"

# ---------------------------------------------------------------------
# 4. Patch grub.cfg (idempotently) to load the override before
#    dual_boot_ramfs.cpio, for both the A and B slots.
# ---------------------------------------------------------------------
if grep -q 'acpi_override\.img' "$grub_cfg"; then
  log "grub.cfg already references acpi_override.img, leaving it untouched."
else
  backup="${grub_cfg}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$grub_cfg" "$backup"
  log "backed up grub.cfg to $backup"

  # Insert the override ahead of dual_boot_ramfs.cpio on every matching
  # initrd line (covers both the "A" and "B" boot entries).
  sed -i \
    's#initrd (\$dualboot_part)/boot/dual_boot_ramfs\.cpio#initrd ($dualboot_part)/boot/acpi_override.img ($dualboot_part)/boot/dual_boot_ramfs.cpio#g' \
    "$grub_cfg"

  if grep -q 'acpi_override\.img' "$grub_cfg"; then
    log "patched grub.cfg successfully."
  else
    cp "$backup" "$grub_cfg"
    die "failed to patch grub.cfg (pattern not found); restored from backup. Check grub.cfg format manually."
  fi
fi

sync
log "done. Reboot for the fix to take effect."
log "after reboot, verify with:"
log "  sudo dmesg | grep -i '^\\[.*ACPI: DSDT'"
log "  (look for OEM revision 00001001 instead of 00001000)"
