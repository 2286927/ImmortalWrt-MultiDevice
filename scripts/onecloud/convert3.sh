#!/bin/bash
# r31 修复版 convert3：onecloud AmlImg 直刷包制作（新布局版）
# r13 修复点（对比配方仓库静态版 convert3.sh）：
#   1. boot 分区改从【本次编译产物 emmc.img 的 p1】提取。原版用 archived 静态素材
#      boot.PARTITION + boot1/boot2.tar.gz，uImage 内核停留在素材制作时代
#      （6.12.71-current-meson），与本次 rootfs kmod（6.12.103+）断配 → 线刷后
#      kmod 全部加载失败、系统残废。
#   2. rootfs 镜像 dd 896M（原版 2000M；r12 用户目标 /dev/root 896M 其他不变）。
#   3. 内核版本一致性硬断言：boot uImage 版本串必须等于 rootfs /lib/modules 目录名。
#   4. 额外产出 onecloud-boot.tar.gz（boot 分区内容打包，供在线升级脚本 v3）。
# r31 新布局（用户 10-27 裁决：放弃本机在线分区手术，构建侧直接产出新布局线刷包）：
#   5. rootfs 896M → 1024M：p2 表内剩余空间留给首启脚本建 p3 btrfs
#      （files/etc/uci-defaults/99-data-partition 首启自动 mkpart + mkfs.btrfs
#      + fstab + dockerd.globals.data_root=/mnt/data/docker）
#   6. 品牌定制：DISTRIB_DESCRIPTION='AI洲长(构建日期)@ImmortalWrt'
#      （直接改挂载后的 rootfs 内容，含 os-release PRETTY_NAME；日期取 runner 本地时区）
#   ⚠ p3 建分区起点与 count=1024 联动（FS 末端=p2 START 272MiB+1024MiB=1296MiB，
#   首启脚本 P3_START=1301MiB，留 5MiB 余量）。改 count 必须同步首启脚本。
set -e

sudo apt install -y android-sdk-libsparse-utils
ver="v0.3.2"
curl -L -o ./AmlImg https://github.com/rmoyulong/AmlImg/releases/download/$ver/AmlImg_${ver}_linux_amd64
chmod +x ./AmlImg
curl -L -o ./uboot.img https://github.com/rmoyulong/u-boot-onecloud/releases/download/Onecloud_Uboot_23.12.24_18.15.09/eMMC.burn.img
./AmlImg unpack ./uboot.img burn/

gunzip openwrt/bin/targets/*/*/*.gz
diskimg=$(ls openwrt/bin/targets/*/*/*.img)
loop=$(sudo losetup --find --show --partscan $diskimg)
sudo rm -rf openwrt.img newroot img boot_mnt
sudo mkdir -p img boot_mnt

# ---- 挂载本次产物的两个分区 ----
sudo mount ${loop}p1 boot_mnt
sudo mount ${loop}p2 img
echo "=== 本次产物 p1(boot) 内容 ==="
ls -la boot_mnt
echo "=== 本次产物 p2(rootfs) 关键内容 ==="
ls img/lib/modules/ || true

# ---- r13 断言1：boot 分区完整性（r17 修正：immortalwrt 25.12 官方 boot 布局
# 为 boot.scr+dtb+uImage 三件套，无也不需要 uInitrd——uInitrd 是旧配方/Armbian
# 静态素材遗留概念；官方 boot.scr 与官方布局自洽，不引用 uInitrd）----
test -f boot_mnt/uImage || { echo "::error::p1 缺 uImage，boot 提取方案失效"; exit 1; }
test -f boot_mnt/boot.scr || { echo "::error::p1 缺 boot.scr，uboot 引导缺失"; exit 1; }
test -f boot_mnt/dtb || { echo "::error::p1 缺 dtb，设备树缺失"; exit 1; }
test -f boot_mnt/uInitrd && echo "NOTE: p1 含 uInitrd（随官方布局）" || true
# ---- r13 断言2：boot 内核与 rootfs kmod 版本一致 ----
KV_ROOTFS=$(ls img/lib/modules/ | head -n1)
KV_BOOT=$(strings boot_mnt/uImage | grep -m1 -o 'Linux version [0-9][^ ]*')
echo "rootfs kmod: $KV_ROOTFS | boot 内核: $KV_BOOT"
echo "$KV_BOOT" | grep -q "Linux version $KV_ROOTFS" || { echo "::error::boot 内核($KV_BOOT) 与 rootfs kmod($KV_ROOTFS) 不匹配"; exit 1; }

# ---- r31: 品牌定制（rootfs 内容级修改，先于 cp 打包） ----
BDATE=$(date +%y.%m.%d)
sudo sed -i -e "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='AI洲长(${BDATE})@ImmortalWrt'/" img/etc/openwrt_release
sudo sed -i -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"AI洲长(${BDATE})@ImmortalWrt\"/" img/usr/lib/os-release
echo "=== r31 品牌定制结果 ==="
grep -h "DISTRIB_DESCRIPTION" img/etc/openwrt_release
grep -h "PRETTY_NAME" img/usr/lib/os-release

# ---- 在线升级资产：boot 分区内容打包 ----
sudo tar -czf onecloud-boot.tar.gz -C boot_mnt .

# ---- boot：从本次 p1 生成 sparse（原版被注释的正道） ----
sudo umount boot_mnt
sudo img2simg ${loop}p1 burn/boot.simg

# ---- rootfs：dd 1024M 新 ext4（r31：896→1024，剩余空间留给首启建 p3 btrfs），拷入本次 p2 全部内容 ----
sudo dd if=/dev/zero of=openwrt.img bs=1M count=1024
sudo mkfs.ext4 -F openwrt.img
sudo mkdir -p newroot
sudo mount openwrt.img newroot
cd img
sudo cp -a ./* ../newroot/
cd ..
sudo sync
sudo umount newroot
sudo umount img
sudo rmdir newroot img boot_mnt
sudo img2simg openwrt.img burn/rootfs.simg
sudo rm -rf openwrt.img
sudo losetup -d $loop

cat <<EOF >>burn/commands.txt
PARTITION:boot:sparse:boot.simg
PARTITION:rootfs:sparse:rootfs.simg
EOF
prefix=$(ls openwrt/bin/targets/*/*/*.img | sed 's/\.img$//')
burnimg=${prefix}.burn.img
./AmlImg pack $burnimg burn/
for f in openwrt/bin/targets/*/*/*.burn.img; do
  sha256sum "$f" >"${f}.sha"
  xz -9 --threads=0 --compress "$f"
done
sudo rm -rf openwrt/bin/targets/*/*/*.img
sudo rm -rf openwrt/bin/targets/*/*/*.gz
# r19 修复（r18 实证死亡点/第四雷）：rm *.gz 会误杀刚归档的 onecloud-boot.tar.gz
# （同为 .gz 后缀；r17 死在更早的 mv 从未走到此行，故雷被掩盖）——mv 必须在清理之后
tgt=$(ls -d openwrt/bin/targets/*/*/ | head -n1)
test -n "$tgt" || { echo "::error::bin/targets 无产物目录"; exit 1; }
mv onecloud-boot.tar.gz "$tgt"
# 归档硬断言：任何静默丢失在此明确报错，不让 ls glob 零匹配背锅
test -f "${tgt}onecloud-boot.tar.gz" || { echo "::error::onecloud-boot.tar.gz 归档丢失"; exit 1; }
echo "=== 直刷包与 boot 资产 ==="
ls -lh openwrt/bin/targets/*/*/*.burn.img.xz openwrt/bin/targets/*/*/onecloud-boot.tar.gz
