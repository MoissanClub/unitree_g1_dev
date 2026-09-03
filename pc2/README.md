# PC2 Setup Scripts

This folder contains helper scripts intended to be copied to the Unitree G1
`pc2` machine and run there during initial setup.

## Required First Step: Populate the Hardware Profile

Before running any installer, open `g1_pc2_hardware.env` and verify the robot Ethernet interface, Wi-Fi interface, BrainCo stable serial ports and adapter serial, head-camera identifiers, LiDAR settings, ROS distribution, and robot DOF. Set `G1_HARDWARE_CONFIGURED=1` only after those values match the physical PC2 wiring.

Useful discovery commands:

```bash
ip -brief addr
ls -l /dev/serial/by-id/
for node in /sys/class/video4linux/video*; do echo "$node: $(cat "$node/name")"; done
udevadm info --query=property --name=/dev/ttyUSB0
```

Every installation script loads this profile through `load_g1_pc2_hardware.sh`. To test a different profile without editing the checked-in file, set `G1_HARDWARE_CONFIG_FILE=/absolute/path/to/another.env`. Individual command-line flags still override profile values for one-off recovery or rewiring tests.

These scripts are meant to be run once, or only when you are intentionally
re-provisioning `g1-pc2`. They are not meant to be part of normal day-to-day
operation on the robot.

Currently included:

- `g1_pc2_wifi_setup.sh`: configure Wi-Fi on PC2 using NetworkManager. Run with `sudo`.
- `g1_pc2_boot_time_sync_setup.sh`: install a one-shot boot-time clock sync service. Run with `sudo`.
- `g1_pc2_apt_mirror_setup.sh`: switch Ubuntu APT sources on PC2 to reliable official Ubuntu mirrors. Run with `sudo`.
- `brainco/setup_g1_brainco.sh`: set up the BrainCo hand software in the user's home directory. Run as the normal login user, not with `sudo`.
- `setup_unitree_g1_pc2_dds.sh`: build and configure Unitree ROS 2 DDS as the normal login user. It auto-selects Foxy on Ubuntu 20.04 and Humble on Ubuntu 22.04.

## Set Up Unitree ROS 2 DDS

Install the ROS 2 distribution supported by the PC2 operating system first:

- Ubuntu 20.04: ROS 2 Foxy
- Ubuntu 22.04: ROS 2 Humble

The script checks this before changing packages. Run it as the normal login user; it invokes `sudo` only for missing APT dependencies:

```bash
./setup_unitree_g1_pc2_dds.sh --install-ros --auto-iface
```

Omit `--install-ros` once ROS is installed. The flag uses the official `ros-apt-source` package and installs the matching `ros-<distro>-ros-base` package; `sudo` prompts interactively.

If APT reports an invalid NVIDIA suite such as `ports.ubuntu.com ... r36.4` on a Jetson, repair the vendor source file while installing ROS:

```bash
./setup_unitree_g1_pc2_dds.sh --install-ros --repair-nvidia-apt --auto-iface
```

The repair is deliberately opt-in. It reads the installed L4T release, backs up `/etc/apt/sources.list.d/nvidia-l4t-apt-source.list`, and replaces only its active repository entries with NVIDIA's canonical `common`, platform, and `ffmpeg` repositories.

On Humble, the script uses the packaged CycloneDDS and builds the `unitree_api`, `unitree_go`, and G1/H-series `unitree_hg` message packages. On Foxy, it builds Unitree's required CycloneDDS 0.10.x source version first.

### Compatibility and Safe Fallbacks

The supported operating-system and ROS combinations are Ubuntu 20.04 with ROS 2 Foxy and Ubuntu 22.04 with ROS 2 Humble. The script rejects a mismatched combination before installing packages.

The NVIDIA APT repair is backward-compatible with earlier L4T releases on the same supported Jetson hardware:

- If the NVIDIA source file is already valid, `--repair-nvidia-apt` makes no changes.
- If the source file contains the known invalid `ports.ubuntu.com ... rXX.X` pattern, the script derives the repository suite from the installed `/etc/nv_tegra_release`; it does not force the version used by a newer system.
- Before changing the source file, the script creates a timestamped backup beside it.
- If the L4T release or Jetson platform cannot be determined confidently, the script stops without changing the file.

ROS 2 Foxy is end-of-life. Existing Foxy installations remain supported by the script, but a fresh Foxy installation may fail if its upstream package repositories no longer provide every required package. ROS 2 Humble on Ubuntu 22.04 is the recommended path for current PC2 images.

## Typical Workflow

The intended one-time setup workflow is:

1. Connect to PC2 from your development machine.
2. Clone or copy the entire repository to PC2 so the shared hardware profile and loader retain their relative paths.
3. SSH into PC2 and run the needed setup script(s) there with the correct privilege level.
4. Leave the installed configuration in place; do not keep rerunning these scripts unless you are deliberately changing the setup.

## Privilege Model

Use the following invocation mode for each script:

- `g1_pc2_wifi_setup.sh`: run with `sudo`.
- `g1_pc2_boot_time_sync_setup.sh`: run with `sudo`.
- `g1_pc2_apt_mirror_setup.sh`: run with `sudo`.
- `brainco/setup_g1_brainco.sh`: run as the normal login user, not with `sudo`.

The BrainCo script is different from the others because it writes into
user-specific paths under `~` and assumes the normal user's home directory and
repo layout. Running the whole script under `sudo` can cause path mismatches.

## 1. Connect To PC2

From your development machine, verify that PC2 is reachable on the Unitree wired side:

```bash
ping 192.168.123.164
```

Then connect with SSH:

```bash
ssh unitree@192.168.123.164
```

## 2. Copy This Folder To PC2

From your development machine, copy this entire folder to PC2 with `scp`:

