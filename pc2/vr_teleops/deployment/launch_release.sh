#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -ge 2 && ${EUID} -ne 0 ]] || { echo 'Run through deployment.py as a non-root operator.' >&2; exit 2; }
payload="$1"
runtime="$2"
shift 2
scripts="${payload}/launcher/pc2/vr_teleops"
export G1_HARDWARE_CONFIG_FILE="${payload}/hardware.env"
export TELEOP_CONFIG_FILE="${runtime}/pc2_teleop.env"
export G1_TELEIMAGER_CONFIG="${runtime}/cam_config_server.yaml"
export G1_TELEOP_CACHE_DIR="${runtime}/cache"
export XR_TELEOP_CERT="${runtime}/cert.pem" XR_TELEOP_KEY="${runtime}/key.pem"
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
unset PYTHONPATH PYTHONHOME
mkdir -p "${runtime}/cache" "${runtime}/recordings" "${runtime}/logs"
cp "${payload}/runtime-template/pc2_teleop.env" "${TELEOP_CONFIG_FILE}"
cp "${payload}/runtime-template/cam_config_server.yaml" "${G1_TELEIMAGER_CONFIG}"
source "${scripts}/common_teleop_env.sh"
teleop_export_common_env
umask 077
if [[ ! -f "${XR_TELEOP_CERT}" || ! -f "${XR_TELEOP_KEY}" ]] || \
   ! openssl x509 -in "${XR_TELEOP_CERT}" -noout -ext subjectAltName | grep -Fq "IP Address:${G1_TELEOP_IMG_SERVER_IP}"; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${XR_TELEOP_KEY}" -out "${XR_TELEOP_CERT}" -subj /CN=teleops \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${G1_TELEOP_IMG_SERVER_IP}"
fi
# Preserve terminal input for sshkeyboard; only output is copied to a session log.
log="${runtime}/logs/$(date -u +%Y%m%dT%H%M%SZ).log"
bash "${scripts}/demo.sh" --task-dir "${runtime}/recordings" "$@" \
  > >(tee -a "${log}") 2> >(tee -a "${log}" >&2)
