#!/usr/bin/env bash
# Robust DDS / Unitree ROS 2 setup helper for a Unitree G1 EDU PC2.
# Supported targets: Ubuntu 20.04 + ROS 2 Foxy, or Ubuntu 22.04 + ROS 2 Humble.
# Run as a normal user from a fresh SSH/terminal session when possible:
#   bash setup_unitree_g1_pc2_dds.sh --auto-iface
# Revision: handles ROS setup files safely even when this script uses bash nounset.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
WORKSPACE="${UNITREE_ROS2_DIR:-$HOME/unitree_ros2}"
ROS_DISTRO_TARGET="${UNITREE_ROS_DISTRO:-}"
OS_ID="unknown"
OS_VERSION="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
fi
if [[ -z "$ROS_DISTRO_TARGET" ]]; then
  case "$OS_ID:$OS_VERSION" in
    ubuntu:20.04) ROS_DISTRO_TARGET="foxy" ;;
    ubuntu:22.04) ROS_DISTRO_TARGET="humble" ;;
    *) ROS_DISTRO_TARGET="foxy" ;;
  esac
fi
ROBOT_IP="${UNITREE_ROBOT_IP:-192.168.123.161}"
IFACE="${UNITREE_DDS_IFACE:-}"
ASSUME_YES=0
INSTALL_DEPS=1
INSTALL_ROS=0
REPAIR_NVIDIA_APT=0
ALLOW_CLONE=1
CLEAN_BUILD=1
PATCH_SETUP=1
RUN_TEST=1
STRICT_TEST=0
TEST_TIMEOUT=15
ENSURE_IP_CIDR=""
PARALLEL_WORKERS=""
STRIP_CONDA_PATH=1

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME [options]

Recommended for G1 EDU PC2:
  bash $SCRIPT_NAME --auto-iface

Options:
  --iface IFACE             Network interface used by DDS/robot traffic, e.g. eth0.
  --auto-iface              Auto-detect interface; this is the default if --iface is omitted.
  --robot-ip IP             Robot/controller IP used only for route-based interface detection.
                             Default: $ROBOT_IP
  --workspace DIR           unitree_ros2 checkout. Default: $WORKSPACE
  --ros-distro DISTRO       ROS 2 distro. Auto-detected default: $ROS_DISTRO_TARGET
  --ensure-ip CIDR          Temporarily add CIDR to --iface if missing, e.g. 192.168.123.99/24.
                             This does not persist across reboot and is intentionally opt-in.
  --parallel-workers N      Pass --parallel-workers N to colcon.
  --install-ros             Install the matching ROS 2 base distribution if missing.
  --repair-nvidia-apt       Back up and repair a malformed Jetson L4T APT source file.
  --skip-deps               Do not apt-install/check dependency packages.
  --skip-clone              Do not clone missing repositories; fail if sources are absent.
  --no-clean                Do not remove cyclonedds_ws/build install log before building.
  --no-patch-setup          Do not rewrite ~/unitree_ros2/setup.sh.
  --no-test                 Do not run the final ros2 topic list smoke test.
  --strict-test             Exit nonzero if the final smoke test fails or sees no topics.
  --keep-conda-path         Run conda deactivate, but do not strip conda-like PATH entries.
  -y, --yes                 Non-interactive mode; choose the best detected interface.
  -h, --help                Show this help.

Environment overrides:
  UNITREE_ROS2_DIR, UNITREE_ROS_DISTRO, UNITREE_ROBOT_IP, UNITREE_DDS_IFACE
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface)
      [[ $# -ge 2 ]] || die "--iface requires a value"
      IFACE="$2"; shift 2 ;;
    --auto-iface)
      IFACE=""; shift ;;
    --robot-ip)
      [[ $# -ge 2 ]] || die "--robot-ip requires a value"
      ROBOT_IP="$2"; shift 2 ;;
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace requires a value"
      WORKSPACE="$2"; shift 2 ;;
    --ros-distro)
      [[ $# -ge 2 ]] || die "--ros-distro requires a value"
      ROS_DISTRO_TARGET="$2"; shift 2 ;;
    --ensure-ip)
      [[ $# -ge 2 ]] || die "--ensure-ip requires a CIDR value, e.g. 192.168.123.99/24"
      ENSURE_IP_CIDR="$2"; shift 2 ;;
    --parallel-workers)
      [[ $# -ge 2 ]] || die "--parallel-workers requires a number"
      PARALLEL_WORKERS="$2"; shift 2 ;;
    --install-ros)
      INSTALL_ROS=1; shift ;;
    --repair-nvidia-apt)
      REPAIR_NVIDIA_APT=1; shift ;;
    --skip-deps)
      INSTALL_DEPS=0; shift ;;
    --skip-clone)
      ALLOW_CLONE=0; shift ;;
    --no-clean)
      CLEAN_BUILD=0; shift ;;
    --no-patch-setup)
      PATCH_SETUP=0; shift ;;
    --no-test)
      RUN_TEST=0; shift ;;
    --strict-test)
      STRICT_TEST=1; shift ;;
    --keep-conda-path)
      STRIP_CONDA_PATH=0; shift ;;
    -y|--yes)
      ASSUME_YES=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

