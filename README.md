# Unitree G1 Development Helpers

This repository contains setup and runtime helpers for the Unitree G1 PC2.

## Configure Hardware Before Running Installers

All installation scripts load [the central PC2 hardware profile](pc2/g1_pc2_hardware.env). Review and populate that file before running any setup script. Set `G1_HARDWARE_CONFIGURED=1` only after checking every value relevant to your hardware.

Use stable identifiers whenever possible:

- Network interfaces: `ip -brief addr`
- BrainCo hand ports: `ls -l /dev/serial/by-id/`
- FTDI serial: `udevadm info --query=property --name=/dev/ttyUSB0`
- Video devices: inspect `/sys/class/video4linux/video*/name`
- USB camera path and serial: `udevadm info --query=property --path=/sys/class/video4linux/video0/device`

The checked-in profile records this PC2's current wiring. Change it if cables, adapters, or cameras move. Command-line flags remain explicit temporary overrides, but the central profile is the normal source of truth.
