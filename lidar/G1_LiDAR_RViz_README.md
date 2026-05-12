# Unitree G1 EDU LiDAR RViz Setup Scripts

This folder contains two helper scripts for viewing the Unitree G1 EDU head LiDAR point cloud in RViz from PC2.

The expected LiDAR topic is:

```bash
/utlidar/cloud_livox_mid360
```

The expected point-cloud frame is:

```bash
livox_frame
```

These scripts are intended for the setup you tested:

```text
local Ubuntu desktop
    ↓ ssh -Y
Unitree G1 PC2
    ↓ ROS 2 / DDS
MID-360 LiDAR point cloud in RViz
```

## Files

```text
g1_lidar_one_time_setup_pc2.sh   # run once on PC2 to install/check/setup
g1_lidar_rviz.sh                 # run after ssh -Y whenever you want RViz
```

The one-time setup script also creates:

```text
~/.g1_lidar_env.sh
~/bin/g1_lidar_rviz.sh
```

After the first setup, you usually run the installed launcher:

```bash
~/bin/g1_lidar_rviz.sh
```

---

## 1. Copy scripts to PC2

From your local Ubuntu desktop, copy the scripts to PC2.

Example:

```bash
scp g1_lidar_one_time_setup_pc2.sh g1_lidar_rviz.sh dwei@192.168.1.201:~
```

Then SSH into PC2 with X11 forwarding:

```bash
ssh -Y dwei@192.168.1.201
```

---

## 2. Run the one-time setup script on PC2

On PC2:

```bash
cd ~
chmod +x g1_lidar_one_time_setup_pc2.sh
./g1_lidar_one_time_setup_pc2.sh
```

The setup script is safe to re-run. It tries to handle existing or partial installation state.

It checks or installs:

```text
xauth
x11-apps
RViz
tf2_ros
CycloneDDS ROS middleware
Unitree ROS 2 workspace dependencies
```

It checks:

```text
/opt/ros/foxy
~/unitree_ros2
~/unitree_ros2/cyclonedds_ws/install/setup.bash
```

It creates:

```text
~/.g1_lidar_env.sh
~/bin/g1_lidar_rviz.sh
```

---

## 3. If network-interface auto-detection is wrong

The script tries to detect the robot network interface automatically.

If the G1 Ethernet interface is known, pass it explicitly:

```bash
G1_IFACE=eth0 ./g1_lidar_one_time_setup_pc2.sh
```

or:

```bash
G1_IFACE=enp3s0 ./g1_lidar_one_time_setup_pc2.sh
```

To list interfaces:

```bash
ip -o -4 addr show
```

A useful sign is an address on the G1 subnet:

```text
192.168.123.x/24
```

---

## 4. Run RViz every time

From your local Ubuntu desktop:

```bash
ssh -Y dwei@192.168.1.201
```

Then on PC2:

```bash
~/bin/g1_lidar_rviz.sh
```

This launches RViz with a PointCloud2 display configured for:

```text
Topic: /utlidar/cloud_livox_mid360
Frame: livox_frame
Position Transformer: XYZ
Color Transformer: Intensity
Reliability: Best Effort
Durability: Volatile
Style: Points
Size: 3 px
Decay Time: 2 sec
```

---

## 5. What you should see in RViz

You should see a 3D point cloud, not a camera image.

Each dot means:

```text
The LiDAR laser hit a surface at this 3D position.
```

Typical shapes:

```text
floor       → large flat sheet of points
wall        → vertical plane of points
table/chair → point clusters and thin edges
person      → blob-like cluster
glass       → sparse, missing, or strange returns
```

With `Color Transformer: Intensity`, the color shows LiDAR return strength.

Intensity is affected by:

```text
material
distance
surface angle
surface roughness
sensor settings
reflective tape or shiny surfaces
```

Intensity does **not** mean real object color, distance, or danger.

---

## 6. About the dummy static TF

The launcher defaults to:

```bash
G1_USE_DUMMY_TF=1
```

This starts a temporary visualization-only static transform:

```text
map → livox_frame
```

This removes RViz's global warning:

```text
Fixed Frame: No tf data. Actual error: Frame [livox_frame] does not exist
```

Important:

```text
This is not SLAM.
This is not localization.
This does not create a real map.
It only helps RViz display the point cloud cleanly.
```

To disable the dummy TF:

```bash
G1_USE_DUMMY_TF=0 ~/bin/g1_lidar_rviz.sh
```

When disabled, RViz will use:

```text
Fixed Frame: livox_frame
```

You may see a global TF warning, but the PointCloud2 display can still be OK.

---

## 7. Useful overrides

### Use a different LiDAR topic

Some systems may expose the older/common topic:

```bash
G1_LIDAR_TOPIC=/utlidar/cloud ~/bin/g1_lidar_rviz.sh
```

### Use a different frame

```bash
G1_LIDAR_FRAME=utlidar_lidar ~/bin/g1_lidar_rviz.sh
```

### Use a different ROS domain

Official Unitree setups often use DDS domain 0/default. Some third-party stacks use domain 10.

```bash
G1_ROS_DOMAIN_ID=10 ~/bin/g1_lidar_rviz.sh
```

### Disable dummy TF

```bash
G1_USE_DUMMY_TF=0 ~/bin/g1_lidar_rviz.sh
```

### Use hardware OpenGL instead of software rendering

The launcher defaults to software rendering because RViz over `ssh -Y` often has OpenGL issues.

To override:

