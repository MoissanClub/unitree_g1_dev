#!/usr/bin/env bash
# g1_pc2_apt_sources.sh
# Replace the USTC Ubuntu mirror in /etc/apt/sources.list with ports.ubuntu.com.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SOURCES_LIST="/etc/apt/sources.list"
OLD_HOST="mirrors.ustc.edu.cn"
NEW_HOST="ports.ubuntu.com"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./g1_pc2_apt_sources.sh [--dry-run]

What it does:
  - Replaces mirrors.ustc.edu.cn with ports.ubuntu.com in /etc/apt/sources.list

Options:
  --dry-run  Print the sed command instead of modifying the file.
  -h, --help Show this help.
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
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; printf "ERROR: %s failed near line %s, exit %s\n" "$SCRIPT_NAME" "$LINENO" "$rc" >&2; exit "$rc"' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

command -v sed >/dev/null 2>&1 || die "sed is required"
[[ -f "$SOURCES_LIST" ]] || die "Missing file: $SOURCES_LIST"

if ! grep -q "$OLD_HOST" "$SOURCES_LIST"; then
  log "No occurrences of $OLD_HOST found in $SOURCES_LIST. Nothing to change."
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf "+ sed -i 's|%s|%s|g' %s\n" "$OLD_HOST" "$NEW_HOST" "$SOURCES_LIST"
  exit 0
fi

log "Replacing $OLD_HOST with $NEW_HOST in $SOURCES_LIST"
sed -i "s|$OLD_HOST|$NEW_HOST|g" "$SOURCES_LIST"
log "Done."
