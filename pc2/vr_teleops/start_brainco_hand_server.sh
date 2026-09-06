#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common_teleop_env.sh"

teleop_export_common_env

find_brainco_binary() {
  local candidates=(
    "${G1_TELEOP_BRAINCO_SERVICE_DIR}/bin/brainco_hand_server"
    "${G1_TELEOP_BRAINCO_SERVICE_DIR}/build/bin/brainco_hand_server"
    "${G1_TELEOP_BRAINCO_SERVICE_DIR}/build/brainco_hand_server"
  )
  local candidate=""
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

server_group_alive() {
  local leader_pid="${1:-}"
  [[ -n "${leader_pid}" ]] || return 1
  ps -eo pgid=,stat= | awk -v pgid="${leader_pid}" '
    $1 == pgid && $2 !~ /^Z/ { alive = 1 }
    END { exit(alive ? 0 : 1) }
  '
}

signal_server_group() {
  local signal="$1"
  local leader_pid="${2:-}"
  if server_group_alive "${leader_pid}"; then
    kill "-${signal}" -- "-${leader_pid}" 2>/dev/null || true
  fi
}

stop_server_group() {
  local leader_pid="${1:-}"
  [[ -n "${leader_pid}" ]] || return 0
  local int_grace="${G1_TELEOP_BRAINCO_INT_GRACE:-1}"
  local term_grace="${G1_TELEOP_BRAINCO_TERM_GRACE:-1}"
  [[ "${int_grace}" =~ ^[0-9]+$ && "${term_grace}" =~ ^[0-9]+$ ]] || \
    teleop_die "BrainCo INT/TERM grace values must be whole seconds."

  signal_server_group INT "${leader_pid}"
  local waited=0
  while server_group_alive "${leader_pid}" && (( waited < int_grace * 10 )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if server_group_alive "${leader_pid}"; then
    teleop_warn "BrainCo server group did not stop after SIGINT; sending SIGTERM."
    signal_server_group TERM "${leader_pid}"
    waited=0
    while server_group_alive "${leader_pid}" && (( waited < term_grace * 10 )); do
      sleep 0.1
      waited=$((waited + 1))
    done
  fi
  if server_group_alive "${leader_pid}"; then
    teleop_warn "BrainCo server group did not stop after SIGTERM; sending SIGKILL."
    signal_server_group KILL "${leader_pid}"
  fi
  wait "${leader_pid}" 2>/dev/null || true
}

run_until_both_hands_ready() {
  local server_bin="$1"
  shift

  local startup_timeout="${G1_TELEOP_BRAINCO_STARTUP_TIMEOUT:-8}"
  local retry_delay="${G1_TELEOP_BRAINCO_RETRY_DELAY:-1}"
  [[ "${startup_timeout}" =~ ^[0-9]+$ ]] || teleop_die "G1_TELEOP_BRAINCO_STARTUP_TIMEOUT must be whole seconds."
  local attempt=0
  local shutdown_status=0
  local child_pid=""

  on_signal() {
    local signal="$1"
    case "${signal}" in
      INT) shutdown_status=130 ;;
      TERM) shutdown_status=143 ;;
    esac
    signal_server_group "${signal}" "${child_pid}"
  }

  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM

  while true; do
    attempt=$((attempt + 1))
    teleop_log "brainco_hand_server startup attempt ${attempt}"

    local state_dir=""
    state_dir="$(mktemp -d "${TMPDIR:-/tmp}/brainco_hand_server.XXXXXX")"
    local fifo="${state_dir}/server.log"
    local left_ready_file="${state_dir}/left.ready"
    local right_ready_file="${state_dir}/right.ready"
    mkfifo "${fifo}"

    child_pid=""
    local reader_pid=""

    cleanup_attempt() {
      stop_server_group "${child_pid}"
      child_pid=""
      if [[ -n "${reader_pid}" ]] && kill -0 "${reader_pid}" 2>/dev/null; then
        kill -TERM "${reader_pid}" 2>/dev/null || true
      fi
      [[ -z "${reader_pid}" ]] || wait "${reader_pid}" 2>/dev/null || true
      reader_pid=""
      rm -rf "${state_dir}"
    }

    (
      set +e
      trap - INT TERM
      while IFS= read -r line; do
        printf '%s\n' "${line}"
        case "${line}" in
          *"Starting worker for left"*) : > "${left_ready_file}" ;;
          *"Starting worker for right"*) : > "${right_ready_file}" ;;
        esac
        if [[ -f "${left_ready_file}" && -f "${right_ready_file}" ]]; then
          break
        fi
      done < "${fifo}"

      if [[ -f "${left_ready_file}" && -f "${right_ready_file}" ]]; then
        while IFS= read -r line; do
          printf '%s\n' "${line}"
        done < "${fifo}"
      fi
    ) &
    reader_pid=$!

    local native_lib_path=""
    native_lib_path="${G1_TELEOP_BRAINCO_SERVICE_DIR}/lib/$(uname -m):${G1_TELEOP_SDK2_DIR}/thirdparty/lib/$(uname -m)"
    setsid stdbuf -oL -eL env LD_LIBRARY_PATH="${native_lib_path}" \
      "${server_bin}" -n "${G1_TELEOP_DDS_IFACE}" "$@" > "${fifo}" 2>&1 &
    child_pid=$!

    local waited=0
    while server_group_alive "${child_pid}"; do
      if [[ -f "${left_ready_file}" && -f "${right_ready_file}" ]]; then
        teleop_log "Both BrainCo hands are online."
        local child_status=0
        wait "${child_pid}" || child_status=$?
        cleanup_attempt
        trap - INT TERM
        [[ "${shutdown_status}" -eq 0 ]] || return "${shutdown_status}"
        return "${child_status}"
      fi
      [[ "${shutdown_status}" -eq 0 ]] || break
      if (( waited >= startup_timeout * 10 )); then
        break
      fi
      sleep 0.1
      waited=$((waited + 1))
    done

    if server_group_alive "${child_pid}" && [[ "${shutdown_status}" -eq 0 ]]; then
      teleop_warn "BrainCo startup timed out before both hands were ready; restarting."
    fi

    cleanup_attempt
    if [[ "${shutdown_status}" -ne 0 ]]; then
      trap - INT TERM
      return "${shutdown_status}"
    fi

    teleop_warn "BrainCo hands were not both detected on attempt ${attempt}. Retrying in ${retry_delay}s."
    sleep "${retry_delay}"
  done
}

