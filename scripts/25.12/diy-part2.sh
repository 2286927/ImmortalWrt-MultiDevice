#!/bin/bash
#=============================================================
# ImmortalWrt DIY 脚本 2（feeds 更新之后、生成编译配置之前执行）
#  1) 修改默认 LAN IP / 主机名（与 workflow env LAN_IP/LAN_HOSTNAME 同源，默认 172.16.7.1 / CMCC-RAX3000M）
#  2) 从 kenzok8/small-package 导入第三方软件包，并自动与
#     官方同名清理（v2.2 第三方优先）：与第三方重复时移除官方同名，使用第三方版本
#=============================================================

echo "===== diy-part2.sh（25.12）开始执行 ====="
echo "执行时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ── 0. 上游补丁失配临时规避（仅 r68s）────────────────────────
# 2026-11-11 上游 Merge Official Source (761b7ff2) 更新了
# drivers/gpu/drm/rockchip/rockchip_drm_vop2.c 等显示子系统代码，
# 而 patches-6.12/041-* 这 62 个 v6.13~v6.17 backport 未同步 refresh：
#   run 43266516576 → 041-30 七个 hunk 全 FAILED
#   run 43335870381 → 移除 041-30 后 041-38 三个 hunk 全 FAILED
# 逐个移除要多轮 40~50 分钟构建。这批补丁全部作用于 HDMI/DP/VOP2
# 显示驱动，r68s 无显示输出，整批移除对固件功能无影响。
# 本脚本被 9 条 25.12 线共用，故严格限定 DEVICE_MODEL=r68s，不误伤其它线。
# ⚠️ 临时规避：上游自行 refresh 该系列补丁后应删除本段。
if [[ "${DEVICE_MODEL:-}" == "r68s" ]]; then
    ROCKCHIP_PATCH_DIR="target/linux/rockchip/patches-6.12"
    if [ -d "$ROCKCHIP_PATCH_DIR" ]; then
        _ds_removed=0
        for _ds_p in "$ROCKCHIP_PATCH_DIR"/041-*.patch; do
            [ -f "$_ds_p" ] || continue
            rm -f "$_ds_p"
            _ds_removed=$((_ds_removed + 1))
        done
        echo ">>> 已移除上游失配的 041-* 显示子系统补丁共 ${_ds_removed} 个（仅 r68s，临时规避）"
    fi
fi
# ── 1. 修改 LAN 默认 IP 与主机名 ───────────────────────────────
CONFIG_FILE="package/base-files/files/bin/config_generate"

# 单一数据源：LAN_IP / LAN_HOSTNAME 由 workflow env 传入，本地直跑用默认值
LAN_IP="${LAN_IP:-172.16.7.1}"
LAN_HOSTNAME="${LAN_HOSTNAME:-CMCC-RAX3000M}"

if [[ -f "$CONFIG_FILE" ]]; then
    # 1a. LAN 默认 IP → ${LAN_IP}
    if grep -qF "$LAN_IP" "$CONFIG_FILE"; then
        echo "LAN IP 已是 ${LAN_IP}，无需修改"
    else
        echo "修改 LAN 默认 IP → ${LAN_IP} ..."
        sed -i \
            -e "s/192\.168\.1\.1/${LAN_IP}/g" \
            -e "s/192\.168\.2\.1/${LAN_IP}/g" \
            -e "s/192\.168\.6\.1/${LAN_IP}/g" \
            -e "s/192\.168\.0\.1/${LAN_IP}/g" \
            -e "s/192\.168\.100\.1/${LAN_IP}/g" \
            "$CONFIG_FILE" 2>/dev/null || echo "  sed 执行出现问题"
    fi

    # 1b. 设备主机名 → ${LAN_HOSTNAME}
    if grep -qF "hostname='${LAN_HOSTNAME}'" "$CONFIG_FILE"; then
        echo "主机名已是 ${LAN_HOSTNAME}，无需修改"
    elif sed -i "s/hostname='ImmortalWrt'/hostname='${LAN_HOSTNAME}'/" "$CONFIG_FILE" && \
         grep -qF "hostname='${LAN_HOSTNAME}'" "$CONFIG_FILE"; then
        echo "主机名已修改 → ${LAN_HOSTNAME}"
    else
        echo "⚠️  未能定位默认主机名，主机名保持不变"
    fi
else
    echo "⚠️  未找到 config_generate，跳过 IP/主机名修改"
fi

# ── 1c. 单网口设备（OCTOPUS 晶晨盒子）网络/防火墙定制 ──────────
# 仅 OCTOPUS 生效（其他线零影响）：单网口当 DHCP 客户端/旁路由
#   network：删除 lan，wan=eth0 DHCP，wan6=@wan DHCPv6
#   firewall：单 lan 域全 ACCEPT（wan/wan6 均归 lan 域，无 wan zone/masq/flow-offload）
if [[ "${DEVICE_MODEL:-}" == "octopus" ]]; then
    echo ">>> 单网口设备定制（OCTOPUS）：写入 files/etc/config/{network,firewall}"
    mkdir -p files/etc/config
    cat > files/etc/config/network <<'SINGLE_NET_EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option packet_steering '1'

