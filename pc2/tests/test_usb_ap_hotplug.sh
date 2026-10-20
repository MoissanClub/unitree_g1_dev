#!/usr/bin/env bash
# Run on PC2 with the USB AP dongle unplugged; no radio traffic is generated.
set -Eeuo pipefail

service=g1-pc2-usb-wifi-ap-vht80.service
iface=${1:-wlx40a5ef5c63e8}
override=/run/systemd/system/$service.d/90-hotplug-test.conf

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo on PC2"
[[ $# -le 1 ]] || die "Usage: $0 [AP_INTERFACE]"
[[ ! -e /sys/class/net/$iface ]] || die "Unplug $iface before testing"
[[ ! -e $override ]] || die "Test override already exists: $override"
[[ -c /dev/net/tun ]] || die "TAP device support is unavailable"

device=$(systemd-escape --path --suffix=device "/sys/subsystem/net/devices/$iface")
[[ $(systemctl show "$service" -p ActiveState --value) == inactive ]] || die "AP service must be inactive"
[[ $(systemctl show "$service" -p BindsTo --value) == "$device" ]] || die "AP service is not bound to $device"
[[ -L /etc/systemd/system/$device.wants/$service ]] || die "Device activation is not enabled"
[[ ! -e /etc/systemd/system/multi-user.target.wants/$service ]] || die "Legacy boot activation is still enabled"

created=0
cleanup() {
  local status=$?
  trap - EXIT
  if (( created )); then
    ip tuntap del dev "$iface" mode tap || status=1
  fi
  systemctl stop "$service" || status=1
  rm -f -- "$override" || status=1
  systemctl daemon-reload || status=1
  return "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# Exercise the installed unit's dependencies without invoking the AP runner.
install -d -m 0755 "$(dirname -- "$override")"
cat > "$override" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/sleep infinity
EOF
systemctl daemon-reload

wait_state() {
  local expected=$1
  for _ in {1..40}; do
    [[ $(systemctl show "$service" -p ActiveState --value) == "$expected" ]] && return 0
    sleep 0.5
  done
  systemctl status "$service" --no-pager || true
  die "AP service did not become $expected"
}

for cycle in 1 2; do
  ip tuntap add dev "$iface" mode tap
  created=1
  udevadm settle --timeout=10
  wait_state active
  pid=$(systemctl show "$service" -p MainPID --value)
  [[ $(cat "/proc/$pid/comm") == sleep ]] || die "Placeholder process is not running"
  echo "Cycle $cycle: interface add automatically started the service (PID $pid)"

  ip tuntap del dev "$iface" mode tap
  created=0
  udevadm settle --timeout=10
  wait_state inactive
  echo "Cycle $cycle: interface removal automatically stopped the service"
done

cleanup
sleep 6
[[ $(systemctl show "$service" -p ActiveState --value) == inactive ]] || die "Service started without the interface"
[[ $(systemctl show "$service" -p NRestarts --value) == 0 ]] || die "Service retried while the interface was absent"
[[ ! -e /sys/class/net/$iface && ! -e $override ]] || die "Test resources remain"
echo 'PASS: device activation, removal, re-addition, and absence without retries'
