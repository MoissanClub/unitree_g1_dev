#!/usr/bin/env bash
# Setup BrainCo Revo2 hands for Unitree G1.
# This script follows BrainCoTech/unitree-g1-brainco-hand and adds:
#   - ~/g1-brainco symlink normalization
#   - FTDI USB-RS485 permission setup
#   - port scanning for Revo2 slave IDs 0x7e and 0x7f
#   - stable /dev/serial/by-id ROS2 config
#   - optional Unitree ROS2 and G1 URDF checks

set -euo pipefail
shopt -s nullglob

REPO_URL="https://github.com/BrainCoTech/unitree-g1-brainco-hand.git"
UNITREE_ROS2_URL="https://github.com/unitreerobotics/unitree_ros2.git"
UNITREE_ROS_URL="https://github.com/unitreerobotics/unitree_ros.git"

CHECKOUT_DIR="${HOME}/unitree-g1-brainco-hand"
BASE_DIR="${HOME}/g1-brainco"
UNITREE_ROS2_DIR="${HOME}/unitree_ros2"
G1_DESC_DIR="${HOME}/g1_description"
CONDA_ENV="g1brainco"
NET_IF="eth0"
ROBOT_DOF="29"
BAUDRATE="460800"
LEFT_SLAVE="0x7e"
RIGHT_SLAVE="0x7f"
LEFT_PORT=""
RIGHT_PORT=""
FTDI_SERIAL=""

SKIP_APT=0
SKIP_CONDA=0
SKIP_UNITREE_ROS2=0
SKIP_G1_DESCRIPTION=0
SKIP_SCAN=0
SKIP_UDEV=0
SKIP_BUILD=0
NO_PULL=0

OBSERVED_LEFT='/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_FTA1LW3T-if02-port0'
OBSERVED_RIGHT='/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_FTA1LW3T-if01-port0'

log()  { printf '\033[1;32m[brainco-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[brainco-setup][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[brainco-setup][error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options]

Default behavior:
  * clone/update ${REPO_URL} into ~/unitree-g1-brainco-hand
  * create/update ~/g1-brainco symlink, because repo launch scripts assume it
  * create conda env '${CONDA_ENV}' with Python 3.8 and required packages
  * chmod current USB serial ports so scanning works immediately
  * scan /dev/serial/by-id and /dev/ttyUSB* for BrainCo Revo2 slaves 0x7e/0x7f
  * write ros2_stark params to source and installed config paths
  * install a permanent udev rule for the FTDI FT4232H USB-RS485 adapter
  * build brainco_ws and ros2_stark_ws

Options:
  --checkout-dir PATH       Repo checkout path. Default: ~/unitree-g1-brainco-hand
  --base-dir PATH           Path expected by launch scripts. Default: ~/g1-brainco
  --unitree-ros2-dir PATH   Unitree ROS2 path. Default: ~/unitree_ros2
  --g1-description-dir PATH G1 description path. Default: ~/g1_description
  --conda-env NAME          Conda env name. Default: g1brainco
  --net-if IFACE            Network interface for ~/unitree_ros2/setup.sh. Default: eth0
  --dof 23|29               robot_dof in smach_config.yaml. Default: 29
  --left-port PATH          Override left hand serial port; skips left result from scan
  --right-port PATH         Override right hand serial port; skips right result from scan
  --ftdi-serial SERIAL      Override FTDI serial used in udev rule, e.g. FTA1LW3T
  --skip-apt                Do not install apt packages
  --skip-conda              Do not create/update conda env
  --skip-unitree-ros2       Do not auto-clone/build ~/unitree_ros2 if missing
  --skip-g1-description     Do not download/patch G1 URDF path
  --skip-scan               Do not scan ports; requires --left-port and --right-port or observed ports
  --skip-udev               Do not install permanent udev rule
  --skip-build              Do not colcon build workspaces
  --no-pull                 Do not git pull existing checkout
  -h|--help                 Show this help

Example with your known adapter:
  $0 \
    --left-port '${OBSERVED_LEFT}' \
    --right-port '${OBSERVED_RIGHT}' \
    --ftdi-serial FTA1LW3T
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkout-dir) CHECKOUT_DIR="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --unitree-ros2-dir) UNITREE_ROS2_DIR="$2"; shift 2 ;;
    --g1-description-dir) G1_DESC_DIR="$2"; shift 2 ;;
    --conda-env) CONDA_ENV="$2"; shift 2 ;;
    --net-if) NET_IF="$2"; shift 2 ;;
    --dof) ROBOT_DOF="$2"; shift 2 ;;
    --left-port) LEFT_PORT="$2"; shift 2 ;;
    --right-port) RIGHT_PORT="$2"; shift 2 ;;
    --ftdi-serial) FTDI_SERIAL="$2"; shift 2 ;;
    --skip-apt) SKIP_APT=1; shift ;;
    --skip-conda) SKIP_CONDA=1; shift ;;
    --skip-unitree-ros2) SKIP_UNITREE_ROS2=1; shift ;;
    --skip-g1-description) SKIP_G1_DESCRIPTION=1; shift ;;
    --skip-scan) SKIP_SCAN=1; shift ;;
    --skip-udev) SKIP_UDEV=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --no-pull) NO_PULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$ROBOT_DOF" == "23" || "$ROBOT_DOF" == "29" ]] || die "--dof must be 23 or 29"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command '$1'. Install it and rerun."
}

