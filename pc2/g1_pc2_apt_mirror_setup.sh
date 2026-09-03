#!/usr/bin/env bash
# g1_pc2_apt_mirror_setup.sh
# Switch Ubuntu APT sources on Unitree G1 PC2 away from slow/unreliable mirrors
# to official Ubuntu endpoints.
# Invoke with sudo. This script rewrites files under /etc/apt.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load_g1_pc2_hardware.sh"
SOURCES_LIST="/etc/apt/sources.list"
SOURCES_DIR="/etc/apt/sources.list.d"
BACKUP_ROOT="/etc/apt/backup-g1-pc2-mirror-switch"

UPDATE_APT=0
DRY_RUN=0
YES=0

ARCHIVE_MIRROR=""
SECURITY_MIRROR=""
PORTS_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
CURRENT_UBUNTU_URLS=""

usage() {
  cat <<'USAGE'
Usage:
  sudo ./g1_pc2_apt_mirror_setup.sh [options]

What it does:
  - Detects whether the machine uses the standard Ubuntu archive or ports archive.
  - Rewrites Ubuntu APT source URLs away from regional mirrors to official Ubuntu endpoints.
  - Backs up modified source files under /etc/apt/backup-g1-pc2-mirror-switch/<timestamp>/.
  - Supports both legacy .list files and newer .sources files.

Default mirrors:
  - Standard Ubuntu archive: http://archive.ubuntu.com/ubuntu
  - Ubuntu security:         http://security.ubuntu.com/ubuntu
  - Ubuntu ports archive:    http://ports.ubuntu.com/ubuntu-ports

Options:
  --archive-url URL     Override the standard Ubuntu archive URL.
  --security-url URL    Override the Ubuntu security URL.
  --ports-url URL       Override the Ubuntu ports archive URL.
  --update              Run apt-get update after rewriting sources.
  --dry-run             Show planned changes without writing files.
  -y, --yes             Do not ask for confirmation.
  -h, --help            Show this help.

Notes:
  - Invoke this script with sudo. It modifies APT source files under /etc/apt.
  - This script only rewrites Ubuntu archive URLs. It does not remove third-party repositories.
  - It is intended to replace slow or unreliable regional mirrors with official Ubuntu endpoints.
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
    --archive-url) need_value "$1" "${2:-}"; ARCHIVE_MIRROR="$2"; shift 2 ;;
    --security-url) need_value "$1" "${2:-}"; SECURITY_MIRROR="$2"; shift 2 ;;
    --ports-url) need_value "$1" "${2:-}"; PORTS_MIRROR="$2"; shift 2 ;;
    --update) UPDATE_APT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

require_cmds() {
  local missing=0 cmd
  for cmd in awk sed grep cp install date dpkg find sort uniq mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing command: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Install missing commands first, then rerun."
}

normalize_url() {
  local url="${1%/}"
  printf '%s\n' "$url"
}

detect_defaults() {
  local arch
  arch="$(dpkg --print-architecture)"

  if [[ -z "$ARCHIVE_MIRROR" ]]; then
    if [[ "$arch" == amd64 || "$arch" == i386 ]]; then
      ARCHIVE_MIRROR="http://archive.ubuntu.com/ubuntu"
    else
      ARCHIVE_MIRROR="$PORTS_MIRROR"
    fi
  fi

  if [[ -z "$SECURITY_MIRROR" ]]; then
    if [[ "$arch" == amd64 || "$arch" == i386 ]]; then
      SECURITY_MIRROR="http://security.ubuntu.com/ubuntu"
    else
      SECURITY_MIRROR="$PORTS_MIRROR"
    fi
  fi

  ARCHIVE_MIRROR="$(normalize_url "$ARCHIVE_MIRROR")"
  SECURITY_MIRROR="$(normalize_url "$SECURITY_MIRROR")"
  PORTS_MIRROR="$(normalize_url "$PORTS_MIRROR")"
}

