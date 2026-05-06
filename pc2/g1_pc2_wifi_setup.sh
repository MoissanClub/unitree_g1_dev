#!/usr/bin/env bash
# g1_pc2_wifi_setup.sh
# Robust Wi-Fi setup for the Unitree G1 development computer PC2.
# Intended to run ON PC2, usually after SSHing to unitree@192.168.123.164.
#
# Important routing note:
# - This script only configures a Wi-Fi NetworkManager profile and does not
#   administratively bring any wired interface down.
# - It does, however, allow the Wi-Fi profile to install the default IPv4
#   route. That can move general outbound traffic away from Ethernet even
#   though the wired link itself stays up.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_DNS="1.1.1.1,8.8.8.8"

SSID=""
WIFI_PASSWORD=""
ASK_PASSWORD=0
OPEN_WIFI=0
STATIC_IP=""
GATEWAY=""
DNS="$DEFAULT_DNS"
DNS_EXPLICIT=0
IFACE=""
CONN_NAME="g1-pc2-wifi"
FIX_RESOLV=0
INSTALL_BOOT_SERVICE=1
ENABLE_NM_BOOT=0
DRY_RUN=0
YES=0
HIDDEN=0
FORCE_UNITREE_SUBNET=0
SCAN_ONLY=0
WAIT_SECONDS=45

usage() {
  cat <<'USAGE'
Usage:
  sudo ./g1_pc2_wifi_setup.sh --ssid SSID --ask-password [options]

Common examples:
  # Static IP Wi-Fi, recommended when the AP has no DHCP:
  sudo ./g1_pc2_wifi_setup.sh \
    --ssid "LabWiFi" --ask-password \
    --ip 10.10.20.164/24 --gateway 10.10.20.1 --dns 1.1.1.1,8.8.8.8 \
    --yes

  # DHCP Wi-Fi, if your AP/router provides DHCP:
  sudo ./g1_pc2_wifi_setup.sh --ssid "LabWiFi" --ask-password --yes

  # Just unblock radio and list visible APs:
  sudo ./g1_pc2_wifi_setup.sh --scan-only

Options:
  --ssid SSID                    Wi-Fi SSID to connect to.
  --password PASSWORD            Wi-Fi password. Less safe than --ask-password.
  --ask-password                 Prompt for Wi-Fi password without echoing it.
  --open                         Connect to an open Wi-Fi network; do not set WPA PSK.
  --hidden                       Mark the SSID as hidden.
  --ip CIDR                      Static IPv4 address, e.g. 10.10.20.164/24.
  --gateway IPv4                 Default gateway for static IPv4.
  --dns LIST                     Comma-separated DNS servers. Default for static: 1.1.1.1,8.8.8.8.
  --iface IFACE                  Wi-Fi interface. Autodetects if omitted, usually wlan0.
  --connection-name NAME         NetworkManager profile name. Default: g1-pc2-wifi.
  --fix-resolv-conf              If DNS lookup fails, write /etc/resolv.conf with --dns servers.
  --no-boot-service              Do not install the one-shot boot unblock/connect service.
  --enable-networkmanager-at-boot Enable NetworkManager service at boot.
  --force-unitree-subnet         Allow Wi-Fi static IP in 192.168.123.0/24. Normally refused.
  --wait SECONDS                 nmcli activation timeout. Default: 45.
  --dry-run                      Print commands instead of running them.
  -y, --yes                      Do not ask for confirmation.
  -h, --help                     Show this help.

Safety notes:
  - This script configures only the Wi-Fi interface/profile.
  - It does not explicitly disable wired Ethernet, but the Wi-Fi profile is
    allowed to become the default route for non-local traffic.
  - It refuses Wi-Fi static addresses in 192.168.123.0/24 by default, because PC2's
    Unitree Ethernet side is normally 192.168.123.164 and route conflicts can break access.
  - The installed boot service is one-shot: it unblocks Wi-Fi, enables the radio,
    tries to activate this profile, then exits. It is not a long-running daemon.
USAGE
}