config interface 'wan'
	option device 'eth0'
	option proto 'dhcp'

config interface 'wan6'
	option device '@wan'
	option proto 'dhcpv6'
	option reqaddress 'try'
	option reqprefix 'auto'
SINGLE_NET_EOF
    cat > files/etc/config/firewall <<'SINGLE_FW_EOF'
config defaults
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'

config zone
	option name 'lan'
	list network 'wan'
	list network 'wan6'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'
SINGLE_FW_EOF
    echo ">>> 单网口定制完成（lan 已移除，wan/wan6 归 lan 域）"
fi

# ── 1d. CM520-79F 无线修复（注入默认 wireless 配置） ────────────
# 背景：ipq40xx(IPQ4019) 无板载 tsens（上游 DTS 无节点/官方 config 关闭），
#   LuCI 温度依赖 ath10k 芯片温度（CONFIG_ATH10K_THERMAL 默认 y）。
#   此前 config 只装 ath10k-firmware-qca4019-ct、缺 ath10k-board-qca4019(board-2.bin)
#   → ath10k 无法 probe → 无线设备未激活 + 无 thermal zone → LuCI "No temperature info"
# 此段：仅 CM520 生效（其他线零影响）；注入 radio0(2.4G)+radio1(5G) 默认开放 SSID
#   （wifi0=a000000=2.4G，wifi1=a800000=5G，IPQ4019 标准布局）
if [[ "${DEVICE_MODEL:-}" == "cm520" ]]; then
    echo ">>> CM520-79F 无线修复：注入默认 wireless 配置"
    mkdir -p files/etc/config
    if [ ! -f files/etc/config/wireless ]; then
        cat > files/etc/config/wireless <<'CM520_WIFI_EOF'
config wifi-device 'radio0'
	option type 'mac80211'
	option channel 'auto'
	option band '2g'
	option cell_density '0'

config wifi-device 'radio1'
	option type 'mac80211'
	option channel 'auto'
	option band '5g'
	option cell_density '0'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'ImmortalWrt'
	option encryption 'none'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'ImmortalWrt'
	option encryption 'none'
CM520_WIFI_EOF
        echo ">>> CM520 默认无线配置已写入 files/etc/config/wireless（SSID=ImmortalWrt 开放，请在 LuCI 设置密码）"
    else
        echo ">>> files/etc/config/wireless 已存在，跳过覆盖"
    fi
fi

# ── 1e. Dropbear SSH 出厂默认配置固化（全设备） ────────────────
# 需求：所有设备固件出厂即 LuCI"SSH 访问"默认态：启用实例、接口未指定
#   （监听全部接口）、端口 22、密码验证开、允许 root 凭密码登录。
# 直接出厂 files/etc/config/dropbear 显式固化（与 OpenWrt 默认一致，防未来偏离）。
mkdir -p files/etc/config
cat > files/etc/config/dropbear <<'DROPBEAR_EOF'
config dropbear
	option password_auth '1'
	option root_password_auth '1'
	option Port '22'
DROPBEAR_EOF
echo ">>> Dropbear 出厂配置已固化（22 端口/全接口/密码验证/root 密码登录）"

# ── 1f. Globitel BT-R320 U-Boot 恢复链 DHCP 化（仅 BT-R320 生效） ─
# 背景：官方 472 patch 的 defenv 恢复路径按 reset 走 TFTP client（固定
#   ipaddr=192.168.1.1 / serverip=192.168.1.254，无 DHCP），且官方安装
#   说明所称 "U-Boot web UI" 在实际构建中并不存在（无 webui 补丁/配置）。
# 改造（追加 504 patch）：
#   1) 所有网络恢复路径前置 dhcp：挂路由器自动获取 IP（避免与用户局域网
#      冲突），直连无 DHCP 时失败回退默认 192.168.1.1
#   2) 按 reset 进入 tftpsrv 接收模式（U-Boot 作 TFTP server 等待 PC 推送
#      recovery.itb，收完自动引导，PC 端无需静态 IP、无需跑 TFTP server）
#   3) bootmenu 追加第 11 项手动触发；bootm 兜底指定 FIT 配置
if [[ "${DEVICE_MODEL:-}" == "globitel-bt-r320" ]]; then
    echo ">>> BT-R320 U-Boot 恢复链 DHCP 化：追加 504 patch"
    cat > package/boot/uboot-mediatek/patches/504-globitel-bt-r320-dhcp-tftpsrv.patch <<'BT320_DHCP_EOF'
diff --git a/defenvs/mt7981_globitel_bt-r320_env b/defenvs/mt7981_globitel_bt-r320_env
index 8c95f81..ac1f59a 100644
--- a/defenvs/mt7981_globitel_bt-r320_env
+++ b/defenvs/mt7981_globitel_bt-r320_env
@@ -27,3 +27,4 @@
 bootmenu_9=Reset all settings to factory defaults.=run reset_factory ; reset
