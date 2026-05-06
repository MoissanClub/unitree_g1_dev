#!/usr/bin/env bash
# Fix BrainCo / Unitree G1 FTDI serial-port permissions.
#
# Your discovered mapping:
#   left hand  = FTDI if02 = /dev/serial/by-id/...if02-port0 = usually /dev/ttyUSB2
#   right hand = FTDI if01 = /dev/serial/by-id/...if01-port0 = usually /dev/ttyUSB1
#
# Usage:
#   ./g1_fix_serial_permissions.sh
#   ./g1_fix_serial_permissions.sh --permanent
#
# Default behavior:
#   Grants read/write access to the left/right hand ports for this boot.
#
# --permanent behavior:
#   Adds the current user to the dialout group and installs a udev rule for this FTDI device.
#   You still need to log out/in or reboot once for the dialout group to take effect.

set -Eeuo pipefail

FTDI_SERIAL="${FTDI_SERIAL:-FTA1LW3T}"

LEFT_PORT="${LEFT_PORT:-/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_${FTDI_SERIAL}-if02-port0}"
RIGHT_PORT="${RIGHT_PORT:-/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_${FTDI_SERIAL}-if01-port0}"

PERMANENT=0
if [[ "${1:-}" == "--permanent" ]]; then
  PERMANENT=1
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage:
  $0
  $0 --permanent

Environment overrides:
  FTDI_SERIAL=FTA1LW3T
  LEFT_PORT=/dev/serial/by-id/...
  RIGHT_PORT=/dev/serial/by-id/...
EOF
  exit 0
elif [[ -n "${1:-}" ]]; then
  echo "Unknown option: $1" >&2
  echo "Use --help for usage." >&2
  exit 2
fi

log() { printf '[g1-serial] %s\n' "$*"; }
die() { printf '[g1-serial] ERROR: %s\n' "$*" >&2; exit 1; }

resolve_port() {
  local p="$1"
  [[ -e "$p" ]] || die "Port does not exist: $p"
  readlink -f "$p"
}

fix_port() {
  local byid="$1"
  local target
  target="$(resolve_port "$byid")"

  log "Port: $byid -> $target"
  sudo chgrp dialout "$target" || true
  sudo chmod 0666 "$target"

  local perms
  perms="$(ls -l "$target")"
  log "Now:  $perms"
}

install_permanent_rule() {
  local user_name="${SUDO_USER:-$USER}"
  local rule_file="/etc/udev/rules.d/99-brainco-ftdi.rules"

  log "Adding user '$user_name' to dialout group..."
  sudo usermod -aG dialout "$user_name"

  log "Installing udev rule: $rule_file"
  sudo tee "$rule_file" >/dev/null <<EOF
# BrainCo / Unitree G1 FTDI FT4232H serial ports.
# Device observed as idVendor=0403, idProduct=6011, serial=${FTDI_SERIAL}.
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6011", ATTRS{serial}=="${FTDI_SERIAL}", GROUP="dialout", MODE="0666"
EOF

  log "Reloading udev rules..."
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=tty || true

  log "Permanent setup done. Reboot or log out/in once so group membership refreshes."
}

log "Fixing BrainCo hand serial permissions for this boot..."
fix_port "$LEFT_PORT"
fix_port "$RIGHT_PORT"

if [[ "$PERMANENT" -eq 1 ]]; then
  install_permanent_rule
fi

log "Done."
log "Test with:"
log "  python ~/brainco-hand-sdk/python/demo/hand_monitor.py -m \"$LEFT_PORT\" 460800 126 touch --duration 30"
log "  python ~/brainco-hand-sdk/python/demo/hand_monitor.py -m \"$RIGHT_PORT\" 460800 127 touch --duration 30"
