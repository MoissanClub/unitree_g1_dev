#!/usr/bin/env bash
# g1_pc2_boot_time_sync_setup.sh
# Install a one-shot boot-time clock sync service for Unitree G1 PC2.
# Invoke with sudo. This script installs root-owned files under /usr/local,
# /etc/systemd/system, and /etc/NetworkManager/dispatcher.d.
#
# Design goals:
# - No continuously running NTP daemon.
# - Sync once at boot, after networking is up.
# - Keep dependencies minimal: systemd, curl, date.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load_g1_pc2_hardware.sh"
HELPER_PATH="/usr/local/sbin/g1-pc2-sync-clock-once.sh"
TRIGGER_PATH="/usr/local/sbin/g1-pc2-sync-clock-trigger.sh"
SERVICE_PATH="/etc/systemd/system/g1-pc2-sync-clock.service"
DISPATCHER_PATH="/etc/NetworkManager/dispatcher.d/90-g1-pc2-sync-clock"
WAIT_ONLINE_SECONDS=45
DISPATCHER_SYNC_WAIT_SECONDS=20
DISPATCHER_COOLDOWN_SECONDS=900
DRY_RUN=0
YES=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./g1_pc2_boot_time_sync_setup.sh [options]

What it installs:
  - /usr/local/sbin/g1-pc2-sync-clock-once.sh
  - /usr/local/sbin/g1-pc2-sync-clock-trigger.sh
  - /etc/systemd/system/g1-pc2-sync-clock.service
  - /etc/NetworkManager/dispatcher.d/90-g1-pc2-sync-clock

Behavior:
  - Runs once at boot after network-online.target.
  - Retries for a bounded window while Wi-Fi/internet comes up.
  - Fetches an HTTP Date header from a small list of public endpoints.
  - Sets the system clock, then exits.
  - Retries again when NetworkManager reports connectivity later in boot.
  - Does not enable an always-on NTP daemon.

Options:
  --wait-online SECONDS  Timeout for network-online.target. Default: 45.
  --dry-run              Print actions instead of writing files.
  -y, --yes              Do not ask for confirmation.
  -h, --help             Show this help.

Notes:
  - Invoke this script with sudo. It installs system services and dispatcher hooks.
  - This is approximate internet time, not a cryptographically authenticated
    secure time protocol.
  - It is intended to keep PC2 from drifting too far, while keeping background
    services to a minimum.
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
    --wait-online) need_value "$1" "${2:-}"; WAIT_ONLINE_SECONDS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

validate_args() {
  [[ "$WAIT_ONLINE_SECONDS" =~ ^[0-9]+$ && "$WAIT_ONLINE_SECONDS" -ge 5 ]] || die "--wait-online must be an integer >= 5"
}

require_cmds() {
  local missing=0 cmd
  for cmd in systemctl date install chmod flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing command: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Install missing commands first, then rerun."
}

confirm_if_needed() {
  [[ "$YES" -eq 1 || "$DRY_RUN" -eq 1 ]] && return 0

  cat <<EOF
About to install the PC2 boot-time clock sync service:
  helper script:     $HELPER_PATH
  trigger helper:    $TRIGGER_PATH
  systemd service:   $SERVICE_PATH
  dispatcher script: $DISPATCHER_PATH
  wait-online:       ${WAIT_ONLINE_SECONDS}s

This keeps boot-time clock correction as a one-shot action, not a persistent NTP service.
EOF
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Cancelled."
}

running_time_sync_service() {
  local svc
  for svc in systemd-timesyncd.service chronyd.service chrony.service ntp.service ntpd.service; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
      printf '%s\n' "$svc"
      return 0
    fi
  done
  return 1
}

skip_if_time_sync_service_running() {
  local svc
  if svc="$(running_time_sync_service)"; then
    log "$svc is already running. Skipping installation of the one-shot boot-time clock sync service."
    exit 0
  fi
}

warn_if_persistent_time_daemon_enabled() {
  local svc
  for svc in systemd-timesyncd.service chronyd.service chrony.service ntp.service ntpd.service; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
      warn "$svc is enabled. This installer does not disable it automatically."
    fi
  done
}

write_helper_script() {
  log "Installing boot-time clock sync helper: $HELPER_PATH"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ write %s\n' "$HELPER_PATH"
    return 0
  fi

  cat > "$HELPER_PATH" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SYNC_WAIT_SECONDS="${SYNC_WAIT_SECONDS:-45}"
SYNC_RETRY_INTERVAL_SECONDS="${SYNC_RETRY_INTERVAL_SECONDS:-3}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T' 2>/dev/null || true)" "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

get_http_date() {
  local hdr

  # Use a regular GET and dump the response headers.  Following redirects is
  # important because many connectivity endpoints now answer HTTP with 301.
  # --insecure is deliberate: this helper is used when the local clock may be
  # too wrong for TLS certificate validation.  HTTP time is only a rough,
  # unauthenticated correction in either case.
  hdr="$(
    curl --silent --show-error --location --insecure \
      --dump-header - --output /dev/null \
      --connect-timeout 5 --max-time 15 \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | tr -d '\r' \
    | awk 'BEGIN{IGNORECASE=1} /^date:[[:space:]]*/ {sub(/^date:[[:space:]]*/, "", $0); value=$0} END {print value}'
  )"

  [[ -n "$hdr" ]] || return 1
  printf '%s\n' "$hdr"
}

