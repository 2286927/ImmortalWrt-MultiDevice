# ImmortalWrt 多设备云编译仓库（v3）

基于已验证的 **v2.1 架构**（缓存提速 + 值守式升级固定 URL Release + apt 容错）扩展而来，将原 CMCC RAX3000M 单设备仓库泛化为 **8 台设备 × 2 条分支（openwrt-25.12 / openwrt-24.10）= 16 条编译流水线**，统一拉取 `immortalwrt/immortalwrt` 官方源码。

## 设备清单

| 设备短名 | 显示名 | target（config 内 target 段） | 产物类型 |
|---|---|---|---|
| rax3000m | CMCC RAX3000M | mediatek/filogic（cmcc_rax3000m） | sysupgrade.itb + 全量包（initramfs-recovery 等） |
| cm520 | 星际宝盒 CM520-79F | ipq40xx/generic（mobipromo_cm520-79f） | sysupgrade.bin |
| hc5962 | 极路由 HC5962 | ramips/mt7621（hiwifi_hc5962） | sysupgrade.bin |
| newifi-d2 | Newifi D2 | ramips/mt7621（d-team_newifi-d2） | sysupgrade.bin |
| newifi-d1 | Newifi D1 | ramips/mt7621（lenovo_newifi-d1） | sysupgrade.bin |
| newifi-y1 | Newifi Y1 | ramips/mt7620（lenovo_newifi-y1） | sysupgrade.bin |
| onecloud | 玩客云 | amlogic/meson8b（thunder-onecloud） | sdcard 直刷镜像 img.gz（官方 target 直出，含 EXT4FS/4K 块大小） |
| octopus | 章鱼星球 | armsr/armv8（generic） | armsr 镜像 + ophub 打包的 s905x3 直刷 img.gz |

> 章鱼星球的 workflow 含第二个 job（`package-s905x3`）：下载编译产出的 armsr `rootfs.tar.gz`，用 `ophub/amlogic-s9xxx-openwrt@main`（BOARD=s905x3，内核 stable）打包为直刷镜像，并追加到同一 Release，固定命名 `octopus-s905x3-<分支>.img.gz`（附 sha256）。

## 目录结构

```
.github/workflows/   16 个 workflow（ImmortalWrt-<分支>-<设备短名>.yml）
config/              16 份设备 config（<设备短名>-<分支>.config）
                     + 5 份共享辅助 config（openclash/keepalived/docker/wechatpush/rust_disable，由 ENABLE_* 开关注入）
scripts/             25.12/、24.10/ 各含 diy-part1.sh、diy-part2.sh（v2.1 原样，diy-part2 的
                     autoupdate prefix 参数化为 AUTOUPDATE_PREFIX）；common/ 含 autoupdate.sh、package-sync.sh
```

插件集统一走基底 config（RAX3000M 线，含 ksmbd-avahi-service、luci-app-oaf、luci-app-3cat、cifs 全家桶等用户既定偏好），各设备 config 仅差异在 target 段 + ROOTFS 行 + 从旧仓库移植的平台绑定 kmod。

## 触发方式

- **手动触发**：Actions → 选择对应 `ImmortalWrt-<分支>-<设备>` → Run workflow。可选参数与 v2.1 相同：上传 bin/packages/所有文件、自定义源仓库地址/分支/config 文件、SSH 调试（tmate）、keepalived/docker 开关。
- **定时触发**：每周一、周四（UTC 6 点档 = 北京时间 14 点档）。16 条流水线按设备错峰 5 分钟，避免同时抢占并发额度（RAX3000M 保持 v2.1 原时刻：25.12 线 6:30、24.10 线 6:00）。
- **源码更新自动触发**：沿用 v2.1 的 `check-source-updates` 检测 job（缓存 last-checked-sha，有新提交才编译）。

## 值守式升级（固定 URL）

固件内预装 `rax-autoupdate`（`scripts/common/autoupdate.sh`，cron 每日 04:40 检查，默认不自动应用）。升级文件走 GitHub Release 固定地址，URL 模式：

```
https://github.com/<owner>/<repo>/releases/latest/download/autoupdate-<设备>-<分支>-sysupgrade.itb
```

- 设备标识取大写短名：`RAX3000M`、`CM520`、`HC5962`、`NEWIFI-D2`、`NEWIFI-D1`、`NEWIFI-Y1`、`ONECLOUD`、`OCTOPUS`
- 每次发布同时产出 `-sysupgrade.itb`（内容为该设备实际 sysupgrade 镜像）、`-sysupgrade.itb.sha256`、`-version.txt`（含 RUN_ID 构建指纹）
- 玩客云/章鱼星球产物为直刷镜像（img.gz），固定资产为 `autoupdate-<设备>-<分支>-img.gz` + sha256 + version.txt；这两类设备**不支持 sysupgrade 在线升级**，固件内自动 apply 不适用，升级请重新写盘
- 每次 Release 前自动清理同设备旧 Release（`ImmortalWrt-<分支>-<设备短名>-*` 正则），`latest/download` 始终指向最新构建

## 来源仓库映射

| 设备 | config 参考来源 | target 段依据 |
|---|---|---|
| rax3000m | v2.1 模板原 config（25.12/24.10） | 模板现成 |
| cm520 | 2286927/OneCloud_Canbox-OpenWrt_DNSfilter（CanBox_immortalwrt_DNSfilter.config，23.05） | 映射表 + 旧 config（kmod-ath10k-ct、ath10k-firmware-qca4019-ct） |
| hc5962 | 2286927/passwall-openwrt-NewifiD1_D2-HC5962-X86_64（hc5962-One.config） | 映射表 + 旧 config（kmod-mt76 系 5 项） |
| newifi-d2 | 同上仓库（newifi3.config） | 映射表 + 旧 config（kmod-mt76 系 5 项） |
| newifi-d1 | 同上仓库（newifi2.config） | 映射表（旧 config 无平台 kmod =y 行，不追加） |
| newifi-y1 | 同上仓库（newifimini.config1） | 映射表（同上） |
| onecloud | 2286927/OneCloud_immortalwrt（OneCloud25_12arm7.config） | 映射表 + 旧 config（EXT4FS/EXT4_BLOCKSIZE_4K/EXT4_JOURNAL） |
| octopus | 2286927/OpenWrt-ARMv8（OpenWrt_ARMv8.config） | 映射表（CONFIG_TARGET_armsr_armv8_DEVICE_generic=y） |

旧 config 中的 luci-app / passwall 相关行一律未迁移（插件集统一走基底），仅移植平台绑定 kmod 的 `=y` 行。

## 使用说明

1. 推送到 GitHub 后确认 Settings → Actions 权限，`GITHUB_TOKEN` 默认即可发布 Release。
2. 首次构建无缓存，耗时较长；之后 dl/ccache 缓存按「分支 + 设备」维度命中。
3. 若要改插件：优先改对应设备的 `<设备短名>-<分支>.config`；全局插件偏好改基底后需同步到 14 份派生 config（或重新生成）。
4. 玩客云/章鱼星球镜像写盘后首次启动建议接串口/看日志确认引导；ophub 镜像默认 IP 及账号见 ophub 文档。
