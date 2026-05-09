---
name: "强脑灵巧手"
path: "brainco_hand"
url: "https://doc-cdn.unitree.com/11/815/zh/11_815_zh"
index_path: "03_06"
parents:
  - "底层运动开发"
parent_paths:
  - "basic_motion_development"
---
# 强脑灵巧手

G1 可搭载强脑科技的[二代灵巧手](../assets/parameters_cc3fb2caaa15.html)，该灵巧手具有6个自由度。

该灵巧手通过串口通信控制，官方提供了C和Python的[SDK](../assets/get_sdk_922620f6d2ee.html)。

在本仓库中，我们将串口消息转换为DDS消息，以便在unitree_sdk2中使用。

- 左右手各由一个USB转串口设备控制，各生成一对`rt/brainco/(left or right)/(cmd or state)`话题。
- 强脑灵巧手的手指位置和速度被归一化到[0, 1]范围。
- 建议将所有手指的速度设置为1.0。
- 各手指索引分别为[Thumb, Thumb_aux, Index, Middle, Ring, Pinky]。

## 环境设置

在deploy中提供了x86_64平台的二进制文件，可以直接运行。

```bash
sudo apt install libspdlog-dev libfmt-dev
# 你可能需要手动下载最新版本的 `stark-serialport-example`。
# git clone https://github.com/BrainCoTech/stark-serialport-example
cd thirdparty/stark-serialport-example
./download-lib.sh

cd path/to/brainco_hand_service
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make
```

## 测试

```bash
# Terminal 1. Run brainco hand service
sudo ./brainco_hand --id 126 --serial /dev/ttyUSB0 # 126: left hand, 127: right hand
# Terminal 2. Run example
./example_brainco_hand left # or right
```

## 程序下载
```bash
git clone --recursive https://github.com/unitreerobotics/brainco_hand_service
```
