# ImmortalWrt 多设备云编译仓库（v3）

基于已验证的 **v2.1 架构**（缓存提速 + 值守式升级固定 URL Release + apt 容错）扩展而来，将原 CMCC RAX3000M 单设备仓库泛化为 **9 台设备 × 2 条分支（openwrt-25.12 / openwrt-24.10）= 18 条编译流水线**，统一拉取 `immortalwrt/immortalwrt` 官方源码。

## 设备清单

| 设备短名 | 显示名 | target（config 内 target 段） | 产物类型 |
|---|---|---|---|
| rax3000m | CMCC RAX3000M | mediatek/filogic（cmcc_rax3000m） | sysupgrade.itb + 全量包（initramfs-recovery 等） |
| r68s | 电犀牛 R68S | rockchip/armv8（lunzn_fastrhino-r68s） | squashfs-sysupgrade.img.gz + rootfs.tar.gz（2.5G 双网卡，kmod-r8125；LAN `172.16.1.1`） |
| cm520 | 星际宝盒 CM520-79F | ipq40xx/generic（mobipromo_cm520-79f） | sysupgrade.bin |
| hc5962 | 极路由 HC5962 | ramips/mt7621（hiwifi_hc5962） | sysupgrade.bin |
| newifi-d2 | Newifi D2 | ramips/mt7621（d-team_newifi-d2） | sysupgrade.bin |
| newifi-d1 | Newifi D1 | ramips/mt7621（lenovo_newifi-d1） | sysupgrade.bin |
| newifi-y1 | Newifi Y1 | ramips/mt7620（lenovo_newifi-y1） | sysupgrade.bin |
| onecloud | 玩客云 | amlogic/meson8b（lede master 注入 target 树） | AmlImg 线刷直刷包 burn.img.xz（单网口定制版） |
| octopus | 章鱼星球 | armsr/armv8（generic） | armsr rootfs.tar.gz → flippy 打包 `octopus-s912-<分支>.img.gz` 双内核直刷包（单网口定制版） |

