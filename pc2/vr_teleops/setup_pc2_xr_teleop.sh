#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC2_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${PC2_DIR}/load_g1_pc2_hardware.sh"

DEFAULT_CONDA_ENV="${G1_XR_CONDA_ENV}"
DEFAULT_XR_REPO="${G1_XR_REPO_DIR}"
DEFAULT_BRAINCO_SERVICE_DIR="${HOME}/brainco_hand_service"
DEFAULT_SDK2_DIR="${HOME}/unitree_sdk2"
DEFAULT_SDK2_PY_DIR="${HOME}/unitree_sdk2_python"
DEFAULT_UNITREE_ROS2_DIR="${G1_UNITREE_ROS2_DIR}"
DEFAULT_CONFIG_DIR="${HOME}/.config/xr_teleoperate"
TELEIMAGER_PATCH="${SCRIPT_DIR}/patches/teleimager-jetson-realsense.patch"
TELEIMAGER_UVC_PATCH="${SCRIPT_DIR}/patches/teleimager-uvc-reload-race.patch"
DEFAULT_DDS_IFACE="${G1_DDS_IFACE}"
DEFAULT_WIFI_IFACE="${G1_WIFI_IFACE}"
DEFAULT_VIDEO_ID="${G1_HEAD_CAMERA_VIDEO_ID}"
DEFAULT_CAMERA_BACKEND="${G1_HEAD_CAMERA_BACKEND}"
DEFAULT_REALSENSE_SERIAL="${G1_HEAD_CAMERA_REALSENSE_SERIAL}"
DEFAULT_ARM="G1_29"
DEFAULT_INPUT_MODE="controller"
DEFAULT_EE="brainco"

OS_ID="unknown"
OS_VERSION="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
fi
SYSTEM_ARCH="$(uname -m)"
BUILD_TAG="${OS_ID}-${OS_VERSION}-${SYSTEM_ARCH}"
BUILD_TAG="${BUILD_TAG//[^A-Za-z0-9._-]/_}"

CONDA_ENV="${DEFAULT_CONDA_ENV}"
XR_REPO_DIR="${DEFAULT_XR_REPO}"
BRAINCO_SERVICE_DIR="${DEFAULT_BRAINCO_SERVICE_DIR}"
SDK2_DIR="${DEFAULT_SDK2_DIR}"
SDK2_PY_DIR="${DEFAULT_SDK2_PY_DIR}"
UNITREE_ROS2_DIR="${DEFAULT_UNITREE_ROS2_DIR}"
CONFIG_DIR="${DEFAULT_CONFIG_DIR}"
DDS_IFACE="${DEFAULT_DDS_IFACE}"
WIFI_IFACE="${DEFAULT_WIFI_IFACE}"
VIDEO_ID="${DEFAULT_VIDEO_ID}"
CAMERA_BACKEND="${DEFAULT_CAMERA_BACKEND}"
REALSENSE_SERIAL="${DEFAULT_REALSENSE_SERIAL}"
ARM_MODEL="${DEFAULT_ARM}"
INPUT_MODE="${DEFAULT_INPUT_MODE}"
EE_TYPE="${DEFAULT_EE}"
SKIP_APT=0
SKIP_DDS=0
SKIP_BRAINCO_SERVICE=0
SKIP_VERIFY=0
RELEASE_UNITREE_CAMERA=0
NO_PULL=0

log() {
  printf '\033[1;34m[setup]\033[0m %s\n' "$*" >&2
}

