# Codex Project Memory

## Purpose

This repository contains setup, configuration, and launcher scripts that make
development on a Unitree G1 EDU robot easier. Most scripts target the robot's
PC2 computer; this repository is not the implementation source for Unitree ROS,
XR teleoperation, BrainCo firmware, or the vendor services it configures.

The project-level `.codex/` directory was empty when this memory was created on
2026-09-04. This file captures durable repository context for future Codex
sessions and is intentionally safe to keep in GitHub.

## Repository Map

- `pc2/`: one-time PC2 provisioning for Wi-Fi, boot-time clock correction,
  Ubuntu APT mirrors, and ROS 2/CycloneDDS.
- `pc2/brainco/`: BrainCo Revo2 hand setup, serial-port discovery, udev rules,
  workspaces, configuration, and launch wrappers.
- `pc2/vr_teleops/`: XR teleoperation setup plus recurring BrainCo,
  teleimager, camera-switching, and XR launchers.
- `lidar/`: one-time ROS 2/RViz setup and the recurring MID-360 point-cloud
  viewer launcher.

Read the nearest README before changing or running a script. The detailed
operating procedures live in `pc2/README.md`, `pc2/vr_teleops/README.md`, and
`lidar/G1_LiDAR_RViz_README.md`.

## Safety and Privilege Boundaries

- Treat robot motion and hand motion as hardware-affecting operations. Do not
  execute them without the user's explicit authorization and normal physical
  safety checks.
- Run `pc2/g1_pc2_wifi_setup.sh`,
  `pc2/g1_pc2_boot_time_sync_setup.sh`, and
  `pc2/g1_pc2_apt_mirror_setup.sh` with `sudo` on PC2.
- Run `pc2/brainco/setup_g1_brainco.sh` and the XR setup/runtime scripts as the
  normal login user. They invoke `sudo` internally only where required.
- Setup scripts can alter networking, routes, APT sources, systemd units, udev
  rules, camera services, repositories, Conda environments, and files under
  the user's home directory. Prefer help, preview, dry-run, and diagnostic
  modes before applying changes.
- Do not commit Wi-Fi passwords, TLS private keys, access tokens, local runtime
  configuration, telemetry containing sensitive data, or Codex session state.

## Important Runtime Assumptions

- The Unitree wired subnet is normally `192.168.123.0/24`; scripts avoid using
  it for Wi-Fi to prevent route conflicts.
- DDS setup defaults to ROS 2 Foxy, CycloneDDS, `~/unitree_ros2`, robot address
  `192.168.123.161`, and a detected or explicitly supplied robot interface.
- XR launchers read `~/.config/xr_teleoperate/pc2_teleop.env`. The downstream
  implementation normally lives in `~/xr_teleoperate`.
- Quest hand tracking with BrainCo uses `G1_TELEOP_INPUT_MODE=hand` and
  `G1_TELEOP_EE=brainco`.
- Teleimager supports OpenCV/UVC and native RealSense modes. Do not disable
  Unitree's `ota_pipe` service when releasing vendor camera services.
- The LiDAR defaults are topic `/utlidar/cloud_livox_mid360`, frame
  `livox_frame`, and ROS domain 0. Its optional `map -> livox_frame` transform
  is visualization-only, not localization or SLAM.

## Change and Verification Guidance

- Preserve scripts' existing normal-user-versus-root behavior.
- Keep setup operations idempotent or safely repeatable where practical.
- Avoid hard-coding device names, interface names, IP addresses, serial
  numbers, or home paths when detection or an environment override exists.
- After editing shell scripts, run `bash -n` on every changed script. Use
  `shellcheck` when available, then verify the relevant `--help` or dry-run path.
- Hardware, networking, system-service, or robot-motion tests require explicit
  authorization; clearly distinguish static validation from on-device testing.
- Keep READMEs synchronized with changed flags, defaults, generated files, and
  operating procedures.
