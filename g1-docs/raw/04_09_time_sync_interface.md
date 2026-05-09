G1的PC1内部内置了时间同步源，每次将G1设置为WiFi模式时，该时钟源都会进行网络授时。您可以使用Chrony（推荐）或Systemd-Timesyncd来与G1的PC1进行时钟同步。

**本文档适用于固件版本大于`1.5.1`的G1机器人。**

!!! note 时钟同步带来的波动
在PC1进行网络授时同步时，可能会导致短时间的时间波动，故推荐您在使用依赖系统时间的程序时关闭G1的WiFI模式。
!!!

## 安装与配置Chrony时钟源

首先需要安装Chrony

``` 
sudo apt-get install chrony
```

修改配置文件`/etc/chrony/chrony.conf`，增加如下配置：

```
# 使用内网 NTP 服务器
server 192.168.123.161 iburst prefer

# 如果启动时网络未就绪，允许后续校时
makestep 1.0 3

# 允许硬件时钟同步
rtcsync

# 日志（调试时很有用）
log tracking measurements statistics
logdir /var/log/chrony
```

![](https://doc-cdn.unitree.com/static/2026/1/16/e9a384c97324408f800cb0931a3ba83e_765x689.png)

## 重启Chrony，验证同步状态

```
sudo systemctl restart chrony
chronyc sources -v
```

在重启Chrony这一步，概率会遇到此问题：
```
(base) supportcbh@supportcbh-MDF-XX:~$ sudo systemctl status chrony.service
● chrony.service - chrony, an NTP client/server
     Loaded: loaded (/lib/systemd/system/chrony.service; enabled; vendor preset: enabled)
     Active: failed (Result: core-dump) since Wed 2026-01-07 20:24:23 CST; 5s ago
       Docs: man:chronyd(8)
             man:chronyc(1)
             man:chrony.conf(5)
    Process: 36514 ExecStart=/usr/lib/systemd/scripts/chronyd-starter.sh $DAEMON_OPTS (code=exited, status=0/SUCCESS)
    Process: 36522 ExecStartPost=/usr/lib/chrony/chrony-helper update-daemon (code=exited, status=0/SUCCESS)
   Main PID: 36519 (code=dumped, signal=SYS)

1月 07 20:24:23 supportcbh-MDF-XX systemd[1]: Starting chrony, an NTP client/server...
1月 07 20:24:23 supportcbh-MDF-XX chronyd-starter.sh[36516]: WARNING: libcap needs an update (cap=40 should have a name).
1月 07 20:24:23 supportcbh-MDF-XX chronyd[36519]: chronyd version 3.5 starting (+CMDMON +NTP +REFCLOCK +RTC +PRIVDROP +SCFILTER +SIGND +ASYNCDNS +SECHASH +IPV6 -DEBUG)
1月 07 20:24:23 supportcbh-MDF-XX chronyd[36519]: Loaded seccomp filter
1月 07 20:24:23 supportcbh-MDF-XX systemd[1]: Started chrony, an NTP client/server.
1月 07 20:24:23 supportcbh-MDF-XX systemd[1]: chrony.service: Main process exited, code=dumped, status=31/SYS
1月 07 20:24:23 supportcbh-MDF-XX systemd[1]: chrony.service: Failed with result 'core-dump'.
```

Chrony调用了被系统安全过滤器禁止使用的指令。解决方案：禁用Seccomp 过滤。修改`/etc/default/chrony`可修正此问题。

```
DAEMON_OPTS="-F 0"
```

要验证Chrony是否与PC1的同步源已建立同步，使用此命令验证。

```
chronyc sources -V
chronyc tracking
```

![](https://doc-cdn.unitree.com/static/2026/1/16/0cfbcd0eeca647e4bd31eb9a6625b503_801x494.png)

## 安装配置Systemd-Timesyncd时钟源

!!! note Chrony和Systemd-Timesyncd的互斥关系

chrony和systemd-timesyncd互斥，安装chrony会自动卸载systemd-timesyncd。使用apt install可以重新换回Systemd-Timesync时钟源（不推荐）

```
sudo systemctl unmusk systemd-timesyncd
sudo apt install systemd-timesyncd
sudo systemctl enable --now systemd-timesyncd
```
!!!

编辑配置文件`/etc/systmd/timesyncd.conf`为以下内容：

```
[Time]
NTP=192.168.123.161
FallbackNTP=
PollIntervalMinSec=32
PollIntervalMaxSec=2048
```

![](https://doc-cdn.unitree.com/static/2026/1/16/9b50e7f8440945bea5f18c827b4fb5c0_750x417.png)

随后，启用并重启服务

```
sudo systemctl enable systemd-timesyncd
sudo systemctl restart systemd-timesyncd
```

验证同步情况

![](https://doc-cdn.unitree.com/static/2026/1/16/b12e852c0e2a44faab432aa022ffa61f_741x515.png)