-boot_first=if button reset ; then run boot_tftp_recovery ; setenv flag_recover 1 ; run boot_default ; fi ; bootmenu
+bootmenu_10=Receive file via TFTP (PC push) and boot.=run boot_tftpsrv ; run bootmenu_confirm_return
+boot_first=if button reset ; then run boot_tftpsrv ; fi ; bootmenu
 boot_default=if env exists flag_recover ; then else run bootcmd ; fi ; run boot_recovery ; setenv replacevol 1 ; run boot_tftp_forever
@@ -33,7 +34,8 @@
 boot_tftp_forever=while true ; do run boot_tftp_recovery ; sleep 1 ; done
-boot_tftp_production=tftpboot $loadaddr $bootfile_upg && env exists replacevol && iminfo $loadaddr && run emmc_write_production ; if env exists noboot ; then else bootm $loadaddr#$bootconf ; fi
-boot_tftp_recovery=tftpboot $loadaddr $bootfile && env exists replacevol && iminfo $loadaddr && run emmc_write_recovery ; if env exists noboot ; then else bootm $loadaddr#$bootconf ; fi
+boot_tftp_production=if dhcp ; then ; fi ; tftpboot $loadaddr $bootfile_upg && env exists replacevol && iminfo $loadaddr && run emmc_write_production ; if env exists noboot ; then else bootm $loadaddr#$bootconf ; fi
+boot_tftp_recovery=if dhcp ; then ; fi ; tftpboot $loadaddr $bootfile && env exists replacevol && iminfo $loadaddr && run emmc_write_recovery ; if env exists noboot ; then else bootm $loadaddr#$bootconf ; fi
 boot_tftp_write_fip=tftpboot $loadaddr $bootfile_fip && run emmc_write_fip
 boot_tftp_write_bl2=tftpboot $loadaddr $bootfile_bl2 && run emmc_write_bl2
-boot_tftp=tftpboot $loadaddr $bootfile && bootm $loadaddr#$bootconf
+boot_tftp=if dhcp ; then ; fi ; tftpboot $loadaddr $bootfile && bootm $loadaddr#$bootconf
+boot_tftpsrv=if dhcp ; then ; fi ; tftpsrv $loadaddr ; bootm $loadaddr#$bootconf
 mmc_write_vol=imszb $loadaddr image_size && test 0x$image_size -le 0x$part_size && mmc erase 0x$part_addr 0x$image_size && mmc write $loadaddr 0x$part_addr 0x$image_size
BT320_DHCP_EOF
    echo ">>> 504 patch 已写入（dhcp 前置 + tftpsrv 接收模式）"
fi

# ── 1g. luci-app-socat 修复（保存即生效 + stop 竞态 + 延迟重载防 502）──
# 背景：luci_socat 未注册 procd、无 config.change 触发器；LuCI 侧保存后
#   不调 restart，只有开机 S99luci_socat 才会拉起 → 新规则长期显示 X，
#   必须重启设备才变 ✓。另有 stop 竞态（kill 异步 + 立刻 rm -rf）导致
#   restart 时 bind EADDRINUSE。
SOCAT_FIX="$GITHUB_WORKSPACE/scripts/common/patch-luci-app-socat.sh"
[ -f "$SOCAT_FIX" ] || SOCAT_FIX="$MYDIR/../common/patch-luci-app-socat.sh"
if [ -f "$SOCAT_FIX" ]; then
    bash "$SOCAT_FIX" || { echo "❌ socat 补丁失败，中止编译"; exit 1; }
else
    echo "⚠️  未找到 patch-luci-app-socat.sh，跳过 socat 修复"
fi

# ── 1h. socat 必须带 OpenSSL（TLS 终结能力硬门禁）───────────────
# 背景：packages feed 的 net/socat/Makefile
#   config SOCAT_SSL（default n），且
#   ifneq ($(CONFIG_SOCAT_SSL),y)
#     CONFIGURE_ARGS += --disable-openssl
#   endif
#   不开时编出的 socat -V 显示 #undef WITH_OPENSSL，
#   OPENSSL-LISTEN / OPENSSL-CONNECT 全部不可用。
#
# 执行上下文（已按仓库现状核对，勿照抄 $GITHUB_WORKSPACE/.config）：
#   workflow「加载配置」步骤先 cp config/<设备>-<分支>.config openwrt/.config，
#   再 cd openwrt 后执行本脚本 → 此处 CWD=openwrt/，.config 就是编译树根的 .config。
#   本段早于「生成编译配置」的 make defconfig，属 feeds 装完之后、make 之前。
#
# 做法：先幂等补写（在 CONFIG_PACKAGE_socat=y 之后紧邻插入，去掉并存的 not set 行），
#       再硬校验三条符号；缺任何一条直接中止，避免又编出一版无 SSL 的 socat。
SVC_CFG=".config"
if [ -f "$SVC_CFG" ] && grep -qx 'CONFIG_PACKAGE_socat=y' "$SVC_CFG"; then
    sed -i '/^# CONFIG_SOCAT_SSL is not set$/d' "$SVC_CFG"
    sed -i '/^# CONFIG_PACKAGE_libopenssl is not set$/d' "$SVC_CFG"
    if ! grep -qx 'CONFIG_SOCAT_SSL=y' "$SVC_CFG"; then
        sed -i '/^CONFIG_PACKAGE_socat=y$/a CONFIG_SOCAT_SSL=y' "$SVC_CFG"
        echo ">>> 已补写 CONFIG_SOCAT_SSL=y（紧随 CONFIG_PACKAGE_socat=y）"
    fi
    # libopenssl 属显式补：SOCAT_SSL 的 DEPENDS 只在 menuconfig 求值时生效，
    # 直接喂静态 .config 时依赖求解未必补上，这里兜一层。
    if ! grep -qx 'CONFIG_PACKAGE_libopenssl=y' "$SVC_CFG"; then
        sed -i '/^CONFIG_SOCAT_SSL=y$/a CONFIG_PACKAGE_libopenssl=y' "$SVC_CFG"
        echo ">>> 已补写 CONFIG_PACKAGE_libopenssl=y"
    fi