```bash
LIBGL_ALWAYS_SOFTWARE=0 ~/bin/g1_lidar_rviz.sh
```

---

## 8. Manual checks

### Check X11 forwarding

After `ssh -Y`:

```bash
echo $DISPLAY
```

Expected output is similar to:

```text
localhost:10.0
```

Test a simple GUI:

```bash
xeyes
```

If `xeyes` opens on your local desktop, X11 forwarding is working.

### Check LiDAR topic discovery

```bash
source ~/.g1_lidar_env.sh
ros2 topic list | grep -E "utlidar|livox|cloud|imu"
```

Expected:

```text
/utlidar/cloud_livox_mid360
/utlidar/imu_livox_mid360
```

### Check point-cloud type

```bash
ros2 topic type /utlidar/cloud_livox_mid360
```

Expected:

```text
sensor_msgs/msg/PointCloud2
```

### Check point-cloud frame

```bash
ros2 topic echo /utlidar/cloud_livox_mid360 | grep -m 1 frame_id
```

Expected:

```text
frame_id: livox_frame
```

### Check point-cloud fields

```bash
timeout 5 ros2 topic echo /utlidar/cloud_livox_mid360 | awk '/fields:/{flag=1} flag{print} /is_bigendian:/{exit}'
```

Expected fields include:

```text
x
y
z
intensity
ring
time
```

### Check message rate

```bash
ros2 topic hz /utlidar/cloud_livox_mid360
```

You should see messages arriving continuously.

---

## 9. Troubleshooting

### `qt.qpa.xcb: could not connect to display`

RViz is a GUI app and has no display.

Reconnect with X11 forwarding:

```bash
ssh -Y dwei@192.168.1.201
```

Then check:

```bash
echo $DISPLAY
xeyes
```

### `libGL error: failed to load driver: swrast` or `Failed to create an OpenGL context`

This happens before ROS topic display matters. RViz/Ogre cannot create an
OpenGL/GLX context through the forwarded X server.

On PC2, first make sure Mesa software rendering support is installed:

```bash
sudo apt-get update
sudo apt-get install -y libgl1-mesa-dri mesa-utils
```

Then test OpenGL from the same SSH session:

```bash
glxinfo -B
```

If you are SSHing from macOS with XQuartz, also enable indirect GLX on the Mac:

```bash
defaults write org.xquartz.X11 enable_iglx -bool true
```

Fully quit and restart XQuartz, reconnect with:

```bash
ssh -Y dwei@192.168.1.201
```

Then rerun:

```bash
~/bin/g1_lidar_rviz.sh
```

If `glxinfo -B` still fails or RViz still reports `BadValue`, use a Linux GUI
path instead of Mac XQuartz forwarding:

```text
PC2 monitor
VNC/NoMachine into PC2
Ubuntu desktop with ssh -Y
RViz on another Ubuntu machine on the same ROS 2 / DDS network
```

### `/usr/bin/xauth: file ~/.Xauthority does not exist`

This is often not fatal. Check:

```bash
echo $DISPLAY
```

If it shows `localhost:10.0` or similar, try:

```bash
xeyes
```

If needed:

```bash
touch ~/.Xauthority
chmod 600 ~/.Xauthority
```

Then reconnect with:

```bash
ssh -Y dwei@192.168.1.201
```

### RViz opens, but no points are visible

In RViz, check:

```text
PointCloud2 display enabled
Topic value is /utlidar/cloud_livox_mid360
Reliability Policy is Best Effort
Durability Policy is Volatile
Size (Pixels) is 3 or 5
Decay Time is 2 to 5 seconds
Color Transformer is Intensity or AxisColor
```

Also zoom out and rotate the view.

### PointCloud2 status is OK, but global status says no TF data

This is usually harmless for raw LiDAR viewing.

The script defaults to a dummy static TF to reduce this warning.

If you disabled the dummy TF, use:

```bash
G1_USE_DUMMY_TF=1 ~/bin/g1_lidar_rviz.sh
```

### Topic exists in terminal but not in RViz's “Add by topic”

Add manually:

```text
Add → By display type → PointCloud2
```

Then set:

```text
Topic → Value → /utlidar/cloud_livox_mid360
```

### Position Transformer or Color Transformer dropdown is empty

Try launching RViz from a clean shell, outside Conda:

```bash
conda deactivate
conda deactivate

unset QT_PLUGIN_PATH
unset QT_QPA_PLATFORM_PLUGIN_PATH

source ~/.g1_lidar_env.sh
rviz2
```

Then add a PointCloud2 display again.

### No LiDAR topics appear

Check the G1 network:

```bash
ping -c 3 192.168.123.120
ping -c 3 192.168.1.201
```

Check your CycloneDDS interface:

```bash
cat ~/.g1_lidar_env.sh | grep NetworkInterface
ip -o -4 addr show
```

If the interface is wrong, rerun setup:

```bash
G1_IFACE=<correct_interface> ./g1_lidar_one_time_setup_pc2.sh
```

---

## 10. Clean removal

To remove the generated files:

```bash
rm -f ~/.g1_lidar_env.sh
rm -f ~/bin/g1_lidar_rviz.sh
```

The script does not uninstall apt packages or delete `~/unitree_ros2`.

---

## 11. Important safety note

Viewing LiDAR in RViz does **not** mean the robot will automatically avoid obstacles.

This setup only visualizes the raw point cloud. Obstacle avoidance, SLAM, and autonomous navigation require additional software and explicit control logic.
