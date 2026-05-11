#!/usr/bin/env bash
# g1_lidar_rviz.sh
#
# Run this after ssh -Y into PC2:
#   ~/bin/g1_lidar_rviz.sh
#
# Optional overrides:
#   G1_LIDAR_TOPIC=/utlidar/cloud ~/bin/g1_lidar_rviz.sh
#   G1_USE_DUMMY_TF=0 ~/bin/g1_lidar_rviz.sh
#   G1_ROS_DOMAIN_ID=10 ~/bin/g1_lidar_rviz.sh

set -Eeuo pipefail

source_relaxed() {
  local had_nounset=0
  [[ $- == *u* ]] && had_nounset=1
  set +u
  # shellcheck disable=SC1090
  source "$1"
  (( had_nounset )) && set -u
}

ENV_FILE="${G1_LIDAR_ENV_FILE:-$HOME/.g1_lidar_env.sh}"
[[ -f "$ENV_FILE" ]] || {
  echo "[ERROR] Missing $ENV_FILE. Run g1_lidar_one_time_setup_pc2.sh first." >&2
  exit 1
}

source_relaxed "$ENV_FILE"

TOPIC="${G1_LIDAR_TOPIC:-/utlidar/cloud_livox_mid360}"
LIDAR_FRAME="${G1_LIDAR_FRAME:-livox_frame}"
MAP_FRAME="${G1_MAP_FRAME:-map}"

# Set to 1 to publish a visualization-only static transform map -> livox_frame.
# This removes RViz's "no tf data" global warning. It is NOT SLAM.
USE_DUMMY_TF="${G1_USE_DUMMY_TF:-1}"

if [[ -z "${DISPLAY:-}" ]]; then
  cat >&2 <<ERR
[ERROR] DISPLAY is empty. RViz needs a GUI display.

Reconnect from your local Ubuntu desktop with:
  ssh -Y dwei@192.168.123.164

Then run:
  ~/bin/g1_lidar_rviz.sh
ERR
  exit 1
fi

# RViz over ssh -Y often needs software rendering.
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

echo "[INFO] DISPLAY=$DISPLAY"
echo "[INFO] Topic=$TOPIC"
echo "[INFO] LiDAR frame=$LIDAR_FRAME"
echo "[INFO] RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-}"
echo "[INFO] ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-<unset/domain 0>}"

# Refresh discovery.
ros2 daemon stop >/dev/null 2>&1 || true
ros2 daemon start >/dev/null 2>&1 || true

echo "[INFO] Waiting briefly for LiDAR topic discovery..."
for i in {1..10}; do
  if ros2 topic list 2>/dev/null | grep -qx "$TOPIC"; then
    echo "[OK] Found topic: $TOPIC"
    break
  fi
  sleep 1
done

if ! ros2 topic list 2>/dev/null | grep -qx "$TOPIC"; then
  echo "[WARN] $TOPIC was not listed by discovery."
  echo "[WARN] RViz may still work if DDS discovery is delayed."
  echo "[WARN] Available lidar/cloud topics:"
  ros2 topic list 2>/dev/null | grep -E 'utlidar|livox|cloud|imu' || true
fi

TYPE="$(ros2 topic type "$TOPIC" 2>/dev/null || true)"
if [[ -n "$TYPE" ]]; then
  echo "[INFO] Topic type: $TYPE"
fi

TF_PID=""
RVIZ_CONFIG=""
FIXED_FRAME="$LIDAR_FRAME"

if [[ "$USE_DUMMY_TF" == "1" ]]; then
  FIXED_FRAME="$MAP_FRAME"
  echo "[INFO] Starting visualization-only static TF: $MAP_FRAME -> $LIDAR_FRAME"
  ros2 run tf2_ros static_transform_publisher \
    0 0 0 0 0 0 "$MAP_FRAME" "$LIDAR_FRAME" >/tmp/g1_lidar_static_tf.log 2>&1 &
  TF_PID="$!"
fi

cleanup() {
  if [[ -n "${TF_PID:-}" ]]; then
    kill "$TF_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${RVIZ_CONFIG:-}" && -f "$RVIZ_CONFIG" ]]; then
    rm -f "$RVIZ_CONFIG"
  fi
}
trap cleanup EXIT

RVIZ_CONFIG="$(mktemp /tmp/g1_lidar_rviz.XXXXXX.rviz)"

cat > "$RVIZ_CONFIG" <<EOF_RVIZ
Panels:
  - Class: rviz_common/Displays
    Name: Displays
  - Class: rviz_common/Views
    Name: Views
Visualization Manager:
  Class: ""
  Displays:
    - Alpha: 0.5
      Cell Size: 1
      Class: rviz_default_plugins/Grid
      Color: 160; 160; 164
      Enabled: true
      Line Style:
        Line Width: 0.03
        Value: Lines
      Name: Grid
      Normal Cell Count: 0
      Offset:
        X: 0
        Y: 0
        Z: 0
      Plane: XY
      Plane Cell Count: 10
      Reference Frame: <Fixed Frame>
      Value: true
    - Alpha: 1
      Autocompute Intensity Bounds: true
      Class: rviz_default_plugins/PointCloud2
      Color Transformer: Intensity
      Decay Time: 2
      Enabled: true
      History Length: 5
      Invert Rainbow: false
      Max Color:
        B: 255
        G: 255
        R: 255
      Min Color:
        B: 0
        G: 0
        R: 0
      Name: G1 MID360 PointCloud
      Position Transformer: XYZ
      Queue Size: 10
      Selectable: true
      Size (Pixels): 3
      Size (m): 0.01
      Style: Points
      Topic:
        Depth: 5
        Durability Policy: Volatile
        History Policy: Keep Last
        Reliability Policy: Best Effort
        Value: $TOPIC
      Use Fixed Frame: true
      Use rainbow: true
      Value: true
  Enabled: true
  Global Options:
    Background Color: 48; 48; 48
    Fixed Frame: $FIXED_FRAME
    Frame Rate: 30
  Name: root
  Tools:
    - Class: rviz_default_plugins/Interact
    - Class: rviz_default_plugins/MoveCamera
    - Class: rviz_default_plugins/Select
  Transformation:
    Current:
      Class: rviz_default_plugins/TF
  Value: true
  Views:
    Current:
      Class: rviz_default_plugins/Orbit
      Distance: 8
      Focal Point:
        X: 0
        Y: 0
        Z: 0
      Name: Current View
      Pitch: 0.6
      Target Frame: <Fixed Frame>
      Yaw: 0.8
Window Geometry:
  Height: 900
  Width: 1400
EOF_RVIZ

echo "[INFO] Launching RViz. Close the RViz window to stop this script."
echo "[INFO] Fixed Frame in RViz: $FIXED_FRAME"
echo "[INFO] PointCloud2 topic: $TOPIC"

rviz2 -d "$RVIZ_CONFIG"