fi

if [ -f "$SVC_CFG" ] && grep -qx 'CONFIG_PACKAGE_socat=y' "$SVC_CFG"; then
    _svc_miss=""
    grep -qx 'CONFIG_PACKAGE_socat=y' "$SVC_CFG" || _svc_miss="$_svc_miss CONFIG_PACKAGE_socat"
    grep -qx 'CONFIG_SOCAT_SSL=y' "$SVC_CFG" || _svc_miss="$_svc_miss CONFIG_SOCAT_SSL"
    grep -qx 'CONFIG_PACKAGE_libopenssl=y' "$SVC_CFG" || _svc_miss="$_svc_miss CONFIG_PACKAGE_libopenssl"
    if [ -n "$_svc_miss" ]; then
        echo "❌ socat 需要 OpenSSL 支持，但以下符号未生效：$_svc_miss"
        echo "   要求同时为 y：CONFIG_PACKAGE_socat / CONFIG_SOCAT_SSL / CONFIG_PACKAGE_libopenssl"
        echo "   否则 socat -V 会显示 #undef WITH_OPENSSL，OPENSSL-LISTEN/CONNECT 不可用"
        exit 1
    fi
    echo "✅ socat OpenSSL 已开启（SOCAT_SSL=y + libopenssl=y，socat 将编译为带 TLS 版本）"
else
    echo ">>> 本配置未选用 socat，跳过 socat OpenSSL 门禁"
fi

# ── 2. 第三方软件包导入 + 官方同名清理（第三方优先） ─────────────────────────
SYNC_SH="$GITHUB_WORKSPACE/scripts/common/package-sync.sh"
[ -f "$SYNC_SH" ] || SYNC_SH="$MYDIR/../common/package-sync.sh"

if [ -f "$SYNC_SH" ]; then
    bash "$SYNC_SH"
else
    echo "❌ 未找到 package-sync.sh（尝试过 $GITHUB_WORKSPACE/scripts/common/ 与 $MYDIR/../common/）"
    exit 1
fi

# ── 2b. Filogic / RAX3000M 出厂性能调优（仅 cmcc_rax3000m 生效）─────
# 参数已逆向核对 mzwrt-25-12 已发布固件（v25.12.6-20261105112318）的真实产物：
#   /etc/sysctl.d/98-mzwrt.conf、/etc/uci-defaults/99-MzWrt-settings、
#   /etc/mzwrt/openclash-tuning.txt、/etc/modules.d/{sched-fq-pie,tcp-bbr}
# 落到固件运行时：
#   ① 队列/拥塞：fq_pie + BBR（MT7981 是 Cortex-A53，加密路径已在 config 侧改为 ChaCha 优先）
#   ② 大带宽时延积：TCP 收发缓冲上限 8MB，默认 256KB，空闲后不回落慢启动
#   ③ 硬件转发：flow offloading 软+硬（MT7981 硬件 NAT）、packet steering 双核分流
#   ④ 内存：ZRAM 兜底、conntrack 收敛到 32768、min_free_kbytes 24MB 留回收余量
#   ⑤ 无线：国家码 CN，放开 5G 全信道与功率上限（默认 world 会压制）
if [[ "${DEVICE_MODEL:-}" == "cmcc_rax3000m" ]]; then
    echo ">>> 注入 Filogic(MT7981) 出厂调优 ..."
    mkdir -p files/etc/sysctl.d files/etc/modules.d files/etc/uci-defaults \
             files/etc/filogic files/usr/sbin

    # ① 启动早期加载调度/拥塞模块，保证 sysctl 写入时目标键已存在
    #    （kmod-sched-fq-pie / kmod-tcp-bbr 包本身也带 modules.d 文件，此处为兜底）
    cat > files/etc/modules.d/99-filogic-tune <<'EOF'
sch_fq_pie
tcp_bbr
EOF

    # ② 运行时内核参数（/etc/init.d/sysctl 每次启动应用）
    cat > files/etc/sysctl.d/99-filogic-tune.conf <<'EOF'
# ===== MediaTek Filogic (MT7981) 出厂调优 =====
# 数值对齐 mzwrt-25-12 的 /etc/sysctl.d/98-mzwrt.conf

