#!/bin/bash
#=============================================================
# ImmortalWrt DIY 脚本 2（feeds 更新之后、生成编译配置之前执行）
#  1) 修改默认 LAN IP / 主机名（与 workflow env LAN_IP/LAN_HOSTNAME 同源，默认 172.16.7.1 / CMCC-RAX3000M）
#  2) 从 kenzok8/small-package 导入第三方软件包，并自动与
#     官方同名清理（v2.2 第三方优先）：与第三方重复时移除官方同名，使用第三方版本
#=============================================================

echo "===== diy-part2.sh（24.10）开始执行 ====="
echo "执行时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

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

# ── 3. 值守式升级（GitHub Releases 固定 URL 自动检查）────────────
# 多设备仓库：AUTOUPDATE_PREFIX 由各 workflow env 注入（缺省保持 v2.1 RAX3000M 行为）
AUTOUPDATE_PREFIX="${AUTOUPDATE_PREFIX:-autoupdate-RAX3000M-24.10}"

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

echo -e "\n===== diy-part2.sh（24.10）执行结束 ====="
echo ""
