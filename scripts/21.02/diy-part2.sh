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

# ── 2. 值守式升级（GitHub Releases 固定 URL 自动检查）────────────
AUTOUPDATE_PREFIX="${AUTOUPDATE_PREFIX:-autoupdate-NEWIFI-Y1-21.02}"

AUTOUPTATE_SRC="$MYDIR/../common/autoupdate.sh"

if [ -f "$AUTOUPTATE_SRC" ]; then
    mkdir -p files/usr/bin files/etc/crontabs files/etc/config
    install -m 755 "$AUTOUPTATE_SRC" files/usr/bin/autoupdate
    ln -sf autoupdate files/usr/bin/rax-autoupdate

    GH_BASE="https://github.com/${GITHUB_REPOSITORY:-OWNER/REPO}/releases/latest/download"

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

echo -e "\n===== diy-part2.sh（21.02）执行结束 ====="
echo ""
