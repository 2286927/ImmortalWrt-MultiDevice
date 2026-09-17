#!/bin/sh
# ============================================================
# OneCloud 在线升级脚本 v3（r13 固件起适用）
# 路径2 A模式：SSH 一条命令在线升级，全程不拆机不接电脑
# 变更（对比 v2/v1）：
#   1. rootfs + boot 双更新：r13 起内核随 rootfs 更新，boot 分区必须同步
#      （rootfs.tar 不含内核；只换 rootfs 不换 boot → kmod 全部加载失败）
#   2. 包内自洽性校验：boot 包内 uImage 内核版本必须等于 rootfs 包内
#      /lib/modules 目录名（防止 boot/rootfs 资产不配套）
#   3. nginx 感知：r13 固件 LuCI 后端为 nginx；旧 uhttpd 配置修正仅在
#      包内含 /etc/config/uhttpd 时执行，并清理 uhttpd 开机自启残留
# 适用于运行 ImmortalWrt 的 OneCloud S805（eMMC，/dev/root=/dev/mmcblk1p2）
# ============================================================
set -u

REPO="2286927/ImmortalWrt-MultiDevice"
ASSET_ROOTFS="immortalwrt-amlogic-meson8b-thunder-onecloud-rootfs.tar.gz"
ASSET_BOOT="onecloud-boot.tar.gz"
WORK="/opt/rfs-upgrade"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/opt/upgrade-backup-$TS"
BOOT_DEV="/dev/mmcblk1p1"
ROOT_DEV="/dev/mmcblk1p2"
REBOOT="no"

for a in "$@"; do
  case "$a" in
    --reboot) REBOOT="yes" ;;
    --url=*) MANUAL_URL="${a#--url=}" ;;
    --url) shift_next=1 ;;
    *) if [ "${shift_next:-0}" = "1" ]; then MANUAL_URL="$a"; shift_next=0; fi ;;
  esac
done

log(){ echo "[upgrade] $*"; }
die(){ echo "[upgrade][FATAL] $*" >&2; exit 1; }

# ---------------- 预检 ----------------
[ "$(id -u)" = "0" ] || die "请以 root 运行"
[ -b "$BOOT_DEV" ] || die "未找到 boot 分区 $BOOT_DEV"
[ -b "$ROOT_DEV" ] || die "未找到 rootfs 分区 $ROOT_DEV"
FSTYPE=$(awk -v d="$ROOT_DEV" '$1==d{print $3}' /proc/mounts)
echo "$FSTYPE" | grep -q ext4 || die "rootfs 文件系统=$FSTYPE，本脚本仅支持 ext4（squashfs 请线刷）"
RW=$(awk -v d="$ROOT_DEV" '$1==d{print $4}' /proc/mounts)
echo "$RW" | grep -qw rw || die "rootfs 当前只读，无法升级"
FREE_KB=$(df -k /opt 2>/dev/null | awk 'END{print $4}')
[ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 409600 ] && die "/opt 剩余空间不足 400MB（当前 ${FREE_KB}KB）"
AVAIL_MB=$(free -m | awk '/^Mem/{print $7}')
[ -n "$AVAIL_MB" ] && [ "$AVAIL_MB" -lt 80 ] && die "可用内存不足 80MB（当前 ${AVAIL_MB}MB）"
CUR_KV=$(uname -r)
log "当前运行内核: $CUR_KV（升级后将被替换，属正常跨版本升级）"

# ---------------- 下载（双通道探测） ----------------
mkdir -p "$WORK"
FETCH="curl -sfL --connect-timeout 20 --max-time 300"
if [ -n "${MANUAL_URL:-}" ]; then
  URL_ROOTFS="$MANUAL_URL"
  URL_BOOT=$(echo "$MANUAL_URL" | sed "s|$ASSET_ROOTFS|$ASSET_BOOT|")
  log "使用手动指定 URL"
