# PC2 XR Teleop Scripts

Before setup, verify `../g1_pc2_hardware.env` as described in `../README.md`. XR setup reads its DDS interface, Wi-Fi interface, and head-camera defaults from that central hardware profile.

This directory contains the PC2-side setup and runtime launch helpers for the
Unitree XR teleoperation workflow.

Unlike the top-level `pc2/` scripts, this directory contains both:

- a one-time setup script that provisions the XR teleop stack on PC2
- recurring runtime launchers used during normal teleop sessions

This directory is a launcher/config layer only. The actual XR teleoperation
implementation lives in the downstream `xr_teleoperate` checkout referenced by
`G1_TELEOP_XR_REPO`, and the BrainCo finger service lives in
`brainco_hand_service`.

## Included Scripts

- `setup_pc2_xr_teleop.sh`: one-time setup for the XR teleop stack on PC2
- `start_brainco_hand_server.sh`: starts the BrainCo hand server
- `start_teleimager.sh`: starts the teleimager server
- `start_xr_teleoperate.sh`: starts the main XR teleoperation app
- `common_teleop_env.sh`: shared environment and auto-detection helpers used by the launchers

## How This Folder Fits The Stack

At runtime, the flow is:

1. `start_brainco_hand_server.sh` starts the DDS bridge that publishes BrainCo hand state and accepts BrainCo hand commands.
2. `start_teleimager.sh` starts the robot-camera image server used by the Quest browser session.
3. `start_xr_teleoperate.sh` activates the configured Conda environment, sources the Unitree DDS setup, and launches `xr_teleoperate/teleop/teleop_hand_and_arm.py`.
4. The Quest browser connects to the URL printed by `start_xr_teleoperate.sh`.

This means changes to tracking mode or end-effector selection belong in this
folder's runtime config, while low-level teleop behavior belongs upstream in
`xr_teleoperate`.

## Privilege Model

Run these scripts as follows:

- `setup_pc2_xr_teleop.sh`: run as the normal login user, not with `sudo`
- `start_brainco_hand_server.sh`: run as the normal login user; it uses `sudo` internally only for the server binary launch
- `start_teleimager.sh`: run as the normal login user
- `start_xr_teleoperate.sh`: run as the normal login user

Do not run the full setup script with `sudo`. It clones repositories into `~`,
creates a Conda environment, and writes runtime configuration under
`~/.config/xr_teleoperate/`.

## What The Setup Script Does

`setup_pc2_xr_teleop.sh` reuses the parent directory's
`setup_unitree_g1_pc2_dds.sh` for DDS setup, then prepares the rest of the
teleop stack by:

- installing required apt packages
- reusing Miniforge, Mambaforge, Miniconda, or Anaconda when present, and installing Miniconda if needed
- creating or updating a Conda environment
- cloning or updating `unitree_sdk2`
- cloning or updating `unitree_sdk2_python`
- cloning or updating `xr_teleoperate`
- optionally cloning and building `brainco_hand_service`
- isolating native build directories by Ubuntu release and CPU architecture so JetPack upgrades do not reuse stale CMake caches
- generating self-signed TLS certs under `~/.config/xr_teleoperate/`
- configuring teleimager for either OpenCV `/dev/videoN` or native RealSense capture
- writing runtime configuration to `~/.config/xr_teleoperate/pc2_teleop.env`
- verifying required Python imports and BrainCo shared-library linkage

## One-Time Setup

Show help:

```bash
./setup_pc2_xr_teleop.sh --help
```

Run the installer as the normal user:

```bash
./setup_pc2_xr_teleop.sh
```

If PC2 has multiple interfaces and you want to pin the robot-facing DDS
interface or the Wi-Fi/default-route interface advertised to the Quest, pass
them explicitly:

```bash
./setup_pc2_xr_teleop.sh --dds-iface enP8p1s0 --wifi-iface wlx94ba06f341b5
```

Other useful options:

```bash
./setup_pc2_xr_teleop.sh --skip-apt --no-pull
./setup_pc2_xr_teleop.sh --no-verify
./setup_pc2_xr_teleop.sh --skip-brainco-service
./setup_pc2_xr_teleop.sh --arm G1_23
./setup_pc2_xr_teleop.sh --input-mode hand --ee brainco
./setup_pc2_xr_teleop.sh --camera-backend realsense --realsense-serial 123456789
```

Important setup choices:

