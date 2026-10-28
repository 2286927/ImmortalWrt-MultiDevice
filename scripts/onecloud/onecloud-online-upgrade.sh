#!/bin/sh
# ============================================================
# OneCloud 在线升级脚本 v9（r13 固件起适用）
# 路径2 A模式：SSH 一条命令在线升级，全程不拆机不接电脑
# 变更（对比 v2/v1）：
#   1. rootfs + boot 双更新：r13 起内核随 rootfs 更新，boot 分区必须同步
#      （rootfs.tar 不含内核；只换 rootfs 不换 boot → kmod 全部加载失败）
#   2. 包内自洽性校验：boot 包内 uImage 内核版本必须等于 rootfs 包内
#      /lib/modules 目录名（防止 boot/rootfs 资产不配套）
#   9. v9（2026-10-27）：
#      ① 空间门槛动态化——真正下载前 HEAD 实得包大小，门槛=rootfs包+boot10.5MB
#         +备份35MB+覆盖缓冲60MB（HEAD 失败按 172MB 上浮估算），替代拍死 400MB，
#         根治 896M rootfs 机型误杀（26.10.27 实机：可用 409.5MB 被 400MB 卡 488KB）
#      ② boot 写入挪至 rootfs 覆盖成功之后——消除"新 boot+半旧 rootfs"起不来窗口；
#         新顺序下覆盖失败时旧 boot+旧 modules 仍配套，可重启回滚旧系统
#      ③ boot dd 备份前置空间检查：可用不足镜像大小时跳过且不留残骸
#         （26.10.27 实机：232MB 可用 dd 256MB 镜像必然爆盘）
#      ④ try_fetch 先清理旧部分文件再下载
#      ⑤ 升级完成后清理非新内核的 /lib/modules/* 残留
#         （26.10.27 实机：覆盖升级残留 6.12.108 旧模块约 100MB）
#      ⑥ 预检/门槛全程打印空间水位（总量/可用/包大小），误杀可自诊
#      ⑦ v7 防线 200MB 底线保留，输出 ×1.2 ext4 落盘参考值——不做全量硬比对：
#         tar 流式覆盖为同名替换+净增量，非双份落盘（26.10.27 实机：可用 232MB
#         完成约 400MB 解包内容的覆盖升级）
#   9. v9.8（2026-10-28）：升级完成段加 rootfs 在线扩容（r38 方案B：resize2fs 吃满分区剩余，幂等）
#   10. v9.9（2026-10-28）：清理被剔除包的守护残留（首例 lighttpd——r40 起固件剔除，
#       覆盖升级不删旧文件，残留 lighttpd 会继续开机自启抢 80 端口致 192.168.1.2 403；
#       包内不含 lighttpd init.d 而本机存在时：停服务+摘自启+删文件，幂等）
#   8. v8（2026-10-26）：--reboot 改 nohup 后台执行——原前台 sleep 10 会被 SSH 会话关闭
#   9. v9.1（2026-10-28）：线刷暴露出厂缺陷修复——dropbear Interface 绑定删除（SSH 不监听根因）+ uhttpd rfc1918_filter 关闭（192.168.1.2 访问 403 根因）
#      （SIGHUP）杀掉，导致 10 秒后不自动重启需手动 reboot；现在断开终端也能按时重启
#   7. v7（2026-10-10）：rootfs 容量预检——896M 固定分区下解包前校验 / 剩余空间 ≥200MB，
#      防未来 rootfs 增长逼近分区上限时升级失败
#   6. v6（2026-09-22）：复用模式来源一致性校验——本地包与目标 Release 不同源时
#      自动清理重下（防旧版本包被误复用升到旧版）；来源标记 /opt/rfs-upgrade/.rootfs_url
#   5. v5（2026-09-22）：空间预检感知包复用——升级包已在位时门槛 400MB→150MB
#   4. v4（2026-09-22）：法1 API 探测改直连+镜像轮询；法2 TAG 增加 onecloud
#      资产存在性校验（防其他设备线 Release 占走 latest）与 TAG 字符集防御；
#      --url 内部变量改名 OPT_URL，防 shell 环境残留误触发手动路径
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

