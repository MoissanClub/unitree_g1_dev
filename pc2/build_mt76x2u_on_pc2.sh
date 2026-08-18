#!/usr/bin/env bash
# build_mt76x2u_on_pc2.sh
# Build and install the MT7612U/MT76x2U USB Wi-Fi modules for the running
# Jetson/Ubuntu kernel when NVIDIA's kernel config ships them disabled.

set -Eeuo pipefail

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

log() { printf '[%s] %s\n' "$(date '+%F %T' 2>/dev/null || true)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./build_mt76x2u_on_pc2.sh [--source-dir DIR] [--jobs N]

DIR must be the NVIDIA L4T kernel source tree matching the running kernel.
By default, the script uses the source location created by the PC2 build notes:
  ~/pc2/mt76-build/source/kernel/kernel-jammy-src
EOF
}

KERNEL="$(uname -r)"
HEADER_DIR="$(readlink -f "/lib/modules/$KERNEL/build")"
OWNER="${SUDO_USER:-root}"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
SOURCE_DIR="${MT76_SOURCE_DIR:-$OWNER_HOME/pc2/mt76-build/source/kernel/kernel-jammy-src}"
JOBS="$(nproc)"
MT76_DIR="drivers/net/wireless/mediatek/mt76"
INSTALL_DIR="/lib/modules/$KERNEL/updates/mt76"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir) [[ $# -ge 2 ]] || die "Missing value for $1"; SOURCE_DIR="$2"; shift 2 ;;
    --jobs) [[ $# -ge 2 ]] || die "Missing value for $1"; JOBS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[[ -d "$SOURCE_DIR/$MT76_DIR" ]] || die "MT76 source not found under $SOURCE_DIR/$MT76_DIR"
[[ -r "$HEADER_DIR/.config" ]] || die "Running kernel config missing under $HEADER_DIR"
[[ -r "$HEADER_DIR/Module.symvers" ]] || die "Module.symvers missing under $HEADER_DIR"

SOURCE_VERSION="$(make -s -C "$SOURCE_DIR" kernelversion)"
[[ "$KERNEL" == "$SOURCE_VERSION"* ]] || \
  die "Source version $SOURCE_VERSION does not match running kernel $KERNEL"
LOCALVERSION="${KERNEL#"$SOURCE_VERSION"}"

log "Preparing NVIDIA source for kernel $KERNEL"
install -m 0644 "$HEADER_DIR/.config" "$SOURCE_DIR/.config"
install -m 0644 "$HEADER_DIR/Module.symvers" "$SOURCE_DIR/Module.symvers"

CONFIG_FRAGMENT="$(mktemp)"
trap 'rm -f "$CONFIG_FRAGMENT"' EXIT
cat > "$CONFIG_FRAGMENT" <<'EOF'
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_MT76_CORE=m
CONFIG_MT76_LEDS=y
CONFIG_MT76_USB=m
CONFIG_MT76x02_LIB=m
CONFIG_MT76x02_USB=m
CONFIG_MT76x2_COMMON=m
CONFIG_MT76x2U=m
EOF
(
  cd "$SOURCE_DIR"
  ./scripts/kconfig/merge_config.sh -m .config "$CONFIG_FRAGMENT"
)
make -C "$SOURCE_DIR" -j"$JOBS" LOCALVERSION="$LOCALVERSION" olddefconfig prepare modules_prepare

BUILT_RELEASE="$(make -s -C "$SOURCE_DIR" LOCALVERSION="$LOCALVERSION" kernelrelease)"
[[ "$BUILT_RELEASE" == "$KERNEL" ]] || \
  die "Prepared source targets $BUILT_RELEASE, not running kernel $KERNEL"

log "Building MT76 USB modules for kernel $KERNEL"
make -C "$SOURCE_DIR" -j"$JOBS" LOCALVERSION="$LOCALVERSION" M="$MT76_DIR" \
  CONFIG_MT76_CORE=m \
  CONFIG_MT76_USB=m \
  CONFIG_MT76x02_LIB=m \
  CONFIG_MT76x02_USB=m \
  CONFIG_MT76x2_COMMON=m \
  CONFIG_MT76x2U=m \
  modules

log "Installing modules into $INSTALL_DIR"
install -d "$INSTALL_DIR"
install -m 0644 \
  "$SOURCE_DIR/$MT76_DIR/mt76.ko" \
  "$SOURCE_DIR/$MT76_DIR/mt76-usb.ko" \
  "$SOURCE_DIR/$MT76_DIR/mt76x02-lib.ko" \
  "$SOURCE_DIR/$MT76_DIR/mt76x02-usb.ko" \
  "$SOURCE_DIR/$MT76_DIR/mt76x2/mt76x2-common.ko" \
  "$SOURCE_DIR/$MT76_DIR/mt76x2/mt76x2u.ko" \
  "$INSTALL_DIR/"

depmod "$KERNEL"

log "Loading mt76x2u"
modprobe mt76x2u

log "Driver status"
modinfo mt76x2u | sed -n '1,20p'
lsusb -t
iw dev || true
