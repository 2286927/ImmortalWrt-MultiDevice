#!/bin/bash
#==============================================================================
# scripts/common/package-sync.sh  (v2.2)
#------------------------------------------------------------------------------
# 从 kenzok8/small-package 导入白名单第三方软件包。
#
# v2.2 策略反转（2026-09-20 指定，全设备生效）：
#   第三方与官方重复时「第三方优先」——移除官方同名包（源码树 + feeds 源
#   目录 + feeds 安装链接），导入第三方版本进入编译。
#
# v2.1 历史：官方已有的一律使用官方版本（跳过第三方导入）。
#
# 共同解决：
#   1) 第三方与官方重复导致的"版本撕裂"
#   2) 重复包名引发的编译冲突/告警
#
# 调用方式：由 diy-part2.sh 在 feeds update/install 之后执行
#   bash "$GITHUB_WORKSPACE/scripts/common/package-sync.sh"
#
# 特性：
#   - 官方检测覆盖：基础源码树 package/<...> 与全部官方 feeds
#     （packages / luci / routing / telephony / video）
#   - 支持嵌套目录查找（small-package 内任意含 Makefile 的同名目录）
#   - 支持强制第三方例外清单 FORCE_THIRD_PARTY_PKGS
#   - 全量日志：导入 / 跳过（官方已提供）/ 缺失（small 无此包）
#==============================================================================

set -u

SMALL_REPO_URL="${SMALL_REPO_URL:-https://github.com/kenzok8/small-package.git}"
SMALL_TMP_DIR="package/small-package-tmp"

# v2.2 起全局第三方优先，本清单仅为兼容保留（逻辑上已无实际作用）
FORCE_THIRD_PARTY_PKGS=(
  # 例如: "luci-app-xxx"
)

