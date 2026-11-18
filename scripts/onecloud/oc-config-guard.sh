#!/bin/sh
# ============================================================================================
# oc-config-guard.sh — OneCloud 配置守护（升级前强制备份 + 完整性校验 + 升级后核对 + 恢复）
#
# 用法：
#   oc-config-guard.sh backup [tag]         密封备份当前配置（归档+清单+sha256），失败即非 0 退出
#   oc-config-guard.sh verify [archive]     重新校验归档完整性（默认最近一份）
#   oc-config-guard.sh postflight [--restore] 升级后核对配置是否保留；缺失可自动补齐
#   oc-config-guard.sh restore [archive] [--all|--missing]  恢复配置（默认只补缺失）
#   oc-config-guard.sh list                 列出归档（时间/版本/大小/校验状态）
#
# 退出码：0=成功  7=备份失败/校验不通过  8=配置核对不通过（缺项且无法恢复）  9=参数错
# 设计要点：
#   ① /opt 被在线升级的 rootfs 覆盖 --exclude 排除，归档放这里可活过升级与重启；
#      若 /mnt/sda1 可写，同时mirror 一份到外置盘，防分区级损坏。
#   ② 归档必须自证完整：gzip -t + 清单条数一致 + 逐文件 sha256 与清单一致，缺一即判失败。
#      失败时删除残档并返回 7——调用方（升级脚本）据此拒绝写盘，绝不"带病升级"。
#   ③ 清单是升级后的比对基准；postflight 只解决"配置是否还在/是否被改"这个问题域。
# ============================================================================================

set -u
. /usr/lib/oc-audit.sh 2>/dev/null || {
	OC_AUDIT_DIR="${OC_AUDIT_DIR:-/opt/oc-audit}"
	OC_AUDIT_LOG="$OC_AUDIT_DIR/upgrade-audit.jsonl"
	OC_STATE_FILE="${OC_STATE_FILE:-/opt/oc-upgrade.last}"
	oc_audit_phase() { :; }
	oc_audit_alert() { logger -t oc-audit -p "user.${1:-warn}" "$2" 2>/dev/null; }
	_oc_json_esc() { printf '%s' "$1"; }
}

ARCH_DIR="${OC_ARCH_DIR:-/opt/oc-backup}"
MIRROR_DIR="/mnt/sda1/oc-backup"
KEEP="${OC_KEEP:-5}"

# 受保护清单（存在才纳入，缺失不报错）
KEEP_LIST="
/etc/config
/etc/rc.local
/etc/shadow
/etc/passwd
/etc/group
/etc/dropbear
/etc/uhttpd.crt
/etc/uhttpd.key
/etc/sysupgrade.conf
/etc/oc-version
/etc/oc-repo
/etc/crontabs
/etc/ssh
/root/.ssh
"

log()  { echo "[guard] $*"; }
die()  { echo "[guard][FATAL] $*" >&2; exit "${2:-1}"; }
_ts()  { date +%Y%m%d-%H%M%S; }
_ver() { sed -e 's/[[:space:]]//g' /etc/oc-version 2>/dev/null || echo unknown; }

# 生成"相对路径"清单（去掉前导 /），供 tar -C / 使用
_rel_list() {
	for p in $KEEP_LIST; do
		case "$p" in
			*/config|*/dropbear|*/crontabs|*/ssh) [ -d "$p" ] && echo "${p#/}" ;;
			*) [ -e "$p" ] && echo "${p#/}" ;;
		esac
	done
}

# 枚举清单内所有普通文件（相对路径）
_files_of() {
	for p in $KEEP_LIST; do
		if [ -d "$p" ]; then
			find "$p" -type f 2>/dev/null | sed -e 's,^/,,'
		elif [ -f "$p" ]; then
			echo "${p#/}"
		fi
	done | sort -u
}