warn() {
  printf '\033[1;33m[setup][warn]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[setup][error]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 [options]

This script follows TELE_OP.md for PC2, but reuses the existing local
../setup_unitree_g1_pc2_dds.sh instead of rebuilding that logic here.

Options:
  --dds-iface IFACE         DDS interface for robot traffic. Default: auto-detect.
  --wifi-iface IFACE        Interface whose IPv4 should be advertised to Quest. Default: default route.
  --camera-backend TYPE     teleimager camera backend: opencv or realsense. Default: ${DEFAULT_CAMERA_BACKEND}
  --video-id N              OpenCV head_camera video_id. Default: auto-detect, else 2.
  --realsense-serial SERIAL RealSense serial_number from 'teleimager-server --cf --rs'. Default: auto-detect when possible.
  --arm G1_23|G1_29         Arm model used by xr_teleoperate. Default: ${DEFAULT_ARM}
  --input-mode MODE         XR tracking mode: hand or controller. Default: ${DEFAULT_INPUT_MODE}
  --ee TYPE                 End effector: dex1, dex3, inspire_ftp, inspire_dfx, brainco. Default: ${DEFAULT_EE}
  --conda-env NAME          Conda env name. Default: ${DEFAULT_CONDA_ENV}
  --xr-repo DIR             xr_teleoperate checkout path. Default: ${DEFAULT_XR_REPO}
  --brainco-dir DIR         brainco_hand_service checkout path. Default: ${DEFAULT_BRAINCO_SERVICE_DIR}
  --sdk2-dir DIR            unitree_sdk2 checkout path. Default: ${DEFAULT_SDK2_DIR}
  --sdk2-python-dir DIR     unitree_sdk2_python checkout path. Default: ${DEFAULT_SDK2_PY_DIR}
  --skip-apt                Do not apt-install packages.
  --skip-dds                Do not call ../setup_unitree_g1_pc2_dds.sh.
  --skip-brainco-service    Do not clone/build brainco_hand_service.
  --no-verify               Skip post-install import and native-linkage checks.
  --release-unitree-camera  Stop/remove Unitree video_hub_pc4 services that can hold the RealSense camera.
  --no-pull                 Do not git pull existing repositories.
  -h, --help                Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dds-iface) DDS_IFACE="$2"; shift 2 ;;
    --wifi-iface) WIFI_IFACE="$2"; shift 2 ;;
    --camera-backend) CAMERA_BACKEND="$2"; shift 2 ;;
    --video-id) VIDEO_ID="$2"; shift 2 ;;
    --realsense-serial) REALSENSE_SERIAL="$2"; shift 2 ;;
    --arm) ARM_MODEL="$2"; shift 2 ;;
    --input-mode) INPUT_MODE="$2"; shift 2 ;;
    --ee) EE_TYPE="$2"; shift 2 ;;
    --conda-env) CONDA_ENV="$2"; shift 2 ;;
    --xr-repo) XR_REPO_DIR="$2"; shift 2 ;;
    --brainco-dir) BRAINCO_SERVICE_DIR="$2"; shift 2 ;;
    --sdk2-dir) SDK2_DIR="$2"; shift 2 ;;
    --sdk2-python-dir) SDK2_PY_DIR="$2"; shift 2 ;;
    --skip-apt) SKIP_APT=1; shift ;;
    --skip-dds) SKIP_DDS=1; shift ;;
    --skip-brainco-service) SKIP_BRAINCO_SERVICE=1; shift ;;
    --no-verify) SKIP_VERIFY=1; shift ;;
    --release-unitree-camera) RELEASE_UNITREE_CAMERA=1; shift ;;
    --no-pull) NO_PULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "${CAMERA_BACKEND}" == "opencv" || "${CAMERA_BACKEND}" == "realsense" ]] || die "--camera-backend must be opencv or realsense"
[[ "${ARM_MODEL}" == "G1_23" || "${ARM_MODEL}" == "G1_29" ]] || die "--arm must be G1_23 or G1_29"
[[ "${INPUT_MODE}" == "hand" || "${INPUT_MODE}" == "controller" ]] || die "--input-mode must be hand or controller"
case "${EE_TYPE}" in
  dex1|dex3|inspire_ftp|inspire_dfx|brainco) ;;
  *) die "--ee must be one of dex1, dex3, inspire_ftp, inspire_dfx, brainco" ;;
esac

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

run() {
  log "Running: $*"
  "$@"
}

git_update() {
  local repo_dir="$1"
  if [[ "${NO_PULL}" -eq 0 ]]; then
    run git -C "${repo_dir}" pull --ff-only || warn "git pull failed in ${repo_dir}; continuing with existing checkout."
  fi
}

ensure_repo() {
  local url="$1"
  local dir="$2"

  if [[ -d "${dir}/.git" ]]; then
    log "Using existing checkout at ${dir}"
    git_update "${dir}"
    return 0
  fi

  log "Cloning ${url} into ${dir}"
  run git clone --depth 1 "${url}" "${dir}"
}

detect_iface_for_ip() {
  local ip_target="$1"
  ip route get "${ip_target}" 2>/dev/null | awk '/dev/ {for (i = 1; i <= NF; ++i) if ($i == "dev") {print $(i + 1); exit}}'
}

default_route_iface() {
  ip route show default 2>/dev/null | awk '/default/ {for (i = 1; i <= NF; ++i) if ($i == "dev") {print $(i + 1); exit}}'
}