else
  log "探测最新 Release 资产地址（法1: GitHub API）…"
  URL_ROOTFS=$($FETCH "https://api.github.com/repos/$REPO/releases?per_page=30" 2>/dev/null | \
    sed -n "s/.*\"browser_download_url\"[ ]*:[ ]*\"\([^\"]*$ASSET_ROOTFS\)\".*/\1/p" | head -n1)
  URL_BOOT=$($FETCH "https://api.github.com/repos/$REPO/releases?per_page=30" 2>/dev/null | \
    sed -n "s/.*\"browser_download_url\"[ ]*:[ ]*\"\([^\"]*$ASSET_BOOT\)\".*/\1/p" | head -n1)
  if [ -z "$URL_ROOTFS" ]; then
    log "法1 未取到（匿名限流或网络），改用法2: releases/latest 302 重定向…"
    TAG=$($FETCH -I "https://github.com/$REPO/releases/latest" 2>/dev/null | \
      sed -n 's|^[Ll]ocation:[ ]*[^ ]*/tag/||p' | tr -d '\r\n')
    [ -n "$TAG" ] || die "无法确定最新 Release TAG，请用 --url 手动指定"
    URL_ROOTFS="https://github.com/$REPO/releases/download/$TAG/$ASSET_ROOTFS"
    URL_BOOT="https://github.com/$REPO/releases/download/$TAG/$ASSET_BOOT"
    log "TAG=$TAG"
  fi
fi
log "下载 rootfs 包: $URL_ROOTFS"
$FETCH -o "$WORK/rootfs.tar.gz" "$URL_ROOTFS" || die "rootfs 包下载失败"
log "下载 boot 包: $URL_BOOT"
$FETCH -o "$WORK/boot.tar.gz" "$URL_BOOT" || die "boot 包下载失败"
ls -lh "$WORK"

# ---------------- 包校验 ----------------
TGZ="$WORK/rootfs.tar.gz"
BTGZ="$WORK/boot.tar.gz"
log "校验包完整性…"
tar -tzf "$TGZ" >/dev/null 2>&1 || die "rootfs.tar.gz 损坏"
tar -tzf "$BTGZ" >/dev/null 2>&1 || die "boot.tar.gz 损坏"
for f in ./etc/openwrt_release ./bin/busybox; do
  tar -tzf "$TGZ" "$f" >/dev/null 2>&1 || die "rootfs 包缺关键文件 $f"
done
# 毒行检测（r11 事故防线）：uhttpd 配置含非法 tlist 行即拒升
if tar -xzOf "$TGZ" ./etc/config/uhttpd 2>/dev/null | grep -q 'tlist ucode_prefix'; then
  die "rootfs 包含已知中毒配置行（tlist ucode_prefix），拒绝升级"
fi
# r13 起固件应为 nginx 后端：包内应有 nginx 配置或 uhttpd 配置（二选一，用于后续修正分支）
PKG_HAS_NGINX=0; PKG_HAS_UHTTPD=0
tar -tzf "$TGZ" ./etc/config/nginx >/dev/null 2>&1 && PKG_HAS_NGINX=1
tar -tzf "$TGZ" ./etc/config/uhttpd >/dev/null 2>&1 && PKG_HAS_UHTTPD=1
[ "$PKG_HAS_NGINX" = "0" ] && [ "$PKG_HAS_UHTTPD" = "0" ] && die "包内既无 nginx 也无 uhttpd 配置，未知固件，拒绝升级"

# ---------------- 包内自洽性校验：boot 内核 == rootfs kmod ----------------
log "校验 boot/rootfs 内核版本配套性…"
PKG_KV=$(tar -tzf "$TGZ" | sed -n 's|^\./lib/modules/||p' | cut -d/ -f1 | grep -v '^$' | head -n1)
[ -n "$PKG_KV" ] || die "rootfs 包内未找到 /lib/modules 内核目录"
mkdir -p "$WORK/boot-extract"
tar -xzf "$BTGZ" -C "$WORK/boot-extract" ./uImage 2>/dev/null || die "boot 包内无 uImage"
# uImage 头部 name 字段（偏移 32，32B，mkimage 写入 'Linux-<版本>'）——busybox dd 即可，无需解压
BOOT_NAME=$(dd if="$WORK/boot-extract/uImage" bs=1 skip=32 count=32 2>/dev/null | tr -d '\0')
[ -n "$BOOT_NAME" ] || die "无法从 uImage 头部读取镜像名"
log "rootfs kmod: $PKG_KV | boot 镜像名: $BOOT_NAME"
echo "$BOOT_NAME" | grep -q "$PKG_KV" || die "boot 内核($BOOT_NAME) 与 rootfs kmod($PKG_KV) 不配套，拒绝升级"
rm -rf "$WORK/boot-extract"
rm -rf "$WORK/boot-extract"

