#!/bin/bash
# 00-prepare-devmode.sh
#
# Run this FIRST, before install-touchpad-fix.sh, on a fresh FydeOS
# install. It checks Developer Mode is on, disables rootfs verification,
# and makes sure the stateful partition (where the fix's persistent
# files live) is writable.
#
# Developer Mode itself CANNOT be enabled by a script — it requires a
# GUI confirmation and a reboot/powerwash. This script tells you how,
# checks whether it's already on, and does the rest that CAN be
# scripted.

set -euo pipefail

log()  { echo "[prep] $*"; }
die()  { echo "[prep] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------
# 1. Check Developer Mode is enabled.
# ---------------------------------------------------------------------
# devsw_boot = 1 means dev mode is on. If crossystem isn't available at
# all, or reports something else, treat it as "not confirmed" and give
# the manual steps rather than guessing.
devmode_on=0
if command -v crossystem >/dev/null 2>&1; then
  if [ "$(crossystem devsw_boot 2>/dev/null || echo 0)" = "1" ]; then
    devmode_on=1
  fi
fi

if [ "$devmode_on" -ne 1 ]; then
  cat <<'EOF'
[prep] Developer Mode does not appear to be enabled.

This has to be done by hand — there is no command-line way to flip it on:

  1. Open FydeOS Settings.
  2. Go to "FydeOS Settings" (or "About/Advanced" depending on your
     build) -> "Enable Developer Mode".
  3. Confirm. The device will powerwash (erase local user data) and
     reboot into Developer Mode.
  4. After it reboots and you're back at the desktop, run this script
     again.

If you already see a black "OS verification is OFF" screen on boot and
have to press Ctrl+D or wait a few seconds every time you start the
machine, Developer Mode is already on and this check is a false
negative (some FydeOS builds don't expose crossystem the same way) —
in that case just continue; the next steps will confirm for real.
EOF
  read -r -p "[prep] Continue anyway? (y/N) " ans
  case "$ans" in
    y|Y) log "continuing despite unconfirmed dev mode state..." ;;
    *) exit 1 ;;
  esac
fi

# ---------------------------------------------------------------------
# 2. Root shell check.
# ---------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run this with 'sudo -i' first, then run this script as root.
Note: on FydeOS v17 / openFyde r114+, 'sudo su' no longer works — use 'sudo -i'."

# ---------------------------------------------------------------------
# 3. Disable rootfs verification (FydeOS's own supported mechanism).
#    This affects the FydeOS host OS's own rootfs, separate from
#    anything inside the dual-boot .img. It's needed for some FydeOS
#    customizations in general; the touchpad fix script itself only
#    writes to the ESP and FYDEOS-DUAL-BOOT partitions, which don't
#    strictly require this — but it's harmless and worth doing once so
#    later customization doesn't hit the same wall.
# ---------------------------------------------------------------------
if [ -x /usr/sbin/crossystem_mode-switch.sh ]; then
  log "disabling rootfs verification..."
  /usr/sbin/crossystem_mode-switch.sh disable-rootfs-verification || \
    log "disable-rootfs-verification returned non-zero — it may already be disabled, continuing."
else
  log "crossystem_mode-switch.sh not found at the expected path — skipping (may not be needed on this build)."
fi

# ---------------------------------------------------------------------
# 4. Confirm the stateful partition (where our persistent files live)
#    is writable. This is where install-touchpad-fix.sh stores the
#    downloaded acpi_override.img and backups, and is independent of
#    the rootfs-verification state above.
# ---------------------------------------------------------------------
mkdir -p /mnt/stateful_partition/unencrypted/acpi-fix
if touch /mnt/stateful_partition/unencrypted/acpi-fix/.write-test 2>/dev/null; then
  rm -f /mnt/stateful_partition/unencrypted/acpi-fix/.write-test
  log "stateful partition is writable, good."
else
  die "stateful partition is not writable. This is unusual — check 'mount | grep stateful' manually."
fi

log "done."
log "If you just ran the disable-rootfs-verification step for the first time, reboot now:"
log "  sudo reboot"
log "Then run install-touchpad-fix.sh."
