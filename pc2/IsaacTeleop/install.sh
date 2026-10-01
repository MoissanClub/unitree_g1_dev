#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
venv="$script_dir/.venv"
python_version=3.12
dry_run=false
uv_bin="${UV_BIN:-}"

usage() {
    cat <<'EOF'
Install standalone Isaac Teleop 1.4.145 with bundled CloudXR runtimes.
Usage: bash install.sh [--venv PATH] [--python VERSION_OR_PATH] [--uv PATH] [--dry-run]

Defaults: .venv beside this script; Python 3.12 (uv downloads it if needed).
Finds uv on PATH, in standard user locations, or in local conda environments.
Use --uv PATH or UV_BIN to select it explicitly. No conda activation required.
No LeRobot, robot SDK, PyTorch, or driver changes.
Installs vulkan-tools if missing and adds missing video/render membership
with sudo when required. Reconnect over SSH after a group change, then rerun.
Loads ../g1_pc2_hardware.env through the shared loader. Override with
G1_HARDWARE_CONFIG_FILE=/path/to/profile.env.
--dry-run prints planned changes without creating an environment or installing.
The installer never starts CloudXR or accepts its EULA.
EOF
}

while (($#)); do
    case "$1" in
        --venv|--python|--uv)
            if (($# < 2)) || [[ -z "$2" ]]; then echo "$1 requires a value" >&2; exit 2; fi
            case "$1" in
                --venv) venv="$2" ;;
                --python) python_version="$2" ;;
                --uv) uv_bin="$2" ;;
            esac
            shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
# shellcheck source=../load_g1_pc2_hardware.sh
source "$script_dir/../load_g1_pc2_hardware.sh"
printf 'Hardware profile: %s\nWi-Fi interface: %s\n' "$G1_HARDWARE_CONFIG_FILE" "$G1_WIFI_IFACE"
if [[ $(uname -s) != Linux ]]; then echo 'Linux is required.' >&2; exit 2; fi
case "$(uname -m)" in aarch64|x86_64) ;; *) echo 'Requires aarch64 or x86_64.' >&2; exit 2 ;; esac
if [[ -n "$uv_bin" ]]; then
    uv_bin=$(command -v -- "$uv_bin") || { echo 'The selected uv executable was not found.' >&2; exit 2; }
