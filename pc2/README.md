# PC2 Setup Scripts

This folder contains helper scripts intended to be copied to the Unitree G1 PC2 machine and run there.

Currently included:

- `g1_pc2_wifi_setup.sh`: configure Wi-Fi on PC2 using NetworkManager.

## Typical Workflow

The intended workflow is:

1. Connect to PC2 from your development machine.
2. Copy this folder from your development machine to PC2.
3. SSH into PC2 and run the script there with `sudo`.

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

## 3. Run The Script On PC2

SSH into PC2:

```bash
ssh unitree@192.168.123.164
```

Change into the copied folder:

```bash
cd /home/unitree/pc2
```

Show help:

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

## Notes

- Run the script on PC2, not on your development machine.
- Use `sudo`; the script modifies NetworkManager and may install a boot-time service.
- The script does not explicitly bring wired Ethernet down, but Wi-Fi can become the preferred default route for outbound traffic.
- By default, the script refuses Wi-Fi static addresses in `192.168.123.0/24` to avoid conflict with the Unitree Ethernet side.
