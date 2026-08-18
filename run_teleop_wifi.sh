#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wifi_iface="${WIFI_IFACE:-}"

if [[ -z "$wifi_iface" ]]; then
    for wireless in /sys/class/net/*/wireless; do
        [[ -d "$wireless" ]] || continue
        candidate="$(basename "$(dirname "$wireless")")"
        if ip -4 -o address show dev "$candidate" scope global | grep -q .; then
            wifi_iface="$candidate"
            break
        fi
    done
fi

[[ -n "$wifi_iface" ]] || {
    echo "No Wi-Fi interface with a global IPv4 address found." >&2
    exit 1
}

img_server_ip="${IMG_SERVER_IP:-$(
    ip -4 -o address show dev "$wifi_iface" scope global |
        awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}'
)}"
[[ -n "$img_server_ip" ]] || {
    echo "No IPv4 address found on $wifi_iface." >&2
    exit 1
}

printf 'Wi-Fi image server: %s (%s)\n' "$img_server_ip" "$wifi_iface"
exec "${PYTHON:-python}" "$script_dir/teleop_hand_and_arm.py" \
    --motion \
    --arm G1_23 \
    --ee brainco \
    --network-interface "${DDS_INTERFACE:-enP8p1s0}" \
    --img-server-ip "$img_server_ip" \
    --display-mode ego \
    "$@"
