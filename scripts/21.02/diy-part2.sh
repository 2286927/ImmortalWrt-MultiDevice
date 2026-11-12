#!/bin/bash
#=============================================================
# ImmortalWrt 21.02 DIY 脚本 2（feeds 更新之后、生成编译配置之前执行）
# 21.02 专用精简版：
#  1) 修改默认 LAN IP / 主机名（与 workflow env LAN_IP/LAN_HOSTNAME 同源）
#  2) 值守式升级注入（GitHub Releases 固定 URL 自动检查）
# 注意：不导入 kenzok8/small-package（21.02 官方 feed 已覆盖所需包，
#       small-package 新体系包在 21.02 无法编译）
#=============================================================

echo "===== diy-part2.sh（21.02）开始执行 ====="
echo "执行时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ── 1. 修改 LAN 默认 IP 与主机名 ───────────────────────────────
CONFIG_FILE="package/base-files/files/bin/config_generate"

# 单一数据源：LAN_IP / LAN_HOSTNAME 由 workflow env 传入，本地直跑用默认值
LAN_IP="${LAN_IP:-172.16.7.1}"
LAN_HOSTNAME="${LAN_HOSTNAME:-Newifi-Y1}"

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

# ── 1b. Dropbear SSH 出厂默认配置固化（全设备） ────────────────
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

# ── 2. 值守式升级（GitHub Releases 固定 URL 自动检查）────────────
AUTOUPDATE_PREFIX="${AUTOUPDATE_PREFIX:-autoupdate-NEWIFI-Y1-21.02}"

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

# ── 3. USB 打印机模式切换（p910nd 全共享打印 + usbip 谁扫谁连）──────
# 原理：p910nd(9100 全共享打印) 与 usbip(Windows 独占扫描) 互斥，
#      开机默认打印模式；要扫描时 SSH 执行 y1-scan-mode，扫完 y1-print-mode 恢复。
# M7605D VID:PID = 17ef:561c（换打印机请同步修改脚本内 grep 值）
mkdir -p files/usr/bin files/etc/config

# 3a. 扫描模式脚本：停 p910nd → 确保 usbipd → bind 导出（动态找 M7605D busid）
cat > files/usr/bin/y1-scan-mode <<'SCANEOF'
#!/bin/sh
# 扫描模式：把 USB 打印机导出给 Windows（usbip）——Windows 端 usbip.exe attach 后扫描
/etc/init.d/p910nd stop 2>/dev/null
# 确保 usbipd 已监听 3240（未起则拉起）
if ! netstat -tln 2>/dev/null | grep -q ":3240"; then
    /usr/sbin/usbipd -D &
    sleep 2
fi
BUSID=$(usbip list -l 2>/dev/null | grep "17ef:561c" | grep -oE "[0-9]+-[0-9]+" | head -1)
if [ -n "$BUSID" ]; then
    usbip bind -b "$BUSID"
    echo "$BUSID" > /tmp/y1-usbip-busid
    echo "已切到扫描模式：busid=$BUSID，Windows 执行 usbip.exe attach -r <路由IP> -b $BUSID"
else
    echo "未找到 M7605D (17ef:561c)，请确认打印机已通电并连接 USB 口"
fi
SCANEOF

# 3b. 打印共享模式脚本：解除 usbip 导出 → 恢复 p910nd（9100 全共享）
cat > files/usr/bin/y1-print-mode <<'PRINTEOF'
#!/bin/sh
# 打印共享模式：恢复 p910nd（9100 端口，局域网所有电脑可直接打印）
BUSID=$(cat /tmp/y1-usbip-busid 2>/dev/null)
if [ -n "$BUSID" ] && usbip unbind -b "$BUSID" 2>/dev/null; then
    echo "已解除导出 busid=$BUSID"
else
    echo "未找到已导出的 busid（可能已解除或 USB 口变化），可手动：usbip list -l 后 usbip unbind -b <busid>"
fi
sleep 1
/etc/init.d/p910nd start 2>/dev/null
echo "已切到打印共享模式（9100），所有电脑可直接打印"
PRINTEOF

chmod +x files/usr/bin/y1-scan-mode files/usr/bin/y1-print-mode

# 3e. 短命令：scan-mode / print-mode（等价于 y1-scan-mode / y1-print-mode）
cat > files/usr/bin/scan-mode <<'SHORTEOF'
#!/bin/sh
exec /usr/bin/y1-scan-mode
SHORTEOF
cat > files/usr/bin/print-mode <<'SHORTEOF'
#!/bin/sh
exec /usr/bin/y1-print-mode
SHORTEOF
chmod +x files/usr/bin/scan-mode files/usr/bin/print-mode

# 3c. rc.local：默认打印模式——只起 usbipd 监听，不 bind（避免开机抢占打印机）
cat > files/etc/rc.local <<'RCEOF'
# 默认打印共享模式：p910nd(9100) 全共享；要扫描时 SSH 执行 scan-mode
sleep 3
/etc/init.d/p910nd start 2>/dev/null || true
/usr/sbin/usbipd -D &
exit 0
RCEOF
chmod +x files/etc/rc.local

# 3d. p910nd 默认配置：开机即 9100 全共享打印
cat > files/etc/config/p910nd <<'P910EOF'
config p910nd
	option device '/dev/usb/lp0'
	option port '9100'
	option enabled '1'
P910EOF

echo ">>> USB 打印/扫描模式切换注入完成（y1-scan-mode / y1-print-mode / rc.local / p910nd 默认启用）"

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

echo -e "\n===== diy-part2.sh（21.02）执行结束 ====="
echo ""