# ── 队列与拥塞控制：BBR 高吞吐低延迟，fq_pie 抗 bufferbloat ──
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# ── 大带宽时延积：单流可跑满千兆跨境链路（8MB 上限，默认 256KB）──
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 8388608
net.ipv4.tcp_wmem = 4096 16384 8388608

# ── 空闲后不回落慢启动，避免突发流量重新爬坡 ──
net.ipv4.tcp_slow_start_after_idle = 0
# ── PMTU 黑洞探测，跨境链路更稳 ──
net.ipv4.tcp_mtu_probing = 1
# ── TCP Fast Open（客户端 + 服务端）──
net.ipv4.tcp_fastopen = 3
# ── 不复用旧连接的拥塞指标，路径变化后不带错误 cwnd 起步 ──
net.ipv4.tcp_no_metrics_save = 1
# ── TIME_WAIT 阶段丢弃畸形包，抗扫描/抗误杀 ──
net.ipv4.tcp_rfc1337 = 1

# ── 连接清理（长期挂机场景及时回收孤儿连接）──
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_max_orphans = 4096

# ── Keepalive：300s 探测，及时回收死连接 ──
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# ── 网络队列（双核 A53，提高 backlog/budget 减少软中断丢包）──
net.core.netdev_max_backlog = 4096
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# ── 连接跟踪：512MB 内存下 32768 足够，且不会打爆 slab ──
net.netfilter.nf_conntrack_max = 32768
net.netfilter.nf_conntrack_acct = 0
net.netfilter.nf_conntrack_checksum = 0
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120

# ── 内存管理（512MB 长期挂机 + ZRAM）──
vm.swappiness = 10
vm.vfs_cache_pressure = 80
vm.min_free_kbytes = 24576

# ── 文件描述符与 BPF（OpenClash 多连接 / 规则匹配）──
fs.file-max = 51200
net.core.bpf_jit_enable = 1
net.core.bpf_jit_kallsyms = 0

# ── IGMP（IPTV / 组播）──
net.ipv4.igmp_max_memberships = 100
EOF

    # ③ 首次启动一次性 UCI 默认值（执行后由系统自动删除）
    cat > files/etc/uci-defaults/99-filogic-tune <<'EOF'
#!/bin/sh
# 首次启动生效：硬件转发卸载 + 双核分流 + 无线国家码 CN + 日志收敛

# 软/硬 flow offloading（MT7981 硬件 NAT；被 Clash 接管的流不进卸载）
[ -f /etc/config/firewall ] && {
	uci -q set firewall.@defaults[0].flow_offloading='1'
	uci -q set firewall.@defaults[0].flow_offloading_hw='1'
	uci -q commit firewall
}

# packet steering：双核分流，降低单核打满的时延毛刺
# 兼容命名 section（network.globals）与匿名 section（network.@globals[0]）
if [ -f /etc/config/network ]; then
	if uci -q get network.globals >/dev/null 2>&1; then
		uci -q set network.globals.packet_steering='1'
		uci -q commit network
	elif uci -q get network.@globals[0] >/dev/null 2>&1; then
		uci -q set network.@globals[0].packet_steering='1'
		uci -q commit network
	fi
	# S25 时该服务已跑过，首次启动需显式 reload 才生效
	[ -x /etc/init.d/packet_steering ] && /etc/init.d/packet_steering reload >/dev/null 2>&1
fi

# 首次启动时 /etc/config/wireless 可能尚未生成，先让 wifi 生成默认配置再改国家码
[ -f /etc/config/wireless ] || wifi config >/dev/null 2>&1
if [ -f /etc/config/wireless ]; then
	for s in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p'); do
		uci -q set wireless.$s.country='CN'
	done
	uci -q commit wireless
fi

# 日志收敛：减少 eMMC 写入量（长期挂机）
[ -f /etc/config/system ] && {
	uci -q set system.@system[0].log_level='6'
	uci -q set system.@system[0].log_size='64'
	uci -q commit system
}

# sysctl 在 S11 执行，早于 nf_conntrack 加载；此处兜底重放一次
[ -f /etc/sysctl.d/99-filogic-tune.conf ] && \
	sysctl -e -p /etc/sysctl.d/99-filogic-tune.conf >/dev/null 2>&1

exit 0
EOF
    chmod 755 files/etc/uci-defaults/99-filogic-tune

    # ④ 调优说明（供用户查阅，不参与运行）
    cat > files/etc/filogic/tuning.txt <<'EOF'
MediaTek Filogic (MT7981 / CMCC RAX3000M) 出厂调优说明
=======================================================

本固件出厂即启用以下优化，无需手动配置。
参数与 mzwrt-25-12 已发布固件核对一致（/etc/sysctl.d/98-mzwrt.conf）。

一、国内直连：低延迟 · 高速率
  1. 软件 + 硬件 Flow Offloading（MT7981 硬件 NAT 转发）
  2. Packet Steering（双核分流，避免单核打满造成延迟毛刺）
  3. fq_pie 队列 + BBR 拥塞控制

