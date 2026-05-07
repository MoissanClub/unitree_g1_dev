#!/usr/bin/env bash
# g1_pc2_dual_wifi_setup.sh
# Configure Unitree G1 PC2 to use one Wi-Fi radio as both:
# - a client uplink to an existing Wi-Fi network
# - a local AP for direct SSH access

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
UPLINK_SSID=""
AP_SSID=""

UPLINK_CONN="g1-pc2-uplink"
AP_CONN="g1-pc2-ap"
AP_IFACE="g1ap0"
AP_ADDR="10.42.0.1/24"
HELPER_PATH="/usr/local/sbin/g1-pc2-dual-wifi-up.sh"
SERVICE_PATH="/etc/systemd/system/g1-pc2-dual-wifi.service"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./g1_pc2_dual_wifi_setup.sh --uplink-ssid SSID --ap-ssid SSID

What it does:
  - Installs NetworkManager, iw, dnsmasq-base, and rfkill.
  - Checks whether the active Wi-Fi chip/driver supports concurrent client + AP.
  - Connects PC2 to the uplink Wi-Fi network.
  - Creates a local AP on 10.42.0.1/24 for direct SSH access.
  - Installs a boot-time service to restore the AP interface and both connections.

Notes:
  - You will be prompted for the uplink Wi-Fi password. Leave it empty for an open network.
  - You will be prompted for the AP password. It must be at least 8 characters.
  - Most single-radio chips require the AP to share the uplink's channel.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

log()  { printf '[%s] %s\n' "$(date '+%F %T' 2>/dev/null || true)" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; printf "ERROR: %s failed near line %s, exit %s\n" "$SCRIPT_NAME" "$LINENO" "$rc" >&2; exit "$rc"' ERR

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "Missing value for $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uplink-ssid) need_value "$1" "${2:-}"; UPLINK_SSID="$2"; shift 2 ;;
    --ap-ssid) need_value "$1" "${2:-}"; AP_SSID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

[[ -n "$UPLINK_SSID" ]] || die "--uplink-ssid is required"
[[ -n "$AP_SSID" ]] || die "--ap-ssid is required"

UPLINK_PASSWORD=""
AP_PASSWORD=""
WIFI_IFACE=""
PHY_NAME=""

require_cmds() {
  local missing=0 cmd
  for cmd in apt-get nmcli iw ip rfkill systemctl awk grep sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing command: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Install missing commands first, then rerun."
}

prompt_secrets() {
  read -r -s -p "Uplink Wi-Fi password for '$UPLINK_SSID' (leave empty if open): " UPLINK_PASSWORD
  printf '\n'

  while true; do
    read -r -s -p "AP password for '$AP_SSID' (min 8 chars): " AP_PASSWORD
    printf '\n'
    [[ "${#AP_PASSWORD}" -ge 8 ]] && break
    warn "AP password must be at least 8 characters."
  done
}

install_packages() {
  log "Installing required packages."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y network-manager iw dnsmasq-base rfkill
}

ensure_networkmanager() {
  systemctl enable NetworkManager.service >/dev/null 2>&1 || true
  systemctl start NetworkManager.service
  nmcli general status >/dev/null 2>&1 || die "nmcli cannot talk to NetworkManager."
}

detect_wifi_iface() {
  WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi" && $1 != "" {print $1; exit}')"
  [[ -n "$WIFI_IFACE" ]] || WIFI_IFACE="$(iw dev 2>/dev/null | awk '$1 == "Interface" {print $2; exit}')"
  [[ -n "$WIFI_IFACE" ]] || die "Could not find a Wi-Fi interface."
  PHY_NAME="$(iw dev "$WIFI_IFACE" info | awk '/wiphy/ {print "phy"$2; exit}')"
  [[ -n "$PHY_NAME" ]] || die "Could not determine the Wi-Fi phy for $WIFI_IFACE."
}

check_concurrent_support() {
  local info combos
  info="$(iw phy "$PHY_NAME" info)"
  grep -qE '^\s+\* AP$' <<<"$info" || die "$PHY_NAME does not advertise AP mode."
  grep -qE '^\s+\* managed$' <<<"$info" || die "$PHY_NAME does not advertise managed/client mode."

  combos="$(awk '/valid interface combinations:/,/Supported commands:/' <<<"$info" || true)"
  if ! grep -qi 'managed' <<<"$combos" || ! grep -wq 'AP' <<<"$combos"; then
    die "$PHY_NAME does not advertise a concurrent managed+AP interface combination."
  fi
}

prepare_radio() {
  rfkill unblock wlan || rfkill unblock wifi || rfkill unblock all || true
  nmcli radio wifi on || true
  ip link set "$WIFI_IFACE" up || true
}