main() {
  local server_bin=""
  command -v setsid >/dev/null 2>&1 || teleop_die "Missing required command: setsid (util-linux)."
  server_bin="$(find_brainco_binary)" || teleop_die "brainco_hand_server was not found. Run ./setup_pc2_xr_teleop.sh first."

  if [[ "${EUID}" -ne 0 ]]; then
    local login_user="${USER:-$(id -un)}"
    teleop_log "Authenticating once, then starting the BrainCo retry supervisor as root."
    exec sudo env \
      HOME="${HOME}" \
      USER="${login_user}" \
      G1_TELEOP_CONDA_ENV="${G1_TELEOP_CONDA_ENV}" \
      G1_TELEOP_DDS_IFACE="${G1_TELEOP_DDS_IFACE}" \
      G1_TELEOP_WIFI_IFACE="${G1_TELEOP_WIFI_IFACE}" \
      G1_TELEOP_IMG_SERVER_IP="${G1_TELEOP_IMG_SERVER_IP}" \
      G1_TELEOP_XR_REPO="${G1_TELEOP_XR_REPO}" \
      G1_TELEOP_BRAINCO_SERVICE_DIR="${G1_TELEOP_BRAINCO_SERVICE_DIR}" \
      G1_TELEOP_SDK2_DIR="${G1_TELEOP_SDK2_DIR}" \
      G1_TELEOP_UNITREE_SETUP="${G1_TELEOP_UNITREE_SETUP}" \
      G1_TELEOP_CYCLONEDDS_HOME="${G1_TELEOP_CYCLONEDDS_HOME}" \
      "${SCRIPT_DIR}/start_brainco_hand_server.sh" "$@"
  fi

  teleop_log "Starting brainco_hand_server on DDS interface ${G1_TELEOP_DDS_IFACE}"
  run_until_both_hands_ready "${server_bin}" "$@"
}

main "$@"
