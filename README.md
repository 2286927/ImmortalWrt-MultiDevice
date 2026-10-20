# ImmortalWrt-MultiDevice

基于 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 的多设备固件云编译仓库，通过 GitHub Actions 自动编译，共 **10 款设备，21 条编译线**（9 款 × 24.10/25.12 双版本 + Newifi Y1 21.02/23.05 专用线 + Globitel BT-R320 25.12 专用线），产物自动发布到 Releases。

## 支持设备

| 设备 | 平台 | 版本线 | 说明 |
|---|---|---|---|
| CM520-79F | Qualcomm IPQ40xx | 24.10 / 25.12 | |
| Globitel BT-R320 | MediaTek MT7981（Filogic 820） | 25.12 | eMMC，2.5G 网口 |
| 极路由 HC5962 | MediaTek MT7621 | 24.10 / 25.12 | |
| 联想 Newifi D1 | MediaTek MT7621 | 24.10 / 25.12 | |
| 联想 Newifi D2 | MediaTek MT7621 | 24.10 / 25.12 | |
| 联想 Newifi Y1 | MediaTek MT7620 | 21.02 / 23.05 / 24.10 / 25.12 | 小内存设备；21.02 线含 USB 打印/扫描双模式 |
| OCTOPUS | AMLogic S912（ARMv8） | 24.10 / 25.12 | 单网口定制 |
| 玩客云 OneCloud | AMLogic S805 | 24.10 / 25.12 | 单网口客户端模式，eMMC |
| R68S | Rockchip RK3568 | 24.10 / 25.12 | 双千兆 |
| CMCC RAX3000M | MediaTek MT7986（Filogic 830） | 24.10 / 25.12 | eMMC 版 |

## 主要功能

以下功能按设备线配置取舍，具体以 `config/` 下对应配置文件为准：

**全线内置（21 条线）**
- LuCI Web 管理后台（uhttpd + ucode 分发）
- fw4 防火墙（nftables）、ZeroTier、socat
- CPU 调频（luci-app-cpufreq）

**多数线内置**
- fullcone NAT、UPnP、ttyd 网页终端、KMS（vlmcsd）——除 Y1 21.02 / 23.05 线
- AdGuard Home、DDNS-Go——除 Y1 各线
- OpenClash——24.10 全线 + 25.12 的 HC5962 / D1 / D2 / OCTOPUS / R68S / RAX3000M（Y1 各线及 25.12 的 CM520、BT-R320 未含）
- TurboACC 网络加速——24.10 各线、玩客云 25.12
- Docker 容器（dockerman，编译时可选开关）——R68S、玩客云 25.12

**部分线内置**
- WOL 网络唤醒（luci-app-wol）：BT-R320 线；中继桥 relayd：BT-R320、Newifi D1（25.12）线
- 应用过滤（OAF）：RAX3000M、OCTOPUS 线
- USB 打印服务（p910nd）：Y1 21.02 / 23.05 线，21.02 线另含打印/扫描双模式切换
- 文件共享 ksmbd（Samba 协议）：除 Y1 21.02 外各线；samba4 完整版：BT-R320、RAX3000M（25.12）线
- 下载工具 Aria2、迅雷远程下载：玩客云 25.12 线

> 25.12 线基于 ImmortalWrt 25.12 分支，软件包管理为 APK（不再使用 opkg）。

## 使用方法

1. **编译**：Fork 本仓库后，在 Actions 中选择对应设备的 workflow 手动触发（workflow_dispatch）；各线也已内置每周定时编译（cron）。
2. **下载**：编译完成后到 Releases 下载对应资产：
   - `*-squashfs-*.bin` / `*-sysupgrade.bin`：标准刷机/升级包
   - `*-rootfs.tar.gz`：根文件系统包
   - `*.burn.img.xz`（玩客云）：USB 双公头直刷包
   - `onecloud-boot.tar.gz`（玩客云 25.12）：boot 分区内容，供在线升级脚本使用
   - `*-sysupgrade.itb`（BT-R320）：FIT 格式刷机/升级包；`globitel_bt-r320-recovery.itb` 为救援镜像
   - `globitel_bt-r320-gpt.bin` / `globitel_bt-r320-bl31-uboot.fip` / `globitel_bt-r320-preloader.bin`（BT-R320）：底层引导文件，仅首刷与救援使用
   - `config.txt`：该次编译的完整配置快照
3. **刷机**：标准设备在 Breed/原厂引导或系统内 sysupgrade 刷入；玩客云需使用直刷包配合双 USB 公头线刷；BT-R320 首刷流程特殊——先在原厂系统内写入 GPT 分区表与 OpenWrt U-Boot，再经 U-Boot 恢复模式从 PC（静态 `192.168.1.254`，跑 TFTP 服务器如 Tftpd64）自动拉取救援镜像进入临时系统，刷入正式固件（详见包内教程第六节）。

## 使用注意

### 默认地址与密码

| 设备 | 默认 LAN IP | 默认密码 |
|---|---|---|
| 多数设备 | 172.16.7.1 | 空（首次登录设置） |
| R68S | 172.16.1.1 | 空（首次登录设置） |
| Globitel BT-R320 | 172.16.0.1 | 空（首次登录设置） |
| 玩客云 OneCloud | DHCP 动态获取 | 空（首次登录设置） |