# Expand ~ and relative paths without requiring realpath/readlink -f to exist on older systems.
WORKSPACE="$(cd "$(dirname "$WORKSPACE")" 2>/dev/null && pwd)/$(basename "$WORKSPACE")" || die "Cannot resolve workspace parent for: $WORKSPACE"
DDS_WS="$WORKSPACE/cyclonedds_ws"
SETUP_FILE="$WORKSPACE/setup.sh"

COLCON_ARGS=(--event-handlers console_direct+)
if [[ -n "$PARALLEL_WORKERS" ]]; then
  [[ "$PARALLEL_WORKERS" =~ ^[0-9]+$ ]] || die "--parallel-workers must be a positive integer"
  COLCON_ARGS+=(--parallel-workers "$PARALLEL_WORKERS")
fi

run() {
  log "Running: $*"
  "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

sudo_cmd() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

safe_source() {
  # ROS/colcon setup scripts assume bash nounset is OFF. This helper lets the
  # outer script keep strict mode while avoiding failures such as:
  #   AMENT_TRACE_SETUP_FILES: unbound variable
  local file="$1"
  [[ -f "$file" ]] || die "Cannot source missing setup file: $file"

  local restore_nounset=0
  local rc=0
  case "$-" in
    *u*) restore_nounset=1; set +u ;;
  esac

  # shellcheck disable=SC1090
  if source "$file"; then
    rc=0
  else
    rc=$?
  fi

  if [[ "$restore_nounset" -eq 1 ]]; then
    set -u
  fi
  return "$rc"
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]
}

on_error() {
  local line="$1"
  warn "Setup failed near line $line. Review the first error above this message; later warnings are often consequences of that error."
  warn "For build failures, retry from a fresh terminal with Conda disabled. AMENT_TRACE_SETUP_FILES errors require nounset to be disabled while sourcing ROS setup files."
}
trap 'on_error $LINENO' ERR

deactivate_conda_completely() {
  log "Deactivating Conda, if present, and clearing ROS/colcon/DDS environment variables."

  if command -v conda >/dev/null 2>&1; then
    local conda_base=""
    conda_base="$(conda info --base 2>/dev/null || true)"
    if [[ -n "$conda_base" && -f "$conda_base/etc/profile.d/conda.sh" ]]; then
      safe_source "$conda_base/etc/profile.d/conda.sh" || true
    fi
    for _ in 1 2 3 4 5; do
      conda deactivate >/dev/null 2>&1 || true
    done
  fi

  if [[ "$STRIP_CONDA_PATH" -eq 1 && -n "${PATH:-}" ]]; then
    local old_path="$PATH"
    local new_path=""
    local p=""
    IFS=':' read -r -a _path_parts <<< "$old_path"
    for p in "${_path_parts[@]}"; do
      case "$p" in
        *conda*|*Conda*|*anaconda*|*Anaconda*|*miniconda*|*Miniconda*|*mambaforge*|*Mambaforge*|*miniforge*|*Miniforge*|*micromamba*|*Micromamba*)
          continue
          ;;
      esac
      if [[ -z "$new_path" ]]; then
        new_path="$p"
      else
        new_path="$new_path:$p"
      fi
    done
    if [[ -n "$new_path" ]]; then
      export PATH="$new_path"
    else
      warn "PATH became empty after stripping Conda paths; restoring original PATH."
      export PATH="$old_path"
    fi
  fi

  unset CONDA_DEFAULT_ENV CONDA_PREFIX CONDA_PROMPT_MODIFIER CONDA_SHLVL
  unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH LD_LIBRARY_PATH
  unset ROS_DISTRO ROS_VERSION ROS_PYTHON_VERSION RMW_IMPLEMENTATION CYCLONEDDS_URI
  hash -r 2>/dev/null || true
}

