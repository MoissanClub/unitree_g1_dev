#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC2_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_CONDA_ENV="tv"
DEFAULT_XR_REPO="${HOME}/xr_teleoperate"
DEFAULT_BRAINCO_SERVICE_DIR="${HOME}/brainco_hand_service"
DEFAULT_SDK2_DIR="${HOME}/unitree_sdk2"
DEFAULT_SDK2_PY_DIR="${HOME}/unitree_sdk2_python"
DEFAULT_UNITREE_ROS2_DIR="${HOME}/unitree_ros2"
DEFAULT_CONFIG_DIR="${HOME}/.config/xr_teleoperate"
DEFAULT_DDS_IFACE=""
DEFAULT_WIFI_IFACE=""
DEFAULT_VIDEO_ID=""
DEFAULT_CAMERA_BACKEND="opencv"
DEFAULT_REALSENSE_SERIAL=""
DEFAULT_ARM="G1_29"
DEFAULT_INPUT_MODE="controller"
DEFAULT_EE="brainco"

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
  if [[ -n "${VIDEO_ID}" ]]; then
    printf '%s\n' "${VIDEO_ID}"
    return 0
  fi

  if [[ -d "${XR_REPO_DIR}/teleop/teleimager" ]]; then
    local teleimager_output=""
    local detected_id=""
    teleimager_output="$(run_in_conda teleimager-server --cf 2>&1 || true)"
    detected_id="$(printf '%s\n' "${teleimager_output}" | sed -n "s/.*Found RGB video devices: \['\/dev\/video\([0-9]\+\)'.*/\1/p" | head -n1)"
    if [[ -n "${detected_id}" ]]; then
      printf '%s\n' "${detected_id}"
      return 0
    fi
  fi

  if compgen -G "/dev/v4l/by-id/*RealSense*index0*" >/dev/null; then
    local dev_path=""
    dev_path="$(readlink -f /dev/v4l/by-id/*RealSense*index0* 2>/dev/null | head -n1 || true)"
    if [[ "${dev_path}" =~ /dev/video([0-9]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  if command -v v4l2-ctl >/dev/null 2>&1; then
    local current_device=""
    local line=""
    while IFS= read -r line; do
      if [[ "${line}" != $'\t'* ]]; then
        current_device="${line}"
        continue
      fi
      if [[ "${current_device}" == *"RealSense"* && "${line}" =~ /dev/video([0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi
    done < <(v4l2-ctl --list-devices 2>/dev/null || true)
  fi

  printf '2\n'
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

  printf 'null\n'
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
    libfmt-dev \
    libspdlog-dev \
    openssl \
    pkg-config \
    python3-pip \
    v4l-utils
}

ensure_miniconda() {
  if command -v conda >/dev/null 2>&1 || [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
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

setup_dds() {
  [[ "${SKIP_DDS}" -eq 1 ]] && return 0
  [[ -f "${PC2_DIR}/setup_unitree_g1_pc2_dds.sh" ]] || die "Missing ${PC2_DIR}/setup_unitree_g1_pc2_dds.sh"

  if [[ -z "${DDS_IFACE}" ]]; then
    DDS_IFACE="$(detect_iface_for_ip 192.168.123.161)"
  fi
  [[ -n "${DDS_IFACE}" ]] || DDS_IFACE="eth0"

  log "Reusing local DDS installer for interface ${DDS_IFACE}"
  run bash "${PC2_DIR}/setup_unitree_g1_pc2_dds.sh" --iface "${DDS_IFACE}" --yes
}

ensure_unitree_sdk2() {
  ensure_repo "https://github.com/unitreerobotics/unitree_sdk2.git" "${SDK2_DIR}"
  log "Building unitree_sdk2"
  run cmake -S "${SDK2_DIR}" -B "${SDK2_DIR}/build" -DBUILD_EXAMPLES=OFF
  run cmake --build "${SDK2_DIR}/build" -j"$(nproc)"
  run sudo cmake --install "${SDK2_DIR}/build"
}

ensure_unitree_sdk2_python() {
  ensure_repo "https://github.com/unitreerobotics/unitree_sdk2_python.git" "${SDK2_PY_DIR}"
  export CYCLONEDDS_HOME="${UNITREE_ROS2_DIR}/cyclonedds_ws/install/cyclonedds"
  [[ -d "${CYCLONEDDS_HOME}" ]] || die "Missing ${CYCLONEDDS_HOME}. The DDS setup step must succeed before sdk2_python install."

  log "Installing unitree_sdk2_python into conda env '${CONDA_ENV}'"
  run_in_conda python -m pip install --upgrade pip
  run_in_conda python -m pip install -e "${SDK2_PY_DIR}"
}

ensure_xr_teleoperate() {
  ensure_repo "https://github.com/unitreerobotics/xr_teleoperate.git" "${XR_REPO_DIR}"
  if [[ -d "${XR_REPO_DIR}/.git" ]]; then
    log "Syncing xr_teleoperate submodules"
    run git -C "${XR_REPO_DIR}" submodule sync --recursive
    run git -C "${XR_REPO_DIR}" submodule update --init --recursive --depth 1
  fi

  log "Installing xr_teleoperate Python dependencies"
  run_in_conda python -m pip install -r "${XR_REPO_DIR}/requirements.txt"
  run_in_conda python -m pip install -e "${XR_REPO_DIR}/teleop/televuer"
  run_in_conda python -m pip install -e "${XR_REPO_DIR}/teleop/teleimager[server]"
  run_in_conda python -m pip install -e "${XR_REPO_DIR}/teleop/robot_control/dex-retargeting"
  run_in_conda python -m pip install 'params-proto<3' 'vuer[all]==0.0.60'

  if [[ "${CAMERA_BACKEND}" == "realsense" ]]; then
    log "Installing pyrealsense2 for teleimager RealSense mode"
    run_in_conda python -m pip install pyrealsense2
  fi
}

ensure_brainco_hand_service() {
  [[ "${SKIP_BRAINCO_SERVICE}" -eq 1 ]] && return 0

  ensure_repo "https://github.com/unitreerobotics/brainco_hand_service.git" "${BRAINCO_SERVICE_DIR}"
  log "Building brainco_hand_service"
  run cmake -S "${BRAINCO_SERVICE_DIR}" -B "${BRAINCO_SERVICE_DIR}/build"
  run cmake --build "${BRAINCO_SERVICE_DIR}/build" -j"$(nproc)"
}

ensure_certs() {
  local cert_path="${CONFIG_DIR}/cert.pem"
  local key_path="${CONFIG_DIR}/key.pem"
  mkdir -p "${CONFIG_DIR}"

  if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
    log "Reusing existing TLS certs under ${CONFIG_DIR}"
    return 0
  fi

  log "Generating self-signed TLS certs for teleimager and xr_teleoperate"
  run openssl req \
    -x509 \
    -nodes \
    -days 3650 \
    -newkey rsa:2048 \
    -keyout "${key_path}" \
    -out "${cert_path}" \
    -subj "/CN=$(hostname -f 2>/dev/null || hostname)"
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

  if [[ "${CAMERA_BACKEND}" == "opencv" && -z "${VIDEO_ID}" ]]; then
    VIDEO_ID="$(detect_realsense_video_id)"
  fi
  if [[ "${CAMERA_BACKEND}" == "realsense" && -z "${REALSENSE_SERIAL}" ]]; then
    REALSENSE_SERIAL="$(detect_realsense_serial)"
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
  [[ -n "${DDS_IFACE}" ]] || DDS_IFACE="eth0"

  if [[ -z "${WIFI_IFACE}" ]]; then
    WIFI_IFACE="$(default_route_iface)"
  fi
  [[ -n "${WIFI_IFACE}" ]] || WIFI_IFACE="${DDS_IFACE}"

  if [[ "${CAMERA_BACKEND}" == "opencv" && -z "${VIDEO_ID}" ]]; then
    VIDEO_ID="$(detect_realsense_video_id)"
  fi
  if [[ "${CAMERA_BACKEND}" == "realsense" && -z "${REALSENSE_SERIAL}" ]]; then
    REALSENSE_SERIAL="$(detect_realsense_serial)"
  fi

  local img_server_ip=""
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
export G1_TELEOP_UNITREE_SETUP="${UNITREE_ROS2_DIR}/setup.sh"
export G1_TELEOP_CYCLONEDDS_HOME="${UNITREE_ROS2_DIR}/cyclonedds_ws/install/cyclonedds"
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

  log "Setup complete."
  log "Run ./start_brainco_hand_server.sh"
  log "Run ./start_teleimager.sh"
  log "Run ./start_xr_teleoperate.sh"
}

main "$@"
