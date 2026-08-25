#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common_teleop_env.sh"

usage() {
  cat <<'EOF'
Usage:
  ./switch_to_camera.sh [realsense|uvc|opencv]

Default:
  realsense

This updates both:
  ~/.config/xr_teleoperate/pc2_teleop.env
  ~/xr_teleoperate/teleop/teleimager/cam_config_server.yaml

The head camera is switched to the selected backend. PC2 does not stream
the left or right wrist cameras, so their ZMQ and WebRTC outputs are disabled.

Then start the stream with:
  ./start_teleimager.sh
EOF
}

camera="${1:-realsense}"
case "${camera}" in
  realsense|uvc|opencv) ;;
  -h|--help) usage; exit 0 ;;
  *) teleop_die "Unsupported camera '${camera}'. Expected 'realsense', 'uvc', or 'opencv'." ;;
esac

teleop_export_common_env
teleop_activate_env "${G1_TELEOP_CONDA_ENV}"

config_path="${G1_TELEOP_XR_REPO}/teleop/teleimager/cam_config_server.yaml"
[[ -f "${config_path}" ]] || teleop_die "Missing teleimager config at ${config_path}."

detect_realsense_serial_from_sysfs() {
  local usb_dir=""
  local vendor=""
  local product=""
  local serial=""

  for usb_dir in /sys/bus/usb/devices/*; do
    [[ -r "${usb_dir}/idVendor" && -r "${usb_dir}/product" && -r "${usb_dir}/serial" ]] || continue
    vendor="$(<"${usb_dir}/idVendor")"
    [[ "${vendor,,}" == "8086" ]] || continue
    product="$(<"${usb_dir}/product")"
    [[ "${product,,}" == *realsense* ]] || continue
    serial="$(<"${usb_dir}/serial")"
    if [[ -n "${serial}" ]]; then
      printf '%s\n' "${serial}"
      return 0
    fi
  done

  return 1
}

detect_realsense_serial_from_teleimager() {
  local output=""
  local serial=""

  output="$(teleimager-server --cf --rs 2>&1 || true)"
  serial="$(printf '%s\n' "${output}" | sed -n "s/.*\['\([0-9][0-9]*\)'\].*/\1/p" | head -n1)"
  if [[ -n "${serial}" ]]; then
    printf '%s\n' "${serial}"
    return 0
  fi

  return 1
}

resolve_realsense_serial() {
  detect_realsense_serial_from_teleimager && return 0

  if [[ -n "${G1_TELEIMAGER_REALSENSE_SERIAL:-}" && "${G1_TELEIMAGER_REALSENSE_SERIAL}" != "null" ]]; then
    printf '%s\n' "${G1_TELEIMAGER_REALSENSE_SERIAL}"
    return 0
  fi

  detect_realsense_serial_from_sysfs && return 0

  teleop_die "No RealSense serial found. Check USB/device permissions or set G1_TELEIMAGER_REALSENSE_SERIAL."
}

update_runtime_config() {
  local backend="$1"
  local serial="$2"
  local config_file="${TELEOP_CONFIG_FILE}"
  local tmp_file=""

  mkdir -p "$(dirname "${config_file}")"
  touch "${config_file}"
  tmp_file="$(mktemp)"

  awk '
    !/^export G1_TELEIMAGER_CAMERA_BACKEND=/ &&
    !/^export G1_TELEIMAGER_REALSENSE_SERIAL=/ {
      print
    }
  ' "${config_file}" > "${tmp_file}"

  {
    printf 'export G1_TELEIMAGER_CAMERA_BACKEND="%s"\n' "${backend}"
    printf 'export G1_TELEIMAGER_REALSENSE_SERIAL="%s"\n' "${serial}"
  } >> "${tmp_file}"

  mv "${tmp_file}" "${config_file}"
}

patch_camera_config() {
  local path="$1"
  local backend="$2"
  local video_id="$3"
  local serial="$4"
  local image_shape="[480, 640]"

  if [[ "${backend}" == "realsense" ]]; then
    image_shape="[720, 1280]"
    video_id="null"
  else
    serial="null"
    [[ -n "${video_id}" && "${video_id}" != "null" ]] || video_id="2"
  fi

  python3 - "${path}" "${backend}" "${image_shape}" "${video_id}" "${serial}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
backend = sys.argv[2]
image_shape = sys.argv[3]
video_id = sys.argv[4]
serial = sys.argv[5]
text = path.read_text()

def update_section_value(src: str, section: str, key: str, value: str) -> str:
    pattern = re.compile(rf"(^({re.escape(section)}:\n)(.*?))(?=^[^\s#]|\Z)", re.M | re.S)
    match = pattern.search(src)
    if not match:
        raise SystemExit(f"Missing section {section!r} in {path}")

    body = match.group(3)
    key_pattern = re.compile(rf"^([ \t]*{re.escape(key)}[ \t]*:[ \t]*).*$", re.M)
    if key_pattern.search(body):
        body = key_pattern.sub(rf"\g<1>{value}", body, count=1)
    else:
        body += f"  {key}: {value}\n"

    return src[:match.start(3)] + body + src[match.end(3):]

for key, value in (
    ("type", backend),
    ("image_shape", image_shape),
    ("binocular", "false"),
    ("video_id", video_id),
    ("serial_number", serial),
    ("physical_path", "null"),
):
    text = update_section_value(text, "head_camera", key, value)

for section in ("left_wrist_camera", "right_wrist_camera"):
    text = update_section_value(text, section, "enable_zmq", "false")
    text = update_section_value(text, section, "enable_webrtc", "false")

path.write_text(text)
PY
}

realsense_serial=""
if [[ "${camera}" == "realsense" ]]; then
  realsense_serial="$(resolve_realsense_serial)"
fi

patch_camera_config "${config_path}" "${camera}" "${G1_TELEIMAGER_VIDEO_ID}" "${realsense_serial}"
update_runtime_config "${camera}" "${realsense_serial}"

teleop_log "Switched teleimager head_camera to ${camera}."
teleop_log "Disabled ZMQ and WebRTC outputs for both wrist cameras."
if [[ "${camera}" == "realsense" ]]; then
  teleop_log "RealSense serial: ${realsense_serial}"
fi
teleop_log "Next: run ./start_teleimager.sh"
