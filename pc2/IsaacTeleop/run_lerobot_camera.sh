#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python_bin="${LEROBOT_PYTHON:-$HOME/miniforge3/envs/lerobot-dev/bin/python}"
lerobot_dir="${LEROBOT_DIR:-$HOME/lerobot}"
accept=false
prepare=false
duration=""
while (($#)); do
    case "$1" in
        --accept-eula) accept=true ;;
        --prepare-only) prepare=true ;;
        --duration-s) duration="${2:?Missing duration}"; shift ;;
        -h|--help)
            echo 'Usage: bash run_lerobot_camera.sh --accept-eula [--prepare-only] [--duration-s SECONDS]'
            echo 'Physical RGB camera to VR through lerobot-teleoperate. No robot motion or DDS.'
            echo 'Uses the shared hardware profile. q Enter or Ctrl+C exits; no r needed.'
            echo '--prepare-only prints the config and CLI command without opening devices.'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
if ! $accept; then echo 'Review the NVIDIA EULA, then pass --accept-eula.' >&2; exit 2; fi
source "$script_dir/lerobot_env.sh"
lerobot_environment
source "$script_dir/../load_g1_pc2_hardware.sh"
runs="${LEROBOT_RUNS_DIR:-$HOME/.local/state/lerobot-g1-vr}"
mkdir -p "$runs"
run_dir=$(mktemp -d "$runs/camera-XXXXXXXX")
"$python_bin" - "$run_dir" "$lerobot_dir" "$G1_HEAD_CAMERA_BACKEND" \
    "${G1_HEAD_CAMERA_VIDEO_ID:-}" "${G1_HEAD_CAMERA_REALSENSE_SERIAL:-}" "$duration" <<'PY'
import json
import math
import sys
from pathlib import Path

run, repo, backend, device, serial, duration = sys.argv[1:]
run = Path(run)
camera = dict(width=640, height=480, fps=30)
if backend in ('opencv', 'uvc'):
    if not device:
        raise SystemExit('Run lerobot-find-cameras opencv and set G1_HEAD_CAMERA_VIDEO_ID in the hardware profile.')
    camera.update(type='opencv', index_or_path=int(device) if device.isdecimal() else device, color_mode='rgb')
else:
    camera.update(type='intelrealsense', serial_number_or_name=serial, use_depth=False)
config = dict(
    robot=dict(type='unitree_g1_motion', mode='camera', cameras={'head': camera},
               video_channel=str(run / 'camera.rgb'), report_path=str(run / 'report.jsonl')),
    teleop=dict(type='xr_controllers', terminal_control=True,
                video_channel=str(run / 'camera.rgb'), video_source='g1-29-physical-camera',
                cloudxr_config=str(Path(repo) / 'examples/unitree_g1/cloudxr_quest3.env'),
                accept_cloudxr_eula=True),
    fps=30, display_data=False,
)
compatible = Path('/proc/device-tree/compatible')
if compatible.exists() and b'tegra234' in compatible.read_bytes():
    config['teleop']['video_openxr_composition'] = False
if duration:
    seconds = float(duration)
    if not math.isfinite(seconds) or seconds <= 0:
        raise SystemExit('Duration must be positive and finite.')
    config['teleop_time_s'] = seconds
(run / 'teleoperate.json').write_text(json.dumps(config, indent=2) + '\n')
PY
printf 'Config: %s\n' "$run_dir/teleoperate.json"
printf 'lerobot-teleoperate --config_path=%q\n' "$run_dir/teleoperate.json"
if $prepare; then exit 0; fi
"$python_bin" "$script_dir/verify.py" --show-config
"$python_bin" - "$script_dir" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from verify import load_hardware_profile, resolve_host_ip
host = resolve_host_ip(None, load_hardware_profile())
print(f'Open https://{host}:48322, click the client button, choose H.264, then Connect and Play.')
PY
echo 'Camera viewing only: no r needed. q Enter or Ctrl+C exits. Stop other camera/XR services first.'
exec lerobot-teleoperate --config_path="$run_dir/teleoperate.json"
