#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common_teleop_env.sh"

teleop_export_common_env

main() {
  local cert_path="${HOME}/.config/xr_teleoperate/cert.pem"
  local key_path="${HOME}/.config/xr_teleoperate/key.pem"

  [[ -f "${cert_path}" && -f "${key_path}" ]] || teleop_die "Missing TLS certs under ~/.config/xr_teleoperate. Run ./setup_pc2_xr_teleop.sh first."
  [[ -d "${G1_TELEOP_XR_REPO}" ]] || teleop_die "Missing xr_teleoperate checkout at ${G1_TELEOP_XR_REPO}."

  teleop_activate_env "${G1_TELEOP_CONDA_ENV}"
  teleop_log "Serving teleimager from ${G1_TELEOP_XR_REPO}; browser URL will be https://${G1_TELEOP_IMG_SERVER_IP}:60001"
  cd "${G1_TELEOP_XR_REPO}/teleop/teleimager"
  exec teleimager-server "$@"
}

main "$@"