二、跨境代理：OpenClash 吞吐
  1. TCP 收发缓冲上限 8MB、默认 256KB，空闲后不回落慢启动
  2. MTU 黑洞探测 + TCP Fast Open + 不复用旧连接拥塞指标
  3. 推荐 OpenClash 组合：Rule 模式 / 大陆分流 DIRECT / Fake-IP + TUN / 协议栈 System
     说明：只有协议栈选 System，流量才走本机内核的 BBR 与大窗口；选 gVisor/Mixed 会绕开。
  4. 不要为了 Clash 长期关闭硬件卸载（国内会明显变慢），也不要日常用 Global 模式。

三、内存与稳定性（512MB 长期挂机画像）
  1. ZRAM 压缩内存兜底（默认约 256MB swap）
  2. conntrack 上限 32768，established 超时 600s，关闭 acct/checksum 省 CPU
  3. vm.min_free_kbytes = 24MB，降低 Clash + AdGuardHome 同开时的 OOM 概率
  4. vm.swappiness = 10、vfs_cache_pressure = 80，优先保留 inode/dentry 缓存
  5. fs.file-max = 51200，BPF JIT 开启但关闭 kallsyms
  6. 内核已裁掉 memcg / io_uring / MPTCP / coredump / DEBUG_FS / MAGIC_SYSRQ

四、无线
  1. 默认国家码 CN：放开 5G 全信道与发射功率上限
  2. 如所在地区法规不同，请自行改为对应国家码

五、自检
  执行 filogic-tune-check 查看全部参数实际值与期望值。

注意：
  - AdGuardHome 与 OpenClash 不要同时占用 53 端口，两套 Fake-IP 不要叠加。
  - 手动执行 /etc/init.d/firewall restart 后，硬件卸载会按 UCI 配置自动恢复。
EOF

    # ⑤ 自检脚本
    cat > files/usr/sbin/filogic-tune-check <<'EOF'
#!/bin/sh
# Filogic 出厂调优自检：打印实际值与期望值
chk() { printf '  %-42s %s\n' "$1" "$2"; }

echo "=== 队列 / 拥塞 / 缓冲 ==="
chk "net.core.default_qdisc"                   "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
chk "net.ipv4.tcp_congestion_control"          "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
chk "net.core.rmem_max"                        "$(sysctl -n net.core.rmem_max 2>/dev/null)"
chk "net.core.wmem_max"                        "$(sysctl -n net.core.wmem_max 2>/dev/null)"
chk "net.ipv4.tcp_rmem"                        "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
chk "net.ipv4.tcp_wmem"                        "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
chk "net.ipv4.tcp_slow_start_after_idle"       "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
chk "net.ipv4.tcp_mtu_probing"                 "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
chk "net.ipv4.tcp_fastopen"                    "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"

echo
echo "=== 队列深度 / BPF ==="
chk "net.core.netdev_max_backlog"              "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
chk "net.core.netdev_budget"                   "$(sysctl -n net.core.netdev_budget 2>/dev/null)"
chk "net.core.bpf_jit_enable"                  "$(sysctl -n net.core.bpf_jit_enable 2>/dev/null)"
chk "fs.file-max"                              "$(sysctl -n fs.file-max 2>/dev/null)"

echo
echo "=== 连接跟踪 ==="
chk "net.netfilter.nf_conntrack_max"           "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
chk "nf_conntrack_tcp_timeout_established"     "$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null)"
chk "nf_conntrack_acct"                        "$(sysctl -n net.netfilter.nf_conntrack_acct 2>/dev/null)"

echo
echo "=== 内存 ==="
chk "vm.swappiness"                            "$(sysctl -n vm.swappiness 2>/dev/null)"
chk "vm.vfs_cache_pressure"                    "$(sysctl -n vm.vfs_cache_pressure 2>/dev/null)"
chk "vm.min_free_kbytes"                       "$(sysctl -n vm.min_free_kbytes 2>/dev/null)"

echo
echo "=== 转发加速 ==="
chk "firewall flow_offloading"                 "$(uci -q get firewall.@defaults[0].flow_offloading)"
chk "firewall flow_offloading_hw"              "$(uci -q get firewall.@defaults[0].flow_offloading_hw)"
chk "network packet_steering"                  "$(uci -q get network.globals.packet_steering || uci -q get network.@globals[0].packet_steering)"