> 玩客云为单网口客户端模式，LAN 地址从上级路由 DHCP 列表查看（Bypass 管理别名 192.168.1.2）。

**首次登录后请立即设置并修改密码**，并注意暴露公网的安全风险（如 IPv6 直达、DDNS 场景建议收紧入站规则）。

### 玩客云 OneCloud 专用说明

- 单网口为 WAN，客户端模式：从上级路由 DHCP 获取地址，Bypass 管理别名 192.168.1.2
- 25.12 线 rootfs 固定 896M，不再首启自动扩容到整卡，剩余空间可自行分区利用；
  在线升级已实测兼容（rootfs 解包约 388M，896M 分区余量充足），升级脚本内置容量预检防线（v7+）
- 直刷包的 boot 与 rootfs 为同一次构建配套生成，请勿混用不同批次资产的 boot/rootfs
#### 在线升级（25.12 线，不拆机）

适用：正在运行本仓库 **25.12 玩客云固件**的设备（eMMC，`/dev/root=/dev/mmcblk1p2`）；支持跨内核小版本升级（如 6.12.71 → 6.12.108，脚本同步更新 boot + rootfs，全程不拆机不接电脑）。请使用 **2026-09-19 及以后**（版本号 ≥ `26.09.19_20.48.19`）的 Release，更早批次的固件存在已修复的 LuCI 配置问题。

SSH 登录 root 后两步执行：

```sh
# 第一步：预检（只读不改机，全部 PASS 才继续）
wget -qO /tmp/oc-upgrade.sh https://raw.githubusercontent.com/2286927/ImmortalWrt-MultiDevice/main/onecloud-online-upgrade.sh
sh /tmp/oc-upgrade.sh --check

# 第二步：正式升级（写入完成约 10 秒后自动重启）
sh /tmp/oc-upgrade.sh --reboot
```

脚本自动从 **Releases 最新版**下载以下 2 个资产（在最近 30 条 Release 内取最新一个同时含这两件的版本，两包同源同批次配套）：

| 脚本下载的资产 | 用途 |
|---|---|
| `immortalwrt-amlogic-meson8b-thunder-onecloud-rootfs.tar.gz` | 新 rootfs（含内核与模块），覆盖 p2；保留 /etc/config、rc.local、密码、密钥、证书、/opt、/root |
| `onecloud-boot.tar.gz` | boot 分区内容（boot.scr / dtb / uImage），写入 p1；脚本校验包内 uImage 内核版本与新 rootfs kmod 一致，不配套则拒绝升级 |

注意：
- `--check` 出现任何 FAIL 均不要执行第二步，请到 Issues 反馈
- 升级后 LuCI 地址从上级路由 DHCP 列表查看（Bypass 管理别名 192.168.1.2）
- 线刷用户请整包刷同批次 `*.burn.img.xz`，勿混用不同批次的 boot / rootfs 资产

### Newifi Y1（21.02 线）USB 打印/扫描模式切换

21.02 固件内置 **打印共享 + 按需扫描** 双模式机制（适配 M7605D 等多功能打印机）：

- **打印模式（默认）**：p910nd 在 `9100` 端口全共享，局域网内任意电脑走 TCP/IP 9100 直接打印
- **扫描模式**：SSH 执行 `scan-mode`，打印机通过 USB/IP 导出，谁要扫描谁 `usbip.exe attach`，扫完 `detach` 后执行 `print-mode` 恢复打印

**路由器端（SSH root）：**

```sh
scan-mode    # 切到扫描模式（停 p910nd → usbipd → 自动绑定 M7605D）
print-mode   # 切回打印共享模式（解除导出 → 恢复 9100）
```

（旧名 `y1-scan-mode` / `y1-print-mode` 仍保留可用，与新短命令等价）

**Windows 端：**

1. 所有电脑添加打印机：`添加打印机 → 手动 → TCP/IP 端口`，IP 填路由器地址、端口 `9100`，驱动选 M7605D —— 可同时打印
2. 需要扫描的电脑（管理员 CMD，配合路由器 `scan-mode`）：

```cmd
usbip.exe list -r <路由器IP>            :: 应看到 M7605D (17ef:561c)
usbip.exe attach -r <路由器IP> -b 1-1   :: 连接（busid 以 list 输出为准）
:: 扫描完成后：
usbip.exe detach -p 1
```

注意事项：

- 两种模式**互斥**：同一时刻打印机只能被一种机制占用（p910nd 需设备挂 usblp，usbip 需挂 usbip-host）
- USB/IP 为**单客户端独占**：扫描时多台电脑需轮流 attach/detach
- 切回打印前必须先让 Windows `usbip.exe detach`，再执行 `print-mode`
- 开机默认打印模式，不 bind 导出；M7605D 未插时 `scan-mode` 会提示找不到设备

### 值守式升级（autoupdate，除玩客云外 19 条线内置）

