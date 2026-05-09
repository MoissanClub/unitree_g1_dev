#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common_teleop_env.sh"

teleop_export_common_env

find_brainco_binary() {
  local candidates=(
    "${G1_TELEOP_BRAINCO_SERVICE_DIR}/bin/brainco_hand_server"
    "${G1_TELEOP_BRAINCO_SERVICE_DIR}/build/bin/brainco_hand_server"
    "${G1_TELEOP_BRAINCO_SERVICE_DIR}/build/brainco_hand_server"
  )
  local candidate=""
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

main() {
  local server_bin=""
  server_bin="$(find_brainco_binary)" || teleop_die "brainco_hand_server was not found. Run ./setup_pc2_xr_teleop.sh first."
  teleop_log "Starting brainco_hand_server on DDS interface ${G1_TELEOP_DDS_IFACE}"
  exec sudo "${server_bin}" -n "${G1_TELEOP_DDS_IFACE}" "$@"
}

main "$@"