CHECK_ONLY="no"
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY="yes" ;;
    --reboot) REBOOT="yes" ;;
    --url=*) OPT_URL="${a#--url=}" ;;
    --url) shift_next=1 ;;
    *) if [ "${shift_next:-0}" = "1" ]; then OPT_URL="$a"; shift_next=0; fi ;;
  esac
done

log(){ echo "[upgrade] $*"; }
die(){ echo "[upgrade][FATAL] $*" >&2; exit 1; }

# ---------------- 预检 ----------------
[ "$(id -u)" = "0" ] || die "请以 root 运行"
# r26 修正：根分区动态探测。写死 /dev/mmcblk1p2 在 root=/dev/root 或 PARTUUID
# 场景下与 /proc/mounts 首列不匹配，FSTYPE 取空被误判为非 ext4（r21 实机 2026-09-21）。
# 以 mountinfo 根挂载的设备号为权威，经 /sys/block 反查真实设备名；失败时退回写死值。
ROOT_RESOLVED=""
if [ -r /proc/self/mountinfo ]; then
  ROOT_MAJMIN=$(awk '$5=="/"{print $3; exit}' /proc/self/mountinfo)
  if [ -n "$ROOT_MAJMIN" ]; then
    for b in /sys/block/*/*; do
      [ -r "$b/dev" ] || continue
      [ "$(cat "$b/dev")" = "$ROOT_MAJMIN" ] || continue
      ROOT_RESOLVED="/dev/$(basename "$b")"
      break
    done
  fi
fi
if [ -n "$ROOT_RESOLVED" ] && [ -b "$ROOT_RESOLVED" ]; then
  ROOT_DEV="$ROOT_RESOLVED"
  BOOT_DEV="${ROOT_RESOLVED%p[0-9]}p1"
  log "根分区探测: $ROOT_DEV（boot: $BOOT_DEV）"
fi
[ -b "$BOOT_DEV" ] || die "未找到 boot 分区 $BOOT_DEV"
[ -b "$ROOT_DEV" ] || die "未找到 rootfs 分区 $ROOT_DEV"
FSTYPE=$(awk -v d="$ROOT_DEV" '$1==d{print $3; exit}' /proc/mounts)
[ -n "$FSTYPE" ] || FSTYPE=$(awk '$2=="/"{print $3; exit}' /proc/mounts)
echo "$FSTYPE" | grep -q ext4 || die "rootfs 文件系统=$FSTYPE，本脚本仅支持 ext4（squashfs 请线刷）"
RW=$(awk -v d="$ROOT_DEV" '$1==d{print $4; exit}' /proc/mounts)
[ -n "$RW" ] || RW=$(awk '$2=="/"{print $4; exit}' /proc/mounts)
echo "$RW" | grep -qw rw || die "rootfs 当前只读，无法升级（mount options: ${RW:-空}）"
# v5（2026-09-22 实机）: --check 下载的 155MB 包占位 /opt 后，--reboot 预检被自己的包挤死
# （/opt 总可用 ~422MB，下载后剩 256MB < 400MB 误拒）。复用场景仅需备份(~35MB)+覆盖净增量，
# 包已在位且完整时门槛放宽到 150MB。
PKG_READY=0
if [ -s "$WORK/rootfs.tar.gz" ] && tar -tzf "$WORK/rootfs.tar.gz" >/dev/null 2>&1 && \
   [ -s "$WORK/boot.tar.gz" ] && tar -tzf "$WORK/boot.tar.gz" >/dev/null 2>&1; then
  PKG_READY=1
fi
# v9⑥ 空间水位报告；动态门槛推迟到真正下载前按包实际大小计算（见下载段）
FREE_KB=$(df -k /opt 2>/dev/null | awk 'END{print $4}')
TOTAL_KB=$(df -k /opt 2>/dev/null | awk 'END{print $2}')
log "空间水位: rootfs 数据区 ${TOTAL_KB:-?}KB / 可用 ${FREE_KB:-?}KB"
if [ "$PKG_READY" = "1" ]; then
  log "升级包已在位且完整（复用模式，免重下）"
  [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 153600 ] && die "/opt 剩余空间不足 150MB（当前 ${FREE_KB}KB），请清理 /opt 后重试"
else
  # v9: 预检只设极端安全网（30MB）；精确门槛在确定包大小后于下载点检查
  [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 30720 ] && die "/opt 剩余空间不足 30MB（当前 ${FREE_KB}KB），请先清理 /opt 后重试"
fi
CUR_KV=$(uname -r)
log "当前运行内核: $CUR_KV（升级后将被替换，属正常跨版本升级）"

# ---------------- 下载（双通道探测） ----------------
mkdir -p "$WORK"
FETCH="curl -sfL --connect-timeout 20 --max-time 300"
# r26b: GitHub 直连失败时自动轮询加速镜像（2026-09-21 实机：raw.githubusercontent.com 挂死）
GH_MIRRORS=" https://ghproxy.net https://gh-proxy.com https://ghfast.top https://gh.llkk.cc https://github.moeyy.xyz"
try_fetch(){ # $1=输出文件 $2=github原始URL
  _out="$1"; _url="$2"
  rm -f "$_out"   # v9④: 清理旧的部分文件/残留，保证从零开始
  for _m in $GH_MIRRORS ""; do
    if [ -z "$_m" ]; then _u="$_url"; else _u="$_m/$_url"; fi
    log "下载尝试: $_u"
    if curl -sfL --connect-timeout 10 --max-time 900 --speed-time 30 --speed-limit 1024 -o "$_out" "$_u" && [ -s "$_out" ]; then
      return 0
    fi
    rm -f "$_out"
  done
  return 1
}
if [ -n "${OPT_URL:-}" ]; then
  URL_ROOTFS="$OPT_URL"
  URL_BOOT=$(echo "$OPT_URL" | sed "s|$ASSET_ROOTFS|$ASSET_BOOT|")
  log "使用手动指定 URL"
else
  log "探测最新 Release 资产地址（法1: GitHub API，直连+镜像轮询）…"
  for _m in $GH_MIRRORS ""; do
    if [ -z "$_m" ]; then _u="https://api.github.com/repos/$REPO/releases?per_page=30"; else _u="$_m/https://api.github.com/repos/$REPO/releases?per_page=30"; fi
    API_JSON=$(curl -sfL --connect-timeout 10 --max-time 60 "$_u" 2>/dev/null)
    [ -n "$API_JSON" ] || continue
    URL_ROOTFS=$(echo "$API_JSON" | sed -n "s/.*\"browser_download_url\"[ ]*:[ ]*\"\([^\"]*$ASSET_ROOTFS\)\".*/\1/p" | head -n1)
    URL_BOOT=$(echo "$API_JSON" | sed -n "s/.*\"browser_download_url\"[ ]*:[ ]*\"\([^\"]*$ASSET_BOOT\)\".*/\1/p" | head -n1)
    if [ -n "$URL_ROOTFS" ] && [ -n "$URL_BOOT" ]; then
      log "API 探测成功（通道: ${_m:-直连}）"
      break
    fi
  done
  if [ -z "${URL_ROOTFS:-}" ]; then
    log "法1 未取到（匿名限流或网络），改用法2: releases/latest 302 重定向…"
    TAG=""
    for _m in $GH_MIRRORS ""; do
      if [ -z "$_m" ]; then _u="https://github.com/$REPO/releases/latest"; else _u="$_m/https://github.com/$REPO/releases/latest"; fi
      TAG=$(curl -sfIL --connect-timeout 10 "$_u" 2>/dev/null | sed -n 's|^[Ll]ocation:[ ]*[^ ]*/tag/||p' | head -n1 | tr -d '\r\n')
      [ -n "$TAG" ] && { log "TAG 探测成功（通道: ${_m:-直连}）"; break; }
    done
    [ -n "$TAG" ] || die "无法确定最新 Release TAG，请用 --url 手动指定"
    echo "$TAG" | grep -qE '^[A-Za-z0-9._-]+$' || die "TAG 异常（$TAG），请用 --url 手动指定"
    URL_ROOTFS="https://github.com/$REPO/releases/download/$TAG/$ASSET_ROOTFS"
    URL_BOOT="https://github.com/$REPO/releases/download/$TAG/$ASSET_BOOT"
    # releases/latest 为全仓语义：其他设备线发包会占走 latest（2026-09-22 实机 r68s 占位实证），
    # 必须验证该 TAG 下确实存在 onecloud 资产才可用
    _ok=""
    for _m in $GH_MIRRORS ""; do
      if [ -z "$_m" ]; then _u="$URL_ROOTFS"; else _u="$_m/$URL_ROOTFS"; fi
      if curl -sfIL --connect-timeout 10 --max-time 60 "$_u" >/dev/null 2>&1; then _ok="${_m:-直连}"; break; fi
    done
    [ -n "$_ok" ] || die "最新 Release($TAG) 不含 $ASSET_ROOTFS（latest 被其他设备线占用），请用 --url 手动指定 onecloud 资产地址"
    log "资产存在性校验通过（通道: $_ok）"
    log "TAG=$TAG"
  fi