各线固件内置 `autoupdate` 值守升级：每天 **04:40 自动检查** Releases 新版本并提示（/etc/crontabs/root 已写入），支持手动立即检查与一键应用。各线资产名前缀不同（如 Y1 21.02 为 `autoupdate-NEWIFI-Y1-21.02`，BT-R320 25.12 为 `autoupdate-BT-R320-25.12`），命令一致。

**SSH root 常用命令：**

```sh
autoupdate status      # 查看当前版本、上次检查与 pending 状态
autoupdate check now   # 立即检查更新（发现新版本写入 /tmp/autoupdate.pending）
autoupdate apply       # 应用已检测到的新版本（sysupgrade 保留配置，自动重启）
autoupdate enable      # 开启每日自动检查（默认开启）
autoupdate disable     # 关闭每日自动检查
```

**配置 `/etc/config/autoupdate`：**

| 选项 | 默认值 | 说明 |
|---|---|---|
| `enabled` | `1` | 值守总开关 |
| `base_url` | 本仓库 Releases/latest/download | 固件下载基址 |
| `prefix` | `autoupdate-NEWIFI-Y1-21.02` | 资产名前缀（各线不同，匹配各自 sysupgrade 包） |
| `auto_apply` | `0` | `1` 时检测到新版自动升级，`0` 仅提示待手动 apply |
| `notify_url` | 空 | 升级通知回调 URL（可留空） |
| `mirror` | `auto` | 多镜像自动降级（加速/防 GitHub 抽风） |

升级采用 `sysupgrade` 保留配置，`check now` 后看到 pending 即可 `apply`，全程不拆机。

### 升级与其他

- 同大版本升级可用 sysupgrade 并保留配置；跨大版本（24.10 ↔ 25.12）建议不保留配置重新设置
- 小内存设备（如 Newifi Y1）开 Docker 或 OpenClash 等重负载前请评估内存余量
- 刷机有变砖风险，请先备份原厂固件，并确认固件与设备型号完全对应

---

## 📦 Globitel BT-R320 刷机资源包（离线自包含）

BT-R320 专用离线刷机包：教程 + 全部刷机文件打包，无需到 Release 页逐个下载。
**[下载 Globitel-BT-R320-flash-package.zip](Globitel-BT-R320-flash-package.zip)**（约 84 MB，含 Tftpd64 工具与 SSH 密钥三件套）

包内清单（解压后顶层目录 `Globitel-BT-R320-flash-package/`）：

| 文件 | 说明 |
|---|---|
| `BT-R320刷机教程.md` | 全流程教程：SSH 密钥配置 → 原厂备份 → 写入 GPT/U-Boot → U-Boot 恢复模式 TFTP 拉取 → LuCI 落盘 → 进入系统 → 救砖恢复 |
| `globitel-bt-r320_r214e26e407_202610171321_sysupgrade.itb` | 正式系统镜像（首刷落盘 + 后续升级） |
| `globitel-bt-r320_r214e26e407_202610171321_initramfs-recovery.itb` | 救援镜像（U-Boot 恢复模式从 PC 自动拉取；**保持原始完整文件名**） |
| `immortalwrt-mediatek-filogic-globitel_bt-r320-gpt.bin` | GPT 分区表（首刷第 2 步写入） |
| `immortalwrt-mediatek-filogic-globitel_bt-r320-bl31-uboot.fip` | OpenWrt U-Boot（首刷第 2 步写入，含 TFTP 恢复模式） |
| `immortalwrt-mediatek-filogic-globitel_bt-r320-preloader.bin` | 底层 preloader（仅底层救援用，勿随意刷写） |
| `sha256sums` | 文件校验清单 |
| `tools/Tftpd64.zip` | TFTP 服务器工具（恢复模式必备，免费绿色软件解压即用） |
| `ssh-keys/`（3 个文件） | SSH 免密登录密钥三件套：`id_rsa_3072-router.pub` 公钥追加到路由器 `/etc/dropbear/authorized_keys`，`id_rsa_3072-WinSCP.ppk` 导入 WinSCP、`id_rsa_3072-Xshell` 导入 Xshell |

- 文件版本对应固定发布页 [globitel-bt-r320-ImmortalWrt-25.12](https://github.com/2286927/ImmortalWrt-MultiDevice/releases/tag/globitel-bt-r320-ImmortalWrt-25.12)（每次编译覆盖更新此页，具体版本看页面标题），与 Release 页单文件下载内容一致（已按对应构建名校验 SHA256）
- 解压后打开教程按步骤操作即可；恢复模式为 U-Boot 从 PC（静态 192.168.1.254 + Tftpd64）**自动拉取**救援镜像，文件名不可改动

**原厂全分区备份（救砖恢复原厂用）**：[Globitel-BT-R320-stock-backup.zip](https://github.com/2286927/ImmortalWrt-MultiDevice/releases/download/BT-R320-stock-backup/Globitel-BT-R320-stock-backup.zip)（约 458 MB，含 GPT/bl2/fip/factory/kernel/rootfs/userdata 七分区与 sha256 清单；存于独立 Release `BT-R320-stock-backup`，**永久保留、不参与编译覆盖**）
- 后续新版本以 Release 页为准，本包为当前版本快照