_cmd_backup() {
	tag="${1:-pre-upgrade}"
	mkdir -p "$ARCH_DIR" || die "无法创建 $ARCH_DIR" 7
	base="config-$(date +%Y%m%d-%H%M%S)-$tag"
	arch="$ARCH_DIR/$base.tar.gz"
	man="$ARCH_DIR/manifest-$base.tsv"
	ux="$ARCH_DIR/uci-export-$base.txt"
	tmp="/tmp/oc-guard.$$"
	rm -rf "$tmp"; mkdir -p "$tmp" || die "/tmp 不可写" 7

	# ① 归档（相对路径 + -C /，恢复时无需关心挂载点）
	_cnt=0
	for p in $KEEP_LIST; do
		[ -e "$p" ] || continue
		_cnt=$((_cnt + 1))
	done
	[ "$_cnt" -gt 0 ] || die "受保护清单内一个文件都没有（异常环境）" 7
	tar -czf "$tmp/arch.tar.gz" -C / $( _rel_list ) 2>/dev/null || die "tar 打包失败" 7

	# ② 清单：sha256 + 大小 + 路径
	: > "$tmp/manifest.tsv"
	_n=0
	for f in $( _files_of ); do
		_h=$(sha256sum "/$f" 2>/dev/null | awk '{print $1}')
		_s=$(wc -c < "/$f" 2>/dev/null | tr -d ' ')
		[ -n "$_h" ] || continue
		printf '%s\t%s\t%s\n' "$_h" "${_s:-0}" "/$f" >> "$tmp/manifest.tsv"
		_n=$((_n + 1))
	done
	[ "$_n" -gt 0 ] || die "清单为空（无法证明备份完整性）" 7

	# ③ uci 全量导出（人工核对/应急回灌的兜底来源）
	uci export > "$tmp/uci-export.txt" 2>/dev/null || true

	# ④ 自校验：gzip -t / 条数一致 / 逐文件 sha256 与清单一致
	log "自校验归档（_n=$_n）..."
	gzip -t "$tmp/arch.tar.gz" || die "归档 gzip 校验失败" 7
	_a=$(tar -tzf "$tmp/arch.tar.gz" 2>/dev/null | grep -v '/$' | wc -l | tr -d ' ')
	[ "$_a" -ge "$_n" ] || die "归档文件数($_a) < 清单条数($_n)" 7
	rm -rf "$tmp/x"; mkdir -p "$tmp/x"
	tar -xzf "$tmp/arch.tar.gz" -C "$tmp/x" 2>/dev/null || die "归档解包失败（自校验）" 7
	_bad=0
	while IFS='	' read -r h s f; do
		_hn=$(sha256sum "$tmp/x$f" 2>/dev/null | awk '{print $1}')
		[ "$_hn" = "$h" ] || { echo "  校验不符: $f" >&2; _bad=$((_bad + 1)); }
	done < "$tmp/manifest.tsv"
	[ "$_bad" -eq 0 ] || die "归档内有 $_bad 个文件与清单不符" 7

	# ⑤ 落盘（mv 原子），并写归档自身 sha256
	mv -f "$tmp/arch.tar.gz" "$arch" || die "归档落盘失败（/opt 空间不足？）" 7
	mv -f "$tmp/manifest.tsv" "$man" 2>/dev/null
	mv -f "$tmp/uci-export.txt" "$ux" 2>/dev/null
	sha256sum "$arch" | awk '{print $1}' > "$arch.sha256"
	rm -rf "$tmp"

	# ⑥ 外置盘 mirror（尽力而为，失败仅告警）
	if [ -d /mnt/sda1 ] && [ -w /mnt/sda1 ]; then
		mkdir -p "$MIRROR_DIR" 2>/dev/null && cp -f "$arch" "$man" "$arch.sha256" "$MIRROR_DIR/" 2>/dev/null \
			&& log "已 mirror 到 $MIRROR_DIR" || log "警告: 外置盘 mirror 失败（不影响本机备份）"
	fi

	# ⑦ 保留最近 KEEP 份
	ls -1dt "$ARCH_DIR"/config-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
		rm -f "$old" "${old%.tar.gz}.sha256" "$ARCH_DIR/manifest-$(basename "$old" .tar.gz).tsv" 2>/dev/null
	done

	oc_audit_phase backup_ok "arch=$arch files=$_n sha256=$(cat "$arch.sha256" | cut -c1-12)"
	log "备份完成: $arch（$_n 个文件，sha256 $(cat "$arch.sha256" | cut -c1-12)…）"
	echo "$arch"
}

_latest_arch() { ls -1dt "$ARCH_DIR"/config-*.tar.gz 2>/dev/null | head -n1; }

_cmd_verify() {
	arch="${1:-$(_latest_arch)}"
	[ -n "${arch:-}" ] && [ -f "$arch" ] || die "找不到归档（$ARCH_DIR）" 9
	exp=$(cat "$arch.sha256" 2>/dev/null)
	got=$(sha256sum "$arch" | awk '{print $1}')
	[ -n "$exp" ] && [ "$exp" = "$got" ] || die "归档 sha256 不符（可能损坏/被篡改）" 7
	gzip -t "$arch" || die "归档 gzip 校验失败" 7
	man="$ARCH_DIR/manifest-$(basename "$arch" .tar.gz).tsv"
	if [ -f "$man" ]; then
		_n=$(wc -l < "$man" | tr -d ' ')
		_a=$(tar -tzf "$arch" | grep -v '/$' | wc -l | tr -d ' ')
		[ "$_a" -ge "$_n" ] || die "归档条目($_a) < 清单($_n)" 7
	fi
	log "归档校验通过: $arch（$(du -h "$arch" | awk '{print $1}')）"
}

