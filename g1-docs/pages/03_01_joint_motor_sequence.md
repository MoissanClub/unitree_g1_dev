---
name: "关节电机顺序"
path: "joint_motor_sequence"
url: "https://doc-cdn.unitree.com/11/249/zh/11_249_zh"
index_path: "03_01"
parents:
  - "底层运动开发"
parent_paths:
  - "basic_motion_development"
---
## Dex3-1 关节电机顺序

`unitree_hg::msg::dds_::HandCmd_.motor_cmd` 与 `unitree_hg::msg::dds_::HandState_.motor_state` 包含所有的灵巧手电机的信息，其电机顺序如下：

| Hand Joint Index in IDL | Hand Joint Name |  
| ----------------------- | --------------- |
| 0                       | thumb_0         | 0.76   | 108  |
| 1                       | thumb_1         | 0.76   | 108  |
| 2                       | thumb_2         | 0.76   | 108  |
| 3                       | middle_0         | 0.76   | 108  |
| 4                       | middle_1         | 0.76   | 108  |
| 5                       | index_0        | 0.76   | 108  |
| 6                       | index_1        | 0.76   | 108  |

## G1 全身关节电机顺序

`unitree_hg::msg::dds_::LowCmd_.motor_cmd` 与 `unitree_hg::msg::dds_::LowState_.motor_state` 包含 G1 全身电机（不含手）的信息，其电机顺序如下：

### 23DOF 版本 (LowCmd_.mode_machine == 1)

| Joint Index in IDL | Joint Name (LowCmd_.mode_pr or LowState_.mode_pr == 0) | Joint Name (LowCmd_.mode_pr or LowState_.mode_pr == 1) | 
| ------------------ | ------------------------------------------------------ | ------------------------------------------------------ |
| 0                  | L_LEG_HIP_PITCH                                        | L_LEG_HIP_PITCH                                        | 75 |  14.3   |
| 1                  | L_LEG_HIP_ROLL                                         | L_LEG_HIP_ROLL                                         | 120  |  22.5 |
| 2                  | L_LEG_HIP_YAW                                          | L_LEG_HIP_YAW                                          | 75  |  14.3   |
| 3                  | L_LEG_KNEE                                             | L_LEG_KNEE                                             | 120  |  22.5 |
| 4                  | **L_LEG_ANKLE_PITCH**                                  | **L_LEG_ANKLE_B**                                      | 25  |  16   |
| 5                  | **L_LEG_ANKLE_ROLL**                                   | **L_LEG_ANKLE_A**                                      | 25  |  16   |
| 6                  | R_LEG_HIP_PITCH                                        | R_LEG_HIP_PITCH                                        | 75 |  14.3   |
| 7                  | R_LEG_HIP_ROLL                                         | R_LEG_HIP_ROLL                                         | 120  |  22.5   |
| 8                  | R_LEG_HIP_YAW                                          | R_LEG_HIP_YAW                                          | 75  |   14.3  |
| 9                  | R_LEG_KNEE                                             | R_LEG_KNEE                                             | 120  |  22.5   |
| 10                 | **R_LEG_ANKLE_PITCH**                                  | **R_LEG_ANKLE_B**                                      | 25  | 16 |
| 11                 | **R_LEG_ANKLE_ROLL**                                   | **R_LEG_ANKLE_A**                                      | 25  | 16 |
| 12                 | WAIST_YAW                                              | WAIST_YAW                                              | 75  | 14.3 |
| 13                 | (empty)                                                | (empty)                                                | (empty) |(empty) |
| 14                 | (empty)                                                | (empty)                                                | (empty) |(empty)|  
| 15                 | L_SHOULDER_PITCH                                       | L_SHOULDER_PITCH                                       | 25  |  16 |
| 16                 | L_SHOULDER_ROLL                                        | L_SHOULDER_ROLL                                        | 25  | 16 |
| 17                 | L_SHOULDER_YAW                                         | L_SHOULDER_YAW                                         | 25  | 16 |
| 18                 | L_ELBOW                                                | L_ELBOW                                                | 25  | 16 |
| 19                 | L_WRIST_ROLL                                           | L_WRIST_ROLL                                           | 25  | 16 |
| 20                 | (empty)                                                | (empty)                                                | (empty)| (empty)|
| 21                 | (empty)                                                | (empty)                                                | (empty)| (empty)|
| 22                 | R_SHOULDER_PITCH                                       | R_SHOULDER_PITCH                                       | 25  | 16 |
| 23                 | R_SHOULDER_ROLL                                        | R_SHOULDER_ROLL                                        | 25  | 16 |
| 24                 | R_SHOULDER_YAW                                         | R_SHOULDER_YAW                                         | 25  | 16 |
| 25                 | R_ELBOW                                                | R_ELBOW                                                | 25  | 16 |
| 26                 | R_WRIST_ROLL                                           | R_WRIST_ROLL                                           | 25  | 16 |
| 27                 | (empty)                                                | (empty)                                                | (empty)|(empty)|
| 28                 | (empty)                                                | (empty)                                                | (empty)|(empty)|