fi
log "下载 rootfs 包: $URL_ROOTFS"
_reuse_ok=0
if [ -s "$WORK/rootfs.tar.gz" ] && tar -tzf "$WORK/rootfs.tar.gz" >/dev/null 2>&1; then
  # v6: 来源一致性校验——本地包必须与本次目标 Release 同源，防止旧版本包被误复用升级
  _saved=$(cat "$WORK/.rootfs_url" 2>/dev/null)
  if [ "$_saved" = "$URL_ROOTFS" ]; then
    _reuse_ok=1
  else
    log "本地包与目标版本不一致（旧: ${_saved:-无记录}），清理后重新下载"
    rm -f "$WORK/rootfs.tar.gz" "$WORK/boot.tar.gz" "$WORK/.rootfs_url"
  fi
fi
if [ "$_reuse_ok" = "1" ]; then
  log "本地包与目标版本一致，跳过下载（复用模式）"
else
  # v9① 动态空间门槛：rootfs包实际大小(HEAD 实得) + boot 10.5MB + 备份35MB + 覆盖缓冲60MB
  _pk_kb=0
  for _m in $GH_MIRRORS ""; do
    if [ -z "$_m" ]; then _u="$URL_ROOTFS"; else _u="$_m/$URL_ROOTFS"; fi
    _len=$(curl -sfIL --connect-timeout 8 --max-time 30 "$_u" 2>/dev/null | tr -d '\r' | grep -i '^content-length' | tail -n1 | awk '{print $2}')
    case "$_len" in ''|*[!0-9]*) _len="";; esac
    [ -n "$_len" ] && { _pk_kb=$((_len/1024)); break; }
  done
  [ "$_pk_kb" -gt 51200 ] || _pk_kb=176128   # HEAD 失败/异常：按 172MB 上浮估算（10-23 包实测 162.1MB）
  REQ_KB=$((_pk_kb + 10752 + 35840 + 61440))
  FREE_KB=$(df -k /opt 2>/dev/null | awk 'END{print $4}')
  log "动态门槛: rootfs包 $((_pk_kb/1024))MB + boot 10.5MB + 备份35MB + 覆盖缓冲60MB = 需 $((REQ_KB/1024))MB，当前可用 $(( ${FREE_KB:-0}/1024 ))MB"
  if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt "$REQ_KB" ]; then
    die "/opt 剩余 $((FREE_KB/1024))MB < 动态门槛 $((REQ_KB/1024))MB。可: 清理 /opt 大文件；或释放 ext4 保留块: opkg install e2fsprogs && tune2fs -m 0 $ROOT_DEV（实机实证 +44.8MB，一次性永久生效）"
  fi
  try_fetch "$WORK/rootfs.tar.gz" "$URL_ROOTFS" || die "rootfs 包下载失败（直连+镜像均失败）"
  echo "$URL_ROOTFS" > "$WORK/.rootfs_url"
