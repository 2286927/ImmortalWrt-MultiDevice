#!/bin/bash
# 品牌统一：清除配方仓库遗留的第三方品牌水印，统一为「AI洲长」
# 背景：上游配方仓库 OneCloud_immortalwrt 已归档只读，且 workflow 锁定 RECIPE_REF，
#       因此在其 clone/内置之后、写入固件之前统一执行本脚本，保证输出零第三方品牌。
# 用法: bash brand-unify.sh <recipe_dir>
set -euo pipefail

R="${1:-recipe}"
[ -d "$R" ] || { echo "::error::配方目录不存在: $R"; exit 1; }

for f in "$R/sh/lean2.sh" "$R/sh/diy-part2.sh"; do
  [ -f "$f" ] || continue
  # 统一行尾为 LF（上游部分脚本为 CRLF）
  sed -i 's/\r$//' "$f"
  # 固件版本标识：品牌名与上游标识
  sed -i 's/莫小小/AI洲长/g; s/洲·Cy/AI洲长/g' "$f"
  sed -i 's/@OpenWrt /@ImmortalWrt /g; s/@lean /@ImmortalWrt /g' "$f"
  sed -i 's/添加个人标识和日期/添加品牌标识和日期（唯一品牌：AI洲长）/g' "$f"
  # 默认 SSID 水印
  sed -i 's/ssid=moyulong/ssid=AI洲长/g; s/ssid=Vomit/ssid=AI洲长/g' "$f"
  sed -i 's/# 修改默认wifi名称ssid为moyulong/# 修改默认 wifi 名称（本机型无无线，保留为通用逻辑）/' "$f"
  # 原配方硬编码的第三方默认无线密码：注释掉并替换为占位符
  sed -i '/1SjWwI^(2t/s/^/# /' "$f"
  sed -i 's/1SjWwI^(2t/<你的强密码>/g' "$f"
done

if [ -f "$R/ax6/banner" ]; then
  printf '%s\n' \
    ' ================================================================' \
    '        AI洲长   |   OneCloud 25.12   |   ImmortalWrt' \
    ' ================================================================' \
    '' > "$R/ax6/banner"
fi

if grep -rIn --binary-files=without-match '莫小小\|moyulong\|Vomit\|洲·Cy\|1SjWwI' \
     "$R/sh" "$R/ax6" "$R/onecloud" 2>/dev/null; then
  echo "::error::配方品牌水印清除失败"
  exit 1
fi

echo "配方品牌统一完成：AI洲长"
