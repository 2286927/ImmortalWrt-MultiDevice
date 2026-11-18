#!/bin/sh
# ============================================================================================
# oc-audit-watch.sh — 升级动作实时告警 watcher（由 /etc/init.d/oc-audit-watch 以 procd 托管）
#   监听 /opt/oc-audit/upgrade-audit.jsonl 的新增行，对 begin 打日志、对 end(ec!=0)/phase 失败告警。
#   只读审计文件，绝不改写；异常退出由 procd respawn 拉起。
# ============================================================================================
LOG="/opt/oc-audit/upgrade-audit.jsonl"
mkdir -p /opt/oc-audit 2>/dev/null
[ -f "$LOG" ] || : > "$LOG" 2>/dev/null
# 先公告"曾发生的上次结果"，便于开机即知上次升级是否异常
_last_rc=$(cat /opt/oc-audit/last-rc 2>/dev/null)
[ -n "${_last_rc:-}" ] && [ "$_last_rc" != "0" ] && \
	logger -t oc-audit -p user.err "上次升级命令异常退出（ec=$_last_rc），详见 /opt/oc-audit/upgrade-audit.jsonl" 2>/dev/null

tail -F -n 0 "$LOG" 2>/dev/null | while IFS= read -r line; do
	case "$line" in
		*'"event":"upgrade.begin"'*)
			logger -t oc-audit -p user.notice "检测到升级命令开始: $line" 2>/dev/null ;;
		*'"event":"upgrade.end"'*)
			case "$line" in
				*'"ec":0'*) logger -t oc-audit -p user.notice "升级命令完成: $line" 2>/dev/null ;;
				*) logger -t oc-audit -p user.err "升级命令失败: $line" 2>/dev/null
				   echo "$(date '+%F %T') [err] $line" >> /opt/oc-audit/alerts.log 2>/dev/null ;;
			esac ;;
	esac
done