> - **玩客云**：官方 ImmortalWrt 无 amlogic target，workflow 从 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) master 注入 `target/linux/amlogic` 树（两线同源：24.10 = lede 6.6 testing 补丁集，`KERNEL_PATCHVER` 6.18→6.6 对齐 24.10 generic；25.12 = 同树 6.6 补丁集改名 6.12，Kwrt 验证方案），config 取配方 [2286927/OneCloud_immortalwrt](https://github.com/2286927/OneCloud_immortalwrt) 的 `recipe/Config/quicker-amlogic.config`，`RECIPE_REF` 固定 commit 保证可复现；产物由 convert3.sh 制作 AmlImg 线刷包（含 uboot，双 USB 公头线刷）。
> - **章鱼星球**：armsr 编译产出 `rootfs.tar.gz` 后由 `package-s912` job 用 flippy 打包为直刷镜像（flippy 双内核 k6.6/k6.12），固定命名 `octopus-s912-<分支>.img.gz`（附 sha256）；SD 启动后执行内置 `openwrt-install-amlogic` 安装到 EMMC。

## 单网口设备定制（octopus / onecloud）

两类单网口设备统一执行 **wan-only 网络布局 + 单 lan 域防火墙**（编译期 files 覆盖注入，非运行时脚本）：

- `/etc/config/network`：删除 lan 接口，仅保留 `wan`（eth0，DHCP）与 `wan6`（`@wan`，DHCPv6）
- `/etc/config/firewall`：defaults 全 ACCEPT，仅一个 `lan` 域（network 含 wan/wan6），设备作为旁路由/单臂网关使用
- 防火墙精简：移除 fw3(firewall) 全家、legacy iptables 用户态及 mod-\* 扩展、kmod-ipt legacy 系（extra/iprange/ipsec/physdev/socket/tproxy 等）、kmod-ipt-ipset、miniupnpd iptables 变体（固化 nftables 变体），固件内仅保留 fw4 一套 nft 原生体系
- 无法移除的锁定依赖（如需更深精简需牺牲对应功能）：`kmod-nft-offload`/`kmod-ipt-offload`/`kmod-ipt-nat(nat6)` ← luci-app-turboacc；`kmod-nft-compat` ← iptables-nft；`odhcpd-ipv6only` ← dnsmasq-full(dhcpv6)；`firewall4`/`ppp` ← luci-light 依赖链
- workflow 内置精简守卫断言：defconfig 后若 fw3 或 kmod-ipt-ipset 被依赖链拉回，直接 fail-fast 并报出包名

## 目录结构

```
.github/workflows/   18 个 workflow（ImmortalWrt-<分支>-<设备短名>.yml）
config/              18 份设备 config（<设备短名>-<分支>.config）
                     + 5 份共享辅助 config（openclash/keepalived/docker/wechatpush/rust_disable，由 ENABLE_* 开关注入）
scripts/             25.12/、24.10/ 各含 diy-part1.sh、diy-part2.sh（v2.1 原样 + 单网口设备定制分支，
                     diy-part2 的 autoupdate prefix 参数化为 AUTOUPDATE_PREFIX）；common/ 含 autoupdate.sh、package-sync.sh
```

插件集统一走基底 config（RAX3000M 线，含 ksmbd-avahi-service、luci-app-oaf、luci-app-3cat、cifs 全家桶等用户既定偏好），各设备 config 仅差异在 target 段 + ROOTFS 行 + 从旧仓库移植的平台绑定 kmod。

## 触发方式

- **手动触发**：Actions → 选择对应 `ImmortalWrt-<分支>-<设备>` → Run workflow。可选参数与 v2.1 相同：上传 bin/packages/所有文件、自定义源仓库地址/分支/config 文件、SSH 调试（tmate）、keepalived/docker 开关。
- **定时触发**：主流设备每周一、周四（UTC 6 点档 = 北京时间 14 点档），24.10 与 25.12 两套平行错峰：
  - 24.10 档：rax3000m :00、cm520 :05、hc5962 :10、newifi-d2 :15、newifi-d1 :20、newifi-y1 :25、octopus :35、r68s :40
  - 25.12 档：octopus :10、r68s :20、rax3000m :30、cm520 :35、hc5962 :40、newifi-d2 :45、newifi-d1 :50、newifi-y1 :55
  - 玩客云因配方式注入流程独立，每周五 UTC 19:30 单独跑。
- **源码更新自动触发**：沿用 v2.1 的 `check-source-updates` 检测 job（缓存 last-checked-sha，有新提交才编译）。

## 值守式升级（固定 URL）

固件内预装 `rax-autoupdate`（`scripts/common/autoupdate.sh`，cron 每日 04:40 检查，默认不自动应用）。升级文件走 GitHub Release 固定地址，URL 模式：

```
https://github.com/<owner>/<repo>/releases/latest/download/autoupdate-<设备>-<分支>-<产物后缀>
```

- 设备标识取大写短名：`RAX3000M`、`R68S`、`CM520`、`HC5962`、`NEWIFI-D2`、`NEWIFI-D1`、`NEWIFI-Y1`、`ONECLOUD`、`OCTOPUS`
- 标准设备（sysupgrade 类）产出 `-sysupgrade.itb`（或 R68S 为 `-sysupgrade.img.gz`）+ `.sha256` + `-version.txt`（含 RUN_ID 构建指纹）
- 直刷镜像类设备（玩客云/章鱼星球）固定资产为 `autoupdate-<设备>-<分支>-img.gz` + sha256 + version.txt；这三类设备**不支持 sysupgrade 在线升级**，固件内自动 apply 不适用，升级请重新写盘/线刷
- 每次 Release 前自动清理同设备旧 Release（`ImmortalWrt-<分支>-<设备短名>-*` 正则），`latest/download` 始终指向最新构建

## 来源仓库映射

| 设备 | config 参考来源 | target 段依据 |
|---|---|---|
| rax3000m | v2.1 模板原 config（25.12/24.10） | 模板现成 |
| r68s | rax3000m 同源模板（nft 完全体 + ddns-go/kmod-oaf 白名单继承） | 映射至 rockchip/armv8 + `kmod-r8125`（2.5G 双网卡），KERNEL_PARTSIZE=16/ROOTFS_PARTSIZE=512 |
| cm520 | 2286927/OneCloud_Canbox-OpenWrt_DNSfilter（CanBox_immortalwrt_DNSfilter.config，23.05） | 映射表 + 旧 config（kmod-ath10k-ct、ath10k-firmware-qca4019-ct） |
| hc5962 | 2286927/passwall-openwrt-NewifiD1_D2-HC5962-X86_64（hc5962-One.config） | 映射表 + 旧 config（kmod-mt76 系 5 项） |
| newifi-d2 | 同上仓库（newifi3.config） | 映射表 + 旧 config（kmod-mt76 系 5 项） |
| newifi-d1 | 同上仓库（newifi2.config） | 映射表（旧 config 无平台 kmod =y 行，不追加） |
| newifi-y1 | 同上仓库（newifimini.config1） | 映射表（同上） |
| onecloud | 配方仓库 2286927/OneCloud_immortalwrt（recipe/Config/quicker-amlogic.config，CRLF） | lede master 注入 amlogic/meson8b target 树 |
| octopus | 2286927/OpenWrt-ARMv8（OpenWrt_ARMv8.config） | CONFIG_TARGET_armsr_armv8_DEVICE_generic=y + flippy 打包 |

旧 config 中的 luci-app / passwall 相关行一律未迁移（插件集统一走基底），仅移植平台绑定 kmod 的 `=y` 行。

## 相关仓库

- **[2286927/OneCloud_immortalwrt](https://github.com/2286927/OneCloud_immortalwrt)**：玩客云配方仓库（专用 config + files + 线刷包制作脚本；amlogic target 树已改由 coolsnowwolf/lede master 提供，配方仓库不再注入内核树）。已脱离上游 rmoyulong/OneCloud_OpenWrt 维护，workflow 通过 `RECIPE_REF` 锁定 commit。
- **[2286927/ImmortalWrt-24.10-CMCC-RAX3000M-EMMC](https://github.com/2286927/ImmortalWrt-24.10-CMCC-RAX3000M-EMMC)**：RAX3000M EMMC 版独立仓库（24.10，ddns-go/luci-app-ddns-go 白名单内置）。

## 使用说明

1. 推送到 GitHub 后确认 Settings → Actions 权限，`GITHUB_TOKEN` 默认即可发布 Release。
2. 首次构建无缓存，耗时较长（rockchip 等大 target 冷编译 3.5-4.5h）；之后 dl/ccache/toolchain 三级缓存按「分支 + 设备」维度命中，热缓存二轮 40-70 分钟。
3. 若要改插件：优先改对应设备的 `<设备短名>-<分支>.config`；全局插件偏好改基底后需同步到 16 份派生 config（或重新生成）。
4. 玩客云/章鱼星球/R68S 镜像写盘后首次启动建议接串口/看日志确认引导；flippy 镜像默认 IP 及账号见 flippy 文档，玩客云线刷包默认 LAN `172.16.8.1`。
5. 单网口设备（玩客云/章鱼星球）固件出厂即 wan-only 布局，无 lan 口，请以旁路由/单臂网关方式接入；应急管理 IP 见 network 注入文件内 Bypass 地址。