# Allow help without sudo.
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Re-exec early so all argument parsing, prompting, and changes happen as root.
if [[ "$EUID" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

log()  { printf '[%s] %s\n' "$(date '+%F %T' 2>/dev/null || true)" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; printf "ERROR: %s failed near line %s, exit %s\n" "$SCRIPT_NAME" "$LINENO" "$rc" >&2; exit "$rc"' ERR

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "Missing value for $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssid) need_value "$1" "${2:-}"; SSID="$2"; shift 2 ;;
    --password) need_value "$1" "${2:-}"; WIFI_PASSWORD="$2"; shift 2 ;;
    --ask-password) ASK_PASSWORD=1; shift ;;
    --open) OPEN_WIFI=1; shift ;;
    --hidden) HIDDEN=1; shift ;;
    --ip|--static-ip) need_value "$1" "${2:-}"; STATIC_IP="$2"; shift 2 ;;
    --gateway) need_value "$1" "${2:-}"; GATEWAY="$2"; shift 2 ;;
    --dns) need_value "$1" "${2:-}"; DNS="$2"; DNS_EXPLICIT=1; shift 2 ;;
    --iface) need_value "$1" "${2:-}"; IFACE="$2"; shift 2 ;;
    --connection-name) need_value "$1" "${2:-}"; CONN_NAME="$2"; shift 2 ;;
    --fix-resolv-conf) FIX_RESOLV=1; shift ;;
    --no-boot-service) INSTALL_BOOT_SERVICE=0; shift ;;
    --enable-networkmanager-at-boot) ENABLE_NM_BOOT=1; shift ;;
    --force-unitree-subnet) FORCE_UNITREE_SUBNET=1; shift ;;
    --scan-only) SCAN_ONLY=1; shift ;;
    --wait) need_value "$1" "${2:-}"; WAIT_SECONDS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

require_cmds() {
  local missing=0 cmd
  for cmd in nmcli ip rfkill ping awk sed grep date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing command: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Install missing commands first, then rerun."
}

valid_ipv4() {
  local ip="$1" a b c d n
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ && "$n" -ge 0 && "$n" -le 255 ]] || return 1
  done
  return 0
}

