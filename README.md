# ImmortalWrt-MultiDevice

基于 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 的多设备固件云编译仓库，通过 GitHub Actions 自动编译，共 **9 款设备 × 2 个版本（24.10 / 25.12）= 18 条编译线**，产物自动发布到 Releases。

## 支持设备

| 设备 | 平台 | 版本线 | 说明 |
|---|---|---|---|
| CM520-79F | Qualcomm IPQ40xx | 24.10 / 25.12 | |
| 极路由 HC5962 | MediaTek MT7621 | 24.10 / 25.12 | |
| 联想 Newifi D1 | MediaTek MT7621 | 24.10 / 25.12 | |
| 联想 Newifi D2 | MediaTek MT7621 | 24.10 / 25.12 | |
| 联想 Newifi Y1 | MediaTek MT7620 | 24.10 / 25.12 | 小内存设备 |
| OCTOPUS | AMLogic S912（ARMv8） | 24.10 / 25.12 | 单网口定制 |
| 玩客云 OneCloud | AMLogic S805 | 24.10 / 25.12 | 单网口客户端模式，eMMC |
| R68S | Rockchip RK3328 | 24.10 / 25.12 | 双千兆 |
| CMCC RAX3000M | MediaTek MT7986（Filogic 830） | 24.10 / 25.12 | NAND 版 |

## 主要功能

以下功能按设备线配置取舍，具体以 `config/` 下对应配置文件为准：

**网络与加速**
- LuCI Web 管理后台（25.12 玩客云线为 nginx 后端，其余为 uhttpd）
- fw4 防火墙（nftables）、fullcone NAT、TurboACC 网络加速、UPnP
- OpenClash（多数线内置；小内存设备线未含）

**服务与应用**
- Docker 容器（dockerman）——内存充裕的设备线
- AdGuard Home、DDNS-Go、ZeroTier、socat
- 应用过滤（OAF）：RAX3000M、OCTOPUS 线

**存储与下载**
- 文件共享：Samba（ksmbd / samba4）、NFS、WebDAV、FTP、CIFS 挂载
- 下载：Aria2、迅雷远程下载
- 磁盘管理、硬盘休眠、USB 打印服务

**系统工具**
- ttyd 网页终端、CPU 调频、内存回收、KMS（vlmcsd）

> 25.12 线基于 ImmortalWrt 25.12 分支，软件包管理为 APK（不再使用 opkg）。

## 使用方法

1. **编译**：Fork 本仓库后，在 Actions 中选择对应设备的 workflow 手动触发（workflow_dispatch）；各线也已内置每周定时编译（cron）。
2. **下载**：编译完成后到 Releases 下载对应资产：
   - `*-squashfs-*.bin` / `*-sysupgrade.bin`：标准刷机/升级包
   - `*-rootfs.tar.gz`：根文件系统包
   - `*.burn.img.xz`（玩客云）：USB 双公头直刷包，附 `.sha` 校验文件
   - `onecloud-boot.tar.gz`（玩客云 25.12）：boot 分区内容，供在线升级脚本使用
   - `config.txt`：该次编译的完整配置快照
3. **刷机**：标准设备在 Breed/原厂引导或系统内 sysupgrade 刷入；玩客云需使用直刷包配合双 USB 公头线刷。

## 使用注意

### 默认地址与密码

| 设备 | 默认 LAN IP | 默认密码 |
|---|---|---|
| 多数设备 | 172.16.7.1 | password |
| R68S | 172.16.1.1 | password |
| 玩客云 OneCloud | 172.16.8.1 | password |

**首次登录后请立即修改密码**，并注意暴露公网的安全风险（如 IPv6 直达、DDNS 场景建议收紧入站规则）。

### 玩客云 OneCloud 专用说明

- 单网口为 WAN，客户端模式：从上级路由 DHCP 获取地址，Bypass 管理别名 192.168.1.2
- 25.12 线 rootfs 固定 896M，不再首启自动扩容到整卡，剩余空间可自行分区利用
- 直刷包的 boot 与 rootfs 为同一次构建配套生成，请勿混用不同批次资产的 boot/rootfs
- 在线升级（不拆机）：使用仓库根目录 `onecloud-online-upgrade.sh`，脚本会自动校验包完整性与 boot/rootfs 内核配套性并备份原配置；仅适用于 25.12 线固件之间的升级

### 升级与其他

- 同大版本升级可用 sysupgrade 并保留配置；跨大版本（24.10 ↔ 25.12）建议不保留配置重新设置
- 小内存设备（如 Newifi Y1）开 Docker 或 OpenClash 等重负载前请评估内存余量
- 刷机有变砖风险，请先备份原厂固件，并确认固件与设备型号完全对应
