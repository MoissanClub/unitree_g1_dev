# Demo account without sudo

These commands target the existing PC2, with administrator account `dwei` and
new account `demo`. They assume the existing hardware profile and device rules
already match this robot. `demo` never joins the sudo group. System provisioning
is performed by `dwei`; the user installer and launchers run as `demo`.

Run everything on PC2. Keep **Terminal A logged in as dwei** for administrator
tasks and use **Terminal B as demo** for installation and operation. The existing
`/home/dwei/unitree_g1_dev` checkout does not need to be cloned again. The separate
checkouts under `/home/demo` belong to demo; system packages are shared.

## 1. Terminal A: dwei — directory /home/dwei

Run once to create the account (omit `adduser` if it already exists):

```bash
cd /home/dwei
sudo adduser demo
sudo usermod -aG video,dialout demo
```

## 2. Terminal A: dwei — directory /home/dwei/unitree_g1_dev/pc2/vr_teleops

Run this block from `dwei`. It uses the ROS distribution in the existing hardware
profile. ROS APT sources must already be configured, as on this provisioned PC2.

```bash
cd /home/dwei/unitree_g1_dev/pc2/vr_teleops
bash <<'ADMIN'
set -euo pipefail
cd /home/dwei/unitree_g1_dev/pc2/vr_teleops
source ../load_g1_pc2_hardware.sh
sudo apt-get update
sudo apt-get install -y \
  build-essential ca-certificates cmake curl git \
  libboost-program-options-dev libfmt-dev libspdlog-dev libyaml-cpp-dev \
  openssl pkg-config python3-pip v4l-utils psmisc iproute2 util-linux \
  python3-colcon-common-extensions \
  "ros-${G1_ROS_DISTRO}-ros-base" \
  "ros-${G1_ROS_DISTRO}-rmw-cyclonedds-cpp" \
  "ros-${G1_ROS_DISTRO}-rosidl-generator-dds-idl"
ADMIN
```

The existing BrainCo rule `/etc/udev/rules.d/99-brainco-ftdi.rules` grants
`dialout` access. Inspect it without modifying device state:

```bash
cat /etc/udev/rules.d/99-brainco-ftdi.rules
```

If the adapter identifiers differ, an administrator must correct the rule.
Native RealSense additionally requires appropriate USB permissions; this guide
uses the checked-in OpenCV camera configuration on this PC2.

## 3. Terminal B: switch from dwei to demo — directory /home/dwei

Open another PC2 terminal as `dwei`. Enter a fresh login for `demo`:

```bash
cd /home/dwei
sudo -iu demo
```

Terminal B is now logged in as `demo`, in `/home/demo`. Leave Terminal A as `dwei`.

## 4. Terminal B: demo — directory /home/demo

```bash
cd /home/demo
whoami
id -nG
git clone https://github.com/MoissanClub/unitree_g1_dev.git
git clone --recurse-submodules https://github.com/MoissanClub/xr_teleoperate.git
```

Expect `whoami` to print `demo`, with `video` and `dialout` in the group list.
Do not rerun clone over an existing checkout. If the launcher repository already
exists and is clean, update it instead (Terminal B, demo):

```bash
cd /home/demo/unitree_g1_dev
git pull --ff-only
```

## 5. Terminal A: dwei — directory /home/dwei/unitree_g1_dev/pc2

The user-only changes are published on GitHub; no script copying is needed.
Copy this PC2's verified hardware profile into the new demo checkout:

```bash
cd /home/dwei/unitree_g1_dev/pc2
sudo install -o demo -g demo -m 0644 g1_pc2_hardware.env \
  /home/demo/unitree_g1_dev/pc2/g1_pc2_hardware.env
```

The copied hardware profile uses `$HOME` for checkout locations, so those paths
resolve under `/home/demo` when sourced by `demo`.

## 6. Terminal B: demo — directory /home/demo/unitree_g1_dev/pc2/vr_teleops

Install demo's environment. If the camera is occupied, resolve the conflict
using step 8 first.

```bash
cd /home/demo/unitree_g1_dev/pc2/vr_teleops
bash setup_pc2_xr_teleop.sh --user-only --no-pull --input-mode hand --ee brainco
```

This installs Conda/Python dependencies, the local C++ SDK, BrainCo, and the
user's ROS workspace, then creates TLS and camera/runtime configuration. It
does not start teleoperation or the hand server; camera discovery can access
the camera. The SDK installs to `~/.local/opt/unitree_sdk2`. `--no-pull` retains
existing checkout revisions but still clones missing repositories and
initializes pinned submodules. The administrator prerequisites must be present;
the installer will not request sudo to repair them.

## 7. Terminal B: demo — directory /home/demo/unitree_g1_dev/pc2/vr_teleops

```bash
cd /home/demo/unitree_g1_dev/pc2/vr_teleops
grep '^export G1_TELEOP_PRIVILEGE_MODE=' /home/demo/.config/xr_teleoperate/pc2_teleop.env
bash demo.sh --help
```

Expect `export G1_TELEOP_PRIVILEGE_MODE="user"`. The installer also checks Python
imports and native library linkage. These checks do not prove hardware operation.

## 8. Terminal A: dwei — directory /home/dwei — optional camera conflict resolution

Stop any previous teleoperation session using Ctrl+C in its owning terminal.
The demo launcher will not kill another account's hand/camera processes.
If Unitree's vendor camera services are still holding the camera, the following
commands deliberately stop those two services for the session:

```bash
cd /home/dwei
sudo /unitree/sbin/mscli stopservice video_hub_pc4
sudo /unitree/sbin/mscli stopservice video_hub_pc4_chest
```

Only use these if that camera conflict exists. They do not stop `ota_pipe` or
permanently remove service definitions. Handle other resource owners explicitly;
do not kill every camera/port holder indiscriminately.

## 9. Terminal B: demo — directory /home/demo/unitree_g1_dev/pc2/vr_teleops

With the robot physically prepared for teleoperation, in a `demo` login:

```bash
cd /home/demo/unitree_g1_dev/pc2/vr_teleops
bash demo.sh --hand
```

Open the printed Quest URL. Ctrl+C stops the session. This starts hardware
services and can move the robot and hands. `--no-motion` is not a guarantee
that arms or fingers cannot move. Subsequent sessions need only this step,
provided no other session or vendor service holds the devices.

## Validation status

The user-prefix native build and mocked supervisor checks can validate software
paths without running hardware. A real `demo` account installation and supervised
non-root camera/hand test are still required on PC2 before declaring the demo
account ready for operation.