_cmd_postflight() {
	auto_restore="no"
	[ "${1:-}" = "--restore" ] && auto_restore="yes"
	arch=$(_latest_arch)
	[ -n "${arch:-}" ] || die "没有可用于核对的归档" 8
	# OC_MANIFEST 可由调用方指定（restore 场景要按"被恢复的那份归档"核对，
	# 而不是 restore 前顺手做的那份 pre-restore 快照，否则基准会被换掉）
	man="${OC_MANIFEST:-$ARCH_DIR/manifest-$(basename "$arch" .tar.gz).tsv}"
	[ -f "$man" ] || die "缺少清单文件，无法核对：$man" 8

	ts=$(date +%Y%m%d-%H%M%S)
	out="$OC_AUDIT_DIR/postflight-$ts.json"
	missing=""; changed=""; n_ok=0
	while IFS='	' read -r h s f; do
		if [ ! -e "$f" ]; then missing="$missing $f"; continue; fi
		_hn=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
		[ "$_hn" = "$h" ] && n_ok=$((n_ok + 1)) || changed="$changed $f"
	done < "$man"

	restored=""
	if [ -n "$missing" ] && [ "$auto_restore" = "yes" ]; then
		for f in $missing; do
			_r="${f#/}"
			if tar -xzf "$arch" -C / "$_r" 2>/dev/null && [ -e "$f" ]; then
				restored="$restored $f"
				oc_audit_alert warn "配置缺失已从归档恢复: $f"
			fi
		done
		# 恢复后复核
		_still=""
		for f in $missing; do
			case " $restored " in *" $f "*) ;; *) _still="$_still $f" ;; esac
		done
		missing="$_still"
	fi

	printf '{"ts":"%s","manifest":"%s","ok":%s,"missing":"%s","changed":"%s","restored":"%s"}\n' \
		"$(_oc_now 2>/dev/null || date '+%F %T')" "$man" "$n_ok" \
		"$(_oc_json_esc "$missing")" "$(_oc_json_esc "$changed")" "$(_oc_json_esc "$restored")" \
		> "$out" 2>/dev/null

	log "核对结果: 一致 $n_ok 项；缺失[${missing:-无}]；有变化[${changed:-无}]${restored:+；已恢复$restored}"
	oc_audit_phase postflight "ok=$n_ok missing=[$missing] changed=[$changed] restored=[$restored]"
	if [ -n "$missing" ]; then
		oc_audit_alert crit "升级后配置缺失且未能恢复: $missing（归档 $arch）"
		echo "$(date '+%F %T') postflight-FAIL missing=[$missing] changed=[$changed]" >> "$OC_STATE_FILE" 2>/dev/null
		die "配置核对不通过：$missing" 8
	fi
	[ -n "$changed" ] && oc_audit_alert warn "升级后配置内容有变化（通常为新固件迁移所致，请人工复核）: $changed"
	echo "$(date '+%F %T') postflight-ok ok=$n_ok changed=[$changed] restored=[$restored]" >> "$OC_STATE_FILE" 2>/dev/null
	return 0
}

_cmd_restore() {
	arch="${1:-$(_latest_arch)}"
	mode="${2:---missing}"
	[ -n "${arch:-}" ] && [ -f "$arch" ] || die "找不到归档" 9
	_cmd_verify "$arch" || exit 7
	man="$ARCH_DIR/manifest-$(basename "$arch" .tar.gz).tsv"
	[ -f "$man" ] || die "缺少清单，拒绝盲恢复" 9

	# 恢复前先给当前状态留一份（避免二次伤害）
	_cmd_backup "pre-restore" >/dev/null || die "恢复前备份失败，中止（避免不可逆）" 7

	if [ "$mode" = "--all" ]; then
		tar -xzf "$arch" -C / 2>/dev/null || die "恢复解包失败" 7
		log "已全量恢复（--all）：$arch"
	else
		_n=0
		while IFS='	' read -r h s f; do
			[ -e "$f" ] && continue
			_r="${f#/}"
			tar -xzf "$arch" -C / "$_r" 2>/dev/null && _n=$((_n + 1))
		done < "$man"
		log "已补齐缺失文件 $_n 个"
	fi
	uci commit 2>/dev/null
	oc_audit_phase restore_ok "arch=$(basename "$arch") mode=$mode"
	OC_MANIFEST="$man" _cmd_postflight || exit 8
}

_cmd_list() {
	for a in $(ls -1dt "$ARCH_DIR"/config-*.tar.gz 2>/dev/null); do
		_sz=$(du -h "$a" | awk '{print $1}')
		_exp=$(cat "$a.sha256" 2>/dev/null | cut -c1-12)
		_got=$(sha256sum "$a" | awk '{print $1}' | cut -c1-12)
		[ "$_exp" = "$_got" ] && _st="OK" || _st="BAD"
		printf '%-62s %6s  %s  %s\n' "$(basename "$a")" "$_sz" "$_st" "$(date -r "$a" '+%F %T' 2>/dev/null)"
	done
}

case "${1:-}" in
	backup)     shift; _cmd_backup "$@" ;;
	verify)     shift; _cmd_verify "$@" ;;
	postflight) shift; _cmd_postflight "$@" ;;
	restore)    shift; _cmd_restore "$@" ;;
	list)       _cmd_list ;;
	*) echo "用法: $0 {backup [tag]|verify [arch]|postflight [--restore]|restore [arch] [--all|--missing]|list}" ; exit 9 ;;
esac
