#!/usr/bin/env bash
# g1_pc2_usb_wifi_ap_setup.sh
# Configure a USB Wi-Fi adapter as a local AP while leaving PC2's existing
# network uplink alone. Intended for MediaTek MT7612U adapters such as
# 0e8d:7612 on Unitree G1 PC2.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

AP_SSID=""
AP_CONN="g1-pc2-usb-ap"
AP_ADDR="10.42.0.1/24"
AP_BAND="a"
AP_CHANNEL="36"
IFACE=""
USB_VID="0e8d"
USB_PID="7612"
HELPER_PATH="/usr/local/sbin/g1-pc2-usb-wifi-ap-up.sh"
SERVICE_PATH="/etc/systemd/system/g1-pc2-usb-wifi-ap.service"
SKIP_APT=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./g1_pc2_usb_wifi_ap_setup.sh --ap-ssid SSID [options]

What it does:
  - Finds the USB Wi-Fi adapter by VID:PID, default 0e8d:7612 for MT7612U.
  - Verifies the adapter advertises AP mode through nl80211/cfg80211.
  - Creates a NetworkManager AP profile on 10.42.0.1/24.
  - Uses NetworkManager ipv4.method=shared so AP clients get DHCP and NAT via
    PC2's existing default route, normally the built-in Wi-Fi uplink.
  - Installs a boot-time service that brings the AP back after reboot.

Options:
  --ap-ssid SSID              AP network name to broadcast. Required.
  --ap-password PASSWORD      AP WPA2 password. If omitted, prompts securely.
  --iface IFACE               Use this Wi-Fi interface instead of VID:PID autodetect.
  --usb-vid HEX               USB vendor ID. Default: 0e8d.
  --usb-pid HEX               USB product ID. Default: 7612.
  --address CIDR              AP IPv4 address/subnet. Default: 10.42.0.1/24.
  --band bg|a                 bg = 2.4 GHz, a = 5 GHz. Default: a.
  --channel CHANNEL           AP channel. Default: 36.
  --connection-name NAME      NetworkManager profile name. Default: g1-pc2-usb-ap.
  --skip-apt                  Do not install/check apt packages.
  -h, --help                  Show this help.

Examples:
  sudo ./g1_pc2_usb_wifi_ap_setup.sh --ap-ssid "g1-pc2"
  sudo ./g1_pc2_usb_wifi_ap_setup.sh --ap-ssid "g1-pc2" --band a --channel 36

Notes:
  - Keep an existing built-in Wi-Fi connection active for PC2 internet access.
  - 5 GHz channel 36 is the default for teleop throughput. It requires the
    regulatory domain to allow AP operation on that channel.
USAGE
}

log()  { printf '[%s] %s\n' "$(date '+%F %T' 2>/dev/null || true)" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; printf "ERROR: %s failed near line %s, exit %s\n" "$SCRIPT_NAME" "$LINENO" "$rc" >&2; exit "$rc"' ERR

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "Missing value for $1"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

AP_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ap-ssid) need_value "$1" "${2:-}"; AP_SSID="$2"; shift 2 ;;
    --ap-password) need_value "$1" "${2:-}"; AP_PASSWORD="$2"; shift 2 ;;
    --iface) need_value "$1" "${2:-}"; IFACE="$2"; shift 2 ;;
    --usb-vid) need_value "$1" "${2:-}"; USB_VID="${2,,}"; shift 2 ;;
    --usb-pid) need_value "$1" "${2:-}"; USB_PID="${2,,}"; shift 2 ;;
    --address) need_value "$1" "${2:-}"; AP_ADDR="$2"; shift 2 ;;
    --band) need_value "$1" "${2:-}"; AP_BAND="$2"; shift 2 ;;
    --channel) need_value "$1" "${2:-}"; AP_CHANNEL="$2"; shift 2 ;;
    --connection-name) need_value "$1" "${2:-}"; AP_CONN="$2"; shift 2 ;;
    --skip-apt) SKIP_APT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

[[ -n "$AP_SSID" ]] || die "--ap-ssid is required"
[[ "$AP_BAND" == "bg" || "$AP_BAND" == "a" ]] || die "--band must be bg or a"

require_cmds() {
  local missing=0 cmd
  for cmd in nmcli iw ip rfkill systemctl awk grep sed readlink; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing command: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Install missing commands first, then rerun."
}

install_packages() {
  [[ "$SKIP_APT" -eq 0 ]] || return 0
  log "Installing required packages."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y network-manager iw dnsmasq-base rfkill
}

prompt_secret() {
  if [[ -n "$AP_PASSWORD" ]]; then
    [[ "${#AP_PASSWORD}" -ge 8 ]] || die "--ap-password must be at least 8 characters."
    return 0
  fi

  while true; do
    read -r -s -p "AP password for '$AP_SSID' (min 8 chars): " AP_PASSWORD
    printf '\n'
    [[ "${#AP_PASSWORD}" -ge 8 ]] && break
    warn "AP password must be at least 8 characters."
  done
}

