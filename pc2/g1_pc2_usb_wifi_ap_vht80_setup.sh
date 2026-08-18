#!/usr/bin/env bash
# Configure a dedicated USB Wi-Fi adapter as a VHT80 access point while
# NetworkManager keeps managing PC2's separate uplink interface.

set -Eeuo pipefail

[[ "$EUID" -eq 0 ]] || exec sudo -E bash "$0" "$@"

SSID=""
PASSWORD=""
IFACE=""
COUNTRY="US"
CHANNEL="149"
SKIP_APT=0

HOSTAPD_CONF="/etc/hostapd/g1-pc2-usb-ap.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/g1-pc2-usb-ap.conf"
RUNNER="/usr/local/sbin/g1-pc2-usb-wifi-ap-vht80"
SERVICE="/etc/systemd/system/g1-pc2-usb-wifi-ap-vht80.service"
NM_CONF="/etc/NetworkManager/conf.d/90-g1-pc2-usb-ap.conf"
OLD_CONNECTION="g1-pc2-usb-ap"

usage() {
  cat <<'EOF'
Usage:
  sudo ./g1_pc2_usb_wifi_ap_vht80_setup.sh \
    --ssid SSID --password PASSWORD --iface IFACE [options]

Options:
  --country CC       Two-letter regulatory country. Default: US.
  --channel CHANNEL  Non-DFS 80 MHz primary channel: 36, 40, 44, 48,
                     149, 153, 157, or 161. Default: 149.
  --skip-apt         Do not install hostapd or other packages.
  -h, --help         Show this help.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "Missing value for $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssid) need_value "$1" "${2:-}"; SSID="$2"; shift 2 ;;
    --password) need_value "$1" "${2:-}"; PASSWORD="$2"; shift 2 ;;
    --iface) need_value "$1" "${2:-}"; IFACE="$2"; shift 2 ;;
    --country) need_value "$1" "${2:-}"; COUNTRY="${2^^}"; shift 2 ;;
    --channel) need_value "$1" "${2:-}"; CHANNEL="$2"; shift 2 ;;
    --skip-apt) SKIP_APT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

[[ -n "$SSID" ]] || die "--ssid is required"
[[ -n "$PASSWORD" ]] || die "--password is required"
[[ -n "$IFACE" ]] || die "--iface is required"
[[ "${#PASSWORD}" -ge 8 && "${#PASSWORD}" -le 63 ]] || die "Password must be 8-63 characters"
[[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || die "Country must be a two-letter code"
[[ "$SSID" != *$'\n'* && "$SSID" != *$'\r'* ]] || die "SSID must be one line"
[[ -d "/sys/class/net/$IFACE" ]] || die "Interface not found: $IFACE"

case "$CHANNEL" in
  36)  CENTER_CHANNEL=42;  HT40='HT40+' ;;
  40)  CENTER_CHANNEL=42;  HT40='HT40-' ;;
  44)  CENTER_CHANNEL=42;  HT40='HT40+' ;;
  48)  CENTER_CHANNEL=42;  HT40='HT40-' ;;
  149) CENTER_CHANNEL=155; HT40='HT40+' ;;
  153) CENTER_CHANNEL=155; HT40='HT40-' ;;
  157) CENTER_CHANNEL=155; HT40='HT40+' ;;
  161) CENTER_CHANNEL=155; HT40='HT40-' ;;
  *) die "Channel must be a non-DFS VHT80 primary channel" ;;
esac

if [[ "$SKIP_APT" -eq 0 ]]; then
  log "Installing hostapd and runtime dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y hostapd dnsmasq-base iw iptables
fi

for cmd in hostapd dnsmasq iw iptables ip nmcli wpa_passphrase systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

PHY="$(iw dev "$IFACE" info | awk '/wiphy/ {print "phy" $2; exit}')"
[[ -n "$PHY" ]] || die "Could not determine phy for $IFACE"
iw phy "$PHY" info | grep -qE '^\s+\* AP$' || die "$PHY does not support AP mode"
iw phy "$PHY" info | grep -q 'VHT Capabilities' || die "$PHY does not support 802.11ac/VHT"

AP_PSK="$(wpa_passphrase "$SSID" "$PASSWORD" | awk -F= '
  /^[[:space:]]*psk=/ && length($2) == 64 && $2 ~ /^[0-9a-f]+$/ { print $2; exit }
')"
[[ "${#AP_PSK}" -eq 64 ]] || die "Could not derive WPA2 PSK"

install -d -m 0755 /etc/hostapd /etc/dnsmasq.d /etc/NetworkManager/conf.d
umask 077

