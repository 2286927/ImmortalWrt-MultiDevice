#!/bin/sh
# r31 OneCloud 新布局首启自动建 data 分区（与 scripts/onecloud/convert3.sh count=1024 联动）
# p2 rootfs FS 固定 1024M（convert3 dd count=1024，FS 末端 = p2 START 272MiB + 1024MiB = 1296MiB）；
# 本脚本把 p2 表内剩余空间建成 p3 btrfs(compress=zstd,noatime) 挂 /mnt/data，
# 并把 docker data_root 指过去。幂等：p3 已存在直接退出。
# 失败不阻塞启动；日志 /tmp/firstboot-data-partition.log。uci-defaults 跑完即删，
# 若失败可 ssh 手动执行等价命令（parted print 看 p2 END，mkpart primary → mkfs.btrfs）。
exec >/tmp/firstboot-data-partition.log 2>&1

DEV=/dev/mmcblk1
[ -b "$DEV" ] || exit 0
[ -b "${DEV}p3" ] && exit 0

# p2 表内 END（KiB；parted -sm 机器可读格式 2:<start>KiB:<end>KiB:<size>KiB:...）
P2_END_KB=$(parted -sm "$DEV" unit KiB print 2>/dev/null | awk -F: '$1==2{gsub(/KiB/,"",$3);print $3}')
[ -n "$P2_END_KB" ] || exit 0

# ⚠ 与 convert3.sh count=1024 联动：起点 = p2 START(272MiB)+1024MiB(FS)+5MiB 余量
P3_START_KB=$(( (272+1024+5) * 1024 ))
P3_END_KB=$(( P2_END_KB - 1024 ))
[ "$P3_END_KB" -gt "$((P3_START_KB + 1024))" ] || { echo "p2 表内空间不足，跳过 p3"; exit 0; }

parted -s "$DEV" unit KiB mkpart primary ${P3_START_KB}KiB ${P3_END_KB}KiB || exit 0
partprobe "$DEV" 2>/dev/null
sleep 2
[ -b "${DEV}p3" ] || { echo "p3 节点未出现"; exit 0; }

mkfs.btrfs -L data -f "${DEV}p3" || exit 0
mkdir -p /mnt/data
mount -o compress=zstd,noatime "${DEV}p3" /mnt/data || exit 0
UUID=$(blkid -s UUID -o value "${DEV}p3")
[ -n "$UUID" ] || exit 0

uci -q delete fstab.data
uci set fstab.data=mount
uci set fstab.data.target='/mnt/data'
uci set fstab.data.uuid="$UUID"
uci set fstab.data.fstype='btrfs'
uci set fstab.data.options='compress=zstd,noatime'
uci set fstab.data.enabled='1'
uci commit fstab

mkdir -p /mnt/data/docker
uci -q get dockerd.globals >/dev/null || uci set dockerd.globals=globals
uci set dockerd.globals.data_root='/mnt/data/docker'
uci commit dockerd

echo "OK: p3 btrfs uuid=$UUID → /mnt/data；dockerd.globals.data_root=/mnt/data/docker"
exit 0
