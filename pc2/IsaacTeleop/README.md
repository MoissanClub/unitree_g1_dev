# Standalone Isaac Teleop on PC2

Install Isaac Teleop and NVIDIA CloudXR, then connect a Quest headset and check
live head/controller input. This folder runs independently of LeRobot, MuJoCo,
the Unitree SDK, and robot hardware. Both scripts read the shared
[`g1_pc2_hardware.env`](../g1_pc2_hardware.env) through
[`load_g1_pc2_hardware.sh`](../load_g1_pc2_hardware.sh). Review that profile and
set `G1_HARDWARE_CONFIGURED=1` before using them. The scripts do not modify it.

## Install

Requires Linux aarch64 or x86_64 and an installed `uv`. The installer searches
PATH, `~/.local/bin`, `~/.cargo/bin`, the active conda environment, and standard
Miniforge/Miniconda/Anaconda installations and their environments. No conda
activation is needed. Use `--uv /path/to/uv` (or `UV_BIN`) to override discovery.
The installer creates a local
`.venv` with Python 3.12; `uv` can download Python if necessary. Run as your normal
user, not with `sudo`. The installer requests sudo only to install missing
`vulkan-tools` or append required `video`/`render` group membership. It does not
change drivers, firewall rules, services, shell profiles, or system Python.
Use [uv's installation guide](https://docs.astral.sh/uv/getting-started/installation/)
if `uv` is not available. An existing environment's `uv` executable can also be
used; packages still install into this folder's separate `.venv`.

From this repository's root (commands also work in zsh):

```sh
cd pc2/IsaacTeleop
bash install.sh --dry-run
bash install.sh
```

If GPU group access is missing, the installer adds the needed membership and
exits with status 3. Open a **new SSH login**, then rerun `bash install.sh`.
An existing shell/tmux session does not acquire the new groups. The installer
never applies broad `chmod` permissions to GPU devices.

Before installing Python packages, the installer runs a headless
`vulkaninfo --summary` check, requires an NVIDIA GPU and the four instance
extensions CloudXR reported missing, and saves the output to
`vulkan-check.log`. It stops on failure rather than treating successful Python
imports as runtime readiness. `--dry-run` only prints the proposed operations;
it does not add groups, install tools, or run the GPU probe.

Optional interpreter/environment locations:

```sh
bash install.sh --python /path/to/python3.12 --venv /path/to/standalone-venv
```

The installer pins `isaacteleop[cloudxr,retargeters-lite]==1.4.145`, uses NumPy
2.0–2.2 and SciPy 1.15–1.16, and checks the installation afterward. The lite
extra avoids the full retargeter's ARM dependency constraints. No PyTorch or
Pinocchio is required. Re-running the installer reuses the environment; an
existing non-venv directory is never replaced. The `--python` option applies
when creating the environment, not to an existing one.

This release includes stable and experimental CloudXR runtimes. Its launcher
automatically selects `isaacteleop.cloudxr_exp` on Jetson Orin/T234. The verifier
checks this selection instead of assuming that an ARM wheel proves runtime
support. See NVIDIA's [CloudXR guide](https://nvidia.github.io/IsaacTeleop/release/1.4.x/references/cloudxr.html)
and [release notes](https://github.com/NVIDIA/IsaacTeleop/issues/1065).

## LeRobot integration and MuJoCo G1-29

These are separate from the standalone `.venv` workflow:

- `setup_lerobot.sh` installs the pinned Isaac Teleop extras into the existing
  `lerobot-dev` environment, preserves its NumPy/SciPy versions, applies the
  certificate-page patch there, and constructs LeRobot's full XR input pipeline.
- `run_lerobot_mujoco.sh` starts the standard LeRobot CLI in **simulation only**.
  `lerobot_env.sh` supplies the existing conda libraries, thread settings, and
  Orin EGL preload at process startup. No global shell/driver changes are made.
  On Orin, `--video` also selects `teleop.video_openxr_composition=false`:
  NVIDIA documents that native OpenXR quad layers can appear black there.
  This requires the matching LeRobot XR configuration option.

Prerequisites: a `~/lerobot` checkout with `unitree_g1_motion` and XR video support, its existing
`lerobot-dev` environment with Pinocchio/CasADi, MuJoCo, and LeRobot dependencies,
and the GPU permissions verified by standalone `install.sh`. Override locations
with `LEROBOT_DIR` and `LEROBOT_PYTHON`; `UV_BIN` selects uv for setup.

```sh
cd ~/unitree_g1_dev/pc2/IsaacTeleop
bash setup_lerobot.sh --dry-run
bash setup_lerobot.sh
bash run_lerobot_mujoco.sh --replay
```

Stop the standalone verifier and any previous CloudXR session before live use:

```sh
bash run_lerobot_mujoco.sh --accept-eula --video
```

The launcher prints the certificate URL using the shared hardware profile.
Use its pre-filled client button, choose **H.264**, connect, and enter VR. In the
**laptop terminal** running the command, type `r` then Enter to start tracking,
`p` then Enter to pause, and `q` then Enter to exit. Browser Play is not the
LeRobot start command. Tracking loss pauses motion and requires another `r`.
Move one controller at a time initially and keep sticks centered. Wrist mapping
is absolute/head-relative, not a squeeze clutch. Hands are not actuated.

Omit `--video` to test controllers without the headset camera. `--onscreen` adds
a local MuJoCo window when a working local display is available. Each run creates
a fresh directory under `~/.local/state/lerobot-g1-vr/` containing its config and
`report.jsonl`; `LEROBOT_RUNS_DIR` overrides this. Asset preparation downloads
pinned Hub snapshots on first use; `HF_HUB_OFFLINE=1` can reuse the cache afterward.
The launcher offers no physical robot mode or motion-enabling flags.

If `ssh -Y` cannot create the onscreen GLX context
(`BadValue`, followed by `could not create window`), check the laptop X server
and its OpenGL support. A nonempty `DISPLAY` alone
does not establish OpenGL support. Omit `--onscreen` to retain the working VR
path.

The installed PyTorch build must support the operations required by the camera
path. A warning about unsupported Orin SM 8.7 kernels does not by itself identify
a video failure, but successful buffer allocation does not establish support for
general CUDA computation or training. Verify camera delivery separately and
ensure the process has `render` group access.

## Check packages without starting XR

```sh
.venv/bin/python verify.py --check-only
```

Checks the pinned version, controller/head graph construction, bundled runtime
files, and shared-library resolution with `ldd` when available. It does not open
an OpenXR session, start CloudXR, accept an EULA, or require a headset.

## Hardware profile and Wi-Fi address

The host address comes from, in order:

1. An explicit `--host-ip` argument.
2. Optional `G1_WIFI_IP="..."` in the hardware profile.
3. The current global IPv4 address on the profile's `G1_WIFI_IFACE`, queried
   with `ip -j -4 addr`. Zero or multiple addresses require an explicit override.

This follows DHCP address changes without hard-coding a Wi-Fi IP in the scripts.
To inspect the selected profile, interface, and address without loading the SDK
or starting XR:

```sh
.venv/bin/python verify.py --show-config
```

Both scripts honor the repository-wide profile override:

```sh
export G1_HARDWARE_CONFIG_FILE=/absolute/path/to/g1_pc2_hardware.env
```

Overrides must be complete profiles accepted by the shared loader. Network
settings, robot addresses, and camera settings are never changed by these scripts.

## Connect the headset

Put PC2 and the headset on a mutually reachable network. Stop any other CloudXR
or XR application first. Review NVIDIA's CloudXR EULA before supplying
`--accept-eula`; installation and package checks do not accept it for you.

The verifier uses the Wi-Fi address from the hardware profile/interface:

```sh
.venv/bin/python verify.py --headset --accept-eula
```

On Jetson Orin/T234, `verify.py` automatically re-executes with the system
`libEGL.so.1` in `LD_PRELOAD` before loading the SDK. This addresses an EGL crash during CloudXR connection. Existing preload
entries are preserved; package/config checks and other platforms are unaffected.
For diagnosis only, `ISAAC_TELEOP_PRELOAD_EGL=0` disables this workaround.

1. In the Quest browser, open the certificate URL printed by the verifier
   (`https://<resolved-host-ip>:48322`) and accept the local certificate if prompted.
2. Click **Open NVIDIA Isaac Teleop Client** on the certificate page. The link
   passes the certificate page's host IP and port as `serverIP` and `port` URL
   parameters to pre-fill the client. Select **H.264** in the Video Codec dropdown
   on Orin, then click **Connect**; no second URL or IP needs to be typed in the
   headset. Dropdowns and buttons are sufficient for the remaining basic setup.
3. Enter VR, wear the headset, wake both controllers, and move them. The terminal
   prints tracking validity, controller positions, and trigger values.

`install.sh` applies `patch_cloudxr_page.py` to the pinned package's certificate
page. The patch adds a large link to <https://nvidia.github.io/IsaacTeleop/client>
in the same tab, is safe to rerun (including upgrading the older link without
parameters), and refuses unknown package versions/templates. The link derives
the address in the browser, so it follows the IP used to open the certificate
page rather than hard-coding an address.
After installing this update, stop and restart `verify.py` and reload the
certificate page. The patch changes only page content; certificate validation
and WebSocket handling remain unchanged.

Default profile: `Quest3`. Pass `--profile NAME` for another profile supported
by the installed CloudXR release. `--duration 1200` allows a longer connection
window; the default is 600 seconds (10 minutes) after OpenXR startup. SDK startup has its
own timeout. Use Ctrl+C to stop early.

The test exits successfully after 90 consecutive fresh frames with valid head
and both controller poses. A timeout, SDK error, or interruption is not a pass.
OpenXR closes before CloudXR during shutdown. A pass verifies live input only:
there is no robot scene, camera streaming, or robot motion in this test.

## Troubleshooting and validation scope

If the runtime disconnects when the headset connects, rerun with fault reporting:

```sh
PYTHONFAULTHANDLER=1 .venv/bin/python verify.py --headset --accept-eula
```

On a tracking exception, the verifier reports the runtime worker's exit code or
signal before cleanup (or reports that it is still running). This does not need
`strace`. Inspect `~/.cloudxr/logs/runtime_stderr.log` for fault output; an exit
signal identifies how the process ended, not necessarily the underlying cause.

- Missing module: use this folder's `.venv/bin/python`, not another interpreter.
- Occupied port: the verifier checks TCP 48322 and 49100; stop the existing XR
  runtime yourself. It never kills another process.
- Runtime fails: inspect `~/.cloudxr/logs`. The native runtime requires a working
  NVIDIA graphics/encoding stack; Python imports do not establish GPU support.
- `Connection refused` on the certificate URL: installation alone does not run
  the HTTPS proxy. Keep `verify.py --headset --accept-eula` running, and inspect
  its terminal if it exits. The page disappears when the verifier stops.
- Crash immediately on **Connect**, followed by `Broken pipe`,
  `XR_ERROR_INSTANCE_LOST`, or browser `Server validation timeout`: an EGL segmentation fault can cause these symptoms; increasing the timeout or
  selecting H.264 alone does not address that fault. Ensure the Orin EGL preload message appears (or EGL is
  already in `LD_PRELOAD`). Inspect the runtime logs for the underlying failure.
- `Missing required instance extensions` / `ERROR_INCOMPATIBLE_DRIVER`: rerun
  `bash install.sh`. Check for `EACCES` opening GPU render devices and missing `render` group
  access. The installer handles that membership change and then requires a new
  login. If the Vulkan check still fails afterward, inspect `vulkan-check.log`;
  do not assume a Python reinstall or a longer CloudXR timeout will fix it.
- No headset: check the certificate, client IP, network isolation/firewall, and
  NVIDIA's [network requirements](https://docs.nvidia.com/cloudxr-sdk/latest/requirement/network_setup.html).
  These scripts do not change firewall rules.
- Orin selects stable CloudXR: remove an inherited `ISAAC_TELEOP_CLOUDXR_EXP=0`
  override and rerun the check.
