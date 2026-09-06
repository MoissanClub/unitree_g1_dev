#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common_teleop_env.sh"

brainco_pid=""
teleimager_pid=""
state_dir=""

usage() {
  cat <<EOF
Usage: $0 [XR teleoperation arguments...]

Starts the BrainCo hand server and teleimager, waits for both to become ready,
then runs start_xr_teleoperate.sh. All arguments are forwarded to the XR
launcher. Ctrl+C or XR exit stops both background services.

Examples:
  $0
  $0 --no-motion
  $0 --hand --record
EOF
}

process_alive() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

find_stale_service_pids() {
  local pid=""
  local cmd=""
  {
    pgrep -f '(^|/)(brainco_hand_server|start_brainco_hand_server\.sh)( |$)' || true
    pgrep -f '(^|/)(teleimager-server|start_teleimager\.sh)( |$)' || true
    sudo fuser /dev/video* 2>/dev/null || true
    sudo fuser -n tcp 60000 60001 2>/dev/null || true
    sudo fuser -n udp 55555 2>/dev/null || true
  } | tr ' ' '\n' | sort -un | while IFS= read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    [[ "${pid}" -ne "$$" && "${pid}" -ne "${PPID}" && "${pid}" -ne 1 ]] || continue
    cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
    if [[ "${cmd}" == *ota_pipe* ]]; then
      teleop_warn "Leaving protected ota_pipe process ${pid} running."
      continue
    fi
    printf '%s\n' "${pid}"
  done
}

stop_stale_services() {
  local -a pids=()
  mapfile -t pids < <(find_stale_service_pids)
  ((${#pids[@]} > 0)) || {
    teleop_log "BrainCo serial ports and camera endpoints are free."
    return 0
  }

  teleop_warn "Stopping processes already using BrainCo or camera resources: ${pids[*]}"
  sudo kill -TERM "${pids[@]}" 2>/dev/null || true
  local waited=0
  while (( waited < 30 )); do
    local any_alive=0
    local pid=""
    for pid in "${pids[@]}"; do
      if process_alive "${pid}"; then
        any_alive=1
        break
      fi
    done
    (( any_alive == 0 )) && return 0
    sleep 0.1
    waited=$((waited + 1))
  done

  local -a survivors=()
  local pid=""
  for pid in "${pids[@]}"; do
    process_alive "${pid}" && survivors+=("${pid}")
  done
  if ((${#survivors[@]} > 0)); then
    teleop_warn "Processes did not stop after 3 seconds; sending SIGKILL: ${survivors[*]}"
    sudo kill -KILL "${survivors[@]}" 2>/dev/null || true
  fi
}

stop_process() {
  local name="$1"
  local pid="${2:-}"
  process_alive "${pid}" || return 0
  teleop_log "Stopping ${name} (PID ${pid})"
  kill -TERM "${pid}" 2>/dev/null || true
  local waited=0
  while process_alive "${pid}" && (( waited < 30 )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if process_alive "${pid}"; then
    teleop_warn "${name} did not stop after 3 seconds; sending SIGKILL."
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  wait "${pid}" 2>/dev/null || true
}

cleanup() {
  trap - EXIT INT TERM
  stop_process "teleimager" "${teleimager_pid}"
  stop_process "BrainCo hand server" "${brainco_pid}"
  [[ -z "${state_dir}" ]] || rm -rf "${state_dir}"
}

wait_for_log() {
  local name="$1"
  local pid="$2"
  local log_file="$3"
  local pattern="$4"
  local timeout_seconds="$5"
  local waited=0

  while (( waited < timeout_seconds * 10 )); do
    if grep -Fq "${pattern}" "${log_file}" 2>/dev/null; then
      teleop_log "${name} is ready."
      return 0
    fi
    process_alive "${pid}" || teleop_die "${name} exited before becoming ready."
    sleep 0.1
    waited=$((waited + 1))
  done
  teleop_die "Timed out waiting for ${name}; see ${log_file}."
}

camera_endpoint_ready() {
  ss -H -ltn | awk '$4 ~ /:60001$/ { found = 1 } END { exit(found ? 0 : 1) }'
}

wait_for_camera() {
  local pid="$1"
  local log_file="$2"
  local timeout_seconds="$3"
  local waited=0

  while (( waited < timeout_seconds * 10 )); do
    if camera_endpoint_ready; then
      sleep 1
      process_alive "${pid}" || teleop_die "teleimager exited after opening its WebRTC endpoint."
      teleop_log "teleimager is ready on TCP port 60001."
      return 0
    fi
    process_alive "${pid}" || teleop_die "teleimager exited before becoming ready."
    sleep 0.1
    waited=$((waited + 1))
  done
  teleop_die "Timed out waiting for teleimager; see ${log_file}."
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi

  teleop_export_common_env
  command -v sudo >/dev/null 2>&1 || teleop_die "Missing required command: sudo."

  local brainco_timeout="${G1_TELEOP_STACK_BRAINCO_TIMEOUT:-45}"
  local camera_timeout="${G1_TELEOP_STACK_CAMERA_TIMEOUT:-30}"
  [[ "${brainco_timeout}" =~ ^[0-9]+$ && "${camera_timeout}" =~ ^[0-9]+$ ]] || \
    teleop_die "Stack readiness timeouts must be whole seconds."

  state_dir="$(mktemp -d "${TMPDIR:-/tmp}/g1_vr_teleop.XXXXXX")"
  local brainco_log="${state_dir}/brainco.log"
  local teleimager_log="${state_dir}/teleimager.log"

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  teleop_log "Authenticating sudo before starting the service stack."
  sudo -v
  stop_stale_services

  stdbuf -oL -eL "${SCRIPT_DIR}/start_brainco_hand_server.sh" \
    > >(tee "${brainco_log}") 2>&1 &
  brainco_pid=$!
  wait_for_log "BrainCo hand server" "${brainco_pid}" "${brainco_log}" \
    "Both BrainCo hands are online." "${brainco_timeout}"

  stdbuf -oL -eL "${SCRIPT_DIR}/start_teleimager.sh" \
    > >(tee "${teleimager_log}") 2>&1 &
  teleimager_pid=$!
  wait_for_camera "${teleimager_pid}" "${teleimager_log}" "${camera_timeout}"

  teleop_log "Starting XR teleoperation. Background services will stop when XR exits."
  "${SCRIPT_DIR}/start_xr_teleoperate.sh" "$@"
}

main "$@"
