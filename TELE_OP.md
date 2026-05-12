# Tele Op using xr_teleoperate
- Everything runs on PC2
- PC2 and VR headset connect to same wifi network

Achieved:
- human can see G1's camera feed in Quest
- G1's arms follow VR controller movement.

Next:
- Control G1 locomotion via controller joystick
- Change G1 Hand/Finger via controller buttons

## Setup
### Install conda and create env
```bash
curl https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh -o miniconda.sh
# -b batch mode (without manual intervention)
# -c run 'conda init' after install
bash miniconda.sh -b -c
# -n tv is env name
# -c conda-forge using community channel for packages
# nlopt=2.7.1 needed by dex_retargeting
conda create -n tv -y pip python=3.10 pinocchio=3.1.0 numpy=1.26.4 nlopt=2.7.1 -c conda-forge
```
Note: All `pip` commands must have tv env active. (tv) at the beginning of terminal prompt.
### Unitree sdk2 and sdk2_python
```bash
git clone --depth 1 https://github.com/unitreerobotics/unitree_sdk2
cd unitree_sdk2
mkdir build && cd build
cmake .. -DBUILD_EXAMPLES=OFF #not build example code
sudo make install -j6
cd $HOME
git clone --depth 1  https://github.com/unitreerobotics/unitree_sdk2_python.git
# CYCLONEDDS_HOME must set for sdk2_python
export CYCLONEDDS_HOME=/home/unitree/cyclonedds_ws/install/cyclonedds
conda activate tv
pip install -e unitree_sdk2_python
```
### Clone repos and pip install
```bash
# all pip commands must be run with tv conda env
conda activate tv
# main xr_teleoperate repo 
git clone –-depth 1 https://github.com/unitreerobotics/xr_teleoperate.git
cd xr_teleoperate
pip install -r requirements.txt
# shallow clone submodules televuer, teleimager and dex-retargeting
git submodule update --init --depth 1
# register local py pkgs
pip install -e teleop/televuer
pip install -e 'teleop/teleimager[server]' # single quote avoid shell expansion
pip install -e teleop/robot_control/dex-retargeting
# vuer has many dependencies and requires params-proto 2.x
pip install 'params-proto<3' 'vuer[all]==0.0.60'
```
### BrainCo hand
```bash
sudo apt install libspdlog-dev libfmt-dev
git clone –-depth 1 https://github.com/unitreerobotics/brainco_hand_service
cd brainco_hand_service
mkdir build && cd build
cmake ..
make -j6
```

## Prepare and start servers
### There are 3 Servers:
- brainco_hand_server: handles both hands serial <-> DDS so unitree code can pub/sub DDS, more like a daemon, not serving network traffic
- teleimager: serve USB camera feed over network, needs ssl cert
- xr_teleoperate: serve Vuer webXR page, needs ssl cert

### brainco_hand_server
```bash
cd brainco_hand_service/bin
# eth0 is PC2's interface for DDS
sudo ./brainco_hand_server -n eth0
```
### SSL Cert
```bash
# generate ssl cert as webRTC and webXR require https
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout key.pem -out cert.pem
mkdir -p ~/.config/xr_teleoperate/
cp cert.pem key.pem ~/.config/xr_teleoperate/
```

### teleimager
- allow non-root user to access usb camera. Script creates video group and add current user(unitree) to it. OK to ignore modprobe error.
```bash
cd ~/xr_teleoperate/teleop/teleimager
bash setup_uvc.sh
```
logout and login again for group to take effect.

- First list available cameras, record the video id of G1's RealSense Camera. mine is 2.
```bash
cd ~/xr_teleoperate/teleop/teleimager
conda activate tv
teleimager-server --cf
```
- update cam_config_server.yaml, in head_camera section, set
```yaml
type: opencv
image_shape: [480, 640]
binocular: false
video_id: 2
serial_number: null
physical_path: null
```
the 640x480 limit is due to opencv generic driver can't handle full resolution, requires pyrealsense2 but I haven't got time to investigate further. 
- update cam_config_server.yaml, disable wrist cameras:
```yaml
left_wrist_camera:
  enable_zmq: false
  enable_webrtc: false
right_wrist_camera:
  enable_zmq: false
  enable_webrtc: false
```

- ensure tv env is active, run `teleimager-server`, now you can check video is available by open https://PC2-WiFi-IP:60001 on any browser

- OK to ignore `ERROR    Failed to reload driver: Command 'sudo modprobe -r uvcvideo' returned non-zero exit status 1. ` as /unitree/module/video_hub_pc4/videohub_pc4 holds /dev/video4 so uvcvideo mod can't be reloaded

### run xr_teleoperate
- Change G1_23 to G1_29 if your G1 has 29DoF, ego mode means G1 view is small overlay in the VR view
```bash
cd ~/xr_teleoperate/teleop
conda activate tv
python teleop_hand_and_arm.py --input-mode controller --arm G1_23 --ee brainco --network-interface eth0 --img-server-ip PC2-WiFi-IP --display-mode ego
```
- press `r` to start tracking mode

### VR Headset
- open Browser `https://PC2-WiFi-IP:8012/?ws=wss://PC2-WiFi-IP:8012`
- click PassThrough at bottom of page
- You should see both the surroundings and G1's camera view in the middle, and G1 arms will follow controller moves

## Fix realsense camera 
### unitree vendor service holding camera
PC2 /etc/init.d/ has master_service and ota_pipe. Both can be stopped/disabled via systemctl. But stop ota_pipe may cause Unitree Explore App report firmware command timeout. So not necessary.
```
sudo systemctl stop master_service ota_pipe
sudo systemctl disable master_service ota_pipe
```

master_service manages /unitree/etc/master_service/service/video_hub_pc4 and video_hub_pc4_chest. Stop and remove via mscli
```
sudo /unitree/sbin/mscli stopservice video_hub_pc4
sudo /unitree/sbin/mscli stopservice video_hub_pc4_chest
sudo /unitree/sbin/mscli removeservice video_hub_pc4
sudo /unitree/sbin/mscli removeservice video_hub_pc4_chest
```

There is also ota_pipe under service/, it's just proxy to systemctl.

video_hub_pc4 is responsible for publishing camera DDS rt/frontvideostream

### update cam_config_server and run
new config
```yaml
type: realsense
image_shape: [720, 1280]
binocular: false
video_id: null
serial_number: xxxxxxx
physical_path: null
```
- serial_number is from `teleimager-server --cf --rs` note without `--rs` flag, it'll show a different serial number
- (tv) `pip install pyrealsense2` and `teleimager-server --rs`

## hand and motion
controller can add `--motion` so Unitree remote and VR controller joystick can move robot. But if input mode is hand, no way to control motion.
```
python teleop_hand_and_arm.py --arm G1_23 --ee brainco --network-interface eth0 --img-server-ip PC2-WiFi-IP --display-mode ego
```