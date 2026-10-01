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
  This needs the matching LeRobot XR configuration option in the local branch.

Prerequisites: the `~/lerobot` checkout on `work/g1-vr-teleoperate`, its existing
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

The tested `ssh -Y` connection could not create the onscreen GLX context
(`BadValue`, followed by `could not create window`). A nonempty `DISPLAY` alone
does not establish OpenGL support. Omit `--onscreen` to retain the working VR
path. A browser camera viewer through an SSH tunnel is not implemented yet.

PC2 integration checks on 2026-10-02: SDK/LeRobot pipeline construction passed;
100-frame replay produced 100 enabled simulation actions and closed cleanly,
with `motor_publication=false` and `base_rpc=false`. Four XR-input/CLI tests,
eleven camera-channel/lifecycle tests, and the opt-in offscreen GPU video
delivery/recovery test passed. Live CloudXR, shared XR input/video, and MuJoCo
startup succeeded. The operator confirmed visible headset video and controller
movement driving the simulated robot; detailed arm-mapping acceptance remains
a separate test. Video-enabled simulation initially ran around
20–24 Hz against a 50 Hz target; no real-time hardware performance is claimed.

The current PyTorch build warns that general CUDA kernels do not support Orin
SM 8.7; do not infer that GPU training works. The exact allocation/copy operations
used by this camera path and its offscreen rendering test passed when the process
had `render` group access. A stale SSH/agent session without that group instead
reported CUDA initialization errors. No alternate GPU-array package is required.

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
`libEGL.so.1` in `LD_PRELOAD` before loading the SDK. This incorporates the
workaround that passed the PC2 headset test described below. Existing preload
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
  `XR_ERROR_INSTANCE_LOST`, or browser `Server validation timeout`: the observed
  PC2 failure was an EGL segmentation fault, not fixed by increasing timeout or
  selecting H.264 alone. Ensure the Orin EGL preload message appears (or EGL is
  already in `LD_PRELOAD`). See the diagnosis and evidence below.
- `Missing required instance extensions` / `ERROR_INCOMPATIBLE_DRIVER`: rerun
  `bash install.sh`. On this PC2, a read-only trace showed `EACCES` opening
  `/dev/dri/renderD128` and `renderD129` because the login lacked `render` group
  access. The installer handles that membership change and then requires a new
  login. If the Vulkan check still fails afterward, inspect `vulkan-check.log`;
  do not assume a Python reinstall or a longer CloudXR timeout will fix it.
- No headset: check the certificate, client IP, network isolation/firewall, and
  NVIDIA's [network requirements](https://docs.nvidia.com/cloudxr-sdk/latest/requirement/network_setup.html).
  These scripts do not change firewall rules.
- Orin selects stable CloudXR: remove an inherited `ISAAC_TELEOP_CLOUDXR_EXP=0`
  override and rerun the check.

## PC2 installation and test record (2026-10-02)

### Scope and environment

The goal was a minimum standalone Quest-to-PC2 tracking test before integrating
LeRobot, a MuJoCo G1-29 scene, or the physical robot. PC2 is the G1-29's Jetson
Orin NX running Ubuntu 22.04 / L4T 36.4.3 (ARM64). During this test its Wi-Fi
address was `192.168.0.201`; scripts resolve the address from the shared profile
and interface rather than embedding that test address.

The scripts were first created in `IsaacTeleop/` and moved under `pc2/IsaacTeleop/`
in this repository. Installation uses a separate `.venv`, Python 3.12,
Isaac Teleop 1.4.145, bundled CloudXR 6.3.0, and the NumPy/SciPy pins above.
The tested venv used the Python interpreter from the existing `lerobot-dev`
conda environment: package isolation does not imply an independent interpreter
or native-library stack. No LeRobot import, robot SDK, or PyTorch is required
for this verification. `--python` can select a different interpreter when
creating a new environment.

### Failures and resolutions