fi
log "下载 boot 包: $URL_BOOT"
if [ -s "$WORK/boot.tar.gz" ] && tar -tzf "$WORK/boot.tar.gz" >/dev/null 2>&1; then
  log "已存在通过校验的 boot 包，跳过下载（--check 复用）"
else
  try_fetch "$WORK/boot.tar.gz" "$URL_BOOT" || die "boot 包下载失败（直连+镜像均失败）"
fi
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

# ---------------- boot 分区可挂载预检（vfat 支持验证，任何模式都做） ----------------
BOOT_MNT_TEST=/mnt/boot-precheck-$$
mkdir -p "$BOOT_MNT_TEST"
if mount "$BOOT_DEV" "$BOOT_MNT_TEST" 2>/dev/null; then
  if [ -f "$BOOT_MNT_TEST/uImage" ]; then
    log "boot 分区挂载正常，当前 uImage 在位（$(ls -lh "$BOOT_MNT_TEST/uImage" | awk '{print $5}')）"
  else
    log "警告: boot 分区可挂载但根目录未见 uImage（布局核对）"
  fi
  umount "$BOOT_MNT_TEST"
else
  die "boot 分区挂载失败（内核缺 vfat/fat 支持？）——boot 更新无法进行，请勿继续，反馈或改用线刷"
