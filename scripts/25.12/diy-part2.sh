#!/bin/bash
#=============================================================
# ImmortalWrt DIY 脚本 2（feeds 更新之后、生成编译配置之前执行）
#  1) 修改默认 LAN IP / 主机名（与 workflow env LAN_IP/LAN_HOSTNAME 同源，默认 172.16.7.1 / CMCC-RAX3000M）
#  2) 从 kenzok8/small-package 导入第三方软件包，并自动与
#     官方（源码树 + feeds）去重：官方已有的一律使用官方版本
#=============================================================

echo "===== diy-part2.sh（25.12）开始执行 ====="
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

# ── 2. 第三方软件包导入 + 官方自动去重 ─────────────────────────
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
AUTOUPDATE_PREFIX="${AUTOUPDATE_PREFIX:-autoupdate-RAX3000M-25.12}"

AUTOUPTATE_SRC="$MYDIR/../common/autoupdate.sh"

if [ -f "$AUTOUPTATE_SRC" ]; then
    mkdir -p files/usr/bin files/etc/crontabs files/etc/config
    install -m 755 "$AUTOUPTATE_SRC" files/usr/bin/rax-autoupdate

    GH_BASE="https://github.com/${GITHUB_REPOSITORY:-OWNER/REPO}/releases/latest/download"

    cat > files/etc/config/autoupdate <<EOF
config main 'main'
	option enabled '1'
	option base_url '$GH_BASE'
	option prefix '${AUTOUPDATE_PREFIX}'
	option notify_url ''
	option auto_apply '0'
EOF

    echo "${GITHUB_RUN_ID:-0}" > files/etc/autoupdate.build

    if ! grep -q "rax-autoupdate" files/etc/crontabs/root 2>/dev/null; then
        echo "40 4 * * * /usr/bin/rax-autoupdate check" >> files/etc/crontabs/root
    fi

    echo ">>> 值守升级注入完成: prefix=${AUTOUPDATE_PREFIX} run_id=$(cat files/etc/autoupdate.build 2>/dev/null)"
else
    echo "⚠️  未找到 autoupdate.sh，跳过值守升级注入"
fi

echo -e "\n===== diy-part2.sh（25.12）执行结束 ====="
echo ""
