# Demo account without sudo

These commands target the existing PC2, with administrator account `dwei` and
new account `demo`. They assume the existing hardware profile and device rules
already match this robot. `demo` never joins the sudo group. System provisioning
is performed by `dwei`; the user installer and launchers run as `demo`.

## 1. Account: dwei — create the account and install system dependencies

Run once to create the account (omit `adduser` if it already exists):

```bash
sudo adduser demo
sudo usermod -aG video,dialout demo
```

Run this block from `dwei`. It uses the ROS distribution in the existing hardware
profile. ROS APT sources must already be configured, as on this provisioned PC2.

```bash
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

## 2. Account: demo — clone the repositories

From `dwei`, enter a fresh login for `demo`:

```bash
sudo -iu demo
```

The following commands now run as `demo`:

```bash
whoami
id -nG
cd ~
git clone https://github.com/MoissanClub/unitree_g1_dev.git
git clone --recurse-submodules https://github.com/MoissanClub/xr_teleoperate.git
exit
```

Expect `whoami` to print `demo`, with `video` and `dialout` in the group list.
`exit` returns to `dwei`. Do not rerun clone over an existing checkout.

## 3. Account: dwei — copy the local changes before they are published

The new user-only mode may not yet be on GitHub. Copy these launcher/setup files
from the modified local checkout into the fresh demo checkout. Once the same
changes are published and cloned, this copy is unnecessary.

```bash
cd /home/dwei/unitree_g1_dev/pc2/vr_teleops
sudo install -o demo -g demo -m 0755 \
  setup_pc2_xr_teleop.sh common_teleop_env.sh demo.sh start_brainco_hand_server.sh \
  /home/demo/unitree_g1_dev/pc2/vr_teleops/
sudo install -o demo -g demo -m 0644 ../g1_pc2_hardware.env \
  /home/demo/unitree_g1_dev/pc2/g1_pc2_hardware.env
```

The copied hardware profile uses `$HOME` for checkout locations, so those paths
resolve under `/home/demo` when sourced by `demo`.

## 4. Account: demo — install its environment without sudo

From `dwei`:

```bash
sudo -iu demo
```

Then as `demo`:

```bash
cd ~/unitree_g1_dev/pc2/vr_teleops
bash setup_pc2_xr_teleop.sh --user-only --no-pull --input-mode hand --ee brainco
```

This installs Conda/Python dependencies, the local C++ SDK, BrainCo, and the
user's ROS workspace, then creates TLS and camera/runtime configuration. It
does not start teleoperation or the hand server; camera discovery can access
the camera. The SDK installs to `~/.local/opt/unitree_sdk2`. `--no-pull` retains
existing checkout revisions but still clones missing repositories and
initializes pinned submodules. The administrator prerequisites must be present;
the installer will not request sudo to repair them.

## 5. Account: demo — check the generated configuration

```bash
grep '^export G1_TELEOP_PRIVILEGE_MODE=' ~/.config/xr_teleoperate/pc2_teleop.env
bash demo.sh --help
```

Expect `export G1_TELEOP_PRIVILEGE_MODE="user"`. The installer also checks Python
imports and native library linkage. These checks do not prove hardware operation.

## 6. Account: dwei — resolve existing sessions if needed

Stop any previous teleoperation session using Ctrl+C in its owning terminal.
The demo launcher will not kill another account's hand/camera processes.
If Unitree's vendor camera services are still holding the camera, the following
commands deliberately stop those two services for the session:

```bash
sudo /unitree/sbin/mscli stopservice video_hub_pc4
sudo /unitree/sbin/mscli stopservice video_hub_pc4_chest
```

Only use these if that camera conflict exists. They do not stop `ota_pipe` or
permanently remove service definitions. Handle other resource owners explicitly;
do not kill every camera/port holder indiscriminately.

## 7. Account: demo — launch the hardware session

With the robot physically prepared for teleoperation, in a `demo` login:

```bash
cd ~/unitree_g1_dev/pc2/vr_teleops
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