- `--input-mode controller`: Quest controllers drive the arm targets. This was the previous hardcoded behavior in this folder.
- `--input-mode hand`: Quest hand tracking drives the arm targets.
- `--ee brainco`: use BrainCo dexterous hands as the end effector.
- `--ee dex1|dex3|inspire_ftp|inspire_dfx`: select other upstream-supported end effectors.
- `--camera-backend opencv`: use the generic UVC `/dev/videoN` path at `480x640`.
- `--camera-backend realsense`: use teleimager's RealSense path at `720x1280`; this also installs `pyrealsense2` and makes `start_teleimager.sh` pass `--rs`.

The setup supports both JetPack 5 (normally Ubuntu 20.04) and JetPack 6
(normally Ubuntu 22.04). Conda keeps the XR Python 3.10 environment independent
of the system Python. Native SDK and BrainCo builds use separate directories for
each Ubuntu release and architecture, so an in-place JetPack upgrade does not
reuse the older release's CMake cache.

CycloneDDS discovery also follows the ROS distribution: Foxy installations can
use the package-specific prefix built under `~/unitree_ros2/cyclonedds_ws`,
while Humble installations can use the system package under `/opt/ros/humble`.
Merged and isolated colcon install layouts are both accepted. On Ubuntu arm64,
setup creates a compatibility prefix under `~/.config/xr_teleoperate/` whose
symlinks expose the multiarch ROS libraries in the standalone layout required
by the pinned CycloneDDS Python binding. Its library directory is added to the
XR process environment so transitive ROS dependencies such as Iceoryx resolve;
system files are not copied or changed.

On Jetson/aarch64, availability of a compatible `pyrealsense2` wheel varies by
JetPack and Python release. If installation fails, setup stops with an explicit
message; use the default OpenCV backend or install matching librealsense Python
bindings before selecting the native RealSense backend.

## Per-Session Runtime

After setup completes, start the teleop services on PC2 in separate terminals:

```bash
./start_brainco_hand_server.sh
./start_teleimager.sh
./start_xr_teleoperate.sh
```

Override the configured XR input mode for a single launch with:

```bash
./start_xr_teleoperate.sh --input-mode controller
./start_xr_teleoperate.sh --input-mode hand
```

The XR launcher prints the Quest browser URL after startup. The advertised IP
is derived from the configured or detected Wi-Fi/default-route interface.

### Recording

Recording is disabled by default. Any arguments `start_xr_teleoperate.sh`
doesn't recognize are forwarded to `teleop_hand_and_arm.py`, so its
recording options work as passthrough flags:

```bash
./start_xr_teleoperate.sh --record
./start_xr_teleoperate.sh --record --task-name "pick cube" --task-dir ./utils/data/
```

Other supported passthrough flags: `--task-goal`, `--task-desc`,
`--task-steps`. Once running with `--record`, press `s` in the terminal to
start or save a recording (toggle cycle); the startup banner reflects
whether recording is enabled for the session.

Recommended order for Quest hand tracking with BrainCo:

```bash
./start_brainco_hand_server.sh
./start_teleimager.sh
./start_xr_teleoperate.sh
```

If `G1_TELEOP_INPUT_MODE=hand` and `G1_TELEOP_EE=brainco`, the launched
teleop process uses:

- XR hand tracking for arm pose targets
- XR hand-joint retargeting for BrainCo finger commands
- the same DDS interface configured for the rest of the PC2 teleop stack

## Runtime Configuration

The launchers read:

```bash
~/.config/xr_teleoperate/pc2_teleop.env
```

That file is written by `setup_pc2_xr_teleop.sh` and contains values such as:

- `G1_TELEOP_CONDA_ENV`
- `G1_TELEOP_DDS_IFACE`
- `G1_TELEOP_WIFI_IFACE`
- `G1_TELEOP_IMG_SERVER_IP`
- `G1_TELEIMAGER_VIDEO_ID`
- `G1_TELEIMAGER_CAMERA_BACKEND`
- `G1_TELEIMAGER_REALSENSE_SERIAL`
- `G1_TELEOP_ARM`
- `G1_TELEOP_INPUT_MODE`
- `G1_TELEOP_EE`
- `G1_TELEOP_DISPLAY_MODE`
- `G1_TELEOP_XR_REPO`

You can edit it later if interface names, IPs, or checkout locations change.

The most important mode controls are:

- `G1_TELEOP_INPUT_MODE=controller|hand`
- `G1_TELEOP_EE=dex1|dex3|inspire_ftp|inspire_dfx|brainco`
- `G1_TELEIMAGER_CAMERA_BACKEND=opencv|realsense`

## RealSense Camera

The G1 head camera can be used through teleimager's native RealSense backend
instead of the generic OpenCV UVC backend. This is the preferred path when you
want the full `720x1280` RealSense stream.

First let teleimager list RealSense devices and note the serial number:

```bash
cd ~/xr_teleoperate/teleop/teleimager
conda activate tv
teleimager-server --cf --rs
```