1. **uv not on PATH:** the installer now discovers uv in common user and conda
   locations, with `--uv` / `UV_BIN` overrides. Activation is optional.
2. **Vulkan startup failure:** missing KHR instance-extension messages initially
   obscured `EACCES` on GPU render devices. The user had `video` access but lacked
   `render` membership. The installer adds missing groups, requests a new login,
   and checks NVIDIA Vulkan support before proceeding. It does not replace
   drivers or make GPU device nodes world-writable.
3. **Headset setup took longer than the test window:** the tracking duration was
   raised from 120 to 600 seconds after OpenXR startup. `--duration` controls
   that window; the SDK's startup timeout is separate. The test still ends
   early when its pass condition is met.
4. **Typing URLs in VR was cumbersome:** the pinned-package patch adds a large
   certificate-page button with `serverIP` and `port` query parameters derived
   from the page address. Re-running the installer applies or upgrades the
   patch; restart the verifier and reload the page afterward. Editing the patch
   script alone does not change the installed page. Prefer no VR typing, then
   laptop input, and only minimal headset typing when unavoidable.
5. **Connect crashed the runtime:** both controllers stayed invalid before the
   connection, then local OpenXR IPC reset and the browser reported a validation
   timeout. H.264 alone did not resolve this. Fault reporting confirmed SIGSEGV;
   a native debugger located the failing thread in system `libEGL.so.1`, called
   from `__nptl_deallocate_tsd` during thread cleanup. The backtrace identifies
   the crash location, not a proven underlying library defect.
6. **EGL preload passed the test:** running the verifier with
   `LD_PRELOAD=/lib/aarch64-linux-gnu/libEGL.so.1` avoided the Connect crash and
   produced the tracking pass below. The verifier now applies this automatically
   on Orin. The manual preload run was headset-tested; the automatic re-exec
   path was checked separately without starting hardware.

### Observed result and limits

The user reported this result with H.264 and the explicit EGL preload:

```text
fresh=True tracking={'head': True, 'left': True, 'right': True} consecutive=77
PASS: 90 consecutive fresh frames with head and both controllers tracked.
```

This confirms sustained valid headset and both-controller poses for the minimum
test. `head=True` alone before connection was not a pass. Trigger values in the
shared output were `0.00`, so button/trigger actuation was not established.
The test does not validate long-running stability, reconnect/reset behavior,
hand tracking, camera/video quality, retargeting, MuJoCo, or robot motion.
Seeing browser controls or pressing Play/Reset is not itself a tracking pass.

### Debugging without additional installs

The verifier reports runtime process exit status before cleanup. Python fault
reporting records native faults in `runtime_stderr.log`. When a native backtrace
is needed, attach GDB to the **CloudXR worker**, not the verifier, before clicking
Connect. Use the current PID each run. PC2 required a sudo attach. A missing
`futex-internal.c` source file in GDB is harmless; it is not the crash cause.
Store debugger logs in a dedicated directory: root opening an existing
user-owned file directly under sticky `/tmp` caused a logging permission error
in this investigation. No permanent ptrace or system permission changes were
needed. Raw logs, TLS keys, environments, and caches are not checked into Git.

### Upstream certificate-page contribution

The certificate page belongs to the Isaac Teleop CloudXR integration. Upstream
has renamed the repository to IsaacCapture. Draft
[PR #1170](https://github.com/NVIDIA/IsaacCapture/pull/1170) adds an optional
client button with pre-filled IP/port and manual server mode, preserves the
return-to-another-client option, and supports local, configured, or versioned
clients without forcing a redirect. It is separate from the EGL workaround.
The local upstream checkout was moved from `/tmp/isaac-cert-pr` to
`~/IsaacCapture`, branch `fix/cloudxr-certificate-client-link`, for iteration.
Its 18 focused tests and upstream pre-commit checks passed; upstream headset
validation and a broader lifecycle check requiring native extensions remain
separate from the successful local patched-page test.
