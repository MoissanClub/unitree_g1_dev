#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-1.20.0}"
REPLACE_PYTHON_SERVER=0
SKIP_CAMERA_CHECK=0
NO_START=0

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Options:
  --replace-python-server  Stop and disable teleimager.service if it is active.
  --skip-camera-check      Install even when the camera is disconnected or busy.
  --no-start               Install and enable services without starting them now.
  -h, --help               Show this help.

Environment:
  MEDIAMTX_VERSION=1.20.0
  XR_TELEOP_CERT=/home/unitree/.config/xr_teleoperate/cert.pem
  XR_TELEOP_KEY=/home/unitree/.config/xr_teleoperate/key.pem
  TLS_EXTRA_NAMES=robot.example.test,10.0.0.20
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --replace-python-server) REPLACE_PYTHON_SERVER=1 ;;
        --skip-camera-check) SKIP_CAMERA_CHECK=1 ;;
        --no-start) NO_START=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$EUID" -eq 0 ]] || {
    echo "Run this installer as root: sudo ./install.sh" >&2
    exit 1
}

[[ "$(uname -m)" == aarch64 ]] || {
    echo "This deployment targets Jetson aarch64, not $(uname -m)." >&2
    exit 1
}

if [[ ! -r /etc/nv_tegra_release ]]; then
    echo "Warning: /etc/nv_tegra_release is absent; verify this is a Jetson with JetPack 6."
fi

l4t_version="$(dpkg-query -W -f='${Version}' nvidia-l4t-core 2>/dev/null || true)"
[[ -n "$l4t_version" ]] || {
    echo "Cannot determine the installed nvidia-l4t-core version." >&2
    exit 1
}

if systemctl is-active --quiet teleimager.service 2>/dev/null; then
    if [[ "$REPLACE_PYTHON_SERVER" -ne 1 ]]; then
        cat >&2 <<'EOF'
teleimager.service is active and may own the RealSense camera. Stop it first,
or rerun with --replace-python-server to stop and disable it explicitly.
EOF
        exit 1
    fi
    systemctl disable --now teleimager.service
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    iproute2 \
    "nvidia-l4t-gstreamer=$l4t_version" \
    openssl \
    python3-zmq \
    v4l-utils \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-rtsp

/usr/bin/python3 -c 'import zmq' || {
    echo "python3-zmq was installed but cannot be imported by /usr/bin/python3." >&2
    exit 1
}

for element in nvvidconv nvv4l2h264enc; do
    if ! gst-inspect-1.0 "$element" >/dev/null 2>&1; then
        echo "Missing NVIDIA GStreamer element: $element" >&2
        echo "nvidia-l4t-gstreamer $l4t_version did not provide the expected plugin." >&2
        exit 1
    fi
done

for element in v4l2src h264parse rtspclientsink fakesink; do
    gst-inspect-1.0 "$element" >/dev/null 2>&1 || {
        echo "Missing GStreamer element after package installation: $element" >&2
        exit 1
    }
done

archive="mediamtx_v${MEDIAMTX_VERSION}_linux_arm64.tar.gz"
release_url="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}"
download_dir="$(mktemp -d)"
trap 'rm -rf "$download_dir"' EXIT

curl --fail --location --silent --show-error \
    --output "$download_dir/$archive" "$release_url/$archive"
curl --fail --location --silent --show-error \
    --output "$download_dir/checksums.sha256" "$release_url/checksums.sha256"

checksum="$(awk -v file="$archive" '$2 == file || $2 == "*" file {print $1; exit}' \
    "$download_dir/checksums.sha256")"
[[ -n "$checksum" ]] || {
    echo "No checksum found for $archive" >&2
    exit 1
}
printf '%s  %s\n' "$checksum" "$download_dir/$archive" | sha256sum --check --status || {
    echo "MediaMTX archive checksum verification failed." >&2
    exit 1
}

tar -xzf "$download_dir/$archive" -C "$download_dir"
[[ -x "$download_dir/mediamtx" ]] || {
    echo "MediaMTX archive did not contain the expected binary." >&2
    exit 1
}

getent group mediamtx >/dev/null 2>&1 || groupadd --system mediamtx
getent group video >/dev/null 2>&1 || groupadd --system video
id mediamtx >/dev/null 2>&1 || useradd --system \
    --gid mediamtx --home-dir /var/lib/mediamtx --create-home \
    --shell /usr/sbin/nologin mediamtx
id teleimager-video >/dev/null 2>&1 || useradd --system \
    --gid video --home-dir /var/lib/teleimager-webrtc --create-home \
    --shell /usr/sbin/nologin teleimager-video
id teleimager-compat >/dev/null 2>&1 || useradd --system \
    --gid mediamtx --home-dir /var/lib/teleimager-compat --create-home \
    --shell /usr/sbin/nologin teleimager-compat

usermod -a -G mediamtx mediamtx

for group in video render; do
    getent group "$group" >/dev/null 2>&1 && usermod -a -G "$group" teleimager-video
done

install -m 0755 -o root -g root "$download_dir/mediamtx" /usr/local/bin/mediamtx
install -d -m 0755 -o root -g root /etc/mediamtx
install -d -m 0755 -o mediamtx -g mediamtx /var/lib/mediamtx
install -d -m 0755 -o teleimager-video -g video /var/lib/teleimager-webrtc
install -d -m 0755 -o root -g root /usr/local/libexec/teleimager
install -d -m 0755 -o root -g root /etc/teleimager

