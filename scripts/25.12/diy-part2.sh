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
AUTOUPDATE_PREFIX="${AUTOUPDATE_PREFIX:-autoupdate-RAX3000M-25.12}"

AUTOUPTATE_SRC="$MYDIR/../common/autoupdate.sh"

if [ -f "$AUTOUPTATE_SRC" ]; then
    mkdir -p files/usr/bin files/etc/crontabs files/etc/config
    install -m 755 "$AUTOUPTATE_SRC" files/usr/bin/autoupdate
    ln -sf autoupdate files/usr/bin/rax-autoupdate

    # 固定 tag autoupdate（多设备资产共存，发版后由 workflow 同步，URL 永不失效）
    GH_BASE="${AUTOUPDATE_BASE_URL:-https://github.com/${GITHUB_REPOSITORY:-OWNER/REPO}/releases/download/autoupdate}"  # 每线固定 tag 发布页，由 workflow env 注入

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

echo -e "\n===== diy-part2.sh（25.12）执行结束 ====="
echo ""
