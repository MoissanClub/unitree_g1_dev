#!/usr/bin/env bash
# Shared loader for the repo's PC2 hardware profile. Source this file; do not execute it.

_g1_loader_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G1_HARDWARE_CONFIG_FILE="${G1_HARDWARE_CONFIG_FILE:-${_g1_loader_dir}/g1_pc2_hardware.env}"

if [[ ! -r "${G1_HARDWARE_CONFIG_FILE}" ]]; then
  printf '[ERROR] Missing PC2 hardware config: %s\n' "${G1_HARDWARE_CONFIG_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "${G1_HARDWARE_CONFIG_FILE}"
if [[ "${G1_HARDWARE_CONFIGURED:-0}" != "1" ]]; then
  printf '[ERROR] Populate %s and set G1_HARDWARE_CONFIGURED=1 first.\n' "${G1_HARDWARE_CONFIG_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi

_g1_required=(
  G1_ROBOT_IP G1_PC2_WIRED_CIDR G1_DDS_IFACE G1_WIFI_IFACE
  G1_BRAINCO_LEFT_PORT G1_BRAINCO_RIGHT_PORT G1_BRAINCO_FTDI_SERIAL
  G1_HEAD_CAMERA_BACKEND G1_LIDAR_IP G1_LIDAR_TOPIC G1_LIDAR_FRAME
  G1_ROS_DISTRO G1_ROBOT_DOF G1_UNITREE_ROS2_DIR G1_UNITREE_SDK2_DIR
)
for _g1_name in "${_g1_required[@]}"; do
  if [[ -z "${!_g1_name-}" ]]; then
    printf '[ERROR] Required value %s is empty in %s.\n' "${_g1_name}" "${G1_HARDWARE_CONFIG_FILE}" >&2
    return 1 2>/dev/null || exit 1
  fi
done

case "${G1_HEAD_CAMERA_BACKEND}" in
  opencv|uvc)
    if [[ -z "${G1_HEAD_CAMERA_VIDEO_ID:-}" && -z "${G1_HEAD_CAMERA_PHYSICAL_PATH:-}" ]]; then
      printf '[ERROR] Set G1_HEAD_CAMERA_VIDEO_ID or G1_HEAD_CAMERA_PHYSICAL_PATH in %s.\n' "${G1_HARDWARE_CONFIG_FILE}" >&2
      return 1 2>/dev/null || exit 1
    fi
    ;;
  realsense)
    if [[ -z "${G1_HEAD_CAMERA_REALSENSE_SERIAL:-}" ]]; then
      printf '[ERROR] RealSense mode requires G1_HEAD_CAMERA_REALSENSE_SERIAL in %s.\n' "${G1_HARDWARE_CONFIG_FILE}" >&2
      return 1 2>/dev/null || exit 1
    fi
    ;;
  *)
    printf '[ERROR] Unsupported G1_HEAD_CAMERA_BACKEND=%s in %s.\n' "${G1_HEAD_CAMERA_BACKEND}" "${G1_HARDWARE_CONFIG_FILE}" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

if [[ "${G1_ROBOT_DOF}" != "23" && "${G1_ROBOT_DOF}" != "29" ]]; then
  printf '[ERROR] G1_ROBOT_DOF must be 23 or 29 in %s.\n' "${G1_HARDWARE_CONFIG_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi

unset _g1_required _g1_name
unset _g1_loader_dir
