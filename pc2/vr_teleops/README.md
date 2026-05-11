# PC2 XR Teleop Scripts

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
- installing Miniconda if needed
- creating or updating a Conda environment
- cloning or updating `unitree_sdk2`
- cloning or updating `unitree_sdk2_python`
- cloning or updating `xr_teleoperate`
- optionally cloning and building `brainco_hand_service`
- generating self-signed TLS certs under `~/.config/xr_teleoperate/`
- writing runtime configuration to `~/.config/xr_teleoperate/pc2_teleop.env`

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
./setup_pc2_xr_teleop.sh --dds-iface eth0 --wifi-iface wlan0
```

Other useful options:

```bash
./setup_pc2_xr_teleop.sh --skip-apt --no-pull
./setup_pc2_xr_teleop.sh --skip-brainco-service
./setup_pc2_xr_teleop.sh --arm G1_23
./setup_pc2_xr_teleop.sh --input-mode hand --ee brainco
```

Important setup choices:

- `--input-mode controller`: Quest controllers drive the arm targets. This was the previous hardcoded behavior in this folder.
- `--input-mode hand`: Quest hand tracking drives the arm targets.
- `--ee brainco`: use BrainCo dexterous hands as the end effector.
- `--ee dex1|dex3|inspire_ftp|inspire_dfx`: select other upstream-supported end effectors.

## Per-Session Runtime

After setup completes, start the teleop services on PC2 in separate terminals:

```bash
./start_brainco_hand_server.sh
./start_teleimager.sh
./start_xr_teleoperate.sh
```

The XR launcher prints the Quest browser URL after startup. The advertised IP
is derived from the configured or detected Wi-Fi/default-route interface.

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
- `G1_TELEOP_ARM`
- `G1_TELEOP_INPUT_MODE`
- `G1_TELEOP_EE`
- `G1_TELEOP_DISPLAY_MODE`
- `G1_TELEOP_XR_REPO`

You can edit it later if interface names, IPs, or checkout locations change.

The most important mode controls are:

- `G1_TELEOP_INPUT_MODE=controller|hand`
- `G1_TELEOP_EE=dex1|dex3|inspire_ftp|inspire_dfx|brainco`

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
`--input-mode controller` or edit `pc2_teleop.env` directly.

## Notes

- Run these scripts on `g1-pc2`, not on your development machine.
- The setup script is intended to be run once, or only when reprovisioning the XR teleop stack.
- The `start_*.sh` wrappers are intended for recurring day-to-day teleop sessions.
- If the Wi-Fi/default-route interface changes, rerun setup or update `pc2_teleop.env`.
- `start_xr_teleoperate.sh` expects the DDS setup created by `../setup_unitree_g1_pc2_dds.sh` to exist.
