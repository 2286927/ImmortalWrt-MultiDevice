#!/bin/bash
#=============================================================
# ImmortalWrt DIY 脚本 1（feeds 更新之前执行，cwd = openwrt/）
# 25.12 全线共用：R68S / CM520 / RAX3000M / OCTOPUS / ONECLOUD / newifi …
#=============================================================

# 修复 LuCI 软件包版本号显示 "0.xxx » 26.xxx" 的问题：
# ImmortalWrt 官方 feeds.conf.default 仍使用 src-git（git clone --depth 1 浅克隆），
# 浅历史下 luci.mk 的 findrev 取不到各包真实版本戳；若编译前 feed 的 .git 再被清理，
# findrev 会退化为文件时间戳 fallback（0.YYMMDD.xxxxx），Updates 页出现全部"升级"误报。
# 对齐 OpenWrt 官方 25.12 做法：src-git → src-git-full（--filter=blob:none 完整提交历史），
# 使 luci-base / luci-app-* / luci-theme-* 等获得真实版本戳（26.DDD.SSSSS~hash）。
if [ -f feeds.conf.default ]; then
  sed -i -E 's|^src-git([[:space:]])|src-git-full\1|' feeds.conf.default
  echo ">>> feeds.conf.default 已切换为 src-git-full："
  grep '^src-git' feeds.conf.default
else
  echo "::warning::feeds.conf.default 不存在，跳过 src-git-full 切换"
fi