install_apt_deps() {
  [[ "$SKIP_APT" == "1" ]] && return 0
  log "Installing/checking apt packages..."
  sudo apt-get update
  sudo apt-get install -y \
    git curl ca-certificates build-essential pkg-config \
    python3-pip python3-colcon-common-extensions \
    udev libyaml-cpp-dev

  if [[ -f /opt/ros/foxy/setup.bash ]]; then
    sudo apt-get install -y ros-foxy-rmw-cyclonedds-cpp ros-foxy-rosidl-generator-dds-idl || true
  fi
}

clone_or_update_repo() {
  need_cmd git

  if [[ -d "${BASE_DIR}/.git" ]]; then
    CHECKOUT_DIR="$BASE_DIR"
    log "Using existing repo at ${BASE_DIR}"
  elif [[ ! -d "${CHECKOUT_DIR}/.git" ]]; then
    log "Cloning BrainCo G1 repo into ${CHECKOUT_DIR}..."
    git clone "$REPO_URL" "$CHECKOUT_DIR"
  else
    log "Using existing repo at ${CHECKOUT_DIR}"
  fi

  if [[ "$NO_PULL" == "0" ]]; then
    log "Updating BrainCo repo with git pull --ff-only..."
    git -C "$CHECKOUT_DIR" pull --ff-only || warn "git pull failed; continuing with existing checkout."
  fi

  if [[ "$(realpath -m "$CHECKOUT_DIR")" != "$(realpath -m "$BASE_DIR")" ]]; then
    if [[ -e "$BASE_DIR" && ! -L "$BASE_DIR" ]]; then
      die "${BASE_DIR} exists and is not a symlink. Move it aside or pass --base-dir."
    fi
    log "Creating symlink ${BASE_DIR} -> ${CHECKOUT_DIR}"
    ln -sfn "$CHECKOUT_DIR" "$BASE_DIR"
  fi

  chmod +x "${BASE_DIR}/brainco_ws/launch/launch_robot.sh" \
           "${BASE_DIR}/brainco_ws/launch/launch_trans.sh" || true
}