### 29DOF 版本 (LowCmd_.mode_machine == 2)

| Joint Index in IDL | Joint Name (LowCmd_.mode_pr or LowState_.mode_pr == 0) | Joint Name (LowCmd_.mode_pr or LowState_.mode_pr == 1) | 
| ------------------ | ------------------------------------------------------ | ------------------------------------------------------ |
| 0                  | L_LEG_HIP_PITCH                                        | L_LEG_HIP_PITCH                                        | 75 |  14.3   |
| 1                  | L_LEG_HIP_ROLL                                         | L_LEG_HIP_ROLL                                         | 120  |  22.5 |
| 2                  | L_LEG_HIP_YAW                                          | L_LEG_HIP_YAW                                          | 75  |  14.3   |
| 3                  | L_LEG_KNEE                                             | L_LEG_KNEE                                             | 120  |  22.5 |
| 4                  | **L_LEG_ANKLE_PITCH**                                  | **L_LEG_ANKLE_B**                                      | 25  |  16   |
| 5                  | **L_LEG_ANKLE_ROLL**                                   | **L_LEG_ANKLE_A**                                      | 25  |  16   |
| 6                  | R_LEG_HIP_PITCH                                        | R_LEG_HIP_PITCH                                        | 75 |  14.3   |
| 7                  | R_LEG_HIP_ROLL                                         | R_LEG_HIP_ROLL                                         | 120  |  22.5   |
| 8                  | R_LEG_HIP_YAW                                          | R_LEG_HIP_YAW                                          | 75  |   14.3  |
| 9                  | R_LEG_KNEE                                             | R_LEG_KNEE                                             | 120  |  22.5   |
| 10                 | **R_LEG_ANKLE_PITCH**                                  | **R_LEG_ANKLE_B**                                      | 25  | 16 |
| 11                 | **R_LEG_ANKLE_ROLL**                                   | **R_LEG_ANKLE_A**                                      | 25  | 16 |
| 12                 | WAIST_YAW                                              | WAIST_YAW                                              | 75  | 14.3 |
| 13                 | WAIST_ROLL                                                | WAIST_A         | 25 | 16 |
| 14                 | WAIST_PITCH                                               | WAIST_B |25 | 16 |  
| 15                 | L_SHOULDER_PITCH                                       | L_SHOULDER_PITCH                                       | 25  |  16 |
| 16                 | L_SHOULDER_ROLL                                        | L_SHOULDER_ROLL                                        | 25  | 16 |
| 17                 | L_SHOULDER_YAW                                         | L_SHOULDER_YAW                                         | 25  | 16 |
| 18                 | L_ELBOW                                                | L_ELBOW                                                | 25  | 16 |
| 19                 | L_WRIST_ROLL                                           | L_WRIST_ROLL                                           | 25  | 16 |
| 20                 |L_WRIST_PITCH                                               | L_WRIST_PITCH                                               | 5| 25|
| 21                 | L_WRIST_YAW                                                | L_WRIST_YAW                                              | 5| 25|
| 22                 | R_SHOULDER_PITCH                                       | R_SHOULDER_PITCH                                       | 25  | 16 |
| 23                 | R_SHOULDER_ROLL                                        | R_SHOULDER_ROLL                                        | 25  | 16 |
| 24                 | R_SHOULDER_YAW                                         | R_SHOULDER_YAW                                         | 25  | 16 |
| 25                 | R_ELBOW                                                | R_ELBOW                                                | 25  | 16 |
| 26                 | R_WRIST_ROLL                                           | R_WRIST_ROLL                                           | 25  | 16 |
| 27                 |R_WRIST_PITCH                                               |              R_WRIST_PITCH                                    |5|25|
| 28                 | R_WRIST_YAW                                              |R_WRIST_YAW                                              | 5|25|
### 14DOF 双臂版本 (LowCmd_.mode_machine == 9)

| Joint Index in IDL | Joint Name       | 
| ------------------ | ---------------- |
| 0                  | (empty)          |
| 1                  | (empty)          |
| 2                  | (empty)          |
| 3                  | (empty)          |
| 4                  | (empty)          |
| 5                  | (empty)          |
| 6                  | (empty)          |
| 7                  | (empty)          |
| 8                  | (empty)          |
| 9                  | (empty)          |
| 10                 | (empty)          |
| 11                 | (empty)          |
| 12                 | (empty)          |
| 13                 | (empty)          |
| 14                 | (empty)          |
| 15                 | L_SHOULDER_PITCH |
| 16                 | L_SHOULDER_ROLL  |
| 17                 | L_SHOULDER_YAW   |
| 18                 | L_ELBOW          |
| 19                 | L_WRIST_ROLL     |
| 20                 | L_WRIST_PITCH    |
| 21                 | L_WRIST_YAW      |
| 22                 | R_SHOULDER_PITCH |
| 23                 | R_SHOULDER_ROLL  |
| 24                 | R_SHOULDER_YAW   |
| 25                 | R_ELBOW          |
| 26                 | R_WRIST_ROLL     |
| 27                 | R_WRIST_PITCH    |
| 28                 | R_WRIST_YAW      |