fi
rmdir "$BOOT_MNT_TEST" 2>/dev/null

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

# ---------------- --check 出口（未做任何写盘操作） ----------------
if [ "$CHECK_ONLY" = "yes" ]; then
  log "=========================================="
  log "--check 全部通过：预检/包完整性/毒行防线/内核配套性/boot 挂载均 OK"
  log "本机未做任何修改。确认无误后执行正式升级: sh $0 --reboot"
  exit 0
fi

# ---------------- 备份 ----------------
mkdir -p "$BACKUP"
log "备份 /etc/config、rc.local、shadow 及 boot 分区 → $BACKUP"
cp -a /etc/config "$BACKUP/config"
cp -a /etc/rc.local "$BACKUP/rc.local" 2>/dev/null
cp -a /etc/shadow "$BACKUP/shadow" 2>/dev/null
# v9③: boot 备份 = dd|gzip 流式压缩（FAT 分区 ~95% 空簇，256M 镜像 gzip 后约 10-20MB，
#       232MB 可用场景也能完整备份——流式写不产生全尺寸中间文件，爆盘问题从根上消除）
#       三层防线：① gunzip -t 完整性校验（dd 半途失败/磁盘写满都不会留坏档）
#                 ② 先落 /tmp(tmpfs RAM) 再 mv 到 $BACKUP——rootfs 空间不足时 mv 失败零残骸
#                 ③ 任一环节失败 rm 残骸并继续升级（boot 无法回滚时走线刷兜底）
BOOT_SIZE_BYTES=$(blockdev --getsize64 "$BOOT_DEV" 2>/dev/null || echo 0)
if [ "$BOOT_SIZE_BYTES" -gt 0 ] 2>/dev/null && [ "$BOOT_SIZE_BYTES" -lt 536870912 ]; then
  rm -f /tmp/boot-p1.img.gz
  if dd if="$BOOT_DEV" bs=1M 2>/dev/null | gzip -6 > /tmp/boot-p1.img.gz && gunzip -t /tmp/boot-p1.img.gz 2>/dev/null; then
    if mv /tmp/boot-p1.img.gz "$BACKUP/boot-p1.img.gz" 2>/dev/null; then
      log "boot 分区已压缩备份: $(ls -lh "$BACKUP/boot-p1.img.gz" 2>/dev/null | awk '{print $5}')（回滚: gunzip -c boot-p1.img.gz | dd of=$BOOT_DEV bs=1M）"
    else
      rm -f /tmp/boot-p1.img.gz
      log "警告: /opt 可用不足（压缩档落盘失败），跳过 boot 备份——本机无法回滚 boot，升级失败需线刷"
    fi
  else
    rm -f /tmp/boot-p1.img.gz
    log "警告: boot 分区压缩备份失败（dd/gzip 中断），已清理残骸——本机无法回滚 boot，升级失败需线刷"
  fi
