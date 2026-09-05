#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common_teleop_env.sh"

teleop_export_common_env

teleimager_config_path() {
  local config_path="${G1_TELEOP_XR_REPO}/teleop/teleimager/cam_config_server.yaml"
  [[ -f "${config_path}" ]] || teleop_die "Missing teleimager camera config at ${config_path}."
  printf '%s\n' "${config_path}"
}

teleimager_config_head_type() {
  local config_path="$1"
  awk '
    /^head_camera:/ {in_head = 1; next}
    in_head && /^[^[:space:]#]/ {exit}
    in_head && /^[[:space:]]*type:[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*type:[[:space:]]*/, "", value)
      gsub(/["'\'']/, "", value)
      print value
      exit
    }
  ' "${config_path}"
}

video_id_supports_rgb() {
  local video_id="$1"
  command -v v4l2-ctl >/dev/null 2>&1 || return 1
  v4l2-ctl -d "/dev/video${video_id}" --list-formats-ext 2>/dev/null | \
    grep -Eq "'(MJPG|JPEG|MPEG|YUYV|RGB[0-9]*|BGR[0-9]*)'"
}

resolve_opencv_video_id() {
  local configured_id="$1"
  local candidate=""
  if video_id_supports_rgb "${configured_id}"; then
    printf '%s\n' "${configured_id}"
    return 0
  fi

  teleop_warn "/dev/video${configured_id} is not an RGB endpoint; detecting an RGB-capable V4L2 device."
  for candidate in /dev/video*; do
    [[ -e "${candidate}" ]] || continue
    if video_id_supports_rgb "${candidate#/dev/video}"; then
      printf '%s\n' "${candidate#/dev/video}"
      return 0
    fi
  done
  return 1
}

patch_opencv_config() {
  local config_path="$1"
  local video_id="$2"
  python3 - "${config_path}" "${video_id}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
video_id = sys.argv[2]
text = path.read_text()
section = re.search(r'(^head_camera:\s*\n)(.*?)(?=^\S|\Z)', text, re.MULTILINE | re.DOTALL)
if not section:
    raise SystemExit(f"Missing head_camera section in {path}")
body = section.group(2)
for key, value in (("type", "opencv"), ("video_id", video_id), ("serial_number", "null"), ("physical_path", "null")):
    pattern = re.compile(rf'(^[ \t]+{re.escape(key)}:\s*).*$', re.MULTILINE)
    if pattern.search(body):
        body = pattern.sub(rf'\g<1>{value}', body, count=1)
    else:
        body += f"  {key}: {value}\n"
path.write_text(text[:section.start(2)] + body + text[section.end(2):])
PY
}

persist_runtime_video_id() {
  local video_id="$1"
  [[ -f "${TELEOP_CONFIG_FILE}" ]] || return 0
  python3 - "${TELEOP_CONFIG_FILE}" "${video_id}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
video_id = sys.argv[2]
text = path.read_text()
pattern = re.compile(r'^export G1_TELEIMAGER_VIDEO_ID=.*$', re.MULTILINE)
line = f'export G1_TELEIMAGER_VIDEO_ID="{video_id}"'
path.write_text(pattern.sub(line, text, count=1) if pattern.search(text) else text.rstrip() + "\n" + line + "\n")
PY
}

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
  if [[ -n "${G1_TELEIMAGER_REALSENSE_SERIAL:-}" && "${G1_TELEIMAGER_REALSENSE_SERIAL}" != "null" ]]; then
    printf '%s\n' "${G1_TELEIMAGER_REALSENSE_SERIAL}"
    return 0
  fi

  detect_realsense_serial_from_teleimager && return 0
  detect_realsense_serial_from_sysfs && return 0

  teleop_die "RealSense backend selected, but no RealSense serial was found. Check USB permissions/device state or set G1_TELEIMAGER_REALSENSE_SERIAL."
}

patch_realsense_config() {
  local config_path="$1"
  local serial="$2"

  python3 - "${config_path}" "${serial}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
serial = sys.argv[2]
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
    ("type", "realsense"),
    ("image_shape", "[720, 1280]"),
    ("binocular", "false"),
    ("video_id", "null"),
    ("serial_number", serial),
    ("physical_path", "null"),
):
    text = update_section_value(text, "head_camera", key, value)

path.write_text(text)
PY
}

main() {
  local cert_path="${HOME}/.config/xr_teleoperate/cert.pem"
  local key_path="${HOME}/.config/xr_teleoperate/key.pem"
  local config_path=""
  local config_backend=""
  local camera_backend="${G1_TELEIMAGER_CAMERA_BACKEND}"
  local realsense_serial=""

  [[ -f "${cert_path}" && -f "${key_path}" ]] || teleop_die "Missing TLS certs under ~/.config/xr_teleoperate. Run ./setup_pc2_xr_teleop.sh first."
  [[ -d "${G1_TELEOP_XR_REPO}" ]] || teleop_die "Missing xr_teleoperate checkout at ${G1_TELEOP_XR_REPO}."

  teleop_activate_env "${G1_TELEOP_CONDA_ENV}"
  config_path="$(teleimager_config_path)"
  config_backend="$(teleimager_config_head_type "${config_path}")"
  if [[ "${config_backend}" == "realsense" ]]; then
    camera_backend="realsense"
  fi

  if [[ "${camera_backend}" == "opencv" ]]; then
    local resolved_video_id=""
    resolved_video_id="$(resolve_opencv_video_id "${G1_TELEIMAGER_VIDEO_ID}")" || \
      teleop_die "No readable RGB-capable V4L2 camera was found. Check video-group access and camera enumeration."
    if [[ "${resolved_video_id}" != "${G1_TELEIMAGER_VIDEO_ID}" ]]; then
      teleop_log "Using detected RGB endpoint /dev/video${resolved_video_id} instead of configured /dev/video${G1_TELEIMAGER_VIDEO_ID}"
      persist_runtime_video_id "${resolved_video_id}"
    fi
    export G1_TELEIMAGER_VIDEO_ID="${resolved_video_id}"
    patch_opencv_config "${config_path}" "${resolved_video_id}"
    local video_device="/dev/video${resolved_video_id}"
    [[ -e "${video_device}" ]] || teleop_die "Configured camera ${video_device} does not exist. Check USB enumeration or run teleimager-server --cf."
    [[ -r "${video_device}" && -w "${video_device}" ]] || \
      teleop_die "No read/write access to ${video_device}. Add $(id -un) to the video group, then log out and back in or reboot."
  fi

  if [[ "${camera_backend}" == "realsense" ]]; then
    realsense_serial="$(resolve_realsense_serial)"
    export G1_TELEIMAGER_REALSENSE_SERIAL="${realsense_serial}"
    teleop_log "Patching ${config_path} for RealSense serial ${realsense_serial}"
    patch_realsense_config "${config_path}" "${realsense_serial}"
  fi

  teleop_log "Serving teleimager from ${G1_TELEOP_XR_REPO} with ${camera_backend} camera backend; browser URL will be https://${G1_TELEOP_IMG_SERVER_IP}:60001"
  cd "${G1_TELEOP_XR_REPO}/teleop/teleimager"
  if [[ "${camera_backend}" == "realsense" ]]; then
    exec teleimager-server --rs "$@"
  fi
  exec teleimager-server "$@"
}

main "$@"