else
    uv_bin=$(command -v uv || true)
    if [[ -z "$uv_bin" ]]; then
        for candidate in \
            "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv" \
            "${CONDA_PREFIX:-/nonexistent}/bin/uv" \
            "$HOME"/{miniforge3,miniconda3,anaconda3}/bin/uv \
            "$HOME"/{miniforge3,miniconda3,anaconda3}/envs/*/bin/uv; do
            if [[ -f "$candidate" && -x "$candidate" ]]; then
                uv_bin="$candidate"
                break
            fi
        done
    fi
fi
if [[ -z "$uv_bin" || ! -x "$uv_bin" ]]; then
    echo 'uv was not found. Install it using https://docs.astral.sh/uv/getting-started/installation/' >&2
    echo 'Or rerun with --uv /absolute/path/to/uv.' >&2
    exit 2
fi
printf 'Using uv: %s\n' "$uv_bin"
if ((EUID == 0)); then
    echo 'Run as your normal login user, not sudo. Privileged steps request sudo individually.' >&2
    exit 2
fi

run() {
    printf '+ '; printf '%q ' "$@"; printf '\n'
    if ! $dry_run; then "$@"; fi
}

check_gpu_access() {
    local node group configured_groups groups_to_add='' inaccessible=false
    local login_user
    login_user=$(id -un)
    configured_groups=" $(id -nG "$login_user") "
    for node in /dev/dri/renderD* /dev/nvmap /dev/nvhost-gpu /dev/nvhost-ctrl-gpu; do
        [[ -e "$node" ]] || continue
        if [[ -r "$node" && -w "$node" ]]; then continue; fi
        inaccessible=true
        group=$(stat -c '%G' "$node")
        printf 'GPU access missing: %s (group %s)\n' "$node" "$group" >&2
        case "$group" in
            video|render)
                if [[ "$configured_groups" != *" $group "* && " $groups_to_add " != *" $group "* ]]; then
                    groups_to_add="${groups_to_add:+$groups_to_add }$group"
                fi ;;
            *)
                echo 'Unexpected GPU device owner group; inspect device permissions/ACLs. No chmod will be applied.' >&2
                return 1 ;;
        esac
    done
    if [[ -n "$groups_to_add" ]]; then
        run sudo usermod -a -G "${groups_to_add// /,}" "$login_user"
    fi
    if $inaccessible; then
        echo 'Open a NEW SSH login (or log out/in locally), then rerun bash install.sh.' >&2
        echo 'New group membership does not update this shell or an existing tmux session.' >&2
        echo 'If a fresh login still cannot access the nodes, inspect their ACLs and group ownership.' >&2
        if ! $dry_run; then return 3; fi
    fi
}

check_gpu_access
if ! command -v vulkaninfo >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install vulkan-tools for your Linux distribution first.' >&2; exit 2; }
    run sudo apt-get update
    run sudo apt-get install -y vulkan-tools
fi

# Test the same library/ICD environment the runtime will inherit. Ignore the
# SSH-forwarded display: CloudXR needs the GPU, not a forwarded desktop window.
vulkan_log="$script_dir/vulkan-check.log"
if $dry_run; then
    run env -u DISPLAY -u WAYLAND_DISPLAY timeout 30s vulkaninfo --summary
else
    if ! env -u DISPLAY -u WAYLAND_DISPLAY timeout 30s vulkaninfo --summary > "$vulkan_log" 2>&1; then
        cat "$vulkan_log" >&2
        printf 'Vulkan GPU initialization failed. See %s\n' "$vulkan_log" >&2
        echo 'Check GPU device permissions, inherited VK_*/LD_LIBRARY_PATH overrides, and the JetPack driver installation.' >&2
        echo 'No driver packages, ICD manifests, or device permissions have been replaced.' >&2
        exit 1
    fi
    for extension in VK_KHR_external_fence_capabilities VK_KHR_external_memory_capabilities \
                     VK_KHR_external_semaphore_capabilities VK_KHR_get_physical_device_properties2; do
        if ! grep -q "$extension" "$vulkan_log"; then
            printf 'Vulkan is missing %s; see %s. CloudXR cannot start.\n' "$extension" "$vulkan_log" >&2
            exit 1
        fi
    done
    if ! grep -qiE 'vendorID[[:space:]]*=[[:space:]]*0x10de' "$vulkan_log"; then
        printf 'No NVIDIA Vulkan GPU found. See %s\n' "$vulkan_log" >&2
        exit 1
    fi
    printf 'PASS: NVIDIA Vulkan GPU and required instance extensions. Log: %s\n' "$vulkan_log"
fi

if [[ ! -f "$venv/pyvenv.cfg" ]]; then
    if [[ -e "$venv" ]]; then echo "Refusing to replace existing non-venv path: $venv" >&2; exit 2; fi
    run "$uv_bin" venv --python "$python_version" "$venv"
fi
if ! $dry_run; then
    "$venv/bin/python" -c 'import sys; sys.exit(0 if (3, 12) <= sys.version_info[:2] < (3, 14) else "Use Python 3.12 or 3.13.")'
fi
run "$uv_bin" pip install --python "$venv/bin/python" \
    'isaacteleop[cloudxr,retargeters-lite]==1.4.145' 'numpy>=2,<2.3' 'scipy>=1.15,<1.17'
run "$venv/bin/python" "$script_dir/patch_cloudxr_page.py"
run "$venv/bin/python" "$script_dir/verify.py" --check-only
if ! $dry_run; then
    printf '\nInstalled. Run a headset test after reviewing NVIDIA’s EULA:\n'
    printf '  %q %q --headset --accept-eula\n' "$venv/bin/python" "$script_dir/verify.py"
fi