ensure_ap_iface() {
  if ip link show "$AP_IFACE" >/dev/null 2>&1; then
    return 0
  fi

  log "Creating AP virtual interface $AP_IFACE on $PHY_NAME."
  iw dev "$WIFI_IFACE" interface add "$AP_IFACE" type __ap
  ip link set "$AP_IFACE" up
  nmcli device set "$AP_IFACE" managed yes || true
}

connection_exists() {
  nmcli -t -f NAME connection show "$1" >/dev/null 2>&1
}

configure_uplink() {
  if connection_exists "$UPLINK_CONN"; then
    log "Updating uplink connection: $UPLINK_CONN"
  else
    log "Creating uplink connection: $UPLINK_CONN"
    nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$UPLINK_CONN" ssid "$UPLINK_SSID"
  fi

  nmcli connection modify "$UPLINK_CONN" \
    connection.interface-name "$WIFI_IFACE" \
    connection.autoconnect yes \
    connection.autoconnect-priority 50 \
    802-11-wireless.ssid "$UPLINK_SSID" \
    802-11-wireless.mode infrastructure \
    ipv4.method auto \
    ipv4.route-metric 50 \
    ipv6.method ignore

  if [[ -n "$UPLINK_PASSWORD" ]]; then
    nmcli connection modify "$UPLINK_CONN" \
      802-11-wireless-security.key-mgmt wpa-psk \
      802-11-wireless-security.psk "$UPLINK_PASSWORD"
  else
    nmcli connection modify "$UPLINK_CONN" \
      802-11-wireless-security.key-mgmt "" \
      802-11-wireless-security.psk ""
  fi
}

configure_ap() {
  if connection_exists "$AP_CONN"; then
    log "Updating AP connection: $AP_CONN"
  else
    log "Creating AP connection: $AP_CONN"
    nmcli connection add type wifi ifname "$AP_IFACE" con-name "$AP_CONN" ssid "$AP_SSID"
  fi

  nmcli connection modify "$AP_CONN" \
    connection.interface-name "$AP_IFACE" \
    connection.autoconnect yes \
    connection.autoconnect-priority 40 \
    802-11-wireless.ssid "$AP_SSID" \
    802-11-wireless.mode ap \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$AP_PASSWORD" \
    ipv4.method shared \
    ipv4.addresses "$AP_ADDR" \
    ipv6.method ignore
}

activate_connections() {
  log "Connecting uplink Wi-Fi: $UPLINK_SSID"
  nmcli --wait 60 connection up "$UPLINK_CONN" ifname "$WIFI_IFACE"

  log "Starting AP Wi-Fi: $AP_SSID"
  if ! nmcli --wait 60 connection up "$AP_CONN" ifname "$AP_IFACE"; then
    die "Failed to bring up the AP. This usually means the chip/driver cannot keep AP+client up together on the current channel."
  fi
}

install_boot_helper() {
  log "Installing boot helper: $HELPER_PATH"
  cat > "$HELPER_PATH" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WIFI_IFACE="$WIFI_IFACE"
AP_IFACE="$AP_IFACE"
UPLINK_CONN="$UPLINK_CONN"
AP_CONN="$AP_CONN"

rfkill unblock wlan || rfkill unblock wifi || rfkill unblock all || true
nmcli radio wifi on || true
ip link set "\$WIFI_IFACE" up || true

if ! ip link show "\$AP_IFACE" >/dev/null 2>&1; then
  iw dev "\$WIFI_IFACE" interface add "\$AP_IFACE" type __ap || true
fi

ip link set "\$AP_IFACE" up || true
nmcli device set "\$WIFI_IFACE" managed yes || true
nmcli device set "\$AP_IFACE" managed yes || true
nmcli --wait 60 connection up "\$UPLINK_CONN" ifname "\$WIFI_IFACE" || true
nmcli --wait 60 connection up "\$AP_CONN" ifname "\$AP_IFACE" || true
EOF
  chmod 755 "$HELPER_PATH"
}

install_boot_service() {
  log "Installing boot service: $SERVICE_PATH"
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Unitree G1 PC2 dual Wi-Fi uplink and AP restore
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
  systemctl enable g1-pc2-dual-wifi.service >/dev/null
}

show_summary() {
  log "Uplink interface: $WIFI_IFACE"
  log "AP interface: $AP_IFACE"
  log "AP SSH address: ${AP_ADDR%/*}"
  log "Check status with: nmcli device status && nmcli connection show --active"
}

main() {
  prompt_secrets
  install_packages
  require_cmds
  ensure_networkmanager
  detect_wifi_iface
  check_concurrent_support
  prepare_radio
  ensure_ap_iface
  configure_uplink
  configure_ap
  activate_connections
  install_boot_helper
  install_boot_service
  show_summary
}

main "$@"