```bash
scp -r /path/to/pc2 unitree@192.168.123.164:/home/unitree/
```

Example using the current folder name:

```bash
scp -r pc2 unitree@192.168.123.164:/home/unitree/
```

After copying, the script should be available on PC2 at:

```bash
/home/unitree/pc2/g1_pc2_wifi_setup.sh
```

## 3. Run The Needed Setup Script On PC2

SSH into PC2:

```bash
ssh unitree@192.168.123.164
```

Change into the copied folder:

```bash
cd /home/unitree/pc2
```

For Wi-Fi setup, show help. This script should be invoked with `sudo`:

```bash
sudo ./g1_pc2_wifi_setup.sh --help
```

Scan for visible Wi-Fi networks:

```bash
sudo ./g1_pc2_wifi_setup.sh --scan-only
```

Recommended for the usual LabWiFi router setup, where DHCP and DNS are already provided by the router:

```bash
sudo ./g1_pc2_wifi_setup.sh --ssid "LabWiFi" --ask-password --yes
```

Only use explicit static IP, gateway, and DNS parameters if your AP does not provide DHCP or you intentionally need a fixed Wi-Fi address:

```bash
sudo ./g1_pc2_wifi_setup.sh \
  --ssid "LabWiFi" \
  --ask-password \
  --ip 10.10.20.164/24 \
  --gateway 10.10.20.1 \
  --dns 1.1.1.1,8.8.8.8 \
  --yes
```

This is normally a one-time setup step. Rerun it only if you need to change the
Wi-Fi configuration on `g1-pc2`.

## Optional: Install Boot-Time Clock Sync

PC2 does not need a persistent NTP daemon if you want to keep background
services to a minimum. This installer adds a one-shot `systemd` service that
waits for networking at boot, fetches an HTTP `Date` header from a small list
of public endpoints, sets the system clock once, then exits.

This script should be invoked with `sudo`.

Show help:

```bash
sudo ./g1_pc2_boot_time_sync_setup.sh --help
```

Install it:

```bash
sudo ./g1_pc2_boot_time_sync_setup.sh --yes
```

Test it immediately after install:

```bash
sudo systemctl start g1-pc2-sync-clock.service
sudo systemctl status --no-pager g1-pc2-sync-clock.service
sudo journalctl -u g1-pc2-sync-clock.service -b --no-pager
```

This installer is also intended to be run once. After installation, `systemd`
and `NetworkManager` trigger the installed clock sync components automatically.

## Optional: Switch APT Mirrors

If `g1-pc2` ships with a slow or unreliable regional Ubuntu mirror, switch it
to the official Ubuntu archive endpoints.

This script should be invoked with `sudo`.

Show help:

```bash
sudo ./g1_pc2_apt_mirror_setup.sh --help
```

Preview detected current Ubuntu source URLs and planned replacements:

```bash
sudo ./g1_pc2_apt_mirror_setup.sh
```

Apply the change and refresh package indexes:

```bash
sudo ./g1_pc2_apt_mirror_setup.sh --yes --update
```

This is intended as a one-time setup correction. Rerun it only if you are
deliberately changing the configured Ubuntu mirror URLs again.

## Optional: Set Up BrainCo Hands

The BrainCo setup script lives under `brainco/` and should be run as the normal
login user, not with `sudo`, because it clones repositories and writes
configuration under `~`.

Show help:

```bash
./brainco/setup_g1_brainco.sh --help
```

Run it as the normal user:

```bash
./brainco/setup_g1_brainco.sh
```

The installer auto-detects BrainCo's current v2 layout and the legacy v1 layout. For v2 it downloads the repository's matching ARM64 Stark SDK, builds the Unitree SDK2 helper that disables the built-in arm action service, writes the separate left/right hand parameter files, and preserves the upstream safety launch sequence. For v1 it retains the bundled SDK and combined hand-parameter format.

The BrainCo Conda environment follows the ROS distribution's system Python ABI:
Python 3.8 for Foxy and Python 3.10 for Humble. When an existing environment
uses the wrong version (for example after upgrading PC2 from JetPack 5/Foxy to
JetPack 6/Humble), rerunning the installer migrates it and rebuilds the
workspaces with a clean CMake cache. The installer also includes OpenCV and
RealSense Python bindings because the main control module imports both even
when the configured task does not use vision.

The generated robot launcher isolates the Unitree SDK2 safety helper from the
ROS environment's `LD_LIBRARY_PATH`. This keeps SDK2's matching CycloneDDS C
and C++ libraries together and avoids an ABI crash before the arm service is
disabled on Humble.

The installer patches both the state manager and the active IK classes to use
the configured G1 description directory rather than upstream's fixed
`/home/unitree/g1_description` path.

The DDS setup must be complete first. Hardware values come from `g1_pc2_hardware.env`; command-line options can override them for a one-time run. Do not launch arm control until the installer completes and the physical safety checks in BrainCo's upstream documentation have been followed.

Do not prepend `sudo` to the entire BrainCo script. It already calls `sudo`
internally for the specific apt and udev steps that require elevation.

## Notes

- Run these scripts on `g1-pc2`, not on your development machine.
- Treat these as setup-time provisioning tools, not recurring maintenance commands.
- Use `sudo` for the Wi-Fi, boot-time clock sync, and APT mirror scripts.
- Run `brainco/setup_g1_brainco.sh` as the normal login user, not with `sudo`.
- The Wi-Fi script does not explicitly bring wired Ethernet down, but Wi-Fi can become the preferred default route for outbound traffic.
- By default, the Wi-Fi script refuses static addresses in `192.168.123.0/24` to avoid conflict with the Unitree Ethernet side.
- The boot-time clock sync uses public HTTP endpoints for rough time correction. It is intended to limit drift, not provide authenticated secure time.
