#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 && ${EUID} -ne 0 ]] || { echo 'Run as builder: prepare_runtime.sh PAYLOAD' >&2; exit 2; }
payload="$1"
source "${payload}/work/config/pc2_teleop.env"
source "${payload}/hardware.env"
template="${payload}/runtime-template"
mkdir -p "${template}"
export G1_TELEOP_CONDA_ROOT="${payload}/work/miniforge3"
export G1_TELEOP_CONDA_ENV="${G1_TELEOP_CONDA_ROOT}/envs/tv"
export G1_TELEOP_DDS_IFACE="${G1_DDS_IFACE}" G1_TELEOP_WIFI_IFACE="${G1_WIFI_IFACE}"
export G1_TELEOP_IMG_SERVER_IP="" G1_TELEOP_MOTION_MODE=motion
export G1_TELEOP_ARM="G1_${G1_ROBOT_DOF}" G1_TELEOP_PRIVILEGE_MODE=user
export G1_TELEIMAGER_CAMERA_BACKEND="${G1_HEAD_CAMERA_BACKEND}"
[[ "${G1_TELEIMAGER_CAMERA_BACKEND}" != uvc ]] || export G1_TELEIMAGER_CAMERA_BACKEND=opencv
export G1_TELEIMAGER_VIDEO_ID="${G1_HEAD_CAMERA_VIDEO_ID:-}"
export G1_TELEIMAGER_REALSENSE_SERIAL="${G1_HEAD_CAMERA_REALSENSE_SERIAL:-}"
export G1_TELEIMAGER_PHYSICAL_PATH="${G1_HEAD_CAMERA_PHYSICAL_PATH:-}"
while IFS= read -r name; do
  printf 'export %s=%q\n' "${name}" "${!name}"
done < <(compgen -A variable | grep -E '^G1_TELE(OP|IMAGER)_') > "${template}/pc2_teleop.env"
"${G1_TELEOP_CONDA_ENV}/bin/python" - "${payload}" <<'PY'
from pathlib import Path
import os, sys, yaml
root = Path(sys.argv[1])
config = yaml.safe_load((root / 'work/xr_teleoperate/teleop/teleimager/cam_config_server.yaml').read_text())
head = config['head_camera']
backend = os.environ['G1_TELEIMAGER_CAMERA_BACKEND']
head.update(type=backend, binocular=False, physical_path=None,
            image_shape=[720, 1280] if backend == 'realsense' else [480, 640],
            video_id=None if backend == 'realsense' else int(os.environ['G1_TELEIMAGER_VIDEO_ID']),
            serial_number=os.environ['G1_TELEIMAGER_REALSENSE_SERIAL'] or None)
for key in ('left_wrist_camera', 'right_wrist_camera'):
    if key in config:
        config[key].update(enable_zmq=False, enable_webrtc=False)
(root / 'runtime-template/cam_config_server.yaml').write_text(yaml.safe_dump(config, sort_keys=False))
PY