else
  log "警告: boot 分区大小异常（${BOOT_SIZE_BYTES}B），跳过备份"
fi

# ---------------- rootfs 容量预检（v7：896M 固定分区防线） ----------------
# r12 起 rootfs 固定 896M 不再首启扩容；升级为原地 tar 覆盖（保留集除外），
# 需确保 / 分区剩余空间足够。实测 rootfs 解包约 388M、分区 896M 余量充足；
# 此处防线防止未来 rootfs 增长逼近分区上限时在线升级静默失败。
log "rootfs 容量预检…"
RFS_MB=$(tar -tvzf "$TGZ" 2>/dev/null | awk '{s+=$3} END{print int(s/1048576)}')
RFS_NEED_MB=$(( ${RFS_MB:-0} * 12 / 10 ))   # v9⑦: ×1.2 ext4 块对齐/元数据开销，作参考值输出
ROOT_FREE_MB=$(df -m / 2>/dev/null | awk 'NR==2{print $4}')
log "新 rootfs 解包约 ${RFS_MB:-?}MB（ext4 落盘约 ${RFS_NEED_MB:-?}MB），/ 分区剩余 ${ROOT_FREE_MB:-?}MB"
# v9⑦: 200MB 底线保留；不做全量落盘硬比对——tar 流式覆盖为同名替换+净增量，非双份落盘
# （26.10.27 实机：可用 232MB 成功完成约 400MB 解包内容的覆盖升级）
[ -n "$RFS_MB" ] && [ -n "$ROOT_FREE_MB" ] && [ "$ROOT_FREE_MB" -lt 200 ] && \
  die "rootfs 分区剩余空间不足 200MB（当前 ${ROOT_FREE_MB}MB），请清理 /opt 或扩分区后重试"

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
  --exclude='./tmp' || die "rootfs 解包失败：系统处于混合状态（部分文件已替换为新版）。boot 分区与旧内核模块未动，此时 reboot 可回滚旧系统；请保留 $BACKUP 备份并立即反馈排障，或线刷恢复"
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

# ---------------- v9.1: 线刷暴露出厂缺陷修复（保配置升级同样生效，幂等） ----------------
# ①dropbear 出厂模板 option Interface 'lan'——新布局（Bypass 旁路由）无 lan 接口，绑定失败
#   → dropbear 不监听任何地址 → SSH 无法连接。删除绑定=全接口监听（配合固件 -B 空密码放行）。
# ②uhttpd rfc1918_filter=1 拦截 Host 为 RFC1918 私网 IPv4 的请求（DNS rebinding 防护误伤旁路由
#   固定 IP 访问：192.168.1.2 → 403 Forbidden；IPv6 链路本地不受限）。关闭。
if uci -q get dropbear.@dropbear[0] >/dev/null 2>&1; then
  if uci -q get dropbear.@dropbear[0].interface >/dev/null 2>&1; then
    uci -q delete dropbear.@dropbear[0].interface
    uci -q commit dropbear
    /etc/init.d/dropbear restart 2>/dev/null
    log "①已删除 dropbear Interface 绑定 → 全接口监听（SSH 修复）"
  fi
fi
if uci -q get uhttpd.main >/dev/null 2>&1; then
  [ "$(uci -q get uhttpd.main.rfc1918_filter)" = "0" ] || {
    uci -q set uhttpd.main.rfc1918_filter='0'
    uci -q commit uhttpd
    /etc/init.d/uhttpd restart 2>/dev/null || true
    log "②已关闭 uhttpd rfc1918_filter（192.168.1.2 访问 403 修复）"
  }
fi