iface_ipv4() {
  local iface="$1"
  ip -4 -o addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

detect_realsense_video_id() {
  local candidate=""
  if [[ -n "${VIDEO_ID}" ]] && video_id_supports_rgb "${VIDEO_ID}"; then
    printf '%s\n' "${VIDEO_ID}"
    return 0
  fi

  if [[ -n "${VIDEO_ID}" ]]; then
    warn "/dev/video${VIDEO_ID} is not an RGB-capable endpoint; detecting the RealSense color stream."
  fi

  if [[ -d "${XR_REPO_DIR}/teleop/teleimager" ]]; then
    local teleimager_output=""
    local detected_id=""
    teleimager_output="$(run_in_conda teleimager-server --cf 2>&1 || true)"
    detected_id="$(printf '%s\n' "${teleimager_output}" | sed -n "s/.*Found RGB video devices: \['\/dev\/video\([0-9]\+\)'.*/\1/p" | head -n1)"
    if [[ -n "${detected_id}" ]] && video_id_supports_rgb "${detected_id}"; then
      printf '%s\n' "${detected_id}"
      return 0
    fi
  fi

  if compgen -G "/dev/v4l/by-id/*RealSense*index0*" >/dev/null; then
    local dev_path=""
    dev_path="$(readlink -f /dev/v4l/by-id/*RealSense*index0* 2>/dev/null | head -n1 || true)"
    if [[ "${dev_path}" =~ /dev/video([0-9]+) ]] && video_id_supports_rgb "${BASH_REMATCH[1]}"; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  if command -v v4l2-ctl >/dev/null 2>&1; then
    for candidate in /dev/video*; do
      [[ -e "${candidate}" ]] || continue
      if video_id_supports_rgb "${candidate#/dev/video}"; then
        printf '%s\n' "${candidate#/dev/video}"
        return 0
      fi
    done
  fi

  die "No RGB-capable V4L2 camera endpoint was found. Check camera permissions and run v4l2-ctl --list-devices."
}

video_id_supports_rgb() {
  local video_id="$1"
  command -v v4l2-ctl >/dev/null 2>&1 || return 1
  v4l2-ctl -d "/dev/video${video_id}" --list-formats-ext 2>/dev/null | \
    grep -Eq "'(MJPG|JPEG|MPEG|YUYV|RGB[0-9]*|BGR[0-9]*)'"
}

detect_realsense_serial() {
  if [[ -n "${REALSENSE_SERIAL}" ]]; then
    printf '%s\n' "${REALSENSE_SERIAL}"
    return 0
  fi

  if [[ -d "${XR_REPO_DIR}/teleop/teleimager" ]]; then
    local teleimager_output=""
    local detected_serial=""
    teleimager_output="$(run_in_conda teleimager-server --cf --rs 2>&1 || true)"
    detected_serial="$(printf '%s\n' "${teleimager_output}" | sed -n 's/.*serial[^0-9]*\([0-9][0-9]*\).*/\1/ip' | head -n1)"
    if [[ -n "${detected_serial}" ]]; then
      printf '%s\n' "${detected_serial}"
      return 0
    fi
  fi

  local usb_dir=""
  local vendor=""
  local product=""
  local detected_serial=""

  for usb_dir in /sys/bus/usb/devices/*; do
    [[ -r "${usb_dir}/idVendor" && -r "${usb_dir}/product" && -r "${usb_dir}/serial" ]] || continue
    vendor="$(<"${usb_dir}/idVendor")"
    [[ "${vendor,,}" == "8086" ]] || continue
    product="$(<"${usb_dir}/product")"
    [[ "${product,,}" == *realsense* ]] || continue
    detected_serial="$(<"${usb_dir}/serial")"
    if [[ -n "${detected_serial}" ]]; then
      printf '%s\n' "${detected_serial}"
      return 0
    fi
  done

  return 1
}

install_apt_deps() {
  [[ "${SKIP_APT}" -eq 1 ]] && return 0

  log "Installing apt dependencies needed by TELE_OP.md..."
  run sudo apt-get update
  run sudo apt-get install -y \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    git \
    libboost-program-options-dev \
    libfmt-dev \
    libspdlog-dev \
    libyaml-cpp-dev \
    openssl \
    pkg-config \
    python3-pip \
    v4l-utils
}

ensure_camera_access() {
  local login_user="${SUDO_USER:-${USER:-$(id -un)}}"
  if ! getent group video >/dev/null 2>&1; then
    warn "The system has no 'video' group; camera access must be configured manually."
    return 0
  fi

  # With no username, id reports the groups active in this process. Supplying
  # a username reads the account database, which can already contain a newly
  # added group that the current SSH/login session has not inherited yet.
  if id -nG | tr ' ' '\n' | grep -qx video; then
    return 0
  fi

  if ! id -nG "${login_user}" | tr ' ' '\n' | grep -qx video; then
    log "Adding ${login_user} to the video group for V4L2 camera access"
    run sudo usermod -aG video "${login_user}"
  fi

  die "${login_user} is configured in the video group, but this session has not activated it. Log out completely and reconnect (or reboot), then rerun this installer."
}

ensure_miniconda() {
  if command -v conda >/dev/null 2>&1 || \
     [[ -f "${HOME}/miniforge3/etc/profile.d/conda.sh" ]] || \
     [[ -f "${HOME}/mambaforge/etc/profile.d/conda.sh" ]] || \
     [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]] || \
     [[ -f "${HOME}/anaconda3/etc/profile.d/conda.sh" ]]; then
    return 0
  fi

  local installer="${HOME}/miniconda.sh"
  log "Installing Miniconda into ${HOME}/miniconda3"
  run curl -L https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh -o "${installer}"
  run bash "${installer}" -b -p "${HOME}/miniconda3"
  rm -f "${installer}"
}

source_conda() {
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

  [[ -n "${conda_sh}" ]] || die "Conda was not found after installation."

  # shellcheck disable=SC1090
  source "${conda_sh}"
}

ensure_conda_env() {
  source_conda

  if ! conda env list | awk '{print $1}' | grep -qx "${CONDA_ENV}"; then
    log "Creating conda env '${CONDA_ENV}'..."
    run conda create -n "${CONDA_ENV}" -y pip python=3.10 pinocchio=3.1.0 numpy=1.26.4 nlopt=2.7.1 -c conda-forge
  else
    log "Conda env '${CONDA_ENV}' already exists; ensuring key packages are present."
    run conda install -n "${CONDA_ENV}" -y pip python=3.10 pinocchio=3.1.0 numpy=1.26.4 nlopt=2.7.1 -c conda-forge
  fi
}

run_in_conda() {
  conda run --no-capture-output -n "${CONDA_ENV}" "$@"
}

resolve_cyclonedds_home() {
  local candidate=""
  local -a candidates=(
    "${UNITREE_ROS2_DIR}/cyclonedds_ws/install/cyclonedds"
    "${UNITREE_ROS2_DIR}/cyclonedds_ws/install"
    "/opt/ros/${G1_ROS_DISTRO:-humble}"
  )

  for candidate in "${candidates[@]}"; do
    [[ -d "${candidate}" ]] || continue
    if find "${candidate}" -type f -name CycloneDDSConfig.cmake -print -quit 2>/dev/null | grep -q .; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

prepare_cyclonedds_home() {
  local source_home=""
  source_home="$(resolve_cyclonedds_home)" || return 1

  # cyclonedds-python 0.10.2 expects a standalone CMAKE_INSTALL_PREFIX
  # containing include/, bin/, and lib/libddsc.so. Ubuntu's arm64 ROS packages
  # put the libraries in lib/aarch64-linux-gnu, so expose a stable compatibility
  # prefix without copying or replacing the system installation.
  if [[ -f "${source_home}/lib/libddsc.so" && -d "${source_home}/include" && -d "${source_home}/bin" ]]; then
    printf '%s\n' "${source_home}"
    return 0
  fi

  local ddsc_library=""
  ddsc_library="$(find "${source_home}/lib" -type f -o -type l 2>/dev/null | grep '/libddsc\.so$' | head -n1 || true)"
  [[ -n "${ddsc_library}" && -d "${source_home}/include" && -d "${source_home}/bin" ]] || return 1

  local compat_home="${CONFIG_DIR}/cyclonedds-${BUILD_TAG}"
  mkdir -p "${compat_home}"
  ln -sfn "${source_home}/include" "${compat_home}/include"
  ln -sfn "${source_home}/bin" "${compat_home}/bin"
  ln -sfn "$(dirname "${ddsc_library}")" "${compat_home}/lib"
  printf '%s\n' "${compat_home}"
}

setup_dds() {
  [[ "${SKIP_DDS}" -eq 1 ]] && return 0
  [[ -f "${PC2_DIR}/setup_unitree_g1_pc2_dds.sh" ]] || die "Missing ${PC2_DIR}/setup_unitree_g1_pc2_dds.sh"

  if [[ -z "${DDS_IFACE}" ]]; then
    DDS_IFACE="$(detect_iface_for_ip 192.168.123.161)"
  fi
  [[ -n "${DDS_IFACE}" ]] || die "DDS interface is empty; populate G1_DDS_IFACE in ${G1_HARDWARE_CONFIG_FILE}."

  log "Reusing local DDS installer for interface ${DDS_IFACE}"
  run bash "${PC2_DIR}/setup_unitree_g1_pc2_dds.sh" --iface "${DDS_IFACE}" --yes
}

ensure_unitree_sdk2() {
  local build_dir="${SDK2_DIR}/build-${BUILD_TAG}"
  ensure_repo "https://github.com/unitreerobotics/unitree_sdk2.git" "${SDK2_DIR}"
  log "Building unitree_sdk2 in ${build_dir} (isolated for ${OS_ID} ${OS_VERSION}/${SYSTEM_ARCH})"
  run cmake -S "${SDK2_DIR}" -B "${build_dir}" -DBUILD_EXAMPLES=OFF
  run cmake --build "${build_dir}" -j"$(nproc)"
  run sudo cmake --install "${build_dir}"
}

ensure_unitree_sdk2_python() {
  ensure_repo "https://github.com/unitreerobotics/unitree_sdk2_python.git" "${SDK2_PY_DIR}"
  CYCLONEDDS_HOME="$(prepare_cyclonedds_home)" || die "CycloneDDS was not found in a Python-compatible layout under the Unitree workspace or /opt/ros/${G1_ROS_DISTRO:-humble}. The DDS setup step must succeed before sdk2_python install."
  export CYCLONEDDS_HOME

  log "Installing unitree_sdk2_python into conda env '${CONDA_ENV}' with CycloneDDS at ${CYCLONEDDS_HOME}"
  run_in_conda python -m pip install --upgrade pip
  run_in_conda python -m pip install -e "${SDK2_PY_DIR}"
}

apply_teleimager_patch() {
  local teleimager_dir="${XR_REPO_DIR}/teleop/teleimager"
  local image_server="${teleimager_dir}/src/teleimager/image_server.py"

  [[ -d "${teleimager_dir}/.git" || -f "${teleimager_dir}/.git" ]] || die "Missing teleimager Git checkout at ${teleimager_dir}."
  [[ -f "${image_server}" ]] || die "Missing teleimager image server at ${image_server}."
  [[ -f "${TELEIMAGER_PATCH}" ]] || die "Missing local teleimager patch at ${TELEIMAGER_PATCH}."

  if grep -q 'Skipping UVC driver reload because sudo is unavailable or not setuid' "${image_server}" && \
     grep -q 'RealSense SDK discovery failed' "${image_server}"; then
    log "Local Jetson/RealSense teleimager patch is already applied."
  elif git -C "${teleimager_dir}" apply --check "${TELEIMAGER_PATCH}"; then
    log "Applying local Jetson/RealSense fixes to teleimager"
    run git -C "${teleimager_dir}" apply "${TELEIMAGER_PATCH}"
  elif git -C "${teleimager_dir}" apply --reverse --check "${TELEIMAGER_PATCH}"; then
    log "Local Jetson/RealSense teleimager patch is already applied."
  else
    die "Local teleimager patch does not apply cleanly. Review ${TELEIMAGER_PATCH} against the pinned teleimager revision."
  fi

  [[ -f "${TELEIMAGER_UVC_PATCH}" ]] || die "Missing local teleimager UVC patch at ${TELEIMAGER_UVC_PATCH}."
  if grep -q 'UVC video devices already exist; skipping disruptive driver reload' "${image_server}"; then
    log "Local UVC reload-race fix is already applied."
  elif git -C "${teleimager_dir}" apply --check "${TELEIMAGER_UVC_PATCH}"; then
    log "Applying local UVC reload-race fix to teleimager"
    run git -C "${teleimager_dir}" apply "${TELEIMAGER_UVC_PATCH}"
  elif git -C "${teleimager_dir}" apply --reverse --check "${TELEIMAGER_UVC_PATCH}"; then
    log "Local UVC reload-race fix is already applied."
  else
    die "Local UVC reload-race patch does not apply cleanly. Review ${TELEIMAGER_UVC_PATCH} against the pinned teleimager revision."
  fi
}

ensure_xr_teleoperate() {
  ensure_repo "https://github.com/unitreerobotics/xr_teleoperate.git" "${XR_REPO_DIR}"
  if [[ -d "${XR_REPO_DIR}/.git" ]]; then
    log "Syncing xr_teleoperate submodules"
    run git -C "${XR_REPO_DIR}" submodule sync --recursive
    run git -C "${XR_REPO_DIR}" submodule update --init --recursive --depth 1
  fi

  apply_teleimager_patch

  log "Installing xr_teleoperate Python dependencies"
  run_in_conda python -m pip install -r "${XR_REPO_DIR}/requirements.txt"
  run_in_conda python -m pip install -e "${XR_REPO_DIR}/teleop/televuer"
  run_in_conda python -m pip install -e "${XR_REPO_DIR}/teleop/teleimager[server]"
  run_in_conda python -m pip install -e "${XR_REPO_DIR}/teleop/robot_control/dex-retargeting"
  run_in_conda python -m pip install 'params-proto<3' 'vuer[all]==0.0.60'

  if [[ "${CAMERA_BACKEND}" == "realsense" ]]; then
    log "Installing pyrealsense2 for teleimager RealSense mode"
    if ! run_in_conda python -m pip install pyrealsense2; then
      die "No compatible pyrealsense2 package was installed for ${SYSTEM_ARCH}. Use --camera-backend opencv, or build librealsense Python bindings for this JetPack release."
    fi
  fi
}

ensure_brainco_hand_service() {
  [[ "${SKIP_BRAINCO_SERVICE}" -eq 1 ]] && return 0

  local build_dir="${BRAINCO_SERVICE_DIR}/build-${BUILD_TAG}"
  ensure_repo "https://github.com/unitreerobotics/brainco_hand_service.git" "${BRAINCO_SERVICE_DIR}"
  log "Building brainco_hand_service in ${build_dir} (isolated for ${OS_ID} ${OS_VERSION}/${SYSTEM_ARCH})"
  run cmake -S "${BRAINCO_SERVICE_DIR}" -B "${build_dir}"
  run cmake --build "${build_dir}" -j"$(nproc)"
}

verify_installation() {
  [[ "${SKIP_VERIFY}" -eq 1 ]] && return 0

  local conda_prefix=""
  local cyclonedds_home=""
  conda_prefix="$(run_in_conda python -c 'import sys; print(sys.prefix)')"
  [[ -d "${conda_prefix}/lib" ]] || die "Unable to resolve the library directory for Conda env '${CONDA_ENV}'."
  cyclonedds_home="$(prepare_cyclonedds_home)" || die "CycloneDDS installation could not be prepared for verification."
  log "Verifying XR Python packages in Conda env '${CONDA_ENV}'"
  CYCLONEDDS_HOME="${cyclonedds_home}" \
    XR_REPO_DIR="${XR_REPO_DIR}" \
    LD_LIBRARY_PATH="${conda_prefix}/lib:${cyclonedds_home}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    run_in_conda python - <<'PY'
import importlib
import os
from pathlib import Path

# Match teleop_hand_and_arm.py's import order so native-library conflicts are
# detected without initializing DDS or connecting to the robot.
from unitree_sdk2py.core.channel import ChannelFactoryInitialize  # noqa: F401
from televuer import TeleVuerWrapper  # noqa: F401
from vuer import Vuer  # noqa: F401
import ssl

modules = {
    name: importlib.import_module(name)
    for name in ("numpy", "pinocchio", "teleimager", "televuer", "dex_retargeting")
}
teleop_dir = Path(os.environ["XR_REPO_DIR"]).expanduser().resolve() / "teleop"
expected_roots = {
    "televuer": teleop_dir / "televuer",
    "teleimager": teleop_dir / "teleimager",
    "dex_retargeting": teleop_dir / "robot_control" / "dex-retargeting",
}
for name, expected_root in expected_roots.items():
    module_file = Path(modules[name].__file__).resolve()
    if not module_file.is_relative_to(expected_root.resolve()):
        raise RuntimeError(
            f"{name} resolves to {module_file}, outside configured checkout {expected_root}"
        )

print(f"XR Python imports and editable sources: OK (OpenSSL: {ssl.OPENSSL_VERSION})")
PY

  if [[ "${CAMERA_BACKEND}" == "realsense" ]]; then
    run_in_conda python -c 'import pyrealsense2; print("pyrealsense2 import: OK")'
  fi

  if [[ "${SKIP_BRAINCO_SERVICE}" -eq 0 ]]; then
    local server_bin="${BRAINCO_SERVICE_DIR}/bin/brainco_hand_server"
    [[ -x "${server_bin}" ]] || die "BrainCo server was not produced at ${server_bin}."
    if command -v ldd >/dev/null 2>&1; then
      local missing=""
      missing="$(LD_LIBRARY_PATH="${BRAINCO_SERVICE_DIR}/lib/${SYSTEM_ARCH}:${SDK2_DIR}/thirdparty/lib/${SYSTEM_ARCH}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ldd "${server_bin}" | awk '/not found/{print}')"
      [[ -z "${missing}" ]] || die "BrainCo server has unresolved libraries: ${missing}"
    fi
    log "BrainCo server and native library linkage: OK"
  fi
}

ensure_certs() {
  local cert_path="${CONFIG_DIR}/cert.pem"
  local key_path="${CONFIG_DIR}/key.pem"
  local cert_iface="${WIFI_IFACE}"
  local cert_ip=""
  local cert_host=""
  local san_entries="DNS:localhost,IP:127.0.0.1"
  mkdir -p "${CONFIG_DIR}"

  if [[ -z "${cert_iface}" ]]; then
    cert_iface="$(default_route_iface)"
  fi
  if [[ -n "${cert_iface}" ]]; then
    cert_ip="$(iface_ipv4 "${cert_iface}")"
  fi
  cert_host="$(hostname -f 2>/dev/null || hostname)"
  if [[ -n "${cert_host}" ]]; then
    san_entries="DNS:${cert_host},${san_entries}"
  fi
  if [[ -n "${cert_ip}" ]]; then
    san_entries="${san_entries},IP:${cert_ip}"
  fi

  if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
    if [[ -z "${cert_ip}" ]] || openssl x509 -in "${cert_path}" -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:${cert_ip}"; then
      log "Reusing existing TLS certs under ${CONFIG_DIR}"
      return 0
    fi
    warn "Existing TLS cert does not include ${cert_ip}; regenerating it for the current Wi-Fi IP."
  fi

  log "Generating self-signed TLS certs for teleimager and xr_teleoperate"
  run openssl req \
    -x509 \
    -nodes \
    -days 3650 \
    -newkey rsa:2048 \
    -keyout "${key_path}" \
    -out "${cert_path}" \
    -subj "/CN=${cert_host:-localhost}" \
    -addext "subjectAltName=${san_entries}"
}

release_unitree_camera_services() {
  [[ "${RELEASE_UNITREE_CAMERA}" -eq 1 ]] || return 0

  warn "Stopping Unitree vendor camera services so teleimager can own the RealSense camera."
  run sudo /unitree/sbin/mscli stopservice video_hub_pc4 || warn "Could not stop video_hub_pc4."
  run sudo /unitree/sbin/mscli stopservice video_hub_pc4_chest || warn "Could not stop video_hub_pc4_chest."
  run sudo /unitree/sbin/mscli removeservice video_hub_pc4 || warn "Could not remove video_hub_pc4."
  run sudo /unitree/sbin/mscli removeservice video_hub_pc4_chest || warn "Could not remove video_hub_pc4_chest."
}

configure_teleimager() {
  local config_file=""
  config_file="$(find "${XR_REPO_DIR}/teleop/teleimager" -type f -name 'cam_config_server.yaml' | head -n1 || true)"
  if [[ -z "${config_file}" ]]; then
    warn "cam_config_server.yaml not found under ${XR_REPO_DIR}/teleop/teleimager; skipping teleimager config patch."
    return 0
  fi

  if [[ "${CAMERA_BACKEND}" == "opencv" ]]; then
    VIDEO_ID="$(detect_realsense_video_id)"
  fi
  if [[ "${CAMERA_BACKEND}" == "realsense" && -z "${REALSENSE_SERIAL}" ]]; then
    REALSENSE_SERIAL="$(detect_realsense_serial)" || die "No RealSense serial found. Check USB/device permissions or pass --realsense-serial."
  fi

  log "Patching ${config_file} for PC2 head camera backend=${CAMERA_BACKEND}"
  python3 - "${config_file}" "${CAMERA_BACKEND}" "${VIDEO_ID:-null}" "${REALSENSE_SERIAL:-null}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
backend = sys.argv[2]
video_id = sys.argv[3]
realsense_serial = sys.argv[4]
text = path.read_text()

def update_section_value(src: str, section: str, key: str, value: str) -> str:
    section_pat = re.compile(rf'(^{re.escape(section)}:\s*\n)(.*?)(?=^\S|\Z)', re.MULTILINE | re.DOTALL)
    match = section_pat.search(src)
    if not match:
        return src

    body = match.group(2)
    key_pat = re.compile(rf'(^[ \t]+{re.escape(key)}:\s*).*$', re.MULTILINE)
    if key_pat.search(body):
      body = key_pat.sub(rf'\g<1>{value}', body, count=1)
    else:
      body = body + f"  {key}: {value}\n"

    return src[:match.start(2)] + body + src[match.end(2):]

if backend == "realsense":
    head_camera_values = (
        ("type", "realsense"),
        ("image_shape", "[720, 1280]"),
        ("binocular", "false"),
        ("video_id", "null"),
        ("serial_number", realsense_serial),
        ("physical_path", "null"),
    )
else:
    head_camera_values = (
        ("type", "opencv"),
        ("image_shape", "[480, 640]"),
        ("binocular", "false"),
        ("video_id", video_id),
        ("serial_number", "null"),
        ("physical_path", "null"),
    )

for key, value in head_camera_values:
    text = update_section_value(text, "head_camera", key, value)

for section in ("left_wrist_camera", "right_wrist_camera"):
    text = update_section_value(text, section, "enable_zmq", "false")
    text = update_section_value(text, section, "enable_webrtc", "false")

path.write_text(text)
PY
}

write_runtime_config() {
  mkdir -p "${CONFIG_DIR}"

  if [[ -z "${DDS_IFACE}" ]]; then
    DDS_IFACE="$(detect_iface_for_ip 192.168.123.161)"
  fi
  [[ -n "${DDS_IFACE}" ]] || die "DDS interface is empty; populate G1_DDS_IFACE in ${G1_HARDWARE_CONFIG_FILE}."

  if [[ -z "${WIFI_IFACE}" ]]; then
    WIFI_IFACE="$(default_route_iface)"
  fi
  [[ -n "${WIFI_IFACE}" ]] || WIFI_IFACE="${DDS_IFACE}"

  if [[ "${CAMERA_BACKEND}" == "opencv" ]]; then
    VIDEO_ID="$(detect_realsense_video_id)"
  fi
  if [[ "${CAMERA_BACKEND}" == "realsense" && -z "${REALSENSE_SERIAL}" ]]; then
    REALSENSE_SERIAL="$(detect_realsense_serial)" || die "No RealSense serial found. Check USB/device permissions or pass --realsense-serial."
  fi

  local img_server_ip=""
  local cyclonedds_home=""
  cyclonedds_home="$(prepare_cyclonedds_home)" || die "CycloneDDS installation could not be prepared while writing runtime configuration."
  img_server_ip="$(iface_ipv4 "${WIFI_IFACE}")"
  if [[ -z "${img_server_ip}" ]]; then
    warn "No IPv4 found on ${WIFI_IFACE}; xr_teleoperate launcher will try again at runtime."
  fi

  cat > "${CONFIG_DIR}/pc2_teleop.env" <<EOF
export G1_TELEOP_CONDA_ENV="${CONDA_ENV}"
export G1_TELEOP_DDS_IFACE="${DDS_IFACE}"
export G1_TELEOP_WIFI_IFACE="${WIFI_IFACE}"
export G1_TELEOP_IMG_SERVER_IP="${img_server_ip}"
export G1_TELEIMAGER_VIDEO_ID="${VIDEO_ID}"
export G1_TELEIMAGER_CAMERA_BACKEND="${CAMERA_BACKEND}"
export G1_TELEIMAGER_REALSENSE_SERIAL="${REALSENSE_SERIAL}"
export G1_TELEOP_ARM="${ARM_MODEL}"
export G1_TELEOP_INPUT_MODE="${INPUT_MODE}"
export G1_TELEOP_EE="${EE_TYPE}"
export G1_TELEOP_DISPLAY_MODE="ego"
export G1_TELEOP_XR_REPO="${XR_REPO_DIR}"
export G1_TELEOP_BRAINCO_SERVICE_DIR="${BRAINCO_SERVICE_DIR}"
export G1_TELEOP_SDK2_DIR="${SDK2_DIR}"
export G1_TELEOP_UNITREE_SETUP="${UNITREE_ROS2_DIR}/setup.sh"
export G1_TELEOP_CYCLONEDDS_HOME="${cyclonedds_home}"
EOF
}

main() {
  need_cmd git
  need_cmd curl
  need_cmd sudo
  need_cmd python3
  need_cmd openssl
  need_cmd cmake
  need_cmd ip

  install_apt_deps
  ensure_camera_access
  ensure_miniconda
  ensure_conda_env
  setup_dds
  ensure_unitree_sdk2
  ensure_unitree_sdk2_python
  ensure_xr_teleoperate
  ensure_brainco_hand_service
  ensure_certs
  release_unitree_camera_services
  configure_teleimager
  write_runtime_config
  verify_installation

  log "Setup complete."
  log "Run ./start_brainco_hand_server.sh"
  log "Run ./start_teleimager.sh"
  log "Run ./start_xr_teleoperate.sh"
}

main "$@"