conda_shell_setup() {
  if command -v conda >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    return 0
  fi

  if [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/miniconda3/etc/profile.d/conda.sh"
    return 0
  fi

  if [[ -f "${HOME}/anaconda3/etc/profile.d/conda.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/anaconda3/etc/profile.d/conda.sh"
    return 0
  fi

  return 1
}

ensure_conda_env() {
  [[ "$SKIP_CONDA" == "1" ]] && return 0
  conda_shell_setup || die "Conda was not found. Install Miniconda for Linux ARM64 on the G1, then rerun."

  if ! conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV"; then
    log "Creating conda env ${CONDA_ENV} with Python 3.8..."
    conda create -y -n "$CONDA_ENV" python=3.8
  fi

  log "Installing Python/conda dependencies in ${CONDA_ENV}..."
  conda activate "$CONDA_ENV"
  conda install -y -c conda-forge pinocchio
  python -m pip install --upgrade pip
  python -m pip install \
    meshcat transitions rospkg colcon-common-extensions loguru matplotlib \
    empy==3.3.2 lark-parser colorlog 'asyncio>=3.4.3' 'bc-stark-sdk==1.1.9'
}

ensure_unitree_ros2() {
  if [[ -f "${UNITREE_ROS2_DIR}/setup.sh" ]]; then
    log "Found Unitree ROS2 at ${UNITREE_ROS2_DIR}"
    patch_unitree_setup
    return 0
  fi

  [[ "$SKIP_UNITREE_ROS2" == "1" ]] && { warn "Skipping Unitree ROS2 setup."; return 0; }

  if [[ ! -f /opt/ros/foxy/setup.bash ]]; then
    warn "${UNITREE_ROS2_DIR}/setup.sh not found and /opt/ros/foxy/setup.bash is missing; cannot auto-build Unitree ROS2."
    warn "Install/source ROS2 Foxy and Unitree ROS2 before building BrainCo workspaces."
    return 0
  fi

  log "Unitree ROS2 not found; cloning/building ${UNITREE_ROS2_URL}..."
  git clone "$UNITREE_ROS2_URL" "$UNITREE_ROS2_DIR"

  if [[ ! -d "${UNITREE_ROS2_DIR}/cyclonedds_ws/src/rmw_cyclonedds" ]]; then
    git clone https://github.com/ros2/rmw_cyclonedds -b foxy \
      "${UNITREE_ROS2_DIR}/cyclonedds_ws/src/rmw_cyclonedds"
  fi
  if [[ ! -d "${UNITREE_ROS2_DIR}/cyclonedds_ws/src/cyclonedds" ]]; then
    git clone https://github.com/eclipse-cyclonedds/cyclonedds -b releases/0.10.x \
      "${UNITREE_ROS2_DIR}/cyclonedds_ws/src/cyclonedds"
  fi

  (
    cd "${UNITREE_ROS2_DIR}/cyclonedds_ws"
    colcon build --packages-select cyclonedds || \
      (export LD_LIBRARY_PATH=/opt/ros/foxy/lib:${LD_LIBRARY_PATH:-}; colcon build --packages-select cyclonedds)
  )

  (
    # shellcheck disable=SC1091
    source /opt/ros/foxy/setup.bash
    cd "${UNITREE_ROS2_DIR}/cyclonedds_ws"
    colcon build
  )

  patch_unitree_setup
}

patch_unitree_setup() {
  local setup_file="${UNITREE_ROS2_DIR}/setup.sh"
  [[ -f "$setup_file" ]] || return 0
  log "Patching ${setup_file} to use network interface '${NET_IF}'..."
  cp -n "$setup_file" "${setup_file}.bak" || true
  python3 - "$setup_file" "$NET_IF" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
iface = sys.argv[2]
text = path.read_text()
text = re.sub(r'<NetworkInterface name="[^"]+"', f'<NetworkInterface name="{iface}"', text)
path.write_text(text)
PY
}

setup_g1_description() {
  [[ "$SKIP_G1_DESCRIPTION" == "1" ]] && return 0
  if [[ ! -d "$G1_DESC_DIR" ]]; then
    log "Downloading Unitree G1 description into ${G1_DESC_DIR}..."
    local tmp
    tmp="$(mktemp -d)"
    if git clone --depth 1 --filter=blob:none --sparse "$UNITREE_ROS_URL" "${tmp}/unitree_ros"; then
      git -C "${tmp}/unitree_ros" sparse-checkout set robots/g1_description
    else
      rm -rf "${tmp}/unitree_ros"
      git clone --depth 1 "$UNITREE_ROS_URL" "${tmp}/unitree_ros"
    fi
    cp -a "${tmp}/unitree_ros/robots/g1_description" "$G1_DESC_DIR"
    rm -rf "$tmp"
  fi

  local rc="${BASE_DIR}/brainco_ws/src/control_py/control_py/action_pkg/robot_control.py"
  if [[ -f "$rc" ]]; then
    log "Patching arm_urdf_path in robot_control.py to ${G1_DESC_DIR}/"
    cp -n "$rc" "${rc}.bak" || true
    python3 - "$rc" "${G1_DESC_DIR}/" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
urdf_dir = sys.argv[2]
text = path.read_text()
text = re.sub(r"arm_urdf_path\s*=\s*['\"][^'\"]*['\"]", f"arm_urdf_path = {urdf_dir!r}", text)
path.write_text(text)
PY
  fi
}

chmod_usb_serial_now() {
  log "Temporarily chmod'ing current USB serial ports for this login/session..."
  local p real
  for p in /dev/ttyUSB* /dev/ttyACM* /dev/serial/by-id/*; do
    [[ -e "$p" ]] || continue
    real="$(readlink -f "$p" 2>/dev/null || true)"
    [[ -n "$real" && -e "$real" ]] || continue
    sudo chmod 666 "$real" || true
  done
}

write_scanner() {
  mkdir -p "${BASE_DIR}/tools"
  cat > "${BASE_DIR}/tools/scan_brainco_ports.py" <<'PY'
#!/usr/bin/env python3
"""Scan serial ports for BrainCo Revo2 Modbus slaves 0x7e and 0x7f."""
import argparse
import asyncio
import glob
import inspect
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def stable_name(path: str) -> str:
    p = Path(path)
    if str(p).startswith("/dev/serial/by-id/"):
        return str(p)
    try:
        real = os.path.realpath(path)
        for byid in sorted(glob.glob("/dev/serial/by-id/*")):
            if os.path.realpath(byid) == real:
                return byid
    except Exception:
        pass
    return path


def serial_short(path: str) -> str:
    names = [path]
    try:
        names.append(os.path.realpath(path))
    except Exception:
        pass
    for name in names:
        try:
            out = subprocess.check_output(
                ["udevadm", "info", "--query=property", f"--name={name}"],
                stderr=subprocess.DEVNULL,
                text=True,
            )
            for line in out.splitlines():
                if line.startswith("ID_SERIAL_SHORT="):
                    return line.split("=", 1)[1].strip()
        except Exception:
            pass
    base = os.path.basename(stable_name(path))
    m = re.search(r"Converter_([^/-]+)-if", base)
    return m.group(1) if m else ""


def candidate_ports():
    preferred = sorted(glob.glob("/dev/serial/by-id/*"))
    fallback = sorted(glob.glob("/dev/ttyUSB*")) + sorted(glob.glob("/dev/ttyACM*"))
    out, seen = [], set()
    for p in preferred + fallback:
        if not os.path.exists(p):
            continue
        try:
            real = os.path.realpath(p)
        except Exception:
            real = p
        if real in seen:
            continue
        seen.add(real)
        out.append(p)
    return out


async def maybe_close(libstark, ctx):
    if ctx is None:
        return
    for attr in ("modbus_close", "close"):
        fn = getattr(ctx, attr, None)
        if fn:
            try:
                result = fn()
                if inspect.isawaitable(result):
                    await result
                return
            except Exception:
                pass
    try:
        result = libstark.modbus_close(ctx)
        if inspect.isawaitable(result):
            await result
    except Exception:
        pass


async def call_with_timeout(coro, timeout):
    return await asyncio.wait_for(coro, timeout=timeout)


async def probe_port(libstark, port, baudrate, slaves, timeout):
    # SDK examples use the enum libstark.Baudrate.Baud460800, but recent wheels also accept int.
    baud_arg = baudrate
    try:
        if int(baudrate) == 460800:
            baud_arg = getattr(getattr(libstark, "Baudrate"), "Baud460800")
    except Exception:
        pass

    results = []
    ctx = None
    try:
        ctx = await call_with_timeout(libstark.modbus_open(port, baud_arg), timeout)
    except Exception as exc:
        return {"port": port, "stable_port": stable_name(port), "error": f"open failed: {exc}", "matches": []}

    try:
        for slave in slaves:
            try:
                info = await call_with_timeout(ctx.get_device_info(slave), timeout)
                desc = getattr(info, "description", str(info))
                voltage = None
                try:
                    voltage = await call_with_timeout(ctx.get_voltage(slave), timeout)
                except Exception:
                    pass
                results.append(
                    {
                        "port": port,
                        "stable_port": stable_name(port),
                        "slave_id": f"0x{slave:02x}",
                        "description": desc,
                        "voltage_mv": voltage,
                        "ftdi_serial": serial_short(port),
                    }
                )
            except Exception:
                continue
    finally:
        await maybe_close(libstark, ctx)

    return {"port": port, "stable_port": stable_name(port), "matches": results}


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baud", type=int, default=460800)
    parser.add_argument("--slaves", nargs="+", default=["0x7e", "0x7f"])
    parser.add_argument("--timeout", type=float, default=1.5)
    parser.add_argument("--json-out", default="")
    args = parser.parse_args()

    try:
        from bc_stark_sdk import main_mod as libstark
    except Exception as exc:
        print(f"ERROR: cannot import bc_stark_sdk: {exc}", file=sys.stderr)
        return 2

    try:
        libstark.init_logging()
    except Exception:
        pass

    slaves = [int(str(s), 0) for s in args.slaves]
    ports = candidate_ports()
    if not ports:
        print("ERROR: no /dev/serial/by-id, /dev/ttyUSB, or /dev/ttyACM ports found", file=sys.stderr)
        return 3

    all_results = []
    for port in ports:
        result = await probe_port(libstark, port, args.baud, slaves, args.timeout)
        all_results.append(result)

    by_slave = {f"0x{s:02x}": [] for s in slaves}
    for result in all_results:
        for match in result.get("matches", []):
            by_slave.setdefault(match["slave_id"], []).append(match)

    left = by_slave.get("0x7e", [])
    right = by_slave.get("0x7f", [])
    ftdi_serial = ""
    for match in (left + right):
        if match.get("ftdi_serial"):
            ftdi_serial = match["ftdi_serial"]
            break

    summary = {
        "baudrate": args.baud,
        "left_slave": "0x7e",
        "right_slave": "0x7f",
        "left_port": left[0]["stable_port"] if left else "",
        "right_port": right[0]["stable_port"] if right else "",
        "ftdi_serial": ftdi_serial,
        "all_results": all_results,
    }

    text = json.dumps(summary, indent=2)
    print(text)
    if args.json_out:
        Path(args.json_out).write_text(text + "\n")

    return 0 if summary["left_port"] and summary["right_port"] else 4


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
PY
  chmod +x "${BASE_DIR}/tools/scan_brainco_ports.py"
}

run_port_scan() {
  [[ "$SKIP_SCAN" == "1" ]] && return 0
  [[ -n "$LEFT_PORT" && -n "$RIGHT_PORT" ]] && return 0

  write_scanner
  log "Scanning serial ports for BrainCo slaves ${LEFT_SLAVE} and ${RIGHT_SLAVE} at ${BAUDRATE}..."

  if [[ "$SKIP_CONDA" == "0" ]]; then
    conda_shell_setup && conda activate "$CONDA_ENV" || true
  fi

  local scan_json
  scan_json="$(mktemp)"
  local scan_rc=0
  python "${BASE_DIR}/tools/scan_brainco_ports.py" --baud "$BAUDRATE" --slaves "$LEFT_SLAVE" "$RIGHT_SLAVE" --json-out "$scan_json" || scan_rc=$?

  if [[ -s "$scan_json" ]]; then
    local scanned_left scanned_right scanned_serial
    scanned_left="$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(j.get("left_port", ""))' "$scan_json" 2>/dev/null || true)"
    scanned_right="$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(j.get("right_port", ""))' "$scan_json" 2>/dev/null || true)"
    scanned_serial="$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(j.get("ftdi_serial", ""))' "$scan_json" 2>/dev/null || true)"
    [[ -z "$LEFT_PORT" ]] && LEFT_PORT="$scanned_left"
    [[ -z "$RIGHT_PORT" ]] && RIGHT_PORT="$scanned_right"
    [[ -z "$FTDI_SERIAL" ]] && FTDI_SERIAL="$scanned_serial"
  fi

  if [[ "$scan_rc" != "0" ]]; then
    warn "Port scan did not find both hands. Full scan output:"
    cat "$scan_json" >&2 || true
  fi
  rm -f "$scan_json"
}

use_observed_ports_if_present() {
  if [[ -z "$LEFT_PORT" && -e "$OBSERVED_LEFT" ]]; then
    warn "Using observed left port fallback: ${OBSERVED_LEFT}"
    LEFT_PORT="$OBSERVED_LEFT"
  fi
  if [[ -z "$RIGHT_PORT" && -e "$OBSERVED_RIGHT" ]]; then
    warn "Using observed right port fallback: ${OBSERVED_RIGHT}"
    RIGHT_PORT="$OBSERVED_RIGHT"
  fi
  if [[ -z "$FTDI_SERIAL" ]]; then
    FTDI_SERIAL="$(derive_serial_from_port "${LEFT_PORT:-${RIGHT_PORT:-}}" || true)"
  fi
}

derive_serial_from_port() {
  local port="$1"
  [[ -n "$port" && -e "$port" ]] || return 1
  local serial=""
  serial="$(udevadm info --query=property --name="$port" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}' || true)"
  if [[ -z "$serial" ]]; then
    serial="$(udevadm info --query=property --name="$(readlink -f "$port")" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}' || true)"
  fi
  if [[ -z "$serial" ]]; then
    serial="$(basename "$port" | sed -n 's/.*Converter_\([^-]*\)-if.*/\1/p')"
  fi
  [[ -n "$serial" ]] || return 1
  printf '%s\n' "$serial"
}

write_params_file() {
  local target="$1"
  local dir
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  cp -n "$target" "${target}.bak" 2>/dev/null || true
  cat > "$target" <<EOF
stark_node:
  ros__parameters:
    port_l: "${LEFT_PORT}"
    port_r: "${RIGHT_PORT}"
    baudrate: ${BAUDRATE}
    slave_id_l: ${LEFT_SLAVE}
    slave_id_r: ${RIGHT_SLAVE}
    firmware_type: 3
    protocol_type: 1
    log_level: 1
    log_screen: false
EOF
}

configure_hand_params() {
  use_observed_ports_if_present
  [[ -n "$LEFT_PORT" ]] || die "Left hand port is unknown. Rerun with --left-port or fix scan/USB wiring."
  [[ -n "$RIGHT_PORT" ]] || die "Right hand port is unknown. Rerun with --right-port or fix scan/USB wiring."

  log "Configuring BrainCo hand ports:"
  log "  left  ${LEFT_SLAVE}: ${LEFT_PORT}"
  log "  right ${RIGHT_SLAVE}: ${RIGHT_PORT}"

  write_params_file "${BASE_DIR}/ros2_stark_ws/src/ros2_stark_controller/config/params_v2_double.yaml"

  local smach="${BASE_DIR}/brainco_ws/src/control_py/config/smach_config.yaml"
  if [[ -f "$smach" ]]; then
    log "Setting robot_dof=${ROBOT_DOF} in smach_config.yaml"
    cp -n "$smach" "${smach}.bak" || true
    python3 - "$smach" "$ROBOT_DOF" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
dof = sys.argv[2]
text = path.read_text()
if "robot_dof:" in text:
    text = re.sub(r"robot_dof:\s*\d+", f"robot_dof: {dof}", text)
else:
    text += f"\nrobot_dof: {dof}\n"
path.write_text(text)
PY
  fi
}

install_permanent_rule() {
  [[ "$SKIP_UDEV" == "1" ]] && return 0
  local user_name="${SUDO_USER:-$USER}"
  local rule_file="/etc/udev/rules.d/99-brainco-ftdi.rules"

  if [[ -z "$FTDI_SERIAL" ]]; then
    FTDI_SERIAL="$(derive_serial_from_port "${LEFT_PORT:-${RIGHT_PORT:-}}" || true)"
  fi
  [[ -n "$FTDI_SERIAL" ]] || die "Could not determine FTDI serial. Pass --ftdi-serial FTA1LW3T or inspect /dev/serial/by-id."

  log "Adding user '${user_name}' to dialout group..."
  sudo usermod -aG dialout "$user_name"

  log "Installing permanent udev rule: ${rule_file}"
  sudo tee "$rule_file" >/dev/null <<EOF
# BrainCo / Unitree G1 FTDI FT4232H serial ports.
# Device observed as idVendor=0403, idProduct=6011, serial=${FTDI_SERIAL}.
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6011", ATTRS{serial}=="${FTDI_SERIAL}", GROUP="dialout", MODE="0666"
EOF

  log "Reloading udev rules..."
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=tty || true

  log "Permanent port setup done. Log out/in or reboot once for dialout membership to refresh."
}

build_workspaces() {
  [[ "$SKIP_BUILD" == "1" ]] && return 0
  log "Building BrainCo workspaces..."

  if [[ "$SKIP_CONDA" == "0" ]]; then
    conda_shell_setup || die "Conda missing while build requested."
    conda activate "$CONDA_ENV"
  fi

  if [[ -f "${UNITREE_ROS2_DIR}/setup.sh" ]]; then
    # shellcheck disable=SC1090
    source "${UNITREE_ROS2_DIR}/setup.sh"
  elif [[ -f /opt/ros/foxy/setup.bash ]]; then
    # shellcheck disable=SC1091
    source /opt/ros/foxy/setup.bash
  else
    warn "No Unitree/ROS2 setup found; build may fail."
  fi

  (
    cd "${BASE_DIR}/brainco_ws"
    python -m colcon build
  )
  (
    cd "${BASE_DIR}/ros2_stark_ws"
    python -m colcon build
  )

  local installed="${BASE_DIR}/ros2_stark_ws/install/ros2_stark_controller/share/ros2_stark_controller/config/params_v2_double.yaml"
  if [[ -d "$(dirname "$installed")" ]]; then
    log "Writing installed ROS2 params: ${installed}"
    write_params_file "$installed"
  else
    warn "Installed params path not found after build: ${installed}"
  fi
}

write_run_wrappers() {
  log "Writing convenience launch wrappers..."
  cat > "${BASE_DIR}/run_brainco_robot.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "\$(conda info --base)/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV}"
cd "${BASE_DIR}/brainco_ws"
./launch/launch_robot.sh
EOF
  cat > "${BASE_DIR}/run_brainco_trans.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "\$(conda info --base)/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV}"
cd "${BASE_DIR}/brainco_ws"
./launch/launch_trans.sh
EOF
  chmod +x "${BASE_DIR}/run_brainco_robot.sh" "${BASE_DIR}/run_brainco_trans.sh"
}

main() {
  install_apt_deps
  ensure_unitree_ros2
  clone_or_update_repo
  ensure_conda_env
  setup_g1_description
  chmod_usb_serial_now
  run_port_scan
  configure_hand_params
  install_permanent_rule
  build_workspaces
  write_run_wrappers

  cat <<EOF

Done.

Configured:
  repo/base:       ${BASE_DIR}
  left hand:       ${LEFT_PORT}  slave ${LEFT_SLAVE}
  right hand:      ${RIGHT_PORT} slave ${RIGHT_SLAVE}
  baudrate:        ${BAUDRATE}
  FTDI serial:     ${FTDI_SERIAL:-unknown}
  robot_dof:       ${ROBOT_DOF}

Next steps:
  1. Log out/in or reboot once so dialout group membership applies.
  2. Start the robot per the BrainCo/Unitree directions: Zero Torque -> Damping -> Ready.
  3. Terminal 1: ${BASE_DIR}/run_brainco_robot.sh
  4. Terminal 2: ${BASE_DIR}/run_brainco_trans.sh

Expected Terminal 1 signs:
  * Left/right Port, Baudrate, slave_id are correct
  * "serial port opened"
  * "Waiting for joint cmd ..."
  * "IK initialization done."
  * "Request 'configure' to start"
EOF
}

main "$@"
