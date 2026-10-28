#!/bin/sh
# r38 方案B（2026-10-28 用户裁决）：放弃 p3 btrfs 独立分区（Amlogic 分区表 rootfs size=-1
# 登记到 eMMC 盘尾，p3 建在 p2 表项内部被 GPT overlap 拒绝——r31 方案不可行，弃案）。
# 改为：首启在线扩容 rootfs 至分区全部——p2 表项到盘尾，ext4 只用前 1024M，
# resize2fs 在线扩容吃满剩余（约 6G+），docker(/opt)/数据全在 / 内，无需 btrfs/迁移。
# 幂等：已扩满输出 Nothing to do；在线升级（v9 tar 覆盖保留集）不回退 FS 尺寸，一次扩容永久有效。
# 失败不阻塞启动；日志 /tmp/firstboot-rootfs-grow.log。
exec >/tmp/firstboot-rootfs-grow.log 2>&1

ROOTDEV=$(awk '$2=="/" && $3=="ext4"{print $1; exit}' /proc/mounts)
[ -n "$ROOTDEV" ] || { echo "/ 非独立 ext4 分区（overlay？），跳过"; exit 0; }
[ -x /usr/sbin/resize2fs ] || { echo "resize2fs 不存在，跳过"; exit 0; }
case "$ROOTDEV" in
  /dev/mmcblk*) ;;
  *) echo "根分区 $ROOTDEV 非 eMMC，跳过"; exit 0 ;;
esac

echo "rootfs 在线扩容: $ROOTDEV"
resize2fs "$ROOTDEV"
RC=$?
if [ $RC -eq 0 ]; then
  echo "OK: rootfs 已扩至分区全部（已满则 Nothing to do，幂等）"
else
  echo "resize2fs 失败 rc=$RC（不阻塞启动；可手动重跑: resize2fs $ROOTDEV）"
fi
exit 0