# ---------------- v9.9: 清理被剔除包的守护残留（r40 起固件剔除 lighttpd） ----------------
# 覆盖升级只覆盖同名文件、不删除旧文件：旧固件里的 lighttpd（开机抢 IPv4:80，
# 192.168.1.2 403 元凶）升级后仍残留并自启——"固件已剔除"但实机 80 仍被占。
# 包内已不含 lighttpd init.d 而本机存在时：停服务→摘自启→删文件（幂等；r39 及更早包内含 lighttpd，不触发）。
if ! tar -tzf "$TGZ" ./etc/init.d/lighttpd >/dev/null 2>&1; then
  if [ -x /etc/init.d/lighttpd ]; then
    /etc/init.d/lighttpd stop >/dev/null 2>&1
    /etc/init.d/lighttpd disable >/dev/null 2>&1
    rm -f /etc/init.d/lighttpd
    rm -f /etc/rc.d/*lighttpd*
    rm -f /etc/config/lighttpd
    rm -rf /etc/lighttpd
    rm -f /usr/sbin/lighttpd
    rm -rf /usr/lib/lighttpd
    log "v9.9: 已清理 lighttpd 残留（新固件不再携带；80 端口归还 uhttpd）"
  else
    log "v9.9: 新固件不含 lighttpd，本机亦无残留，无需处理"
  fi
fi

# ---------------- v9.8: rootfs 在线扩容（r38 方案B，幂等） ----------------
# 旧机首启未扩容的（26.10.27 及更早），升级 tar 覆盖后顺手扩至分区全部；
# 已扩满的输出 Nothing to do 无副作用。FS 尺寸在 tar 覆盖升级下不回退，一次扩容永久有效。
if [ -x /usr/sbin/resize2fs ] && [ "$FSTYPE" = "ext4" ]; then
  _GL=$(resize2fs "$ROOT_DEV" 2>&1)
  log "rootfs 扩容: $_GL"
fi

# ---------------- v9⑤: 清理旧内核模块残留 ----------------
# 覆盖升级不删除旧文件：旧内核 modules 目录会永久残留（26.10.27 实机残留 6.12.108 约 100MB）。
# 运行中内核模块已全部载入内存，磁盘目录删除无影响；重启后仅新内核使用。
for d in /lib/modules/*; do
  [ -d "$d" ] || continue
  _kv=$(basename "$d")
  [ "$_kv" = "$PKG_KV" ] && continue
  rm -rf "$d" 2>/dev/null && log "已清理旧内核模块残留: $_kv"
done
sync

# ---------------- boot 分区更新（v9②: 挪至 rootfs 覆盖成功之后） ----------------
# 原顺序"先 boot 后 rootfs"存在爆盘窗口：rootfs 覆盖中途失败 = 新 boot 内核 + 半旧 rootfs，
# kmod 不配套可能起不来。新顺序下覆盖失败时旧 boot+旧 modules 仍配套，可重启回滚。
log "更新 boot 分区 $BOOT_DEV …"
BOOT_MNT=/mnt/boot-upgrade
mkdir -p "$BOOT_MNT"
mount "$BOOT_DEV" "$BOOT_MNT" || die "挂载 $BOOT_DEV 失败"
tar -xzf "$BTGZ" -C "$BOOT_MNT" || { umount "$BOOT_MNT"; die "boot 内容写入失败：rootfs 已更新为新版而 boot 仍为旧版，请勿 reboot（内核与模块不配套），立即反馈或线刷"; }
sync
umount "$BOOT_MNT"
rmdir "$BOOT_MNT" 2>/dev/null
log "boot 分区更新完成（uboot 本体未动，仅内核/initrd/引导文件）"
sync

# ---------------- 完成 ----------------
log "=========================================="
log "升级完成！目标固件内核: $PKG_KV / 后端: $([ "$PKG_HAS_NGINX" = "1" ] && echo nginx || echo uhttpd)"
log "备份位置: $BACKUP（确认系统正常后可删除）"
log "重启后新内核生效：reboot"
if [ "$REBOOT" = "yes" ]; then
  nohup sh -c "sleep 10 && sync && reboot" >/dev/null 2>&1 &
  RB_PID=$!
  log "--reboot 参数生效，10 秒后自动重启（断开 SSH 也不影响；取消: kill $RB_PID）…"
else
  log "请手动执行: reboot"
fi