install -m 0640 -o root -g mediamtx "$SCRIPT_DIR/mediamtx.yml" /etc/mediamtx/mediamtx.yml
install -m 0755 -o root -g root "$SCRIPT_DIR/publish-camera.sh" \
    /usr/local/libexec/teleimager/publish-camera.sh
install -m 0755 -o root -g root "$SCRIPT_DIR/generate-tls.sh" \
    /usr/local/libexec/teleimager/generate-tls.sh
install -m 0755 -o root -g root "$SCRIPT_DIR/compat-server.py" \
    /usr/local/libexec/teleimager/compat-server.py
install -m 0644 -o root -g root "$SCRIPT_DIR/compat-camera.json" \
    /etc/teleimager/compat-camera.json

if [[ ! -e /etc/default/teleimager-webrtc ]]; then
    install -m 0644 -o root -g root "$SCRIPT_DIR/camera.env" /etc/default/teleimager-webrtc
else
    echo "Keeping existing camera settings in /etc/default/teleimager-webrtc"
fi

operator_user="${SUDO_USER:-unitree}"
operator_home="$(getent passwd "$operator_user" 2>/dev/null | awk -F: 'NR == 1 {print $6}' || true)"
operator_home="${operator_home:-/home/unitree}"
tls_source_cert="${XR_TELEOP_CERT:-$operator_home/.config/xr_teleoperate/cert.pem}"
tls_source_key="${XR_TELEOP_KEY:-$operator_home/.config/xr_teleoperate/key.pem}"

if [[ -e "$tls_source_cert" || -e "$tls_source_key" ]]; then
    [[ -s "$tls_source_cert" && -s "$tls_source_key" ]] || {
        echo "Both existing TLS files are required:" >&2
        echo "  $tls_source_cert" >&2
        echo "  $tls_source_key" >&2
        exit 1
    }

    if ! cert_public_key="$(openssl x509 -in "$tls_source_cert" -pubkey -noout |
        openssl pkey -pubin -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"; then
        echo "Invalid TLS certificate: $tls_source_cert" >&2
        exit 1
    fi
    if ! key_public_key="$(openssl pkey -in "$tls_source_key" -passin pass: \
        -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"; then
        echo "Private key is invalid or encrypted: $tls_source_key" >&2
        exit 1
    fi
    [[ -n "$cert_public_key" && "$cert_public_key" == "$key_public_key" ]] || {
        echo "TLS certificate and private key do not match." >&2
        exit 1
    }

    install -d -m 0755 -o root -g root /etc/mediamtx/tls
    install -m 0644 -o root -g mediamtx "$tls_source_cert" \
        /etc/mediamtx/tls/server.crt
    install -m 0640 -o root -g mediamtx "$tls_source_key" \
        /etc/mediamtx/tls/server.key
    tls_result="Copied existing certificate from $tls_source_cert"
else
    TLS_EXTRA_NAMES="${TLS_EXTRA_NAMES:-}" \
        /usr/local/libexec/teleimager/generate-tls.sh
    tls_result="Generated a private CA; trust /etc/mediamtx/tls/ca.crt on clients"
fi

install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/mediamtx.service" \
    /etc/systemd/system/mediamtx.service
install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/teleimager-realsense-webrtc.service" \
    /etc/systemd/system/teleimager-realsense-webrtc.service
install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/teleimager-compat.service" \
    /etc/systemd/system/teleimager-compat.service
systemctl daemon-reload

if [[ "$SKIP_CAMERA_CHECK" -ne 1 ]]; then
    set -a
    # shellcheck disable=SC1091
    source /etc/default/teleimager-webrtc
    set +a
    runuser -u teleimager-video --preserve-environment -- \
        /usr/local/libexec/teleimager/publish-camera.sh --check
fi

systemctl enable mediamtx.service teleimager-compat.service \
    teleimager-realsense-webrtc.service
if [[ "$NO_START" -ne 1 ]]; then
    systemctl restart mediamtx.service
    systemctl restart teleimager-compat.service
    systemctl restart teleimager-realsense-webrtc.service
    sleep 2
    systemctl is-active --quiet mediamtx.service || {
        journalctl -u mediamtx.service -n 50 --no-pager >&2
        exit 1
    }
    systemctl is-active --quiet teleimager-compat.service || {
        journalctl -u teleimager-compat.service -n 50 --no-pager >&2
        exit 1
    }
    systemctl is-active --quiet teleimager-realsense-webrtc.service || {
        journalctl -u teleimager-realsense-webrtc.service -n 50 --no-pager >&2
        exit 1
    }
fi

player_host="$(hostname -f 2>/dev/null || hostname)"
cat <<EOF

Installation complete.

Player:           https://${player_host}:60001/
Teleop /offer:    https://${player_host}:60001/offer
Direct WHEP:      https://${player_host}:60001/d435/whep
TLS:              ${tls_result}
Encoder config:   /etc/default/teleimager-webrtc
Camera metadata:  /etc/teleimager/compat-camera.json

Open TCP 60001 and UDP 8189 from the browser. Open TCP 60000 too when the
teleop process runs on another host. See README.md for protocol details.
EOF
