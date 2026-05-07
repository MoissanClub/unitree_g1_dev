# PC2 Setup Scripts

This folder contains helper scripts intended to be copied to the Unitree G1
`pc2` machine and run there during initial setup.

These scripts are meant to be run once, or only when you are intentionally
re-provisioning `g1-pc2`. They are not meant to be part of normal day-to-day
operation on the robot.

Currently included:

- `g1_pc2_wifi_setup.sh`: configure Wi-Fi on PC2 using NetworkManager.
- `g1_pc2_boot_time_sync_setup.sh`: install a one-shot boot-time clock sync service.
- `g1_pc2_apt_mirror_setup.sh`: switch Ubuntu APT sources on PC2 to reliable official Ubuntu mirrors.

## Typical Workflow

The intended one-time setup workflow is:

1. Connect to PC2 from your development machine.
2. Copy this folder from your development machine to PC2.
3. SSH into PC2 and run the needed setup script(s) there with `sudo`.
4. Leave the installed configuration in place; do not keep rerunning these scripts unless you are deliberately changing the setup.

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

For Wi-Fi setup, show help:

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

## Notes

- Run these scripts on `g1-pc2`, not on your development machine.
- Treat these as setup-time provisioning tools, not recurring maintenance commands.
- Use `sudo`; these scripts modify system configuration and may install boot-time services.
- The Wi-Fi script does not explicitly bring wired Ethernet down, but Wi-Fi can become the preferred default route for outbound traffic.
- By default, the Wi-Fi script refuses static addresses in `192.168.123.0/24` to avoid conflict with the Unitree Ethernet side.
- The boot-time clock sync uses public HTTP endpoints for rough time correction. It is intended to limit drift, not provide authenticated secure time.
