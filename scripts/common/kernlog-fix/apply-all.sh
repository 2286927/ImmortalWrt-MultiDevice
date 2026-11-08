#!/bin/sh
# =================================================================================================
# apply-all.sh —— 内核/启动期 7 条 Error 日志的构建期修复注入
#
# 用法：在 OpenWrt/ImmortalWrt 源码树根目录执行（即 diy-part2.sh 的运行位置）
#       sh /path/to/apply-all.sh
#       或在 diy-part2.sh 末尾追加： sh "$GITHUB_WORKSPACE/scripts/common/kernlog-fix/apply-all.sh"
#
# 幂等：重复执行不会重复写入（每处都有 grep 守卫）
# 容错：单个修复失败只告警不中断构建（exit 0），最后统一汇总
# =================================================================================================
set -u

# -------------------------------------------------------------------------------------------------
# 路径约定（两个根不是同一个，必须分开取）：
#   SRC_ROOT  = 当前工作目录 = OpenWrt 源码树（workflow 里是 /workdir/openwrt）
#               target/linux、package/base-files、feeds 都在它下面
#   REPO_ROOT = 本脚本所在仓库根 = scripts/common/kernlog-fix 往上三级
#               recipe/ 在这里（UP 仓为 git clone 的实体目录，MD 仓为 tar 解压产物）
# -------------------------------------------------------------------------------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SRC_ROOT="$(pwd)"

FAIL=0
OK=0

say()  { echo "[kernlog-fix] $*"; }
ok()   { OK=$((OK+1));  echo "[kernlog-fix][OK]   $*"; }
fail() { FAIL=$((FAIL+1)); echo "[kernlog-fix][WARN] $*"; }

# -------------------------------------------------------------------------------------------------
# K1 + U3：内核补丁与内核 config
#   K1  arch/arm/mm/cache-l2x0.c：l2c310_enable() 里非 A9 平台关闭 A9 特性位时用 pr_err 打印，
#       对 Cortex-A5(Meson8b) 属预期行为，级别误标 → 降为 pr_info
#   U3  CONFIG_MEMCG_SWAP：设备实测 CONFIG_MEMCG=y 但无 MEMCG_SWAP，
#       cgroup v2 下 /sys/fs/cgroup/memory.swap.max 不存在 → dockerd 报
#       "WARNING: No swap limit support"，容器 swap 限制失效
# -------------------------------------------------------------------------------------------------
TARGET_DIR="$SRC_ROOT/target/linux/amlogic"
if [ -d "$TARGET_DIR" ]; then
	# U3：内核 config（同时覆盖 target 根与 subtarget 两种布局）
	_found_cfg=0
	for _cfg in $TARGET_DIR/config-6.12 $TARGET_DIR/*/config-6.12; do
		[ -f "$_cfg" ] || continue
		_found_cfg=1
		for _sym in CONFIG_MEMCG_SWAP CONFIG_MEMCG_SWAP_ENABLED; do
			if grep -q "^${_sym}=" "$_cfg"; then
				sed -i "s/^${_sym}=.*/${_sym}=y/" "$_cfg"
			else
				printf '%s=y\n' "$_sym" >> "$_cfg"
			fi
		done
		ok "U3 $_cfg 已启用 MEMCG_SWAP"
	done
	[ $_found_cfg -eq 1 ] || fail "U3 未找到 $TARGET_DIR 下的 config-6.12"

	# U3 兜底：同步写进 .config（defconfig 后仍生效）
	for _sym in CONFIG_KERNEL_MEMCG_SWAP; do
		grep -q "^${_sym}=" "$SRC_ROOT/.config" 2>/dev/null || echo "${_sym}=y" >> "$SRC_ROOT/.config" 2>/dev/null
	done

	# K1：内核补丁（默认关闭，2026-11-08 起）
	#   实测（run 42473647210）：该补丁对 linux-6.12.112 打不上 ——
	#     Applying .../999-l2c310-loglevel.patch
	#     Hunk #1 FAILED at 640.  Patch failed!
	#   → target/linux failed to build，整轮构建失败。
	#   原因：实际内核已被上游 stable 与 lede/amlogic 多层补丁改写，上下文与 vanilla v6.12 不同。
	#   恢复步骤：按新内核上下文重新生成补丁，然后置 KERNLOG_KERNEL_PATCH=1 再启用。
	if [ "${KERNLOG_KERNEL_PATCH:-0}" = "1" ]; then
		_pdir="$TARGET_DIR/patches-6.12"
		[ -d "$_pdir" ] || _pdir="$TARGET_DIR/generic/patches-6.12"
		[ -d "$_pdir" ] || { mkdir -p "$TARGET_DIR/patches-6.12"; _pdir="$TARGET_DIR/patches-6.12"; }
		if [ -f "$HERE/02-kernel-patch-l2c310.patch" ]; then
			cp "$HERE/02-kernel-patch-l2c310.patch" "$_pdir/999-l2c310-loglevel.patch"
			ok "K1 内核补丁已放入 $_pdir（KERNLOG_KERNEL_PATCH=1）"
		else
			fail "K1 缺少 02-kernel-patch-l2c310.patch"
		fi
	else
		say "K1 内核补丁已跳过（默认关闭；该补丁对 6.12.112 无法应用，详见脚本内注释）"
	fi