cat > "$HOSTAPD_CONF" <<EOF
interface=$IFACE
driver=nl80211
ctrl_interface=/run/hostapd
ssid=$SSID
country_code=$COUNTRY
ieee80211d=1
hw_mode=a
channel=$CHANNEL
beacon_int=100
dtim_period=2
max_num_sta=16
wmm_enabled=1
ieee80211n=1
ht_capab=[$HT40][SHORT-GI-20][SHORT-GI-40][TX-STBC][RX-STBC1]
ieee80211ac=1
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=$CENTER_CHANNEL
vht_capab=[RXLDPC][SHORT-GI-80][TX-STBC-2BY1][RX-STBC-1]
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_psk=$AP_PSK
EOF

cat > "$DNSMASQ_CONF" <<EOF
port=0
interface=$IFACE
bind-dynamic
dhcp-authoritative
dhcp-range=10.42.0.10,10.42.0.200,255.255.255.0,12h
dhcp-option=3,10.42.0.1
dhcp-option=6,1.1.1.1,8.8.8.8
dhcp-leasefile=/run/g1-pc2-usb-ap.leases
EOF

cat > "$NM_CONF" <<EOF
[keyfile]
unmanaged-devices=interface-name:$IFACE
EOF

cat > /etc/modules-load.d/mt76x2u.conf <<'EOF'
mt76x2u
EOF

cat > /etc/modprobe.d/cfg80211-regdom.conf <<EOF
options cfg80211 ieee80211_regdom=$COUNTRY
EOF

cat > /etc/sysctl.d/90-g1-pc2-usb-ap.conf <<'EOF'
net.ipv4.ip_forward=1
EOF

cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

IFACE="$IFACE"
COUNTRY="$COUNTRY"
SUBNET="10.42.0.0/24"
HOSTAPD_CONF="$HOSTAPD_CONF"
DNSMASQ_CONF="$DNSMASQ_CONF"
HOSTAPD_PID=""
DNSMASQ_PID=""

remove_firewall_rules() {
  iptables -w 5 -t nat -D POSTROUTING -s "\$SUBNET" ! -d "\$SUBNET" -j MASQUERADE 2>/dev/null || true
  iptables -w 5 -D FORWARD -i "\$IFACE" -j ACCEPT 2>/dev/null || true
  iptables -w 5 -D FORWARD -o "\$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
}

cleanup() {
  [[ -z "\$DNSMASQ_PID" ]] || kill "\$DNSMASQ_PID" 2>/dev/null || true
  [[ -z "\$HOSTAPD_PID" ]] || kill "\$HOSTAPD_PID" 2>/dev/null || true
  remove_firewall_rules
}
trap cleanup EXIT INT TERM

for _ in {1..30}; do
  [[ -d "/sys/class/net/\$IFACE" ]] && break
  sleep 1
done
[[ -d "/sys/class/net/\$IFACE" ]] || { echo "Interface not found: \$IFACE" >&2; exit 1; }

iw reg set "\$COUNTRY"
rfkill unblock wifi 2>/dev/null || rfkill unblock wlan 2>/dev/null || true
nmcli device set "\$IFACE" managed no 2>/dev/null || true
ip link set "\$IFACE" down
ip addr flush dev "\$IFACE"
ip addr add 10.42.0.1/24 dev "\$IFACE"
ip link set "\$IFACE" up
sysctl -q -w net.ipv4.ip_forward=1

remove_firewall_rules
iptables -w 5 -t nat -A POSTROUTING -s "\$SUBNET" ! -d "\$SUBNET" -j MASQUERADE
iptables -w 5 -A FORWARD -i "\$IFACE" -j ACCEPT
iptables -w 5 -A FORWARD -o "\$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

/usr/sbin/hostapd "\$HOSTAPD_CONF" &
HOSTAPD_PID=\$!
sleep 1
kill -0 "\$HOSTAPD_PID"

/usr/sbin/dnsmasq --no-daemon --conf-file="\$DNSMASQ_CONF" &
DNSMASQ_PID=\$!

set +e
wait -n "\$HOSTAPD_PID" "\$DNSMASQ_PID"
STATUS=\$?
set -e
exit "\$STATUS"
EOF
chmod 0755 "$RUNNER"

cat > "$SERVICE" <<EOF
[Unit]
Description=Unitree G1 PC2 USB Wi-Fi VHT80 access point
After=NetworkManager.service systemd-modules-load.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=$RUNNER
Restart=on-failure
RestartSec=2
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

systemctl disable --now g1-pc2-usb-wifi-ap.service >/dev/null 2>&1 || true
systemctl disable --now hostapd.service >/dev/null 2>&1 || true
nmcli connection down "$OLD_CONNECTION" >/dev/null 2>&1 || true
nmcli connection modify "$OLD_CONNECTION" connection.autoconnect no >/dev/null 2>&1 || true
nmcli device set "$IFACE" managed no || true

systemctl daemon-reload
systemctl enable --now g1-pc2-usb-wifi-ap-vht80.service

log "VHT80 AP '$SSID' started on $IFACE, channel $CHANNEL, address 10.42.0.1"
iw dev "$IFACE" info
