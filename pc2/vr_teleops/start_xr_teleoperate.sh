#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common_teleop_env.sh"

usage() {
  cat <<EOF
Usage: $0 [--input-mode hand|controller] [teleop args...]

Options:
  --input-mode MODE         XR tracking mode to use for this launch:
                            hand or controller.
  --hand                    Shortcut for --input-mode hand.
  --controller              Shortcut for --input-mode controller.
  -h, --help                Show this help.

Additional arguments are forwarded to teleop_hand_and_arm.py, including its
recording options: --record, --task-dir, --task-name, --task-goal,
--task-desc, --task-steps. Recording is disabled unless --record is passed.

Example:
  $0 --record --task-name "pick cube" --task-dir ./utils/data/
EOF
}

main() {
  teleop_load_config

  local input_mode="${G1_TELEOP_INPUT_MODE:-controller}"
  local -a teleop_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input-mode)
        [[ $# -ge 2 ]] || teleop_die "--input-mode requires 'hand' or 'controller'."
        input_mode="$2"
        shift 2
        ;;
      --input-mode=*)
        input_mode="${1#*=}"
        shift
        ;;
      --hand)
        input_mode="hand"
        shift
        ;;
      --controller)
        input_mode="controller"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        teleop_args+=("$1")
        shift
        ;;
    esac
  done

  case "${input_mode}" in
    hand|controller) ;;
    *) teleop_die "Unsupported input mode '${input_mode}'. Expected 'hand' or 'controller'." ;;
  esac

  local requested_input_mode="${input_mode}"
  teleop_export_common_env
  export G1_TELEOP_INPUT_MODE="${requested_input_mode}"
  input_mode="${requested_input_mode}"

  [[ -d "${G1_TELEOP_XR_REPO}" ]] || teleop_die "Missing xr_teleoperate checkout at ${G1_TELEOP_XR_REPO}."
  [[ -d "${G1_TELEOP_CYCLONEDDS_HOME}" ]] || teleop_die "Missing CycloneDDS install at ${G1_TELEOP_CYCLONEDDS_HOME}. Run ./setup_pc2_xr_teleop.sh first."

  teleop_activate_env "${G1_TELEOP_CONDA_ENV}"
  export CYCLONEDDS_HOME="${G1_TELEOP_CYCLONEDDS_HOME}"
  teleop_source_unitree_ros2
  # ROS setup prepends its system library directories. Restore the selected
  # CycloneDDS prefix and Conda libraries so the Python binding loads the
  # matching libddsc and Conda's _ssl does not inherit Ubuntu's older OpenSSL.
  export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:${CYCLONEDDS_HOME}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

  local quest_url="https://${G1_TELEOP_IMG_SERVER_IP}:8012/?ws=wss://${G1_TELEOP_IMG_SERVER_IP}:8012"
  teleop_log "Starting xr_teleoperate with DDS interface ${G1_TELEOP_DDS_IFACE}, img-server-ip ${G1_TELEOP_IMG_SERVER_IP}, input mode ${input_mode}, ee ${G1_TELEOP_EE}"
  teleop_log "Open ${quest_url} in the Quest browser after the server starts."

  cd "${G1_TELEOP_XR_REPO}/teleop"
  exec python teleop_hand_and_arm.py \
    --input-mode "${input_mode}" \
    --arm "${G1_TELEOP_ARM}" \
    --ee "${G1_TELEOP_EE}" \
    --network-interface "${G1_TELEOP_DDS_IFACE}" \
    --img-server-ip "${G1_TELEOP_IMG_SERVER_IP}" \
    --display-mode "${G1_TELEOP_DISPLAY_MODE}" \
    "${teleop_args[@]}"
}

main "$@"