collect_source_files() {
  local file
  [[ -f "$SOURCES_LIST" ]] && printf '%s\n' "$SOURCES_LIST"
  if [[ -d "$SOURCES_DIR" ]]; then
    while IFS= read -r file; do
      printf '%s\n' "$file"
    done < <(find "$SOURCES_DIR" -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) | sort)
  fi
}

collect_current_ubuntu_urls() {
  local file tmp
  tmp="$(mktemp)"

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    awk '
      /^[[:space:]]*deb([[:space:]]|\[)/ {
        for (i = 1; i <= NF; ++i) {
          if ($i ~ /^(http|https|ftp):\/\//) {
            print $i
            break
          }
        }
      }

      /^[[:space:]]*URIs:[[:space:]]*/ {
        values = substr($0, index($0, ":") + 1)
        gsub(/^[[:space:]]+/, "", values)
        n = split(values, parts, /[[:space:]]+/)
        for (i = 1; i <= n; ++i) {
          if (parts[i] ~ /^(http|https|ftp):\/\//) {
            print parts[i]
          }
        }
      }
    ' "$file" >> "$tmp"
  done < <(collect_source_files)

  CURRENT_UBUNTU_URLS="$(
    grep -E 'ubuntu|ubuntu-ports' "$tmp" 2>/dev/null \
    | sed 's#/$##' \
    | sort -u \
    || true
  )"
  rm -f "$tmp"
}

confirm_if_needed() {
  [[ "$YES" -eq 1 || "$DRY_RUN" -eq 1 ]] && return 0

  printf 'Detected current Ubuntu APT source URLs:\n'
  if [[ -n "$CURRENT_UBUNTU_URLS" ]]; then
    while IFS= read -r url; do
      [[ -n "$url" ]] || continue
      printf '  - %s\n' "$url"
    done <<< "$CURRENT_UBUNTU_URLS"
  else
    printf '  - none detected\n'
  fi

  cat <<EOF
Proposed replacement target URLs:
  - $ARCHIVE_MIRROR
  - $SECURITY_MIRROR
  - $PORTS_MIRROR

This will back up each modified APT source file before changing it.
EOF
  printf 'Additional actions:\n'
  printf '  - apt-get update: %s\n' "$([[ "$UPDATE_APT" -eq 1 ]] && echo yes || echo no)"
  read -r -p "Update the detected Ubuntu APT source URLs to these targets? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Cancelled."
}

backup_path_for() {
  local path="$1"
  local rel
  rel="${path#/}"
  printf '%s/%s\n' "$BACKUP_ROOT" "$rel"
}

rewrite_list_file() {
  local file="$1" tmp changed=0
  tmp="$(mktemp)"

  awk -v archive="$ARCHIVE_MIRROR" -v security="$SECURITY_MIRROR" -v ports="$PORTS_MIRROR" '
    function map_url(url) {
      if (url ~ /security\.ubuntu\.com\/ubuntu\/?$/) return security
      if (url ~ /archive\.ubuntu\.com\/ubuntu\/?$/) return archive
      if (url ~ /ports\.ubuntu\.com\/ubuntu-ports\/?$/) return ports
      if (url ~ /[.]ubuntu[.]com\/ubuntu\/?$/) return archive
      if (url ~ /ubuntu-ports\/?$/) return ports
      return archive
    }

    /^[[:space:]]*deb([[:space:]]|\[)/ {
      for (i = 1; i <= NF; ++i) {
        if ($i ~ /^(http|https|ftp):\/\//) {
          old = $i
          new = map_url($i)
          if (new != old) {
            $i = new
            changed = 1
          }
          break
        }
      }
    }

    { print }

    END { exit(changed ? 10 : 0) }
  ' "$file" > "$tmp" || changed=$?

  case "$changed" in
    0)
      rm -f "$tmp"
      return 1
      ;;
    10)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Would rewrite $file"
        rm -f "$tmp"
      else
        run install -d -m 0755 "$(dirname "$(backup_path_for "$file")")"
        run cp -a "$file" "$(backup_path_for "$file")"
        run install -m 0644 "$tmp" "$file"
        rm -f "$tmp"
      fi
      return 0
      ;;
    *)
      rm -f "$tmp"
      die "Failed to rewrite $file"
      ;;
  esac
}