Then configure this launcher layer for RealSense:

```bash
./setup_pc2_xr_teleop.sh --camera-backend realsense --realsense-serial SERIAL_FROM_CF_RS
```

If the serial is omitted, the setup script tries to parse it from
`teleimager-server --cf --rs`; if detection is ambiguous, rerun setup with
`--realsense-serial`.

On Unitree PC2, the vendor camera services can keep the RealSense device open.
If `teleimager-server --rs` cannot acquire the camera, rerun setup once with:

```bash
./setup_pc2_xr_teleop.sh --camera-backend realsense --realsense-serial SERIAL_FROM_CF_RS --release-unitree-camera
```

That stops and removes `video_hub_pc4` and `video_hub_pc4_chest` via
`/unitree/sbin/mscli`, matching the manual TELE_OP.md fix. It does not disable
`ota_pipe`, because doing that can cause firmware command timeouts in the
Unitree Explore app.

After setup, launch normally:

```bash
./start_teleimager.sh
```

To change the head-camera backend later without rerunning the full setup,
stop the current teleimager process and run one of:

```bash
./switch_to_camera.sh realsense
./switch_to_camera.sh opencv
./switch_to_camera.sh uvc
```

With no argument, `switch_to_camera.sh` selects `realsense`. It updates both
`~/.config/xr_teleoperate/pc2_teleop.env` and teleimager's
`cam_config_server.yaml`. In RealSense mode it detects the camera serial number
automatically. For every backend it configures a monocular head stream and
disables the unused left- and right-wrist ZMQ and WebRTC streams. Start the
stream again after switching:

```bash
./start_teleimager.sh
```

For RealSense configs, `start_teleimager.sh` automatically runs
`teleimager-server --rs`. You can verify the stream from another browser at
`https://PC2-WiFi-IP:60001`.

## Hand Tracking And BrainCo

`start_xr_teleoperate.sh` now reads the XR input mode and end-effector choice from
`~/.config/xr_teleoperate/pc2_teleop.env`.

For Quest hand tracking that drives both G1 arms and BrainCo hands, configure:

```bash
./setup_pc2_xr_teleop.sh --input-mode hand --ee brainco
```

Or edit the runtime config directly:

```bash
export G1_TELEOP_INPUT_MODE="hand"
export G1_TELEOP_EE="brainco"
```

This launches `teleop_hand_and_arm.py` in the upstream-supported mode that uses
hand tracking for arm IK and BrainCo finger retargeting.

In practice, that means:

- wrist pose from Quest hand tracking drives the G1 arm IK targets
- full tracked hand joints are retargeted into BrainCo finger commands
- no Quest controllers are required for arm and hand teleoperation in this mode

If you switch back to controller teleop later, rerun setup with
`--input-mode controller`, edit `pc2_teleop.env` directly, or launch once with
`./start_xr_teleoperate.sh --input-mode controller`.

## Quest 3 Controller Session Control

`teleop_hand_and_arm.py` (in `xr_teleoperate`) already lets the PC2 terminal operator drive
session state with the keyboard: **r** = start tracking, **s** = toggle recording (with
`--record`), **q** = quit. The same three transitions are also wired to Quest 3 controller face
buttons, funneled through the same `on_press()` state machine so keyboard, IPC, and Quest-button
input all stay consistent:

| Action | Button |
| :---: | :---: |
| Start tracking (READY → active) | Right **B** |
| Toggle recording (only with `--record`) | Left **X** |
| Quit | Right **A** |

This is default-on — no extra flag needed on `start_xr_teleoperate.sh`.

**Mode caveat:** by default, `televuer` only reads controller buttons when
`G1_TELEOP_INPUT_MODE=controller`. Since this folder's recommended flow uses
`G1_TELEOP_INPUT_MODE=hand` (Quest hand tracking + BrainCo fingers), our `televuer` submodule is
patched (forked at `MoissanClub/televuer`) to also report controller buttons while hand tracking
drives arm IK, so the table above works in both modes here. If `xr_teleoperate/.gitmodules`
ever gets repointed back at the stock `unitreerobotics/televuer` submodule, these buttons will
silently stop working in `--input-mode hand` (they'll still work in `--input-mode controller`).

## Notes

- Run these scripts on `g1-pc2`, not on your development machine.
- The setup script is intended to be run once, or only when reprovisioning the XR teleop stack.
- The `start_*.sh` wrappers are intended for recurring day-to-day teleop sessions.
- If the Wi-Fi/default-route interface changes, rerun setup or update `pc2_teleop.env`.
- `start_xr_teleoperate.sh` expects the DDS setup created by `../setup_unitree_g1_pc2_dds.sh` to exist.