echo
echo "=== 无线国家码 ==="
for dev in $(uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p'); do
	chk "$dev country" "$(uci -q get wireless.$dev.country)"
done

echo
echo "=== 内存 / ZRAM ==="
free -m | sed -n '1,3p'
[ -e /dev/zram0 ] && echo "  /dev/zram0 就绪（$(cat /sys/block/zram0/disksize 2>/dev/null) bytes）" || echo "  ⚠ /dev/zram0 不存在，检查 kmod-zram"

echo
echo "期望值："
echo "  fq_pie | bbr | 8388608 | 8388608 | 4096 262144 8388608 | 4096 16384 8388608 | 0 | 1 | 3"
echo "  4096 | 600 | 1 | 51200 | 32768 | 600 | 0 | 10 | 80 | 24576 | 1 | 1 | 1 | CN"
EOF
    chmod 755 files/usr/sbin/filogic-tune-check

    # ⑥ 构建期断言：文件存在且关键项已落地
    for f in files/etc/sysctl.d/99-filogic-tune.conf \
             files/etc/modules.d/99-filogic-tune \
             files/etc/uci-defaults/99-filogic-tune \
             files/usr/sbin/filogic-tune-check \
             files/etc/filogic/tuning.txt; do
        [ -s "$f" ] || { echo "::error::调优文件缺失或为空：$f"; exit 1; }
    done
    for kv in 'net.ipv4.tcp_congestion_control = bbr' 'net.core.default_qdisc = fq_pie' \
              'net.ipv4.tcp_slow_start_after_idle = 0' 'vm.min_free_kbytes = 24576' \
              'net.netfilter.nf_conntrack_max = 32768'; do
        grep -qF "$kv" files/etc/sysctl.d/99-filogic-tune.conf \
            || { echo "::error::sysctl 缺少关键项：$kv"; exit 1; }
    done
    grep -q 'flow_offloading_hw' files/etc/uci-defaults/99-filogic-tune \
        || { echo "::error::flow_offloading_hw 未注入"; exit 1; }
    grep -q 'packet_steering' files/etc/uci-defaults/99-filogic-tune \
        || { echo "::error::packet_steering 未注入"; exit 1; }
    echo ">>> 调优注入完成：sysctl=$(grep -vc '^\s*#\|^\s*$' files/etc/sysctl.d/99-filogic-tune.conf) 项，uci-defaults 就绪"
fi

# ── 3. 值守式升级（GitHub Releases 固定 URL 自动检查）────────────
# 多设备仓库：AUTOUPDATE_PREFIX 由各 workflow env 注入（缺省保持 v2.1 RAX3000M 行为）
AUTOUPDATE_PREFIX="${AUTOUPDATE_PREFIX:-autoupdate-RAX3000M-25.12}"

AUTOUPDATE_SRC="$MYDIR/../common/autoupdate.sh"

if [ -f "$AUTOUPDATE_SRC" ]; then
    mkdir -p files/usr/bin files/etc/crontabs files/etc/config
    install -m 755 "$AUTOUPDATE_SRC" files/usr/bin/autoupdate

    # 固定 tag autoupdate（多设备资产共存，发版后由 workflow 同步，URL 永不失效）
    GH_BASE="https://github.com/${GITHUB_REPOSITORY:-OWNER/REPO}/releases/download/autoupdate"

    cat > files/etc/config/autoupdate <<EOF
config main 'main'
	option enabled '1'
	option base_url '$GH_BASE'
	option prefix '${AUTOUPDATE_PREFIX}'
	option notify_url ''
	option auto_apply '0'
	option mirror 'auto'
EOF

    echo "${GITHUB_RUN_ID:-0}" > files/etc/autoupdate.build

    if ! grep -q "autoupdate" files/etc/crontabs/root 2>/dev/null; then
        echo "40 4 * * * /usr/bin/autoupdate check" >> files/etc/crontabs/root
    fi

    echo ">>> 值守升级注入完成: prefix=${AUTOUPDATE_PREFIX} run_id=$(cat files/etc/autoupdate.build 2>/dev/null)"
else
    echo "⚠️  未找到 autoupdate.sh，跳过值守升级注入"
fi

# ── 3b. 镜像自动维护（autoupdate-maint）────────────────────────
# 出厂自带：脚本 + 默认配置 + uci-defaults 首次启动自愈
# token 不进固件（凭据不入版本库），首次使用需用户放置到 /etc/config/.gh_token
MAINT_SRC="$MYDIR/../common/autoupdate-maint.sh"
MAINT_CONF="$MYDIR/../common/autoupdate-maint.conf"
MAINT_DEFAULTS="$MYDIR/../common/autoupdate-maint.defaults"

if [ -f "$MAINT_SRC" ]; then
    mkdir -p files/usr/bin files/etc/config files/etc/uci-defaults files/etc/crontabs
    install -m 755 "$MAINT_SRC" files/usr/bin/autoupdate-maint

    if [ -f "$MAINT_CONF" ]; then
        install -m 644 "$MAINT_CONF" files/etc/config/autoupdate-maint
    else
        echo "⚠️  未找到 autoupdate-maint.conf，跳过默认配置注入"
    fi

    if [ -f "$MAINT_DEFAULTS" ]; then
        install -m 755 "$MAINT_DEFAULTS" files/etc/uci-defaults/99-autoupdate-maint
    else
        echo "⚠️  未找到 autoupdate-maint.defaults，跳过首次启动自愈注入"
    fi

    if ! grep -q "autoupdate-maint" files/etc/crontabs/root 2>/dev/null; then
        echo "30 3 * * * /usr/bin/autoupdate-maint run" >> files/etc/crontabs/root
    fi

    echo ">>> 镜像自动维护注入完成：$(wc -c < files/usr/bin/autoupdate-maint) 字节（token 需用户放置）"
else
    echo "⚠️  未找到 autoupdate-maint.sh，跳过镜像自动维护注入"
fi


# ── dns-switch 包源接入（仅 r68s）────────────────────────────────────────
# 走「包安装线」：源码进 package/，config 选中 → 固件自带该包，且在 apk 里
# 可见、可 apk del（卸载走 prerm 还原 DNS，不会卸个软件把网卸断）。
#
# 不走 files/ 覆盖线：两条线同时用会让同一批文件装两遍，apk 记录与 overlay 打架。
#
# 执行上下文：CWD=openwrt/，.config 在编译树根；本段早于 make defconfig。
# 顺序很关键 —— 包源必须先把 .config 里的选中项落实，defconfig 才不会被丢掉。
#
# 为什么 clone 而不是把源码复制进本仓：包仓已是 public，clone 拿到就是发版那个
# tag，不会出现「固件里是旧版」；换版本只改 DNS_SWITCH_REF。
if [[ "${DEVICE_MODEL:-}" == "r68s" ]]; then
    DNS_SWITCH_REF="${DNS_SWITCH_REF:-v1.0.0}"
    DNS_SWITCH_REPO="${DNS_SWITCH_REPO:-https://github.com/2286927/luci-app-dns-switch.git}"
    DNS_SWITCH_DIR="package/luci-app-dns-switch"

    echo ">>> 接入 dns-switch 包源（${DNS_SWITCH_REF}）"
    rm -rf /tmp/dns-switch-src "$DNS_SWITCH_DIR"
    if git clone --depth 1 --branch "$DNS_SWITCH_REF" "$DNS_SWITCH_REPO" /tmp/dns-switch-src; then
        # 仓库根是 luci-app-dns-switch/ 再套一层 luci-app-dns-switch/，
        # 这里把内层提上来，落到标准形态 package/<name>/Makefile —— 保证能被扫到。
        mkdir -p "$DNS_SWITCH_DIR"
        cp -a /tmp/dns-switch-src/luci-app-dns-switch/. "$DNS_SWITCH_DIR"/
        rm -rf /tmp/dns-switch-src
    else
        echo "❌ 克隆 dns-switch 失败（${DNS_SWITCH_REPO} @ ${DNS_SWITCH_REF}）"
        exit 1
    fi

    if [ ! -f "$DNS_SWITCH_DIR/Makefile" ]; then
        echo "❌ dns-switch 包源结构不对，找不到 $DNS_SWITCH_DIR/Makefile"
        find "$DNS_SWITCH_DIR" -maxdepth 2 -name Makefile | head
        exit 1
    fi
    echo ">>> dns-switch 包源已就位: $(ls "$DNS_SWITCH_DIR" | tr '\n' ' ')"

    # 网页上传导致仓库里三个脚本是 644；luci.mk 用 cp -p 打包会原样带进固件，
    # 装上去 dns-switch 跑不起来、init 不执行，属「打包成功但装上就废」。
    for _ds_x in \
        "$DNS_SWITCH_DIR/root/usr/bin/dns-switch" \
        "$DNS_SWITCH_DIR/root/etc/init.d/dns-switch" \
        "$DNS_SWITCH_DIR/root/etc/uci-defaults/99-dns-switch"; do
        [ -f "$_ds_x" ] && chmod +x "$_ds_x"
    done
    echo ">>> dns-switch 执行位已补"

    # config 里选中它。先删可能并存的 not set 行，再幂等追加。
    if [ -f .config ]; then
        sed -i '/^# CONFIG_PACKAGE_luci-app-dns-switch is not set$/d' .config
        grep -qx 'CONFIG_PACKAGE_luci-app-dns-switch=y' .config \
            || echo 'CONFIG_PACKAGE_luci-app-dns-switch=y' >> .config
        if grep -qx 'CONFIG_PACKAGE_luci-app-dns-switch=y' .config; then
            echo "✅ dns-switch 已选中（CONFIG_PACKAGE_luci-app-dns-switch=y）"
        else
            echo "❌ CONFIG_PACKAGE_luci-app-dns-switch=y 写入 .config 失败"
            exit 1
        fi
    else
        echo "❌ 找不到 .config（CWD=$(pwd)），dns-switch 无法选中"
        exit 1
    fi
else
    echo ">>> 非 r68s 机型，跳过 dns-switch 接入"
fi

# ── rust 下载源预检（仅 r68s，纯诊断，不做任何规避）──────────
# dufs（实机在用）的 Makefile 声明 PKG_BUILD_DEPENDS:=rust/host，
# rust 1.96.0 编译需下载 CI LLVM 与 bootstrap；前两轮均在 2 分钟内失败。
# 用户决定保留 dufs，故此处只探测下载源可达性并留在日志里，
# 判断失败是否出在网络环节；rust feed 与 dufs 均保持原样。
if [[ "${DEVICE_MODEL:-}" == "r68s" ]]; then
    echo ">>> rust 下载源预检开始（仅诊断）"
    curl -sI -m 20 https://static.rust-lang.org/dist/rustc-1.96.0-src.tar.xz 2>&1 | head -4 || true
    echo ">>> rust 下载源预检结束"
fi

echo -e "\n===== diy-part2.sh（25.12）执行结束 ====="
echo ""