rewrite_sources_file() {
  local file="$1" tmp changed=0
  tmp="$(mktemp)"

  awk -v archive="$ARCHIVE_MIRROR" -v security="$SECURITY_MIRROR" -v ports="$PORTS_MIRROR" '
    function map_url(url) {
      if (url ~ /security\.ubuntu\.com\/ubuntu\/?$/) return security
      if (url ~ /archive\.ubuntu\.com\/ubuntu\/?$/) return archive
      if (url ~ /ports\.ubuntu\.com\/ubuntu-ports\/?$/) return ports
      if (url ~ /[.]ubuntu[.]com\/ubuntu\/?$/) return archive
      if (url ~ /ubuntu-ports\/?$/) return ports
      return archive
    }

    /^[[:space:]]*URIs:[[:space:]]*/ {
      prefix = substr($0, 1, index($0, ":"))
      values = substr($0, index($0, ":") + 1)
      gsub(/^[[:space:]]+/, "", values)
      n = split(values, parts, /[[:space:]]+/)
      out = prefix
      for (i = 1; i <= n; ++i) {
        old = parts[i]
        new = parts[i]
        if (old ~ /^(http|https|ftp):\/\//) {
          new = map_url(old)
        }
        if (new != old) changed = 1
        out = out " " new
      }
      print out
      next
    }

    { print }

    END { exit(changed ? 10 : 0) }
  ' "$file" > "$tmp" || changed=$?

  case "$changed" in
    0)
      rm -f "$tmp"
      return 1
      ;;
    10)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Would rewrite $file"
        rm -f "$tmp"
      else
        run install -d -m 0755 "$(dirname "$(backup_path_for "$file")")"
        run cp -a "$file" "$(backup_path_for "$file")"
        run install -m 0644 "$tmp" "$file"
        rm -f "$tmp"
      fi
      return 0
      ;;
    *)
      rm -f "$tmp"
      die "Failed to rewrite $file"
      ;;
  esac
}

process_source_file() {
  local file="$1"
  case "$file" in
    *.list) rewrite_list_file "$file" ;;
    *.sources) rewrite_sources_file "$file" ;;
    *) return 1 ;;
  esac
}

rewrite_sources() {
  local file changed_count=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if process_source_file "$file"; then
      changed_count=$((changed_count + 1))
    fi
  done < <(collect_source_files)

  if [[ "$changed_count" -eq 0 ]]; then
    warn "No Ubuntu APT source URLs needed rewriting."
  else
    log "Updated $changed_count APT source file(s)."
  fi
}

run_apt_update_if_requested() {
  [[ "$UPDATE_APT" -eq 1 ]] || return 0
  log "Running apt-get update"
  run apt-get update
}

print_next_steps() {
  cat <<EOF

APT mirror rewrite completed.

Selected mirrors:
  standard archive:  $ARCHIVE_MIRROR
  security archive:  $SECURITY_MIRROR
  ports archive:     $PORTS_MIRROR

Backup root:
  $BACKUP_ROOT

Useful commands:
  grep -RIn 'archive.ubuntu.com\\|security.ubuntu.com\\|ports.ubuntu.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null
  sudo apt-get update
EOF
}

main() {
  require_cmds
  detect_defaults
  collect_current_ubuntu_urls
  confirm_if_needed
  if [[ "$DRY_RUN" -eq 0 ]]; then
    BACKUP_ROOT="${BACKUP_ROOT}/$(date +%Y%m%d%H%M%S)"
  fi
  rewrite_sources
  run_apt_update_if_requested
  print_next_steps
}

main "$@"