else
	fail "K1/U3 未找到 $TARGET_DIR，跳过内核层修复"
fi

# -------------------------------------------------------------------------------------------------
# K2：/lib/preinit/79_move_config 写死 mount -t ext4
#   本板 boot 分区 mmcblk1p1 是 vfat，ext4 挂载必失败 → 内核 KERN_ERR
#   "VFS: Can't find ext4 filesystem"。改为按 blkid 实际类型挂载。
#   副作用（正向）：原脚本对本板从未成功挂载过 /boot，sysupgrade.tgz 恢复链实际是断的，修复后可用。
# -------------------------------------------------------------------------------------------------
_bfl="$SRC_ROOT/package/base-files/files/lib/preinit/79_move_config"
if [ -f "$HERE/05-79_move_config" ]; then
	if [ -f "$_bfl" ]; then
		if grep -q 'blkid -s TYPE' "$_bfl"; then
			ok "K2 79_move_config 已是修复版"
		else
			cp "$_bfl" "$_bfl.orig-kernlog" 2>/dev/null
			cp "$HERE/05-79_move_config" "$_bfl"
			chmod 755 "$_bfl"
			ok "K2 79_move_config 已替换为按 fs 类型挂载版本"
		fi
	else
		fail "K2 未找到 $_bfl（该 target 的 base-files 布局可能不同）"
	fi
else
	fail "K2 缺少 05-79_move_config"
fi

# -------------------------------------------------------------------------------------------------
# U2：dockerd 二进制自带 aufs graphdriver 探测
#   实测：锁定 storage-driver=overlay2 后，每次 dockerd 启动仍请求 modprobe aufs
#   （停 dockerd 期间不出现，启动即出现，证明在 dockerd 进程内）。
#   用官方 build tag exclude_graphdriver_aufs 把 aufs driver 排除出编译产物。
# -------------------------------------------------------------------------------------------------
_dk="$SRC_ROOT/feeds/packages/utils/dockerd/Makefile"
if [ -f "$_dk" ]; then
	if grep -q 'exclude_graphdriver_aufs' "$_dk"; then
		ok "U2 dockerd 已含 exclude_graphdriver_aufs"
	elif grep -q '^BUILDTAGS:=' "$_dk"; then
		sed -i 's/^BUILDTAGS:=/BUILDTAGS:= exclude_graphdriver_aufs/' "$_dk"
		ok "U2 已给 dockerd 注入 build tag"
	else
		sed -i '/^include .*golang-package.mk/a BUILDTAGS:= exclude_graphdriver_aufs' "$_dk"
		ok "U2 已给 dockerd 追加 BUILDTAGS"
	fi
