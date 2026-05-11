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

forward_signal() {
  local signal="$1"
  local target_pid="${2:-}"
  if [[ -n "${target_pid}" ]] && kill -0 "${target_pid}" 2>/dev/null; then
    kill "-${signal}" "${target_pid}" 2>/dev/null || true
  fi
}

run_until_both_hands_ready() {
  local server_bin="$1"
  shift

  local startup_timeout="${G1_TELEOP_BRAINCO_STARTUP_TIMEOUT:-8}"
  local retry_delay="${G1_TELEOP_BRAINCO_RETRY_DELAY:-1}"
  local attempt=0

  while true; do
    attempt=$((attempt + 1))
    teleop_log "brainco_hand_server startup attempt ${attempt}"

    local state_dir=""
    state_dir="$(mktemp -d "${TMPDIR:-/tmp}/brainco_hand_server.XXXXXX")"
    local fifo="${state_dir}/server.log"
    local left_ready_file="${state_dir}/left.ready"
    local right_ready_file="${state_dir}/right.ready"
    mkfifo "${fifo}"

    local child_pid=""

    cleanup_attempt() {
      trap - INT TERM
      if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
        kill -INT "${child_pid}" 2>/dev/null || true
        wait "${child_pid}" 2>/dev/null || true
      fi
      rm -rf "${state_dir}"
    }

    trap 'forward_signal INT "${child_pid}"' INT
    trap 'forward_signal TERM "${child_pid}"' TERM

    (
      set +e
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
    local reader_pid=$!

    stdbuf -oL -eL sudo "${server_bin}" -n "${G1_TELEOP_DDS_IFACE}" "$@" > "${fifo}" 2>&1 &
    child_pid=$!

    local waited=0
    while kill -0 "${child_pid}" 2>/dev/null; do
      if [[ -f "${left_ready_file}" && -f "${right_ready_file}" ]]; then
        teleop_log "Both BrainCo hands are online."
        wait "${child_pid}"
        local child_status=$?
        wait "${reader_pid}" 2>/dev/null || true
        cleanup_attempt
        return "${child_status}"
      fi
      if (( waited >= startup_timeout * 10 )); then
        break
      fi
      sleep 0.1
      waited=$((waited + 1))
    done

    if ! kill -0 "${child_pid}" 2>/dev/null; then
      wait "${child_pid}" || true
    else
      teleop_warn "BrainCo startup timed out before both hands were ready; restarting."
      kill -INT "${child_pid}" 2>/dev/null || true
      wait "${child_pid}" 2>/dev/null || true
    fi

    wait "${reader_pid}" 2>/dev/null || true
    cleanup_attempt

    teleop_warn "BrainCo hands were not both detected on attempt ${attempt}. Retrying in ${retry_delay}s."
    sleep "${retry_delay}"
  done
}

main() {
  local server_bin=""
  server_bin="$(find_brainco_binary)" || teleop_die "brainco_hand_server was not found. Run ./setup_pc2_xr_teleop.sh first."
  teleop_log "Starting brainco_hand_server on DDS interface ${G1_TELEOP_DDS_IFACE}"
  run_until_both_hands_ready "${server_bin}" "$@"
}

main "$@"