apt_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

install_dependencies() {
  [[ "$INSTALL_DEPS" -eq 1 ]] || { log "Skipping apt dependency install/check."; return 0; }

  local packages=(
    git
    python3-colcon-common-extensions
    libyaml-cpp-dev
    "ros-${ROS_DISTRO_TARGET}-rmw-cyclonedds-cpp"
    "ros-${ROS_DISTRO_TARGET}-rosidl-generator-dds-idl"
  )
  local missing=()
  local pkg=""
  for pkg in "${packages[@]}"; do
    if ! apt_pkg_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "Required apt packages are already installed."
    return 0
  fi

  log "Installing missing apt packages: ${missing[*]}"
  run sudo_cmd apt-get update
  run sudo_cmd apt-get install -y "${missing[@]}"
}

validate_platform() {
  local expected=""
  case "$OS_ID:$OS_VERSION" in
    ubuntu:20.04) expected="foxy" ;;
    ubuntu:22.04) expected="humble" ;;
  esac

  if [[ -n "$expected" && "$ROS_DISTRO_TARGET" != "$expected" ]]; then
    die "Ubuntu $OS_VERSION requires ROS 2 $expected for this setup; requested: $ROS_DISTRO_TARGET"
  fi

}

repair_nvidia_apt_if_requested() {
  local source_file="/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
  [[ -f "$source_file" ]] || return 0

  # A Jetson suite such as r36.4 is invalid on ports.ubuntu.com. This exact
  # corruption also commonly duplicates the same bad line several times.
  if ! grep -Eq '^[[:space:]]*deb[[:space:]]+https?://ports\.ubuntu\.com/ubuntu-ports/?[[:space:]]+r[0-9]+' "$source_file"; then
    return 0
  fi

  if [[ "$REPAIR_NVIDIA_APT" -ne 1 ]]; then
    die "Malformed Jetson APT entries found in $source_file (Ubuntu Ports with an NVIDIA rXX.X suite). Rerun with --repair-nvidia-apt to back up and repair that file."
  fi
  [[ -r /etc/nv_tegra_release ]] || die "Cannot safely repair NVIDIA APT sources: /etc/nv_tegra_release is missing."

  local l4t_suite=""
  local platform=""
  local backup=""
  local tmp=""
  l4t_suite="$(sed -n 's/^# R\([0-9][0-9]*\).*REVISION:[[:space:]]*\([0-9][0-9]*\)\..*/r\1.\2/p' /etc/nv_tegra_release | head -n1)"
  [[ "$l4t_suite" =~ ^r[0-9]+\.[0-9]+$ ]] || die "Could not determine the Jetson L4T APT suite from /etc/nv_tegra_release."

  if [[ -r /proc/device-tree/compatible ]] && tr '\0' '\n' < /proc/device-tree/compatible | grep -q 'tegra234'; then
    platform="t234"
  elif [[ "$l4t_suite" == r36.* ]]; then
    # Jetson Linux R36 supports the Orin/T234 generation.
    platform="t234"
  else
    die "Could not safely determine the NVIDIA Jetson repository platform."
  fi

  backup="${source_file}.bak.$(date +%Y%m%d_%H%M%S)"
  tmp="$(mktemp)"
  sed '/^[[:space:]]*deb[[:space:]]/d' "$source_file" > "$tmp"
  printf '\ndeb https://repo.download.nvidia.com/jetson/common %s main\n' "$l4t_suite" >> "$tmp"
  printf 'deb https://repo.download.nvidia.com/jetson/%s %s main\n' "$platform" "$l4t_suite" >> "$tmp"
  printf 'deb https://repo.download.nvidia.com/jetson/ffmpeg %s main\n' "$l4t_suite" >> "$tmp"

  log "Backing up malformed NVIDIA APT sources to $backup"
  run sudo_cmd cp -a "$source_file" "$backup"
  run sudo_cmd install -m 0644 "$tmp" "$source_file"
  rm -f "$tmp"
  log "Repaired NVIDIA APT sources for $platform $l4t_suite."
}

