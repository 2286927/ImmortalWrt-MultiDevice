#!/bin/sh
# onecloud-online-upgrade.sh — 玩客云 OneCloud 在线升级（路径2·单槽覆盖）
# 适用: ext4 rootfs 固件（/dev/root 6.9G 整卡或 896M 均可），全程不拆机不接电脑
# 用法:
#   sh onecloud-online-upgrade.sh --check    # 只预检+下载+校验包，不升级
#   sh onecloud-online-upgrade.sh            # 升级，完成后提示手动 reboot
#   sh onecloud-online-upgrade.sh --reboot   # 升级，10 秒后自动重启
#   sh onecloud-online-upgrade.sh --url <rootfs.tar.gz 直链>   # 手动指定升级包
# 保留: /etc/config(网络/密码等配置) /etc/rc.local /etc/shadow(密码) /etc/dropbear
#       /etc/uhttpd.crt|key /opt(Docker数据) /root
# 修正: uhttpd ucode_prefix（LuCI 403 根治，uci 方式写入，不依赖文本格式）
# 拒升: 包内 uhttpd 含毒行(tlist)或缺 ucode_prefix、关键文件缺失、下载不完整
set -u

REPO=2286927/ImmortalWrt-MultiDevice
WORK=/opt/rfs-upgrade
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=/opt/upgrade-backup-$TS
TGZ=$WORK/rootfs.tar.gz

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

MODE=upgrade; AUTO_REBOOT=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --reboot) AUTO_REBOOT=1 ;;
    --url) [ $# -ge 2 ] || die "--url 需要参数"; URL="$2"; shift ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

# ---------- 预检 ----------
[ "$(id -u)" = "0" ] || die "请用 root 运行（当前 uid=$(id -u)）"
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "缺少 curl/wget"
command -v tar >/dev/null 2>&1 || die "缺少 tar"

FSTYPE=$(awk '$2=="/"{print $3; exit}' /proc/mounts)
[ "$FSTYPE" = "ext4" ] || die "根分区文件系统是 ${FSTYPE:-unknown}（仅支持 ext4 rootfs）"
MNT_OPT=$(awk '$2=="/"{print $4; exit}' /proc/mounts)
case "$MNT_OPT" in rw*|*rw,*) : ;; *) mount -o remount,rw / 2>/dev/null || die "根分区不可写且 remount 失败" ;; esac

AVAIL_KB=$(df / | awk 'NR==2{print $4}')
[ "${AVAIL_KB:-0}" -ge 400000 ] || die "根分区剩余 ${AVAIL_KB}KB，不足 400MB"
MEM_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
[ "${MEM_MB:-0}" -ge 80 ] || die "可用内存 ${MEM_MB}MB，不足 80MB"
log "预检通过（rootfs=$FSTYPE 剩余=$((AVAIL_KB/1024))MB 可用内存=${MEM_MB}MB）"

# ---------- 探测下载地址（取最新 Release 的 onecloud rootfs 包；API+重定向双通道） ----------
ASSET=immortalwrt-amlogic-meson8b-thunder-onecloud-rootfs.tar.gz
if [ -z "$URL" ]; then
  log "探测最新 OneCloud Release 升级包..."
  if command -v curl >/dev/null 2>&1; then FETCH="curl -sfL"; else FETCH="wget -qO-"; fi
  # 法1: GitHub API（匿名限流 60 次/小时）
  URL=$($FETCH "https://api.github.com/repos/$REPO/releases?per_page=30" 2>/dev/null | \
        sed -n "s/.*\"browser_download_url\"[ ]*:[ ]*\"\([^\"]*$ASSET\)\".*/\1/p" | head -n1)
  # 法2: releases/latest 302 重定向兜底（不走 API 无限流）
  if [ -z "$URL" ] && command -v curl >/dev/null 2>&1; then
    TAG=$(curl -sI "https://github.com/$REPO/releases/latest" 2>/dev/null | \
          sed -n 's|^[Ll]ocation:[ ]*[^ ]*/tag/||p' | tr -d '\r\n')
    [ -n "$TAG" ] && URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
  fi
  [ -n "$URL" ] || die "未探测到升级包地址（API 限流或网络不通）；可 --url 手动指定"
fi
log "升级包: $URL"

# ---------- 下载 ----------
mkdir -p "$WORK"
log "下载中（约 154MB，视网络 1-10 分钟）..."
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --retry-delay 2 -o "$TGZ" "$URL" || die "下载失败（检查网络或换 --url）"
else
  wget -q -O "$TGZ" "$URL" || die "下载失败（检查网络或换 --url）"
fi
SZ_KB=$(du -k "$TGZ" | awk '{print $1}')
[ "${SZ_KB:-0}" -ge 100000 ] || die "下载不完整（${SZ_KB}KB）"
log "下载完成 $((SZ_KB/1024))MB"

