#!/bin/bash
# openclash32.sh 修复版 —— 适配 vernesong/OpenClash core 分支 2026 新结构
# 变更原因（16 连败根因）：
#   1. core 分支 premium/ 目录已删除 -> 原脚本动态获取 clash_tun 链接 404
#   2. classic dev 内核停发 -> core/master/dev/clash-linux-armv7.tar.gz 404
# 修复方案：dev/tun/meta 三个内核槽位统一安装 meta(mihomo) armv7 内核，
#   master/meta 与 dev/meta 双源降级；Geo 数据下载失败不阻断编译（可运行后在线更新）。
# 执行位置：编译树根目录（CWD = /workdir/openwrt）

set -u

# 删除以前设置的所有openclash
rm -rf ./package/OpenClash
rm -rf ./package/luci-app-openclash
rm -rf feeds/kenzo/luci-app-openclash
rm -rf feeds/luci/applications/luci-app-openclash

# 如果 core 文件夹不存在，创建文件夹
if [ ! -d "./files/etc/openclash/core" ]; then
  mkdir -p files/etc/openclash/core
fi

# OpenClash 面板（dev 分支）
git clone --depth=1 --single-branch --branch "dev" \
  https://github.com/vernesong/OpenClash.git package/OpenClash

# meta(mihomo) armv7 内核：双源降级下载
CLASH_TAR=""
for u in \
  "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-armv7.tar.gz" \
  "https://raw.githubusercontent.com/vernesong/OpenClash/core/dev/meta/clash-linux-armv7.tar.gz"; do
  if wget -qO /tmp/clash-armv7.tar.gz "$u"; then
    sz=$(stat -c%s /tmp/clash-armv7.tar.gz 2>/dev/null || echo 0)
    if [ "$sz" -gt 1000000 ]; then
      CLASH_TAR=/tmp/clash-armv7.tar.gz
      echo "openclash 内核下载成功: $u ($sz bytes)"
      break
    fi
  fi
  echo "内核源不可用，尝试下一源: $u"
done

install_core() { # $1 = 槽位名（clash / clash_tun / clash_meta）
  if [ -n "$CLASH_TAR" ]; then
    if ! tar xzOf "$CLASH_TAR" > "files/etc/openclash/core/$1" 2>/dev/null; then
      gunzip -c "$CLASH_TAR" > "files/etc/openclash/core/$1"
    fi
    chmod 755 "files/etc/openclash/core/$1"
    echo "  -> $1 安装完成 ($(stat -c%s "files/etc/openclash/core/$1") bytes)"
  else
    echo "  -> $1 跳过（内核源均不可用，可在 OpenClash 面板内在线更新）"
  fi
}

install_core clash
install_core clash_tun
install_core clash_meta
[ -n "$CLASH_TAR" ] && rm -f "$CLASH_TAR"

# Geo 数据（失败不阻断编译）
wget -qO files/etc/openclash/GeoIP.dat \
  "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
  || echo "GeoIP.dat 下载失败（不影响编译）"
wget -qO files/etc/openclash/GeoSite.dat \
  "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
  || echo "GeoSite.dat 下载失败（不影响编译）"
wget -qO files/etc/openclash/Country.mmdb \
  "https://github.com/alecthw/mmdb_china_ip_list/raw/release/lite/Country.mmdb" \
  || echo "Country.mmdb 下载失败（不影响编译）"

# 异常小的文件（404 页面）直接删除
for f in files/etc/openclash/GeoIP.dat files/etc/openclash/GeoSite.dat files/etc/openclash/Country.mmdb; do
  [ -f "$f" ] && [ "$(stat -c%s "$f")" -lt 10000 ] && rm -f "$f"
done

echo "=== openclash 32位内核与 Geo 数据 ==="
ls -l files/etc/openclash/core/ 2>/dev/null
ls -l files/etc/openclash/*.dat files/etc/openclash/*.mmdb 2>/dev/null
echo "openclash32-fixed 完成"