is_force_third_party() {
  local p
  for p in ${FORCE_THIRD_PARTY_PKGS[@]+"${FORCE_THIRD_PARTY_PKGS[@]}"}; do
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

# 是否为官方已提供的包
is_official_pkg() {
  local pkg="$1"
  # 基础源码树（顶层 + 分类目录）；必须排除第三方临时克隆目录
  # small-package-tmp（v2.1 潜伏 bug：find 扫入该目录导致白名单包
  # 被误判"官方已有"而从未导入）
  [ -e "package/$pkg" ] && return 0
  find package -maxdepth 3 -type d -name "$pkg" -not -path "package/small-package-tmp*" -print -quit 2>/dev/null | grep -q . && return 0
  # 官方 feeds
  find feeds -maxdepth 3 -type d -name "$pkg" -print -quit 2>/dev/null | grep -q . && return 0
  return 1
}

# 移除官方同名包的全部落点（基础源码树 + feeds 源目录 + feeds 安装链接），
# 确保构建树中该包名唯一，由第三方版本接管
remove_official_pkg() {
  local pkg="$1" p
  local paths
  paths=$(
    { find package -maxdepth 3 \( -type d -o -type l \) -name "$pkg" -not -path "package/small-package-tmp*" 2>/dev/null
      find feeds -maxdepth 3 -type d -name "$pkg" 2>/dev/null; } | sort -u
  )
  for p in $paths; do
    # 符号链接用 -L 判断（-e 对断链为假）
    [ -e "$p" ] || [ -L "$p" ] || continue
    rm -rf "$p"
    echo "  ↳ 移除官方同名：$p（改用第三方版本）"
  done
}

# 在 small-package 中查找包目录（含嵌套，必须含 Makefile）
find_in_small() {
  local pkg="$1"
  [ -f "$SMALL_TMP_DIR/$pkg/Makefile" ] && { echo "$SMALL_TMP_DIR/$pkg"; return 0; }
  find "$SMALL_TMP_DIR" -mindepth 2 -maxdepth 3 -type d -name "$pkg" \
    -exec test -f '{}/Makefile' ';' -print -quit 2>/dev/null
}

sync_small_packages() {
  # 工作目录校验：必须在 openwrt 源码根目录且 feeds 已更新
  if [ ! -f rules.mk ] || [ ! -d feeds ]; then
    echo "❌ package-sync.sh 必须在 openwrt 源码根目录（feeds 更新之后）运行"
    return 1
  fi

  echo ">>> 克隆 small-package ..."
  rm -rf "$SMALL_TMP_DIR"
  git clone --depth=1 "$SMALL_REPO_URL" "$SMALL_TMP_DIR" || {
    echo "❌ small-package 克隆失败"; return 1;
  }

  local imported=0 overridden=0 missing=0
  local overridden_list=() missing_list=()
  local pkg dir

  while read -r line; do
    # v2.1 修复：白名单行内多包以空格分隔，逐词解析（此前整行被当作单个包名查找，
    # 导致多包行全部误报"small-package 中不存在"）
    for pkg in $line; do
    [ -z "$pkg" ] && continue
    case "$pkg" in \#*|\-*|*\/*) continue ;; esac
    # 包名字符集过滤：跳过中文注释段等非包名词（v2.1 逐词修复遗留脏日志）
    [[ "$pkg" =~ ^[A-Za-z0-9+._-]+$ ]] || continue

    # 1) 官方已有同名 → 清理官方落点（第三方优先，v2.2 反转）
    if is_official_pkg "$pkg"; then
      overridden=$((overridden+1)); overridden_list+=("$pkg")
      remove_official_pkg "$pkg"
    fi

    # 2) small-package 中查找（含嵌套目录）
    dir="$(find_in_small "$pkg")"
    if [ -z "$dir" ]; then
      missing=$((missing+1)); missing_list+=("$pkg")
      echo "⚠️  $pkg：small-package 中不存在，已跳过"
      continue
    fi

    # 3) 导入
    rm -rf "package/$pkg"
    cp -a "$dir" "package/$pkg"
    imported=$((imported+1))
    echo "📦 导入 $pkg"
    done
  done <<'WHITELIST_EOF'
# ---------- 代理/科学上网 ----------
mihomo luci-app-passwall2 luci-app-ssr-plus luci-app-clash
luci-app-clashoo luci-app-fchomo luci-app-nikki nikki
luci-app-daede luci-app-mosdns trojan-go clashoo
luci-app-netwizard
# ---------- DNS 相关 ----------
dns2socks-rust luci-app-dnsfilter luci-app-dnscrypt-proxy2 luci-app-dnsmasq-ipset
luci-app-dnsproxy
# ---------- 内网穿透/组网/远程 ----------
easytier luci-app-easytier ddnsto luci-app-ddnsto
headscale lucky luci-app-lucky linkease
linkeasefull linkease-common-bin luci-app-linkease istoreenhance
luci-app-istoreenhance luci-app-tailscale
# ---------- 网盘/NAS/文件服务 ----------
alist baidudrive luci-app-baidudrive baidusdk
luci-app-clouddrive2 luci-app-chinesesubfinder luci-app-gogs luci-app-gowebdav
webd luci-app-webd luci-app-kodexplorer verysync
luci-app-verysync quickfile luci-app-quickfile openlist2
luci-app-openlist2 baidupcs-web luci-app-baidupcs-web
# ---------- Docker 管理增强 ----------
dockermanager luci-app-dockermanager docker-lan-bridge
# ---------- 媒体服务器 ----------
luci-app-emby luci-app-jellyfin luci-app-plex airconnect
luci-app-airconnect UnblockNeteaseMusic UnblockNeteaseMusic-Go
# ---------- 系统管理/工具 ----------
luci-app-store quickstart luci-app-quickstart luci-app-partexp
luci-app-fileassistant luci-app-advanced luci-app-turboacc luci-app-watchdog
luci-app-poweroffdevice luci-app-socat luci-app-autoupdate autoupdate
luci-app-easyupdate luci-app-demon luci-app-chatgpt-web luci-app-homeassistant
luci-app-homebridge luci-app-navidrome luci-app-drawio luci-app-codeserver
luci-app-dpanel luci-app-excalidraw luci-app-ghttpd ghttpd
luci-app-taskplan luci-app-control-timewol luci-app-control-webrestriction luci-app-control-weburl
luci-app-dogcom luci-app-chongyoung luci-app-chongyoung2.0 MentoHUST-OpenWrt-ipk
mentohust luci-app-mentohust luci-app-beardropper luci-app-homeredirect
homeredirect luci-app-timecontrol luci-app-pushbot luci-app-wrtbwmon
luci-app-bandwidthd luci-app-cloudflarespeedtest luci-app-speedtest-web luci-app-usb3disable
luci-app-oaf oaf luci-app-ap-modem luci-app-arcadia
luci-app-fakemesh luci-app-fastnet fastnet luci-app-floatip
floatip luci-app-gecoosac luci-app-godproxy luci-app-feishuvpn
luci-app-droidmodem lcdsimple
# ---------- QoS/流量控制 ----------
luci-app-eqosplus
# ---------- 广告过滤/去广告 ----------
luci-app-koolproxyR luci-app-openclaw luci-app-adbyby-plus
# ---------- 游戏加速 ----------
LingTiGameAcc luci-app-LingTiGameAcc lingtigameacc luci-app-UUGameAcc
# ---------- 网络工具 ----------
luci-app-webvirtcloud
# ---------- LuCI 主题 ----------
luci-theme-design luci-app-design-config luci-theme-alpha luci-app-alpha-config
luci-theme-atmaterial_new luci-theme-tomato luci-theme-ifit luci-theme-glass
luci-theme-material3 luci-theme-argone luci-app-argone-config
# ---------- 网络代理工具 ----------
honk
# ---------- 依赖库（排除官方已有的） ----------
lua-ipops lua-neturl luci-lib-taskd luci-lib-xterm
taskd
# ---------- iStore 生态 ----------
luci-app-istorex agentflow luci-app-agentflow kai
kai_session kaiplus luci-app-kaiplus
# ---------- EasyMesh 相关 ----------
luci-app-easymesh
WHITELIST_EOF

  rm -rf "$SMALL_TMP_DIR"

  echo ""
  echo "===== 第三方包同步完成 ====="
  echo "  导入第三方包：$imported"
  echo "  覆盖官方同名（使用第三方版本）：$overridden"
  if [ "${#overridden_list[@]}" -gt 0 ]; then echo "    ${overridden_list[*]}"; fi
  echo "  缺失（small-package 无此包）：$missing"
  if [ "${#missing_list[@]}" -gt 0 ]; then echo "    ${missing_list[*]}"; fi
  echo "============================"
}

sync_small_packages
