#!/usr/bin/env bash
set -Eeuo pipefail

WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FPS="${FPS:-30}"
BITRATE="${BITRATE:-8000000}"
GOP="${GOP:-30}"
V4L2_IO_MODE="${V4L2_IO_MODE:-auto}"
STREAM_PATH="${STREAM_PATH:-d435}"
RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:8554/${STREAM_PATH}}"
GST_DEBUG="${GST_DEBUG:-2}"

log() {
    printf '[teleimager-webrtc] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

require_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer, got: $value"
}

for command in gst-launch-1.0 gst-inspect-1.0 v4l2-ctl timeout; do
    command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

for element in v4l2src nvvidconv nvv4l2h264enc h264parse rtspclientsink fakesink; do
    gst-inspect-1.0 "$element" >/dev/null 2>&1 || die "missing GStreamer element: $element"
done

require_positive_integer WIDTH "$WIDTH"
require_positive_integer HEIGHT "$HEIGHT"
require_positive_integer FPS "$FPS"
require_positive_integer BITRATE "$BITRATE"
require_positive_integer GOP "$GOP"

supports_mode() {
    local device="$1"
    local details

    details="$(v4l2-ctl --device="$device" --list-formats-ext 2>/dev/null)" || return 1
    awk -v width="$WIDTH" -v height="$HEIGHT" -v fps="$FPS" '
        $0 ~ /^[[:space:]]*\[[0-9]+\]:/ || $0 ~ /Pixel Format/ {
            yuyv = index($0, "YUYV") > 0
            matching_size = 0
            next
        }
        /Size: Discrete/ {
            matching_size = yuyv && index($0, width "x" height) > 0
            next
        }
        matching_size && /Interval: Discrete/ {
            if (index($0, "(" fps ".000 fps)") > 0) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' <<<"$details"
}

camera_name() {
    v4l2-ctl --device="$1" --info 2>/dev/null |
        sed -n 's/^[[:space:]]*Card type[[:space:]]*:[[:space:]]*//p' |
        head -n 1
}

discover_camera() {
    local device name fallback=""

    for device in /dev/video*; do
        [[ -c "$device" ]] || continue
        supports_mode "$device" || continue
        name="$(camera_name "$device")"
        if [[ "$name" == *RealSense* || "$name" == *Intel*D435* ]]; then
            printf '%s\n' "$device"
            return 0
        fi
        [[ -n "$fallback" ]] || fallback="$device"
    done

    [[ -n "$fallback" ]] || return 1
    printf '%s\n' "$fallback"
}

CAMERA_DEVICE="${CAMERA_DEVICE:-}"
if [[ -z "$CAMERA_DEVICE" ]]; then
    CAMERA_DEVICE="$(discover_camera)" || die \
        "no V4L2 node offers YUYV ${WIDTH}x${HEIGHT}@${FPS}; inspect with: v4l2-ctl --list-formats-ext -d /dev/videoN"
fi

[[ -e "$CAMERA_DEVICE" ]] || die "camera device does not exist: $CAMERA_DEVICE"
supports_mode "$CAMERA_DEVICE" || die \
    "$CAMERA_DEVICE does not advertise YUYV ${WIDTH}x${HEIGHT}@${FPS}"

probe_io_mode() {
    local mode="$1"

    GST_DEBUG=1 timeout --signal=INT 10 gst-launch-1.0 -q -e \
        v4l2src device="$CAMERA_DEVICE" io-mode="$mode" num-buffers="$((FPS * 2))" \
        ! "video/x-raw,format=YUY2,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
        ! nvvidconv compute-hw=VIC output-buffers=4 \
        ! "video/x-raw(memory:NVMM),format=NV12,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
        ! fakesink sync=false >/dev/null 2>&1
}

case "$V4L2_IO_MODE" in
    auto)
        if probe_io_mode dmabuf; then
            IO_MODE=dmabuf
        else
            log "DMABUF import is unavailable; falling back to mmap"
            probe_io_mode mmap || die "camera-to-VIC probe failed with both dmabuf and mmap"
            IO_MODE=mmap
        fi
        ;;
    dmabuf|mmap)
        IO_MODE="$V4L2_IO_MODE"
        probe_io_mode "$IO_MODE" || die "camera-to-VIC probe failed with io-mode=$IO_MODE"
        ;;
    *)
        die "V4L2_IO_MODE must be auto, dmabuf, or mmap; got: $V4L2_IO_MODE"
        ;;
esac

log "camera=$CAMERA_DEVICE ($(camera_name "$CAMERA_DEVICE"))"
log "mode=${WIDTH}x${HEIGHT}@${FPS} YUY2, io-mode=$IO_MODE, bitrate=$BITRATE, GOP=$GOP"

if [[ "${1:-}" == "--check" ]]; then
    log "capture and VIC conversion check passed"
    exit 0
fi

log "publishing H.264 to $RTSP_URL"
export GST_DEBUG

exec gst-launch-1.0 -e \
    v4l2src device="$CAMERA_DEVICE" io-mode="$IO_MODE" do-timestamp=true \
    ! "video/x-raw,format=YUY2,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
    ! nvvidconv compute-hw=VIC output-buffers=4 \
    ! "video/x-raw(memory:NVMM),format=NV12,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
    ! nvv4l2h264enc \
        preset-level=1 \
        maxperf-enable=true \
        control-rate=1 \
        bitrate="$BITRATE" \
        iframeinterval="$GOP" \
        idrinterval="$GOP" \
        profile=0 \
        num-B-Frames=0 \
        insert-sps-pps=true \
        insert-vui=true \
    ! "video/x-h264,stream-format=byte-stream,alignment=au,profile=baseline" \
    ! h264parse config-interval=-1 \
    ! rtspclientsink location="$RTSP_URL" protocols=tcp latency=0 rtx-time=0
