# PC2 Setup Scripts

This folder contains helper scripts intended to be copied to the Unitree G1
`pc2` machine and run there during initial setup.

These scripts are meant to be run once, or only when you are intentionally
re-provisioning `g1-pc2`. They are not meant to be part of normal day-to-day
operation on the robot.

Currently included:

- `build_mt76x2u_on_pc2.sh`: build and install MT7612U kernel modules from the matching NVIDIA L4T source tree. Run with `sudo`.
- `g1_pc2_wifi_setup.sh`: configure Wi-Fi on PC2 using NetworkManager. Run with `sudo`.
- `g1_pc2_dual_wifi_setup.sh`: connect PC2 to an uplink Wi-Fi network while also exposing its own AP for direct SSH access. Run with `sudo`.
- `g1_pc2_usb_wifi_ap_setup.sh`: configure a USB Wi-Fi adapter as a local AP while leaving the built-in Wi-Fi uplink alone. Run with `sudo`.
- `g1_pc2_usb_wifi_ap_vht80_setup.sh`: configure the USB adapter as a dedicated 5 GHz, 80 MHz `hostapd` AP. Run with `sudo`.
- `g1_pc2_boot_time_sync_setup.sh`: install a one-shot boot-time clock sync service. Run with `sudo`.
- `g1_pc2_apt_mirror_setup.sh`: switch Ubuntu APT sources on PC2 to reliable official Ubuntu mirrors. Run with `sudo`.
- `brainco/setup_g1_brainco.sh`: set up the BrainCo hand software in the user's home directory. Run as the normal login user, not with `sudo`.

## Typical Workflow

The intended one-time setup workflow is:

1. Connect to PC2 from your development machine.
2. Copy this folder from your development machine to PC2.
3. SSH into PC2 and run the needed setup script(s) there with the correct privilege level.
4. Leave the installed configuration in place; do not keep rerunning these scripts unless you are deliberately changing the setup.

## Privilege Model

Use the following invocation mode for each script:

- `build_mt76x2u_on_pc2.sh`: run with `sudo` on PC2, never on the development Mac.
- `g1_pc2_wifi_setup.sh`: run with `sudo`.
- `g1_pc2_dual_wifi_setup.sh`: run with `sudo`.
- `g1_pc2_usb_wifi_ap_setup.sh`: run with `sudo`.
- `g1_pc2_usb_wifi_ap_vht80_setup.sh`: run with `sudo`.
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

## Optional: Uplink Wi-Fi Plus Local AP

If PC2's actual Wi-Fi chip/driver supports concurrent client plus AP mode, this
script can keep PC2 on your home Wi-Fi for internet access while also exposing
its own SSH-friendly Wi-Fi network. The script checks support on the live
machine before it tries to configure anything.

Show help:

```bash
sudo ./g1_pc2_dual_wifi_setup.sh --help
```

Configure uplink plus AP:

```bash
sudo ./g1_pc2_dual_wifi_setup.sh --uplink-ssid "HomeWiFi" --ap-ssid "g1-pc2"
```

If setup succeeds, clients that join the local AP can SSH to:

```bash
ssh unitree@10.42.0.1
```

## Optional: USB Wi-Fi Adapter As Local AP

If PC2 already gets internet through the built-in Wi-Fi, use this script to make
the USB MT7612U adapter provide a local access point for SSH/control traffic.
This avoids single-radio client+AP concurrency: the built-in Wi-Fi remains the
uplink, and the USB dongle is AP-only.

First confirm the adapter is present:

```bash
lsusb | grep -i '0e8d:7612'
iw dev
```

On L4T 36.4.3, the stock `5.15.148-tegra` configuration does not build MT76.
The matching NVIDIA `public_sources.tbz2` download is about 216 MiB, its nested
kernel archive is about 149 MiB, and the extracted source plus build artifacts
use about 1.3 GiB on PC2. Keeping both archives brings the complete build
directory to about 1.6 GiB. Once that source is extracted at the default
location, build and install the six required modules with:

```bash
sudo ./build_mt76x2u_on_pc2.sh --jobs 8
```

The modules are installed under
`/lib/modules/$(uname -r)/updates/mt76/`; `depmod` and `modprobe mt76x2u` are
run automatically.

Show help:

```bash
sudo ./g1_pc2_usb_wifi_ap_setup.sh --help
```

Configure the USB adapter with NetworkManager:

```bash
sudo ./g1_pc2_usb_wifi_ap_setup.sh --ap-ssid "g1-pc2"
```

The script finds the Wi-Fi interface backed by USB VID:PID `0e8d:7612`, checks
that it supports AP mode, creates a NetworkManager AP profile, and installs a
boot-time restore service. Clients that join the AP can SSH to:

```bash
ssh unitree@10.42.0.1
```

Check status:

```bash
nmcli device status
nmcli connection show --active
ip route show default
```

For 5 GHz, use a legal local channel after setting the correct regulatory
domain:

```bash
sudo iw reg set US
sudo ./g1_pc2_usb_wifi_ap_setup.sh --ap-ssid "g1-pc2-5g" --band a --channel 36
```

NetworkManager 1.36 on the L4T 36.4.3 image does not expose a channel-width
setting and may create this AP at only 20 MHz. For the MT7612U teleoperation
link, use the dedicated `hostapd` setup to enforce VHT80:

```bash
sudo ./g1_pc2_usb_wifi_ap_vht80_setup.sh \
  --ssid "G1-PC2" \
  --password "change-this-password" \
  --iface wlx40a5ef5c63e8 \
  --country US \
  --channel 149
```

This makes only the named USB interface unmanaged by NetworkManager, assigns
it `10.42.0.1/24`, runs DHCP with `dnsmasq`, and NATs clients through PC2's
existing default route. The built-in Wi-Fi remains managed as the uplink.
Verify the live radio and service with:

```bash
iw dev wlx40a5ef5c63e8 info
systemctl status g1-pc2-usb-wifi-ap-vht80.service
ip route get 8.8.8.8
```

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
