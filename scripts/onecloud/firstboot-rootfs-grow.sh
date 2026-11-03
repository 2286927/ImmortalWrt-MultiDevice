#!/bin/sh
# r38 方案B（2026-10-28 用户裁决）：放弃 p3 btrfs 独立分区（Amlogic 分区表 rootfs size=-1
# 登记到 eMMC 盘尾，p3 建在 p2 表项内部被 GPT overlap 拒绝——r31 方案不可行，弃案）。
# 改为：首启在线扩容 rootfs 至分区全部——p2 表项到盘尾，ext4 只用前 1024M，
# resize2fs 在线扩容吃满剩余（约 6G+），docker(/opt)/数据全在 / 内，无需 btrfs/迁移。
#
# r45 修复（2026-11-03 实机定位）：原实现按 `case "$ROOTDEV" in /dev/mmcblk*)` 判断，
#   但 /proc/mounts 里根分区源显示为 **/dev/root 别名**，且该设备节点在本固件上
#   根本不存在（`ls /dev/root` → No such file），于是永远落到 `*)` 分支
#   "根分区 /dev/root 非 eMMC，跳过" —— 扩容从未生效，用户设备长期停留在 973M。
#   实机取证：
#     /proc/mounts        → /dev/root / ext4 rw,noatime
#     /proc/self/mountinfo → 13 1 179:2 / / rw - ext4 /dev/root rw
#     /sys/dev/block/179:2/uevent → DEVNAME=mmcblk1p2 DEVTYPE=partition
#   修复：改用 mountinfo 的 major:minor 反查 /sys/dev/block/<mm>/uevent 还原真实设备名。
#
# 幂等：已扩满输出 Nothing to do；在线升级（v9 tar 覆盖保留集）不回退 FS 尺寸，一次扩容永久有效。
# 失败不阻塞启动；日志 /tmp/firstboot-rootfs-grow.log。
exec >/tmp/firstboot-rootfs-grow.log 2>&1

ROOTFS_SRC=$(awk '$2=="/" && $3=="ext4"{print $1; exit}' /proc/mounts)
if [ -z "$ROOTFS_SRC" ]; then
	echo "/ 非独立 ext4 分区（overlay？），跳过"
	exit 0
fi

# 解析真实块设备：/dev/mmcblkXpY 直接用；/dev/root 等别名走 major:minor 反查
case "$ROOTFS_SRC" in
/dev/mmcblk*)
	ROOTDEV="$ROOTFS_SRC"
	;;
*)
	MM=$(awk '$5=="/"{print $3; exit}' /proc/self/mountinfo)
	if [ -n "$MM" ]; then
		DEVNAME=$(sed -n 's/^DEVNAME=//p' "/sys/dev/block/$MM/uevent" 2>/dev/null)
		if [ -n "$DEVNAME" ]; then
			ROOTDEV="/dev/$DEVNAME"
		fi
	fi
	;;
esac

case "$ROOTDEV" in
/dev/mmcblk*) ;;
*)
	echo "无法把根分区解析为 eMMC 块设备（mounts 源=$ROOTFS_SRC，解析结果=${ROOTDEV:-空}），跳过"
	exit 0
	;;
esac

if [ ! -b "$ROOTDEV" ]; then
	echo "块设备 $ROOTDEV 不存在，跳过"
	exit 0
fi

[ -x /usr/sbin/resize2fs ] || { echo "resize2fs 不存在，跳过"; exit 0; }

echo "rootfs 在线扩容: $ROOTDEV（/proc/mounts 源为 $ROOTFS_SRC）"
resize2fs "$ROOTDEV"
RC=$?
if [ $RC -eq 0 ]; then
	echo "OK: rootfs 已扩至分区全部（已满则 Nothing to do，幂等）"
else
	echo "resize2fs 失败 rc=$RC（不阻塞启动；可手动重跑: resize2fs $ROOTDEV）"
fi
exit 0
