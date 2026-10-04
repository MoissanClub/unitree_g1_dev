#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python_bin="${LEROBOT_PYTHON:-$HOME/miniforge3/envs/lerobot-dev/bin/python}"
lerobot_dir="${LEROBOT_DIR:-$HOME/lerobot}"
sdk_dir="${UNITREE_SDK2_PYTHON_DIR:-$HOME/unitree_sdk2_python}"
dry_run=false
case "${1:-}" in
    --dry-run) dry_run=true ;;
    -h|--help)
        echo 'Usage: bash setup_lerobot.sh [--dry-run]'
        echo 'Install Isaac Teleop into existing lerobot-dev; no XR or robot is started.'
        echo 'Overrides: LEROBOT_PYTHON, LEROBOT_DIR, UV_BIN, UNITREE_SDK2_PYTHON_DIR.'
        echo 'Unitree SDK defaults to ~/unitree_sdk2_python. Standalone .venv is unchanged.'
        exit 0 ;;
    '') ;;
    *) echo 'Unknown argument; use --help.' >&2; exit 2 ;;
esac
(( $# <= 1 )) || exit 2
(( EUID != 0 )) || { echo 'Run as your normal login user.' >&2; exit 2; }
source "$script_dir/lerobot_env.sh"
lerobot_environment
source "$script_dir/../load_g1_pc2_hardware.sh"
uv_bin="${UV_BIN:-$(command -v uv || true)}"
[[ -x "$uv_bin" ]] || { echo 'Set UV_BIN to an installed uv executable.' >&2; exit 2; }
# Upstream setup.py omits utils/lib/*.so from ordinary wheel installations.
# Editable installation keeps the native CRC beside the matching SDK sources.
[[ -f "$sdk_dir/setup.py" ]] || {
    echo "Unitree SDK checkout missing: $sdk_dir. Set UNITREE_SDK2_PYTHON_DIR." >&2
    exit 2
}
case "$(uname -m)" in
    aarch64) crc_library=crc_aarch64.so ;;
    x86_64) crc_library=crc_amd64.so ;;
    *) echo 'Unitree native CRC requires aarch64 or x86_64 Linux.' >&2; exit 2 ;;
esac
[[ -r "$sdk_dir/unitree_sdk2py/utils/lib/$crc_library" ]] || {
    echo "Missing native CRC library in SDK checkout: $crc_library" >&2
    exit 2
}
# Preserve the existing numerical stack used by Pinocchio/CasADi and MuJoCo.
constraints=$(mktemp)
trap 'rm -f "$constraints"' EXIT
"$python_bin" - <<'PY' > "$constraints"
import numpy, scipy, pinocchio.casadi, casadi, mujoco
print(f'numpy=={numpy.__version__}\nscipy=={scipy.__version__}')
PY
args=(pip install --python "$python_bin" --constraint "$constraints"
    'isaacteleop[cloudxr,retargeters-lite]==1.4.145' 'numpy>=2,<2.3' 'scipy>=1.15,<1.17')
if $dry_run; then args+=(--dry-run); fi
"$uv_bin" "${args[@]}"
sdk_args=(pip install --python "$python_bin" --no-deps --editable "$sdk_dir")
if $dry_run; then sdk_args+=(--dry-run); fi
"$uv_bin" "${sdk_args[@]}"
if $dry_run; then
    echo 'Would verify native Unitree CRC, patch the certificate page, and verify SDK/LeRobot imports.'
    exit 0
fi
"$python_bin" "$script_dir/verify_unitree_sdk.py" --sdk-dir "$sdk_dir"
"$python_bin" "$script_dir/patch_cloudxr_page.py"
"$python_bin" "$script_dir/verify.py" --check-only
"$python_bin" - "$lerobot_dir" <<'PY'
import sys
from pathlib import Path
import numpy as np
import lerobot
from lerobot.teleoperators.xr_controllers.config_xr_controllers import XRControllersConfig
from lerobot.teleoperators.xr_controllers.xr_controllers import IsaacControllerSession
assert Path(lerobot.__file__).resolve().is_relative_to(Path(sys.argv[1]).resolve())
IsaacControllerSession(XRControllersConfig(full_input=True, base_T_anchor=np.eye(4).tolist()))
print('PASS: LeRobot head/controller pipeline constructed; no XR session or DDS started.')
PY
echo 'Ready for: bash run_lerobot_mujoco.sh --replay'
echo 'Then: bash run_lerobot_mujoco.sh --accept-eula'