main() {
  command -v curl >/dev/null 2>&1 || { warn "curl not found; skipping boot-time clock sync."; exit 0; }

  local hdr before after deadline now
  before="$(date -u '+%F %T UTC' 2>/dev/null || true)"
  deadline=$(( $(date +%s) + SYNC_WAIT_SECONDS ))

  while true; do
    if hdr="$(get_http_date)"; then
      log "Setting clock from HTTP Date header: $hdr"
      if date -u -s "$hdr" >/dev/null 2>&1; then
        after="$(date -u '+%F %T UTC' 2>/dev/null || true)"
        log "Clock updated: $before -> $after"
        exit 0
      fi
      warn "Failed to set clock from HTTP Date header: $hdr"
      exit 0
    fi

    now="$(date +%s)"
    if (( now >= deadline )); then
      break
    fi

    sleep "$SYNC_RETRY_INTERVAL_SECONDS"
  done

  warn "Could not obtain an HTTP Date header from Cloudflare within ${SYNC_WAIT_SECONDS}s."
}

main "$@"
EOF

  run chmod 0755 "$HELPER_PATH"
}

write_trigger_script() {
  log "Installing clock sync trigger helper: $TRIGGER_PATH"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ write %s\n' "$TRIGGER_PATH"
    return 0
  fi

  cat > "$TRIGGER_PATH" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SYNC_HELPER_PATH="$HELPER_PATH"
TRIGGER_SYNC_WAIT_SECONDS="${DISPATCHER_SYNC_WAIT_SECONDS}"
TRIGGER_SYNC_RETRY_INTERVAL_SECONDS=2
TRIGGER_COOLDOWN_SECONDS="${DISPATCHER_COOLDOWN_SECONDS}"
LOCK_PATH=/run/g1-pc2-sync-clock.lock
STAMP_PATH=/run/g1-pc2-sync-clock.last-success

log() {
  printf '[%s] %s\n' "\$(date '+%F %T' 2>/dev/null || true)" "\$*"
}

main() {
  local now last

  [[ -x "\$SYNC_HELPER_PATH" ]] || exit 0

  exec 9>"\$LOCK_PATH"
  if ! flock -n 9; then
    exit 0
  fi

  now="\$(date +%s 2>/dev/null || printf '0')"
  if [[ -r "\$STAMP_PATH" ]]; then
    last="\$(cat "\$STAMP_PATH" 2>/dev/null || printf '0')"
    if [[ "\$last" =~ ^[0-9]+$ ]] && (( now - last < TRIGGER_COOLDOWN_SECONDS )); then
      exit 0
    fi
  fi

  if SYNC_WAIT_SECONDS="\$TRIGGER_SYNC_WAIT_SECONDS" \\
     SYNC_RETRY_INTERVAL_SECONDS="\$TRIGGER_SYNC_RETRY_INTERVAL_SECONDS" \\
     "\$SYNC_HELPER_PATH"; then
    printf '%s\n' "\$(date +%s)" > "\$STAMP_PATH"
    log "Clock sync trigger completed successfully."
  fi
}

main "\$@"
EOF

  run chmod 0755 "$TRIGGER_PATH"
}

write_service() {
  log "Installing one-shot boot service: $SERVICE_PATH"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ write %s\n' "$SERVICE_PATH"
    return 0
  fi

  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Unitree G1 PC2 one-shot boot-time clock sync
Wants=network-online.target
After=network-online.target NetworkManager.service g1-pc2-wifi.service

[Service]
Type=oneshot
TimeoutStartSec=${WAIT_ONLINE_SECONDS}
Environment=SYNC_WAIT_SECONDS=${WAIT_ONLINE_SECONDS}
ExecStart=$HELPER_PATH
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
}

write_dispatcher_script() {
  log "Installing NetworkManager dispatcher hook: $DISPATCHER_PATH"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ write %s\n' "$DISPATCHER_PATH"
    return 0
  fi

  install -d -m 0755 "$(dirname "$DISPATCHER_PATH")"
  cat > "$DISPATCHER_PATH" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TRIGGER_PATH="$TRIGGER_PATH"
ACTION="\${2:-}"

case "\$ACTION" in
  up|dhcp4-change|dhcp6-change|connectivity-change)
    ;;
  *)
    exit 0
    ;;
esac

[[ -x "\$TRIGGER_PATH" ]] || exit 0
"$TRIGGER_PATH" >/dev/null 2>&1 || true
EOF
  run chmod 0755 "$DISPATCHER_PATH"
}

enable_service() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ systemctl daemon-reload\n'
    printf '+ systemctl enable g1-pc2-sync-clock.service\n'
    return 0
  fi

  run systemctl daemon-reload
  run systemctl enable g1-pc2-sync-clock.service
}

print_next_steps() {
  cat <<EOF

Installed:
  $HELPER_PATH
  $TRIGGER_PATH
  $SERVICE_PATH
  $DISPATCHER_PATH

Useful commands:
  sudo systemctl start g1-pc2-sync-clock.service
  sudo systemctl status --no-pager g1-pc2-sync-clock.service
  sudo journalctl -u g1-pc2-sync-clock.service -b --no-pager
  sudo $TRIGGER_PATH
EOF
}

main() {
  validate_args
  require_cmds
  skip_if_time_sync_service_running
  confirm_if_needed
  warn_if_persistent_time_daemon_enabled
  write_helper_script
  write_trigger_script
  write_service
  write_dispatcher_script
  enable_service
  print_next_steps
}

main "$@"