ensure_networkmanager() {
  systemctl enable NetworkManager.service >/dev/null 2>&1 || true
  systemctl start NetworkManager.service
  nmcli general status >/dev/null 2>&1 || die "nmcli cannot talk to NetworkManager."
}

iface_usb_vid_pid() {
  local iface="$1" devpath vid pid
  devpath="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
  while [[ -n "$devpath" && "$devpath" != "/" ]]; do
    if [[ -r "$devpath/idVendor" && -r "$devpath/idProduct" ]]; then
      vid="$(tr '[:upper:]' '[:lower:]' < "$devpath/idVendor")"
      pid="$(tr '[:upper:]' '[:lower:]' < "$devpath/idProduct")"
      printf '%s:%s\n' "$vid" "$pid"
      return 0
    fi
    devpath="${devpath%/*}"
  done
  return 1
}

detect_usb_wifi_iface() {
  local candidate ids

  if [[ -n "$IFACE" ]]; then
    [[ -d "/sys/class/net/$IFACE" ]] || die "Interface not found: $IFACE"
    return 0
  fi

  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    ids="$(iface_usb_vid_pid "$candidate" || true)"
    if [[ "$ids" == "$USB_VID:$USB_PID" ]]; then
      IFACE="$candidate"
      return 0
    fi
  done < <(iw dev 2>/dev/null | awk '$1 == "Interface" {print $2}')

  die "Could not find a Wi-Fi interface backed by USB device $USB_VID:$USB_PID."
}

check_ap_support() {
  local phy info
  phy="$(iw dev "$IFACE" info | awk '/wiphy/ {print "phy"$2; exit}')"
  [[ -n "$phy" ]] || die "Could not determine wireless phy for $IFACE."

  info="$(iw phy "$phy" info)"
  grep -qE '^\s+\* AP$' <<<"$info" || die "$phy/$IFACE does not advertise AP mode."
}

prepare_radio() {
  rfkill unblock wlan || rfkill unblock wifi || rfkill unblock all || true
  nmcli radio wifi on || true
  ip link set "$IFACE" up || true
  nmcli device set "$IFACE" managed yes || true
}

connection_exists() {
  nmcli -t -f NAME connection show "$1" >/dev/null 2>&1
}

configure_ap() {
  if connection_exists "$AP_CONN"; then
    log "Updating AP connection: $AP_CONN"
  else
    log "Creating AP connection: $AP_CONN"
    nmcli connection add type wifi ifname "$IFACE" con-name "$AP_CONN" ssid "$AP_SSID"
  fi

  nmcli connection modify "$AP_CONN" \
    connection.interface-name "$IFACE" \
    connection.autoconnect yes \
    connection.autoconnect-priority 20 \
    802-11-wireless.ssid "$AP_SSID" \
    802-11-wireless.mode ap \
    802-11-wireless.band "$AP_BAND" \
    802-11-wireless.channel "$AP_CHANNEL" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$AP_PASSWORD" \
    ipv4.method shared \
    ipv4.addresses "$AP_ADDR" \
    ipv4.never-default yes \
    ipv6.method ignore
}

activate_ap() {
  log "Starting AP '$AP_SSID' on $IFACE."
  nmcli --wait 60 connection up "$AP_CONN" ifname "$IFACE"
}

install_boot_helper() {
  log "Installing boot helper: $HELPER_PATH"
  cat > "$HELPER_PATH" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
IFACE="$IFACE"
AP_CONN="$AP_CONN"

rfkill unblock wlan || rfkill unblock wifi || rfkill unblock all || true
nmcli radio wifi on || true
ip link set "\$IFACE" up || true
nmcli device set "\$IFACE" managed yes || true
nmcli --wait 60 connection up "\$AP_CONN" ifname "\$IFACE" || true
EOF
  chmod 755 "$HELPER_PATH"
}

install_boot_service() {
  log "Installing boot service: $SERVICE_PATH"
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Unitree G1 PC2 USB Wi-Fi AP restore
After=NetworkManager.service systemd-rfkill.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=$HELPER_PATH
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable g1-pc2-usb-wifi-ap.service >/dev/null
}

show_summary() {
  log "AP interface: $IFACE"
  log "AP connection: $AP_CONN"
  log "AP SSH address: ${AP_ADDR%/*}"
  log "Active default route:"
  ip route show default || true
  log "Check status with: nmcli device status && nmcli connection show --active"
}

main() {
  prompt_secret
  install_packages
  require_cmds
  ensure_networkmanager
  detect_usb_wifi_iface
  check_ap_support
  prepare_radio
  configure_ap
  activate_ap
  install_boot_helper
  install_boot_service
  show_summary
}

main "$@"