ensure_ros() {
  if [[ -f "/opt/ros/${ROS_DISTRO_TARGET}/setup.bash" ]]; then
    log "ROS 2 $ROS_DISTRO_TARGET is already installed."
    return 0
  fi

  if [[ "$INSTALL_ROS" -ne 1 ]]; then
    die "ROS 2 $ROS_DISTRO_TARGET is not installed. Rerun with --install-ros, or install ros-${ROS_DISTRO_TARGET}-ros-base using the official ROS instructions."
  fi
  [[ "$OS_ID" == "ubuntu" ]] || die "Automatic ROS installation supports Ubuntu only (detected: $OS_ID $OS_VERSION)."
  need_cmd curl

  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ -n "$codename" ]] || die "Could not determine the Ubuntu codename from /etc/os-release."
  local release_json=""
  local apt_source_version=""
  local apt_source_deb=""

  log "Installing the official ROS 2 APT source and ros-${ROS_DISTRO_TARGET}-ros-base."
  repair_nvidia_apt_if_requested
  run sudo_cmd apt-get update
  run sudo_cmd apt-get install -y software-properties-common curl
  run sudo_cmd add-apt-repository -y universe

  release_json="$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest)"
  apt_source_version="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$release_json" | head -n1)"
  [[ "$apt_source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not determine a valid ros-apt-source release version."

  apt_source_deb="$(mktemp --suffix=.deb)"
  curl -fL --retry 3 -o "$apt_source_deb" \
    "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${apt_source_version}/ros2-apt-source_${apt_source_version}.${codename}_all.deb"
  run sudo_cmd dpkg -i "$apt_source_deb"
  rm -f "$apt_source_deb"
  run sudo_cmd apt-get update
  run sudo_cmd apt-get install -y "ros-${ROS_DISTRO_TARGET}-ros-base"

  [[ -f "/opt/ros/${ROS_DISTRO_TARGET}/setup.bash" ]] || die "ROS installation completed without creating /opt/ros/${ROS_DISTRO_TARGET}/setup.bash"
}

preflight() {
  need_cmd git
  need_cmd colcon
  need_cmd ip
  need_cmd timeout
}

clone_repo_if_needed() {
  if [[ -d "$WORKSPACE" ]]; then
    log "Using existing Unitree ROS 2 workspace: $WORKSPACE"
  else
    [[ "$ALLOW_CLONE" -eq 1 ]] || die "Workspace does not exist and --skip-clone was set: $WORKSPACE"
    run git clone https://github.com/unitreerobotics/unitree_ros2 "$WORKSPACE"
  fi

  [[ -d "$DDS_WS" ]] || die "Expected CycloneDDS workspace not found: $DDS_WS"
  mkdir -p "$DDS_WS/src"
}

package_present() {
  local package_name="$1"
  local xml=""
  while IFS= read -r -d '' xml; do
    if grep -Eq "<name>[[:space:]]*${package_name}[[:space:]]*</name>" "$xml"; then
      return 0
    fi
  done < <(find "$DDS_WS" \
    \( -path "$DDS_WS/build" -o -path "$DDS_WS/install" -o -path "$DDS_WS/log" -o -path '*/.git' \) -prune \
    -o -name package.xml -type f -print0)
  return 1
}

clone_package_if_missing() {
  local package_name="$1"
  local dir_name="$2"
  local repo_url="$3"
  local branch="$4"

  if package_present "$package_name"; then
    log "Package already present: $package_name"
    return 0
  fi

  [[ "$ALLOW_CLONE" -eq 1 ]] || die "Package $package_name is missing and --skip-clone was set."
  if [[ -e "$DDS_WS/src/$dir_name" ]]; then
    die "Path exists but package $package_name was not found: $DDS_WS/src/$dir_name"
  fi

  run git clone -b "$branch" "$repo_url" "$DDS_WS/src/$dir_name"
}

ensure_sources() {
  if [[ "$ROS_DISTRO_TARGET" == "humble" ]]; then
    log "ROS 2 Humble uses its packaged CycloneDDS; skipping the Foxy-only CycloneDDS source checkout."
    if ! package_present "unitree_go" || ! package_present "unitree_api"; then
      die "Could not find unitree_go and unitree_api packages under $DDS_WS"
    fi
    return 0
  fi

  clone_package_if_missing "cyclonedds" "cyclonedds" "https://github.com/eclipse-cyclonedds/cyclonedds" "releases/0.10.x"

  if package_present "rmw_cyclonedds_cpp"; then
    log "Package already present: rmw_cyclonedds_cpp"
  else
    [[ "$ALLOW_CLONE" -eq 1 ]] || die "Package rmw_cyclonedds_cpp is missing and --skip-clone was set."
    if [[ -e "$DDS_WS/src/rmw_cyclonedds" ]]; then
      die "Path exists but package rmw_cyclonedds_cpp was not found: $DDS_WS/src/rmw_cyclonedds"
    fi
    run git clone -b "$ROS_DISTRO_TARGET" "https://github.com/ros2/rmw_cyclonedds" "$DDS_WS/src/rmw_cyclonedds"
  fi

  if ! package_present "unitree_go" || ! package_present "unitree_api"; then
    warn "Could not find both unitree_go and unitree_api package.xml files under $DDS_WS."
    warn "The final colcon build may fail if this checkout is incomplete."
  fi
}

print_network_context() {
  log "Network context for interface selection:"
  printf '  SSH_CONNECTION=%s\n' "${SSH_CONNECTION:-<not set>}" >&2
  ip -br addr show >&2 || true
  ip route get "$ROBOT_IP" >&2 || true
}

iface_exists() {
  ip link show dev "$1" >/dev/null 2>&1
}

iface_is_up() {
  ip -o link show dev "$1" 2>/dev/null | grep -q "state UP"
}

route_iface_for_robot() {
  # Only trust a direct/on-link route to the Unitree subnet. If Linux would
  # send 192.168.123.161 through the default gateway, that is usually the
  # management/internet interface, not the robot DDS link.
  ip route get "$ROBOT_IP" 2>/dev/null | awk '
    {
      dev=""; src=""; via=0
      for (i=1; i<=NF; i++) {
        if ($i=="dev") dev=$(i+1)
        if ($i=="src") src=$(i+1)
        if ($i=="via") via=1
      }
      if (dev != "" && via == 0) print dev
      else if (dev != "" && src ~ /^192\.168\.123\./) print dev
    }
  ' | head -n1
}

iface_with_unitree_subnet() {
  ip -o -4 addr show scope global 2>/dev/null \
    | awk '$4 ~ /^192\.168\.123\./ {print $2; exit}'
}

management_iface_from_ssh() {
  local client_ip="" server_ip=""
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  # SSH_CONNECTION: client_ip client_port server_ip server_port
  read -r client_ip _ server_ip _ <<< "$SSH_CONNECTION"
  [[ -n "$server_ip" ]] || return 1
  ip -o -4 addr show scope global 2>/dev/null \
    | awk -v ip="$server_ip" '$4 ~ "^" ip "/" {print $2; exit}'
}

choose_interface() {
  print_network_context

  if [[ -n "$IFACE" ]]; then
    iface_exists "$IFACE" || die "Requested interface does not exist on this machine: $IFACE"
    log "Using requested DDS interface: $IFACE"
    return 0
  fi

  local route_iface="" subnet_iface="" ssh_iface=""
  route_iface="$(route_iface_for_robot || true)"
  subnet_iface="$(iface_with_unitree_subnet || true)"
  ssh_iface="$(management_iface_from_ssh || true)"

  local candidates=()
  if [[ -n "$route_iface" ]]; then candidates+=("$route_iface:route to $ROBOT_IP"); fi
  if [[ -n "$subnet_iface" && "$subnet_iface" != "$route_iface" ]]; then candidates+=("$subnet_iface:has 192.168.123.x address"); fi
  if iface_exists eth0 && [[ "eth0" != "$route_iface" && "eth0" != "$subnet_iface" ]]; then candidates+=("eth0:PC2 common default"); fi

  # Last-resort non-virtual candidates.
  local dev=""
  while IFS= read -r dev; do
    case "$dev" in
      lo|docker*|br-*|veth*|virbr*|tailscale*|zt*|tun*|tap*|wg*) continue ;;
    esac
    if [[ "$dev" != "$route_iface" && "$dev" != "$subnet_iface" && "$dev" != "eth0" ]]; then
      candidates+=("$dev:non-virtual interface")
    fi
  done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1)

  [[ "${#candidates[@]}" -gt 0 ]] || die "Could not auto-detect a DDS interface. Rerun with --iface IFACE using an interface from: ip -br addr"

  if [[ "$ASSUME_YES" -eq 0 && "${#candidates[@]}" -gt 1 ]]; then
    printf '\nDetected possible DDS interfaces:\n' >&2
    local i=1 item=""
    for item in "${candidates[@]}"; do
      printf '  %d) %s\n' "$i" "$item" >&2
      i=$((i + 1))
    done
    printf 'Choose interface number, or press Enter for 1: ' >&2
    local choice=""
    read -r choice
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid choice: $choice"
    (( choice >= 1 && choice <= ${#candidates[@]} )) || die "Choice out of range: $choice"
    IFACE="${candidates[$((choice - 1))]%%:*}"
  else
    IFACE="${candidates[0]%%:*}"
  fi

  iface_exists "$IFACE" || die "Auto-selected interface no longer exists: $IFACE"
  log "Selected DDS interface: $IFACE"

  if [[ -n "$ssh_iface" && "$IFACE" == "$ssh_iface" ]]; then
    warn "Selected DDS interface is also the current SSH interface ($ssh_iface). That may be correct, but PC2 often uses a separate robot interface such as eth0."
  fi

  if ! iface_is_up "$IFACE"; then
    warn "Interface $IFACE does not appear to be UP. DDS may not see robot topics until the link is up."
  fi
}

ensure_ip_if_requested() {
  [[ -n "$ENSURE_IP_CIDR" ]] || return 0
  [[ -n "$IFACE" ]] || die "Internal error: IFACE empty before --ensure-ip"
  iface_exists "$IFACE" || die "Cannot add IP; interface does not exist: $IFACE"

  if ip -o -4 addr show dev "$IFACE" | awk '{print $4}' | grep -Fxq "$ENSURE_IP_CIDR"; then
    log "$IFACE already has $ENSURE_IP_CIDR"
    return 0
  fi

  warn "About to temporarily add $ENSURE_IP_CIDR to $IFACE. This is not persistent."
  if confirm "Continue"; then
    run sudo_cmd ip addr add "$ENSURE_IP_CIDR" dev "$IFACE"
    run sudo_cmd ip link set "$IFACE" up
  else
    die "Aborted by user before adding IP."
  fi
}

clean_workspace() {
  [[ "$CLEAN_BUILD" -eq 1 ]] || { log "Skipping clean build."; return 0; }
  [[ -d "$DDS_WS" ]] || die "Cannot clean missing workspace: $DDS_WS"
  [[ "$DDS_WS" == */cyclonedds_ws ]] || die "Refusing to clean suspicious path that does not end in cyclonedds_ws: $DDS_WS"
  log "Removing $DDS_WS/build, $DDS_WS/install, and $DDS_WS/log"
  rm -rf "$DDS_WS/build" "$DDS_WS/install" "$DDS_WS/log"
}

build_cyclonedds_first() {
  if [[ "$ROS_DISTRO_TARGET" == "humble" ]]; then
    log "Skipping custom CycloneDDS build on ROS 2 Humble, as recommended by Unitree."
    return 0
  fi
  log "Building CycloneDDS first from the correct workspace: $DDS_WS"
  (
    cd "$DDS_WS"
    colcon build --packages-select cyclonedds "${COLCON_ARGS[@]}"
  )
}

build_unitree_packages() {
  log "Sourcing /opt/ros/${ROS_DISTRO_TARGET}/setup.bash, then building Unitree packages in $DDS_WS"
  (
    safe_source "/opt/ros/${ROS_DISTRO_TARGET}/setup.bash"
    cd "$DDS_WS"
    if [[ "$ROS_DISTRO_TARGET" == "humble" ]]; then
      colcon build --packages-select unitree_api unitree_go "${COLCON_ARGS[@]}"
    else
      colcon build "${COLCON_ARGS[@]}"
    fi
  )
}

write_setup_sh() {
  [[ "$PATCH_SETUP" -eq 1 ]] || { log "Skipping setup.sh patch."; return 0; }
  [[ -n "$IFACE" ]] || die "Internal error: IFACE empty before writing setup.sh"

  local backup=""
  local tmp=""
  local ros_setup_q=""
  local dds_setup_q=""
  ros_setup_q="$(printf '%q' "/opt/ros/${ROS_DISTRO_TARGET}/setup.bash")"
  dds_setup_q="$(printf '%q' "$DDS_WS/install/setup.bash")"

  if [[ -f "$SETUP_FILE" ]]; then
    backup="${SETUP_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "$SETUP_FILE" "$backup"
    log "Backed up existing setup.sh to: $backup"
  fi

  tmp="$(mktemp)"
  cat > "$tmp" <<SETUP
#!/usr/bin/env bash
# Generated by $SCRIPT_NAME on $(date -Iseconds)
# Unitree G1 PC2 ROS 2 / CycloneDDS environment.
# This file is safe to source from shells that have \`set -u\` enabled.
_unitree_safe_source() {
  local _file="\$1"
  if [[ ! -f "\$_file" ]]; then
    echo "[ERROR] Missing setup file: \$_file" >&2
    return 1
  fi
  local _restore_nounset=0
  local _rc=0
  case "\$-" in
    *u*) _restore_nounset=1; set +u ;;
  esac
  # shellcheck disable=SC1090
  if source "\$_file"; then
    _rc=0
  else
    _rc=\$?
  fi
  if [[ "\$_restore_nounset" -eq 1 ]]; then
    set -u
  fi
  return "\$_rc"
}

echo "Setup Unitree ROS 2 environment for G1 PC2; DDS interface: $IFACE"
_unitree_safe_source $ros_setup_q
_unitree_safe_source $dds_setup_q
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI='<CycloneDDS><Domain><General><Interfaces><NetworkInterface name="$IFACE" priority="default" multicast="default" /></Interfaces></General></Domain></CycloneDDS>'
unset -f _unitree_safe_source
SETUP
  install -m 0644 "$tmp" "$SETUP_FILE"
  rm -f "$tmp"
  log "Wrote $SETUP_FILE with DDS interface: $IFACE"
}

smoke_test() {
  [[ "$RUN_TEST" -eq 1 ]] || { log "Skipping smoke test."; return 0; }
  [[ -f "$SETUP_FILE" ]] || die "Cannot run smoke test; setup file missing: $SETUP_FILE"

  log "Running smoke test: source setup.sh && ros2 topic list"
  local out=""
  out="$(mktemp)"

  set +e
  UNITREE_SETUP_FILE="$SETUP_FILE" timeout "${TEST_TIMEOUT}s" bash --noprofile --norc -c '
    set -e
    source "$UNITREE_SETUP_FILE"
    echo "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-}"
    echo "CYCLONEDDS_URI=${CYCLONEDDS_URI:-}"
    echo "--- ros2 topic list ---"
    ros2 topic list
  ' > "$out" 2>&1
  local rc=$?
  set -e

  cat "$out"

  local topic_count=0
  topic_count="$(awk '/^\// {count++} END {print count+0}' "$out")"
  rm -f "$out"

  if [[ "$rc" -ne 0 ]]; then
    warn "Smoke test command failed or timed out after ${TEST_TIMEOUT}s. Build/setup may still be correct if the robot network is disconnected."
    [[ "$STRICT_TEST" -eq 1 ]] && exit "$rc"
    return 0
  fi

  if [[ "$topic_count" -eq 0 ]]; then
    warn "Smoke test ran, but no ROS topics were listed. Check robot power, network cable, IP routing, and whether $IFACE is the robot DDS interface."
    [[ "$STRICT_TEST" -eq 1 ]] && exit 2
  else
    log "Smoke test saw $topic_count topic(s)."
  fi
}

main() {
  log "Starting Unitree G1 PC2 DDS setup."
  log "Workspace: $WORKSPACE"
  log "ROS distro: $ROS_DISTRO_TARGET"
  log "Robot IP used for detection: $ROBOT_IP"

  validate_platform
  ensure_ros
  install_dependencies
  deactivate_conda_completely
  preflight
  clone_repo_if_needed
  ensure_sources
  choose_interface
  ensure_ip_if_requested
  clean_workspace
  build_cyclonedds_first
  build_unitree_packages
  write_setup_sh
  smoke_test

  cat <<DONE

Done.

To use this environment in a new shell on PC2, run:
  source "$SETUP_FILE"
  ros2 topic list

Selected DDS interface: $IFACE
Generated setup file:   $SETUP_FILE
CycloneDDS workspace:   $DDS_WS

If topics are empty, rerun with the explicit PC2 robot-network interface, for example:
  bash $SCRIPT_NAME --iface IFACE --strict-test
DONE
}

main "$@"