# ---------------- 备份 ----------------
mkdir -p "$BACKUP"
log "备份 /etc/config、rc.local、shadow 及 boot 分区 → $BACKUP"
cp -a /etc/config "$BACKUP/config"
cp -a /etc/rc.local "$BACKUP/rc.local" 2>/dev/null
cp -a /etc/shadow "$BACKUP/shadow" 2>/dev/null
BOOT_SIZE_BYTES=$(blockdev --getsize64 "$BOOT_DEV" 2>/dev/null || echo 0)
[ "$BOOT_SIZE_BYTES" -gt 0 ] 2>/dev/null && [ "$BOOT_SIZE_BYTES" -lt 536870912 ] && {
  dd if="$BOOT_DEV" of="$BACKUP/boot-p1.img" bs=1M 2>/dev/null || log "警告: boot 分区 dd 备份失败（继续，但无法回滚 boot）"
  log "boot 分区已备份: $(ls -lh "$BACKUP/boot-p1.img" 2>/dev/null | awk '{print $5}')"
} || log "警告: boot 分区大小异常（${BOOT_SIZE_BYTES}B），跳过 dd 备份"

# ---------------- boot 分区更新 ----------------
log "更新 boot 分区 $BOOT_DEV …"
BOOT_MNT=/mnt/boot-upgrade
mkdir -p "$BOOT_MNT"
mount "$BOOT_DEV" "$BOOT_MNT" || die "挂载 $BOOT_DEV 失败"
tar -xzf "$BTGZ" -C "$BOOT_MNT" || { umount "$BOOT_MNT"; die "boot 内容写入失败"; }
sync
umount "$BOOT_MNT"
rmdir "$BOOT_MNT" 2>/dev/null
log "boot 分区更新完成（uboot 本体未动，仅内核/initrd/引导文件）"

# ---------------- rootfs 覆盖（排除保留集） ----------------
log "rootfs 覆盖开始（/etc/config、rc.local、shadow、密码、密钥、证书、/opt、/root 均保留）…"
tar -xzf "$TGZ" -C / \
  --exclude='./etc/config' \
  --exclude='./etc/rc.local' \
  --exclude='./etc/shadow' \
  --exclude='./etc/passwd' \
  --exclude='./etc/group' \
  --exclude='./etc/gshadow' \
  --exclude='./etc/dropbear' \
  --exclude='./etc/uhttpd.crt' \
  --exclude='./etc/uhttpd.key' \
  --exclude='./opt' \
  --exclude='./root' \
  --exclude='./proc' \
  --exclude='./sys' \
  --exclude='./dev' \
  --exclude='./tmp' || die "rootfs 解包失败（系统未破坏，原文件仍在）"
sync
log "rootfs 覆盖完成"

# ---------------- uhttpd/nginx 后端处理（nginx 感知） ----------------
if [ "$PKG_HAS_UHTTPD" = "1" ]; then
  log "目标固件为 uhttpd 后端，执行 uhttpd 配置修正…"
  U=/tmp/uhttpd.fix
  if ! uci -q show uhttpd >/dev/null 2>&1 || ! uci -q get uhttpd.main >/dev/null 2>&1; then
    tar -xzOf "$TGZ" ./etc/config/uhttpd > "$U" 2>/dev/null || die "提取 uhttpd 模板失败"
    cp "$U" /etc/config/uhttpd
  fi
  uci -q delete uhttpd.main.ucode_prefix 2>/dev/null
  uci -q delete uhttpd.main.lua_prefix 2>/dev/null
  uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc' || die "uci add_list 失败"
  uci commit uhttpd || die "uci commit 失败"
  uci -q get uhttpd.main.ucode_prefix >/dev/null || die "ucode_prefix 验证失败"
  log "uhttpd 配置修正完成"
else
  log "目标固件为 nginx 后端（r13+），清理 uhttpd 残留…"
  rm -f /etc/rc.d/*uhttpd* 2>/dev/null
  if [ -f /etc/config/uhttpd ]; then
    mv /etc/config/uhttpd "/etc/config/uhttpd.bak-$TS"
    log "旧 uhttpd 配置已移出（备份为 uhttpd.bak-$TS）"
  fi
  /etc/init.d/nginx enable 2>/dev/null || log "警告: nginx enable 失败（新包自带 init.d/nginx，通常无需手动）"
fi
sync

# ---------------- 完成 ----------------
log "=========================================="
log "升级完成！目标固件内核: $PKG_KV / 后端: $([ "$PKG_HAS_NGINX" = "1" ] && echo nginx || echo uhttpd)"
log "备份位置: $BACKUP（确认系统正常后可删除）"
log "重启后新内核生效：reboot"
if [ "$REBOOT" = "yes" ]; then
  log "--reboot 参数生效，10 秒后自动重启（Ctrl+C 取消）…"
  sleep 10
  reboot
else
  log "请手动执行: reboot"
fi