validate_args() {
  [[ "$WAIT_SECONDS" =~ ^[0-9]+$ && "$WAIT_SECONDS" -ge 5 ]] || die "--wait must be an integer >= 5"

  if [[ "$SCAN_ONLY" -eq 0 ]]; then
    [[ -n "$SSID" ]] || { usage; die "--ssid is required unless --scan-only is used."; }
    if [[ "$OPEN_WIFI" -eq 1 && -n "$WIFI_PASSWORD" ]]; then
      die "Use either --open or --password/--ask-password, not both."
    fi
    if [[ "$OPEN_WIFI" -eq 0 && -z "$WIFI_PASSWORD" && "$ASK_PASSWORD" -eq 0 ]]; then
      die "Provide --ask-password, --password, or --open."
    fi
  fi

  if [[ -n "$STATIC_IP" ]]; then
    [[ "$STATIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die "--ip must look like 10.10.20.164/24"
    valid_ipv4 "${STATIC_IP%/*}" || die "Invalid --ip address: ${STATIC_IP%/*}"
    [[ -n "$GATEWAY" ]] || die "--gateway is required when --ip is used."
    valid_ipv4 "$GATEWAY" || die "Invalid --gateway: $GATEWAY"
    if [[ "$STATIC_IP" == 192.168.123.*/* && "$FORCE_UNITREE_SUBNET" -eq 0 ]]; then
      die "Refusing Wi-Fi static IP $STATIC_IP in 192.168.123.0/24. PC2 Ethernet normally uses 192.168.123.164. Use --force-unitree-subnet only if you are certain."
    fi
  elif [[ -n "$GATEWAY" ]]; then
    die "--gateway only makes sense with --ip."
  fi
}

prompt_password_if_needed() {
  if [[ "$SCAN_ONLY" -eq 0 && "$OPEN_WIFI" -eq 0 && "$ASK_PASSWORD" -eq 1 && -z "$WIFI_PASSWORD" ]]; then
    read -r -s -p "Wi-Fi password for SSID '$SSID': " WIFI_PASSWORD
    printf '\n'
    [[ -n "$WIFI_PASSWORD" ]] || die "Empty password. Use --open for an open network."
  fi
}

confirm_if_needed() {
  [[ "$YES" -eq 1 || "$DRY_RUN" -eq 1 || "$SCAN_ONLY" -eq 1 ]] && return 0
  cat <<EOF
About to configure Wi-Fi on PC2:
  interface:        ${IFACE:-autodetect}
  connection name:  $CONN_NAME
  ssid:             $SSID
  ipv4:             ${STATIC_IP:-DHCP/auto}
  gateway:          ${GATEWAY:-auto/none}
  dns:              $([[ -n "$STATIC_IP" || "$DNS_EXPLICIT" -eq 1 ]] && echo "$DNS" || echo "DHCP-provided")
  boot one-shot:    $([[ "$INSTALL_BOOT_SERVICE" -eq 1 ]] && echo yes || echo no)

This should not change PC2's wired 192.168.123.164 connection.
EOF
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Cancelled."
}

ensure_networkmanager() {
  if nmcli general status >/dev/null 2>&1; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    log "Starting NetworkManager for Wi-Fi setup."
    run systemctl start NetworkManager.service || run systemctl start network-manager.service || true
  fi

  nmcli general status >/dev/null 2>&1 || die "nmcli cannot talk to NetworkManager. Start/install NetworkManager first."

  if [[ "$ENABLE_NM_BOOT" -eq 1 && -d /run/systemd/system ]]; then
    log "Enabling NetworkManager at boot."
    run systemctl enable NetworkManager.service || true
  fi
}

detect_wifi_iface() {
  if [[ -n "$IFACE" ]]; then
    ip link show "$IFACE" >/dev/null 2>&1 || die "Interface not found: $IFACE"
    return 0
  fi

  local dev=""
  dev="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi" && $1 != "" {print $1; exit}')"
  if [[ -z "$dev" ]] && command -v iw >/dev/null 2>&1; then
    dev="$(iw dev 2>/dev/null | awk '$1 == "Interface" {print $2; exit}')"
  fi
  if [[ -z "$dev" ]]; then
    dev="$(ip -o link show | awk -F': ' '$2 ~ /^wl/ {print $2; exit}')"
  fi
  [[ -n "$dev" ]] || die "No Wi-Fi interface found. Check 'lshw -C network' and driver/USB dongle state."
  IFACE="$dev"
  log "Using Wi-Fi interface: $IFACE"
}

unblock_wifi() {
  log "Unblocking Wi-Fi radio and bringing $IFACE up."
  run rfkill unblock wlan || run rfkill unblock wifi || run rfkill unblock all || true
  if rfkill list 2>/dev/null | grep -A3 -iE 'wireless|wlan|wifi' | grep -qi 'Hard blocked: yes'; then
    warn "Wi-Fi appears hard-blocked. Software cannot fix a hardware/firmware kill switch."
  fi
  run nmcli radio wifi on || true
  run nmcli device set "$IFACE" managed yes || true
  run ip link set "$IFACE" up || true
}

scan_wifi() {
  log "Scanning visible Wi-Fi networks."
  run nmcli device wifi rescan ifname "$IFACE" || true
  nmcli -f IN-USE,SSID,SIGNAL,SECURITY device wifi list ifname "$IFACE" || true
}

profile_exists() {
  nmcli -t -f NAME connection show "$CONN_NAME" >/dev/null 2>&1
}

configure_connection() {
  [[ "$SCAN_ONLY" -eq 1 ]] && return 0

  local dns_nm
  dns_nm="$(printf '%s' "$DNS" | tr ',' ' ')"

  if [[ "$OPEN_WIFI" -eq 1 && profile_exists ]]; then
    log "Deleting existing profile '$CONN_NAME' so open-network security settings are clean."
    run nmcli connection delete "$CONN_NAME"
  fi

  if profile_exists; then
    log "Updating existing NetworkManager profile: $CONN_NAME"
  else
    log "Creating NetworkManager profile: $CONN_NAME"
    run nmcli connection add type wifi ifname "$IFACE" con-name "$CONN_NAME" ssid "$SSID"
  fi

  # Route behavior matters more than link state here:
  # - `ipv4.never-default no` lets Wi-Fi install a default route.
  # - `ipv4.route-metric 50` gives Wi-Fi a relatively preferred metric.
  # Together, that can shift internet-bound traffic from Ethernet to Wi-Fi
  # without actually shutting the wired interface down.
  run nmcli connection modify "$CONN_NAME" \
    connection.interface-name "$IFACE" \
    connection.autoconnect yes \
    connection.autoconnect-priority 50 \
    802-11-wireless.ssid "$SSID" \
    802-11-wireless.mode infrastructure \
    ipv4.never-default no \
    ipv4.route-metric 50 \
    ipv6.method ignore

  if [[ "$HIDDEN" -eq 1 ]]; then
    run nmcli connection modify "$CONN_NAME" 802-11-wireless.hidden yes
  fi

  if [[ "$OPEN_WIFI" -eq 0 ]]; then
    run nmcli connection modify "$CONN_NAME" \
      802-11-wireless-security.key-mgmt wpa-psk \
      802-11-wireless-security.psk "$WIFI_PASSWORD"
  fi

  if [[ -n "$STATIC_IP" ]]; then
    log "Applying static IPv4: $STATIC_IP gateway $GATEWAY DNS $DNS"
    run nmcli connection modify "$CONN_NAME" \
      ipv4.method manual \
      ipv4.addresses "$STATIC_IP" \
      ipv4.gateway "$GATEWAY" \
      ipv4.dns "$dns_nm" \
      ipv4.ignore-auto-dns yes
  else
    log "Using DHCP/auto IPv4."
    run nmcli connection modify "$CONN_NAME" \
      ipv4.method auto \
      ipv4.addresses "" \
      ipv4.gateway ""
    if [[ "$DNS_EXPLICIT" -eq 1 ]]; then
      log "Overriding DHCP DNS with: $DNS"
      run nmcli connection modify "$CONN_NAME" ipv4.dns "$dns_nm" ipv4.ignore-auto-dns yes
    else
      run nmcli connection modify "$CONN_NAME" ipv4.dns "" ipv4.ignore-auto-dns no
    fi
  fi
}

activate_connection() {
  [[ "$SCAN_ONLY" -eq 1 ]] && return 0

  log "Activating Wi-Fi profile '$CONN_NAME'."
  run nmcli device wifi rescan ifname "$IFACE" || true
  if ! nmcli --wait "$WAIT_SECONDS" connection up "$CONN_NAME" ifname "$IFACE"; then
    nmcli device status || true
    nmcli -f GENERAL,IP4 device show "$IFACE" || true
    die "NetworkManager failed to activate '$CONN_NAME'. Check SSID/password/static IP/gateway."
  fi
}

write_resolv_conf_if_requested() {
  [[ "$FIX_RESOLV" -eq 1 ]] || return 0
  [[ -n "$DNS" ]] || return 0

  if getent hosts example.com >/dev/null 2>&1; then
    return 0
  fi

  local backup="/etc/resolv.conf.g1-pc2-wifi.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)"
  warn "DNS lookup failed; writing /etc/resolv.conf with: $DNS"
  if [[ -e /etc/resolv.conf ]]; then
    run cp -a /etc/resolv.conf "$backup" || true
    log "Backed up old resolv.conf to $backup"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ write /etc/resolv.conf with nameservers: %s\n' "$DNS"
  else
    rm -f /etc/resolv.conf
    {
      echo "# Written by $SCRIPT_NAME because DNS resolution failed."
      echo "# Backup: $backup"
      for ns in ${DNS//,/ }; do
        [[ -n "$ns" ]] && echo "nameserver $ns"
      done
    } > /etc/resolv.conf
  fi
}

check_connectivity() {
  [[ "$SCAN_ONLY" -eq 1 ]] && return 0

  log "NetworkManager status for $IFACE:"
  nmcli -f GENERAL.DEVICE,GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show "$IFACE" || true

  # This shows whether Wi-Fi became the preferred path for generic outbound
  # traffic after activation.
  log "Route chosen for 8.8.8.8:"
  ip route get 8.8.8.8 || true

  if ping -I "$IFACE" -c 3 -W 3 8.8.8.8 >/dev/null 2>&1; then
    log "IPv4 internet test passed: ping 8.8.8.8 via $IFACE"
  else
    warn "Could not ping 8.8.8.8 via $IFACE. Check gateway, AP isolation, firewall, or static IP settings."
  fi

  write_resolv_conf_if_requested

  if getent hosts example.com >/dev/null 2>&1; then
    log "DNS test passed: example.com resolves."
  else
    warn "DNS test failed. Try rerunning with '--dns 1.1.1.1,8.8.8.8 --fix-resolv-conf'."
  fi
}

install_boot_service() {
  [[ "$INSTALL_BOOT_SERVICE" -eq 1 ]] || return 0
  [[ "$SCAN_ONLY" -eq 0 ]] || return 0
  command -v systemctl >/dev/null 2>&1 || { warn "systemctl not found; skipping boot service."; return 0; }
  [[ -d /run/systemd/system ]] || { warn "systemd not active; skipping boot service."; return 0; }

  local rfkill_bin nmcli_bin ip_bin service_path
  rfkill_bin="$(command -v rfkill)"
  nmcli_bin="$(command -v nmcli)"
  ip_bin="$(command -v ip)"
  service_path="/etc/systemd/system/g1-pc2-wifi.service"

  log "Installing one-shot boot service: $service_path"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ write and enable %s\n' "$service_path"
    return 0
  fi

  cat > "$service_path" <<EOF
[Unit]
Description=Unitree G1 PC2 Wi-Fi radio unblock and profile activation
After=NetworkManager.service systemd-rfkill.service
Wants=NetworkManager.service

[Service]
Type=oneshot
TimeoutStartSec=60
ExecStart=/bin/sh -c '$rfkill_bin unblock wlan || $rfkill_bin unblock wifi || $rfkill_bin unblock all || true; $nmcli_bin radio wifi on || true; $ip_bin link set "$IFACE" up || true; $nmcli_bin --wait 45 connection up "$CONN_NAME" ifname "$IFACE" || true'
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable g1-pc2-wifi.service >/dev/null
}

main() {
  validate_args
  require_cmds
  prompt_password_if_needed
  ensure_networkmanager
  detect_wifi_iface
  confirm_if_needed
  unblock_wifi
  scan_wifi
  configure_connection
  activate_connection
  check_connectivity
  install_boot_service

  if [[ "$SCAN_ONLY" -eq 1 ]]; then
    log "Scan complete."
  else
    log "Done. Re-test later with: nmcli device status && ping -I $IFACE 8.8.8.8"
  fi
}

main "$@"
