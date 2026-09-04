#!/usr/bin/env bash

set -Eeuo pipefail

TELEOP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${TELEOP_SCRIPT_DIR}/../load_g1_pc2_hardware.sh"
TELEOP_CONFIG_FILE="${HOME}/.config/xr_teleoperate/pc2_teleop.env"

teleop_log() {
  printf '\033[1;34m[teleop]\033[0m %s\n' "$*" >&2
}

teleop_warn() {
  printf '\033[1;33m[teleop][warn]\033[0m %s\n' "$*" >&2
}

teleop_die() {
  printf '\033[1;31m[teleop][error]\033[0m %s\n' "$*" >&2
  exit 1
}

teleop_load_config() {
  if [[ -f "${TELEOP_CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${TELEOP_CONFIG_FILE}"
  fi
}

teleop_detect_dds_iface() {
  if [[ -n "${G1_TELEOP_DDS_IFACE:-}" ]]; then
    printf '%s\n' "${G1_TELEOP_DDS_IFACE}"
    return 0
  fi

  local robot_ip="${UNITREE_ROBOT_IP:-${G1_ROBOT_IP}}"
  local iface=""
  iface="$(ip route get "${robot_ip}" 2>/dev/null | awk '/dev/ {for (i = 1; i <= NF; ++i) if ($i == "dev") {print $(i + 1); exit}}')"
  if [[ -n "${iface}" ]]; then
    printf '%s\n' "${iface}"
    return 0
  fi

  iface="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')"
  [[ -n "${iface}" ]] || teleop_die "Unable to detect a DDS network interface."
  printf '%s\n' "${iface}"
}

teleop_detect_wifi_iface() {
  if [[ -n "${G1_TELEOP_WIFI_IFACE:-}" ]]; then
    printf '%s\n' "${G1_TELEOP_WIFI_IFACE}"
    return 0
  fi

  local iface=""
  iface="$(ip route show default 2>/dev/null | awk '/default/ {for (i = 1; i <= NF; ++i) if ($i == "dev") {print $(i + 1); exit}}')"
  if [[ -n "${iface}" ]]; then
    printf '%s\n' "${iface}"
    return 0
  fi

  iface="$(ip -4 -o addr show scope global 2>/dev/null | awk '$4 !~ /^192\.168\.123\./ {print $2; exit}')"
  [[ -n "${iface}" ]] || teleop_die "Unable to detect a Wi-Fi or default-route interface."
  printf '%s\n' "${iface}"
}

teleop_iface_ipv4() {
  local iface="$1"
  ip -4 -o addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

teleop_detect_img_server_ip() {
  if [[ -n "${G1_TELEOP_IMG_SERVER_IP:-}" ]]; then
    printf '%s\n' "${G1_TELEOP_IMG_SERVER_IP}"
    return 0
  fi

  local wifi_iface
  wifi_iface="$(teleop_detect_wifi_iface)"
  local ip_addr=""
  ip_addr="$(teleop_iface_ipv4 "${wifi_iface}")"
  [[ -n "${ip_addr}" ]] || teleop_die "Unable to find an IPv4 address on ${wifi_iface}."
  printf '%s\n' "${ip_addr}"
}

teleop_source_conda() {
  local conda_sh=""

  if command -v conda >/dev/null 2>&1; then
    local conda_base=""
    conda_base="$(conda info --base 2>/dev/null || true)"
    if [[ -n "${conda_base}" && -f "${conda_base}/etc/profile.d/conda.sh" ]]; then
      conda_sh="${conda_base}/etc/profile.d/conda.sh"
    fi
  fi

  if [[ -z "${conda_sh}" && -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
    conda_sh="${HOME}/miniconda3/etc/profile.d/conda.sh"
  fi

  if [[ -z "${conda_sh}" && -f "${HOME}/miniforge3/etc/profile.d/conda.sh" ]]; then
    conda_sh="${HOME}/miniforge3/etc/profile.d/conda.sh"
  fi

  if [[ -z "${conda_sh}" && -f "${HOME}/mambaforge/etc/profile.d/conda.sh" ]]; then
    conda_sh="${HOME}/mambaforge/etc/profile.d/conda.sh"
  fi

  if [[ -z "${conda_sh}" && -f "${HOME}/anaconda3/etc/profile.d/conda.sh" ]]; then
    conda_sh="${HOME}/anaconda3/etc/profile.d/conda.sh"
  fi

  [[ -n "${conda_sh}" ]] || teleop_die "Conda was not found. Run ./setup_pc2_xr_teleop.sh first."

  # shellcheck disable=SC1090
  source "${conda_sh}"
}

teleop_activate_env() {
  local env_name="${1:-${G1_TELEOP_CONDA_ENV:-tv}}"
  teleop_source_conda
  conda activate "${env_name}" >/dev/null 2>&1 || teleop_die "Failed to activate conda env '${env_name}'."
}

teleop_source_unitree_ros2() {
  local setup_file="${G1_TELEOP_UNITREE_SETUP:-${HOME}/unitree_ros2/setup.sh}"
  [[ -f "${setup_file}" ]] || teleop_die "Missing Unitree ROS2 setup at ${setup_file}. Run ./setup_pc2_xr_teleop.sh first."

  local restore_nounset=0
  case "$-" in
    *u*) restore_nounset=1; set +u ;;
  esac

  # shellcheck disable=SC1090
  source "${setup_file}"

  if [[ "${restore_nounset}" -eq 1 ]]; then
    set -u
  fi
}

teleop_export_common_env() {
  teleop_load_config

  export G1_TELEOP_CONDA_ENV="${G1_TELEOP_CONDA_ENV:-tv}"
  export G1_TELEOP_XR_REPO="${G1_TELEOP_XR_REPO:-${HOME}/xr_teleoperate}"
  export G1_TELEOP_BRAINCO_SERVICE_DIR="${G1_TELEOP_BRAINCO_SERVICE_DIR:-${HOME}/brainco_hand_service}"
  export G1_TELEOP_SDK2_DIR="${G1_TELEOP_SDK2_DIR:-${G1_UNITREE_SDK2_DIR:-${HOME}/unitree_sdk2}}"
  export G1_TELEOP_ARM="${G1_TELEOP_ARM:-G1_29}"
  export G1_TELEOP_INPUT_MODE="${G1_TELEOP_INPUT_MODE:-controller}"
  export G1_TELEOP_EE="${G1_TELEOP_EE:-brainco}"
  export G1_TELEOP_DISPLAY_MODE="${G1_TELEOP_DISPLAY_MODE:-ego}"
  export G1_TELEIMAGER_VIDEO_ID="${G1_TELEIMAGER_VIDEO_ID:-${G1_HEAD_CAMERA_VIDEO_ID}}"
  export G1_TELEIMAGER_CAMERA_BACKEND="${G1_TELEIMAGER_CAMERA_BACKEND:-${G1_HEAD_CAMERA_BACKEND}}"
  export G1_TELEIMAGER_REALSENSE_SERIAL="${G1_TELEIMAGER_REALSENSE_SERIAL:-${G1_HEAD_CAMERA_REALSENSE_SERIAL}}"
  export G1_TELEIMAGER_PHYSICAL_PATH="${G1_TELEIMAGER_PHYSICAL_PATH:-${G1_HEAD_CAMERA_PHYSICAL_PATH}}"
  export G1_TELEOP_DDS_IFACE="${G1_TELEOP_DDS_IFACE:-${G1_DDS_IFACE:-$(teleop_detect_dds_iface)}}"
  export G1_TELEOP_WIFI_IFACE="${G1_TELEOP_WIFI_IFACE:-${G1_WIFI_IFACE:-$(teleop_detect_wifi_iface)}}"
  export G1_TELEOP_IMG_SERVER_IP="${G1_TELEOP_IMG_SERVER_IP:-$(teleop_detect_img_server_ip)}"
  export G1_TELEOP_UNITREE_SETUP="${G1_TELEOP_UNITREE_SETUP:-${HOME}/unitree_ros2/setup.sh}"
  export G1_TELEOP_CYCLONEDDS_HOME="${G1_TELEOP_CYCLONEDDS_HOME:-${HOME}/unitree_ros2/cyclonedds_ws/install/cyclonedds}"

  case "${G1_TELEOP_INPUT_MODE}" in
    hand|controller) ;;
    *) teleop_die "Unsupported G1_TELEOP_INPUT_MODE='${G1_TELEOP_INPUT_MODE}'. Expected 'hand' or 'controller'." ;;
  esac

  case "${G1_TELEOP_EE}" in
    dex1|dex3|inspire_ftp|inspire_dfx|brainco) ;;
    *) teleop_die "Unsupported G1_TELEOP_EE='${G1_TELEOP_EE}'." ;;
  esac

  case "${G1_TELEIMAGER_CAMERA_BACKEND}" in
    opencv|realsense|uvc) ;;
    *) teleop_die "Unsupported G1_TELEIMAGER_CAMERA_BACKEND='${G1_TELEIMAGER_CAMERA_BACKEND}'. Expected 'realsense', 'uvc', or 'opencv'." ;;
  esac
}
