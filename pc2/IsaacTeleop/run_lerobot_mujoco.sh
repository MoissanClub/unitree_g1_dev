#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python_bin="${LEROBOT_PYTHON:-$HOME/miniforge3/envs/lerobot-dev/bin/python}"
lerobot_dir="${LEROBOT_DIR:-$HOME/lerobot}"
replay=false
accept=false
video=false
onscreen=false
while (($#)); do
    case "$1" in
        --replay) replay=true ;;
        --accept-eula) accept=true ;;
        --video) video=true ;;
        --onscreen) onscreen=true ;;
        -h|--help)
            echo 'Usage: bash run_lerobot_mujoco.sh --replay | --accept-eula [--video] [--onscreen]'
            echo 'Simulation only. Laptop controls: r Enter starts, p Enter pauses, q Enter quits.'
            echo 'Overrides: LEROBOT_PYTHON, LEROBOT_DIR, LEROBOT_RUNS_DIR, HF_HUB_OFFLINE.'
            echo '--video requires working PyTorch CUDA and Isaac Teleop Viz; off by default.'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
if ! $replay && ! $accept; then echo 'Live XR requires --accept-eula.' >&2; exit 2; fi
if $replay && $video; then echo 'Replay cannot use headset video.' >&2; exit 2; fi
source "$script_dir/lerobot_env.sh"
lerobot_environment
source "$script_dir/../load_g1_pc2_hardware.sh"
for node in /dev/dri/renderD* /dev/nvmap; do
    [[ -e "$node" ]] || continue
    if [[ ! -r "$node" || ! -w "$node" ]]; then
        echo "No GPU access to $node. Open a fresh SSH login after install.sh adds groups." >&2
        exit 2
    fi
done
if $video; then
    "$python_bin" -c 'import torch; from isaacteleop import viz; torch.empty(1, device="cuda"); print("CUDA video allocation OK")'
fi
runs="${LEROBOT_RUNS_DIR:-$HOME/.local/state/lerobot-g1-vr}"
mkdir -p "$runs"
run_dir=$(mktemp -d "$runs/session-XXXXXXXX")
args=(--config-dir "$run_dir")
if $replay; then args+=(--replay-frames 100); fi
cd "$lerobot_dir"
"$python_bin" examples/unitree_g1/prepare_vr_assets.py "${args[@]}"
"$python_bin" - "$run_dir/teleoperate.json" "$onscreen" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); cfg = json.loads(p.read_text())
cfg['robot'].update(mode='simulation', enable_motion=False, enable_locomotion=False, onscreen=sys.argv[2]=='true')
p.write_text(json.dumps(cfg, indent=2))
PY
args=(--config_path="$run_dir/teleoperate.json")
if ! $replay; then
    "$python_bin" "$script_dir/verify.py" --show-config
    "$python_bin" - "$script_dir" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from verify import load_hardware_profile, resolve_host_ip
host = resolve_host_ip(None, load_hardware_profile())
print(f'Open https://{host}:48322, click the client button, choose H.264, then Connect.')
PY
    echo 'Laptop controls: r Enter starts tracking, p Enter pauses, q Enter quits.'
    args+=(--teleop.cloudxr_config="$lerobot_dir/examples/unitree_g1/cloudxr_quest3.env" --teleop.accept_cloudxr_eula=true)
    if $video; then
        args+=(--teleop.video_channel="$run_dir/camera.rgb" --robot.video_channel="$run_dir/camera.rgb")
        if [[ -f /proc/device-tree/compatible ]] && grep -aq tegra234 /proc/device-tree/compatible; then
            args+=(--teleop.video_openxr_composition=false)
        fi
    fi
fi
echo "Simulation report: $run_dir/report.jsonl"
exec "$python_bin" -m lerobot.scripts.lerobot_teleoperate "${args[@]}"
