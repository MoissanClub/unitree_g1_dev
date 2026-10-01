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

1. In the Quest browser, open the certificate URL printed by the verifier
   (`https://<resolved-host-ip>:48322`) and accept the local certificate if prompted.
2. Open <https://nvidia.github.io/IsaacTeleop/client>, enter the printed IP, and connect.
3. Enter VR, wear the headset, wake both controllers, and move them. The terminal
   prints tracking validity, controller positions, and trigger values.

Default profile: `Quest3`. Pass `--profile NAME` for another profile supported
by the installed CloudXR release. `--duration 300` allows a longer connection
window; the default is 120 seconds after OpenXR startup. SDK startup has its
own timeout. Use Ctrl+C to stop early.

The test exits successfully after 90 consecutive fresh frames with valid head
and both controller poses. A timeout, SDK error, or interruption is not a pass.
OpenXR closes before CloudXR during shutdown. A pass verifies live input only:
there is no robot scene, camera streaming, or robot motion in this test.

## Troubleshooting and validation scope

- Missing module: use this folder's `.venv/bin/python`, not another interpreter.
- Occupied port: the verifier checks TCP 48322 and 49100; stop the existing XR
  runtime yourself. It never kills another process.
- Runtime fails: inspect `~/.cloudxr/logs`. The native runtime requires a working
  NVIDIA graphics/encoding stack; Python imports do not establish GPU support.
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

Development validation on PC2 (Jetson Orin NX, Ubuntu 22.04, L4T 36.4.3): an
isolated Python 3.12 environment installed the pinned wheel and constructed the
input graph without LeRobot or PyTorch. Live CloudXR startup and physical
headset acceptance still require the test above; they have not been claimed
as passing. `.venv`, Python caches, and local logs are excluded from Git.
