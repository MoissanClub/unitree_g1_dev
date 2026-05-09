#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common_teleop_env.sh"

teleop_export_common_env

main() {
  [[ -d "${G1_TELEOP_XR_REPO}" ]] || teleop_die "Missing xr_teleoperate checkout at ${G1_TELEOP_XR_REPO}."
  [[ -d "${G1_TELEOP_CYCLONEDDS_HOME}" ]] || teleop_die "Missing CycloneDDS install at ${G1_TELEOP_CYCLONEDDS_HOME}. Run ./setup_pc2_xr_teleop.sh first."

  teleop_activate_env "${G1_TELEOP_CONDA_ENV}"
  export CYCLONEDDS_HOME="${G1_TELEOP_CYCLONEDDS_HOME}"
  teleop_source_unitree_ros2

  local quest_url="https://${G1_TELEOP_IMG_SERVER_IP}:8012/?ws=wss://${G1_TELEOP_IMG_SERVER_IP}:8012"
  teleop_log "Starting xr_teleoperate with DDS interface ${G1_TELEOP_DDS_IFACE} and img-server-ip ${G1_TELEOP_IMG_SERVER_IP}"
  teleop_log "Open ${quest_url} in the Quest browser after the server starts."

  cd "${G1_TELEOP_XR_REPO}/teleop"
  exec python teleop_hand_and_arm.py \
    --input-mode controller \
    --arm "${G1_TELEOP_ARM}" \
    --ee brainco \
    --network-interface "${G1_TELEOP_DDS_IFACE}" \
    --img-server-ip "${G1_TELEOP_IMG_SERVER_IP}" \
    --display-mode "${G1_TELEOP_DISPLAY_MODE}" \
    "$@"
}

main "$@"
