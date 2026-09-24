#!/usr/bin/env bash
set -Eeuo pipefail
# Invoked by the administrator's manager as the unprivileged builder account.
[[ $# -eq 4 ]] || { echo 'Usage: build_worker.sh PAYLOAD REPO REF XR_URL' >&2; exit 2; }
[[ ${EUID} -ne 0 ]] || { echo 'Build worker must not run as root.' >&2; exit 1; }
payload="$1"
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_ASKPASS=/bin/false G1_TELEOP_XR_URL="$4"
export G1_TELEOP_TELEIMAGER_URL=https://github.com/unitreerobotics/teleimager.git
export G1_TELEOP_BUILD_JOBS=2 CMAKE_BUILD_PARALLEL_LEVEL=2 MAKEFLAGS=-j2
export PYTHONNOUSERSITE=1 PIP_CONFIG_FILE=/dev/null PIP_NO_INPUT=1
unset PIP_CONSTRAINT PYTHONPATH PYTHONHOME CONDA_PREFIX CONDA_DEFAULT_ENV
umask 022
cd "${payload}"
git clone --depth 1 --branch "$3" -- "$2" launcher
scripts="${payload}/launcher/pc2/vr_teleops"
export G1_HARDWARE_CONFIG_FILE="${payload}/hardware.env"
export CONDARC="${payload}/condarc"
printf 'channels:\n  - conda-forge\nchannel_priority: strict\n' > "${CONDARC}"
export CONDA_PKGS_DIRS="${payload}/conda-pkgs"
bash "${scripts}/setup_pc2_xr_teleop.sh" --user-only --software-only \
  --workspace-root "${payload}/work" --no-pull --input-mode hand --ee brainco
python3 "${scripts}/deployment/patch_runtime.py" "${payload}/work/xr_teleoperate"
bash "${scripts}/deployment/prepare_runtime.sh" "${payload}"
git -C launcher rev-parse HEAD > launcher-revision.txt
git -C work/xr_teleoperate submodule status --recursive > submodules.txt
for repo in xr_teleoperate unitree_sdk2 unitree_sdk2_python unitree_ros2 brainco_hand_service; do
  printf '%s ' "${repo}"
  git -C "work/${repo}" rev-parse HEAD
done > revisions.txt
"${payload}/work/miniforge3/envs/tv/bin/python" -m pip freeze --all > pip-freeze.txt
"${payload}/work/miniforge3/bin/conda" list -n tv --json > conda-packages.json
cat /etc/os-release > system-os.txt
dpkg-query -W > system-packages.txt
