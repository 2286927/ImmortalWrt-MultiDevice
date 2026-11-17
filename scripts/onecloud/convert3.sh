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
# r42 离线自足：AmlImg / uboot.img 改为使用仓库内固化文件（tools/onecloud/），
#   不再从 GitHub 实时下载；上游删库或改 release 不再影响本步骤。
set -e

sudo apt install -y android-sdk-libsparse-utils
# 版本锚点：AmlImg v0.3.2（原 curl URL 变量，现记录于 tools/onecloud/README.md）
# r42 离线自足：AmlImg / uboot.img 已固化入库（tools/onecloud/），不再从 GitHub 实时下载
#   来源与校验值见 tools/onecloud/README.md
DEP="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/../.." && pwd)}/tools/onecloud"
test -f "$DEP/AmlImg" || { echo "::error::缺少入库工具 $DEP/AmlImg"; exit 1; }
test -f "$DEP/uboot.img" || { echo "::error::缺少入库 uboot $DEP/uboot.img"; exit 1; }
cp "$DEP/AmlImg" ./AmlImg
chmod +x ./AmlImg
cp "$DEP/uboot.img" ./uboot.img
./AmlImg unpack ./uboot.img burn/

# ---- U-Boot env：随包写入，去掉 autoboot 按键窗口 ----
# 目的：BootROM/U-Boot 的 abortboot 只要在 3 秒窗口内收到任意字节就停在
#       `m8b_onecloud#` 提示符且永不重试；现场无串口时设备直接变砖，只能断电。
# bootdelay=0 → 不再轮询按键；bootretry=10 → bootcmd 失败后自动重试。
# env.PARTITION 必须是「设备原始 env 删掉 ethaddr、改 bootdelay/bootretry」的结果，
# 保留 bootcmd/preboot/upgrade_step 等厂商变量，保证线刷模式行为不变。
cp "$DEP/env.PARTITION" burn/env.PARTITION

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
PARTITION:env:normal:env.PARTITION
EOF
prefix=$(ls openwrt/bin/targets/*/*/*.img | sed 's/\.img$//')
burnimg=${prefix}.burn.img
# ---- env 落包前置校验（构建期失败优于出厂砖）----
test -f burn/env.PARTITION || { echo "::error::burn/env.PARTITION 缺失，env 不会写入直刷包"; exit 1; }
strings burn/env.PARTITION | grep -qx 'bootdelay=0' || { echo "::error::env.PARTITION 未设置 bootdelay=0"; exit 1; }
if strings burn/env.PARTITION | grep -q '^ethaddr='; then
  echo "::error::env.PARTITION 含 ethaddr —— 出厂会让所有设备同 MAC"; exit 1
fi
echo "[env] bootdelay=0 就绪，ethaddr 已剔除"

./AmlImg pack $burnimg burn/

# ---- 回读自检（warn-only：解包命名若与预期不同，不阻断发布）----
if ./AmlImg unpack "$burnimg" envcheck/ >/dev/null 2>&1 && [ -f envcheck/env.PARTITION ]; then
  if strings envcheck/env.PARTITION | grep -qx 'bootdelay=0'; then
    echo "[env] 直刷包内 env 校验通过"
  else
    echo "::warning::直刷包内 env 未含 bootdelay=0，请人工复核"
  fi
else
  echo "::warning::未能解包回读 env（不阻断发布，需人工复核）"
fi
rm -rf envcheck
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
