#!/usr/bin/env bash
# g1_pc2_boot_time_sync_setup.sh
# Install a one-shot boot-time clock sync service for Unitree G1 PC2.
#
# Design goals:
# - No continuously running NTP daemon.
# - Sync once at boot, after networking is up.
# - Keep dependencies minimal: systemd, curl, date.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
HELPER_PATH="/usr/local/sbin/g1-pc2-sync-clock-once.sh"
SERVICE_PATH="/etc/systemd/system/g1-pc2-sync-clock.service"
WAIT_ONLINE_SECONDS=45
DRY_RUN=0
YES=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./g1_pc2_boot_time_sync_setup.sh [options]

What it installs:
  - /usr/local/sbin/g1-pc2-sync-clock-once.sh
  - /etc/systemd/system/g1-pc2-sync-clock.service

Behavior:
  - Runs once at boot after network-online.target.
  - Fetches an HTTP Date header from a small list of public endpoints.
  - Sets the system clock, then exits.
  - Does not enable an always-on NTP daemon.

Options:
  --wait-online SECONDS  Timeout for network-online.target. Default: 45.
  --dry-run              Print actions instead of writing files.
  -y, --yes              Do not ask for confirmation.
  -h, --help             Show this help.

Notes:
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
  for cmd in systemctl date install chmod; do
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
  systemd service:   $SERVICE_PATH
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

log() {
  printf '[%s] %s\n' "$(date '+%F %T' 2>/dev/null || true)" "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

get_http_date() {
  local url hdr

  # Use simple public HTTP endpoints so large clock drift does not break TLS.
  # This is meant to keep boot-time drift bounded, not provide authenticated
  # secure time.
  for url in \
    http://1.1.1.1/ \
    http://connectivitycheck.gstatic.com/generate_204 \
    http://neverssl.com/ \
    http://connectivity-check.ubuntu.com/; do
    hdr="$(
      curl -fsSI --connect-timeout 3 --max-time 6 "$url" 2>/dev/null \
      | tr -d '\r' \
      | awk 'BEGIN{IGNORECASE=1} /^date:/ {sub(/^date:[[:space:]]*/, "", $0); print; exit}'
    )"
    if [[ -n "$hdr" ]]; then
      printf '%s\n' "$hdr"
      return 0
    fi
  done

  return 1
}

main() {
  command -v curl >/dev/null 2>&1 || { warn "curl not found; skipping boot-time clock sync."; exit 0; }

  local hdr before after
  before="$(date -u '+%F %T UTC' 2>/dev/null || true)"

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

  warn "Could not obtain an HTTP Date header from any configured source."
}

main "$@"
EOF

  run chmod 0755 "$HELPER_PATH"
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
ExecStart=$HELPER_PATH
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
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
  $SERVICE_PATH

Useful commands:
  sudo systemctl start g1-pc2-sync-clock.service
  sudo systemctl status --no-pager g1-pc2-sync-clock.service
  sudo journalctl -u g1-pc2-sync-clock.service -b --no-pager
EOF
}

main() {
  validate_args
  require_cmds
  skip_if_time_sync_service_running
  confirm_if_needed
  warn_if_persistent_time_daemon_enabled
  write_helper_script
  write_service
  enable_service
  print_next_steps
}

main "$@"
