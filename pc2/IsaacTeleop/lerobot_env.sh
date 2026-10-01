#!/usr/bin/env bash
# Shared PC2 environment; sourced only by the two LeRobot scripts.
lerobot_environment() {
    [[ -x "$python_bin" ]] || { echo "Python not found: $python_bin. Set LEROBOT_PYTHON." >&2; return 2; }
    [[ -f "$lerobot_dir/src/lerobot/teleoperators/xr_controllers/xr_controllers.py" ]] || {
        echo "Use the work/g1-vr-teleoperate checkout via LEROBOT_DIR." >&2; return 2;
    }
    lerobot_dir=$(cd -- "$lerobot_dir" && pwd)
    local prefix
    prefix=$("$python_bin" -c 'import sys; print(sys.prefix)')
    export PATH="$prefix/bin:$PATH" PYTHONNOUSERSITE=1
    export PYTHONPATH="$lerobot_dir/src${PYTHONPATH:+:$PYTHONPATH}"
    export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MUJOCO_GL=egl
    if [[ -z "${CYCLONEDDS_HOME:-}" && -d "$HOME/.config/xr_teleoperate/cyclonedds-ubuntu-22.04-aarch64" ]]; then
        export CYCLONEDDS_HOME="$HOME/.config/xr_teleoperate/cyclonedds-ubuntu-22.04-aarch64"
    fi
    if [[ -n "${CYCLONEDDS_HOME:-}" ]]; then
        export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$CYCLONEDDS_HOME/lib"
    fi
    if [[ -f /proc/device-tree/compatible ]] && grep -aq tegra234 /proc/device-tree/compatible; then
        local egl=/lib/aarch64-linux-gnu/libEGL.so.1
        [[ -r "$egl" ]] || { echo "Missing JetPack EGL: $egl" >&2; return 2; }
        export LD_PRELOAD="$egl${LD_PRELOAD:+:$LD_PRELOAD}"
    fi
    export PYTHONFAULTHANDLER=1
}