else
	fail "U2 未找到 $_dk（feeds 可能未安装或路径不同）"
fi

# -------------------------------------------------------------------------------------------------
# U1：fstools 对"配置文件不存在"报 LOG_ERR
#   block 按 /tmp/overlay/upper/etc/config/fstab → /tmp/overlay/etc/config/fstab → /etc/config/fstab
#   顺序加载；本机根是 ext4 直读、无 overlayfs，前两级恒不存在 → 每次开机 2 条 user.err。
#   patch 后：文件不存在降为 debug，文件存在但解析失败仍保留 err（不丢诊断价值）。
#
#   ⚠️ 默认不启用：该 patch 依赖 block.c 的具体上下文，不同 fstools 版本可能打不上，
#      而 OpenWrt 构建期内 patch 失败会直接中断构建。启用前请先在源码树手工验证：
#        cd build_dir/target-*/fstools-*/ && patch -p1 --dry-run < 该 patch
#      验证通过后再 export ENABLE_FSTOOLS_PATCH=1 重跑本脚本；
#      未启用时该 2 条日志请纳入出厂白名单（它们是非 overlayfs 系统的通用行为）。
# -------------------------------------------------------------------------------------------------
_fp="$SRC_ROOT/package/system/fstools/patches"
if [ "${ENABLE_FSTOOLS_PATCH:-0}" = "1" ]; then
	if [ -d "$SRC_ROOT/package/system/fstools" ]; then
		mkdir -p "$_fp"
		if [ -f "$HERE/03-fstools-quiet-missing-fstab.patch" ]; then
			cp "$HERE/03-fstools-quiet-missing-fstab.patch" "$_fp/100-quiet-missing-fstab.patch"
			ok "U1 fstools 补丁已放入 $_fp（已显式启用，请确认 dry-run 通过）"
		else
			fail "U1 缺少 03-fstools-quiet-missing-fstab.patch"
		fi
	else
		fail "U1 未找到 package/system/fstools"
	fi
else
	say "U1 跳过 fstools 补丁（未设置 ENABLE_FSTOOLS_PATCH=1）→ 该 2 条日志走白名单"
fi

# -------------------------------------------------------------------------------------------------
# U2 配套 + U5/U6 固化：出厂配置文件
#   dockerd：显式 storage_driver=overlay2，防止将来回退到 aufs
#   system ：cronloglevel=8（数值越大越精简；5 实测 75s 刷 12 条，8 只 1 条）
# 注：两个配置文件与脚本同目录扁平存放（06-system / 06-dockerd），
#     因为 GitHub 网页上传不保留子目录结构，扁平命名才能一次传完。
# -------------------------------------------------------------------------------------------------
_rc="$HERE"
_rdir="$REPO_ROOT/recipe/onecloud/files/etc/config"
if [ -d "$_rdir" ]; then
	[ -f "$_rc/06-dockerd" ] && cp "$_rc/06-dockerd" "$_rdir/dockerd" && ok "U2 recipe dockerd 已固化 storage_driver=overlay2"
	[ -f "$_rc/06-system" ] && cp "$_rc/06-system" "$_rdir/system" && ok "U5/U6 recipe system 已固化 cronloglevel=8"
	[ -f "$_rc/06-dockerd" ] || fail "缺少 06-dockerd"
	[ -f "$_rc/06-system" ] || fail "缺少 06-system"
else
	fail "未找到 $REPO_ROOT/recipe/onecloud/files/etc/config，recipe 配置未固化"
fi

# -------------------------------------------------------------------------------------------------
echo "[kernlog-fix] 完成：成功 ${OK} 项，告警 ${FAIL} 项"
[ "$FAIL" -eq 0 ] || echo "[kernlog-fix] 有告警项，请核对上面 WARN 行（构建可继续）"
exit 0