# ---------- 包校验（防毒行版/残缺包/过旧包） ----------
log "校验升级包..."
P=$(tar -xzOf "$TGZ" ./etc/config/uhttpd 2>/dev/null) || die "包内缺 etc/config/uhttpd（非预期包）"
echo "$P" | grep -q 'tlist ucode_prefix' && \
  die "该包 uhttpd 配置含毒行（r11 已知问题）。请等 r11.1+ 修复版 Release 再跑本脚本"
echo "$P" | grep -q 'ucode_prefix' || \
  die "包内 uhttpd 无 ucode_prefix（包版本过旧），拒绝升级"
for f in ./etc/openwrt_release ./bin/busybox ./usr/lib/uhttpd_ucode.so ./lib/apk/packages/uhttpd-mod-ucode.list; do
  tar -tzf "$TGZ" "$f" >/dev/null 2>&1 || die "包内缺 $f（包不完整或版本不符）"
done
log "包校验通过（ucode_prefix 合法、关键文件齐全）"

if [ "$MODE" = "check" ]; then
  rm -f "$TGZ"
  log "检查全部通过。正式升级请去掉 --check 重新运行"
  exit 0
fi

# ---------- 备份 ----------
log "备份 /etc/config、rc.local、shadow → $BACKUP"
mkdir -p "$BACKUP"
cp -a /etc/config "$BACKUP/config" 2>/dev/null || die "备份 /etc/config 失败"
cp -a /etc/rc.local "$BACKUP/rc.local" 2>/dev/null
cp -a /etc/shadow "$BACKUP/shadow" 2>/dev/null

# ---------- 覆盖解包（保留用户数据，只换系统文件） ----------
log "解包覆盖 /（1-3 分钟，期间请勿断电！断电可 USB 线刷兜底）..."
tar -xzf "$TGZ" -C / \
  --exclude='./etc/config' \
  --exclude='./etc/rc.local' \
  --exclude='./etc/shadow' --exclude='./etc/passwd' \
  --exclude='./etc/group' --exclude='./etc/gshadow' \
  --exclude='./etc/dropbear' \
  --exclude='./etc/uhttpd.crt' --exclude='./etc/uhttpd.key' \
  --exclude='./opt' --exclude='./root' \
  --exclude='./proc' --exclude='./sys' --exclude='./dev' --exclude='./tmp' \
  || { echo "ERROR: 解包中断，rootfs 可能不完整：重跑本脚本可修复，或 USB 线刷兜底" >&2; exit 1; }
log "解包完成"

# ---------- uhttpd 修正（uci 方式写入，稳健不依赖文本格式） ----------
log "修正 uhttpd（LuCI ucode_prefix）..."
U=/etc/config/uhttpd
if ! uci -q show uhttpd >/dev/null 2>&1; then
  log "  旧 uhttpd 配置无法被 uci 解析，用包内模板重建"
  tar -xzOf "$TGZ" ./etc/config/uhttpd > "$U" 2>/dev/null || die "提取 uhttpd 模板失败"
fi
if ! uci -q get uhttpd.main >/dev/null 2>&1; then
  log "  uhttpd main 段缺失，用包内模板重建"
  tar -xzOf "$TGZ" ./etc/config/uhttpd > "$U" 2>/dev/null || die "提取 uhttpd 模板失败"
fi
uci -q delete uhttpd.main.ucode_prefix 2>/dev/null
uci -q delete uhttpd.main.lua_prefix 2>/dev/null
uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc' || die "uci add_list 失败"
uci commit uhttpd || die "uci commit 失败"
uci -q get uhttpd.main.ucode_prefix >/dev/null 2>&1 || die "ucode_prefix 写入校验失败"
log "uhttpd: ucode_prefix 已就位（重启后 LuCI 直连生效）"

# ---------- 收尾 ----------
rm -f "$TGZ"
NREV=$(grep DISTRIB_REVISION /etc/openwrt_release | cut -d"'" -f2)
cat <<EOF

====================================================
升级解包完成（rootfs=$NREV）
配置备份: $BACKUP
已保留: 网络配置 / root密码 / rc.local / dropbear / 证书 / /opt(Docker数据) / /root
已更新: 全部系统文件 + Docker 回滚版二进制 + LuCI ucode 修复
说明: 在线覆盖不改分区表，/dev/root 仍为原大小；896M 固定布局需 v2 线刷包
下一步: $( [ "$AUTO_REBOOT" = "1" ] && echo "10 秒后自动重启" || echo "执行 reboot 重启生效" )
重启后验证: uci get uhttpd.main.ucode_prefix ; docker version
====================================================
EOF
[ "$AUTO_REBOOT" = "1" ] && { log "10 秒后重启..."; sleep 10; reboot; }
exit 0
