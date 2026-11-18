#!/bin/sh
# ============================================================================================
# oc-audit.sh — OneCloud 升级动作审计库（被 source，不单独执行）
#   目标：root 每次执行 upgrade / sysupgrade / 配置恢复，都留下「时间 + 命令 + 会话 + 结果」。
#   落盘：/opt/oc-audit/upgrade-audit.jsonl（/opt 被 rootfs 覆盖 --exclude，可活过升级与重启）
#   告警：logger -p user.<level>（logread / LuCI 系统日志可见）+ /opt/oc-audit/alerts.log
#   职责边界：本库只记录，不做判定；判定与阻断在 oc-config-guard.sh / oc-upgrade.sh。
# ============================================================================================

OC_AUDIT_DIR="${OC_AUDIT_DIR:-/opt/oc-audit}"
OC_AUDIT_LOG="${OC_AUDIT_LOG:-$OC_AUDIT_DIR/upgrade-audit.jsonl}"
OC_AUDIT_ALERT="${OC_AUDIT_ALERT:-$OC_AUDIT_DIR/alerts.log}"
OC_AUDIT_RC="${OC_AUDIT_RC:-$OC_AUDIT_DIR/last-rc}"
OC_STATE_FILE="${OC_STATE_FILE:-/opt/oc-upgrade.last}"

_oc_json_esc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n\t' 2>/dev/null || printf '%s' "$1"
}

_oc_now() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }

_oc_audit_init() {
	mkdir -p "$OC_AUDIT_DIR" 2>/dev/null
	[ -f "$OC_AUDIT_LOG" ] || : > "$OC_AUDIT_LOG" 2>/dev/null
}

_oc_ver() { sed -e 's/[[:space:]]//g' /etc/oc-version 2>/dev/null || echo "-"; }

# 会话标识（JSON 片段）：来源 ssh/luci/tty/cron + tty + 父进程名 + SSH 四元组
_oc_session() {
	_src="tty"
	[ -n "${SSH_CONNECTION:-}" ] && _src="ssh"
	_ppid_comm=$(cat "/proc/$PPID/comm" 2>/dev/null)
	case "$_ppid_comm" in
		rpcd|uhttpd|luci*) [ "$_src" = "tty" ] && _src="luci" ;;
		crond) [ "$_src" = "tty" ] && _src="cron" ;;
	esac
	_tty=$(tty 2>/dev/null)
	[ "$_tty" = "not a tty" ] && _tty="-"
	[ -n "$_tty" ] || _tty="-"
	printf '"src":"%s","tty":"%s","ppid":"%s","ssh":"%s"' \
		"$_src" "$_tty" "${_ppid_comm:--}" "${SSH_CONNECTION:--}"
}

# oc_audit_event <event> [tag...]
oc_audit_event() {
	_ev="$1"; shift
	_oc_audit_init
	printf '{"ts":"%s","event":"%s","pid":%s,"uid":%s,"cmd":"%s","argv":"%s",%s,"ver":"%s","boot":"%s"%s}\n' \
		"$(_oc_now)" "$(_oc_json_esc "$_ev")" "$$" "$(id -u 2>/dev/null || echo 0)" \
		"$(_oc_json_esc "$0")" "$(_oc_json_esc "$*")" \
		"$(_oc_session)" "$(_oc_ver)" \
		"$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo -)" \
		"${OC_AUDIT_EXTRA:-}" >> "$OC_AUDIT_LOG" 2>/dev/null
}

# oc_audit_begin <scope> <原始命令行>  — 命令入口（同步落盘，即"实时"）
oc_audit_begin() {
	OC_AUDIT_SCOPE="$1"; shift
	OC_AUDIT_T0=$(date +%s)
	OC_AUDIT_EXTRA=$(printf ',"scope":"%s","phase":"begin","ec":null' "$OC_AUDIT_SCOPE")
	oc_audit_event "upgrade.begin" "$@"
}

# oc_audit_phase <阶段名> [备注] — 备份 / 校验 / 写入 / 重启 打点
oc_audit_phase() {
	OC_AUDIT_EXTRA=$(printf ',"scope":"%s","phase":"%s","ec":null,"note":"%s"' \
		"${OC_AUDIT_SCOPE:-upgrade}" "$1" "$(_oc_json_esc "${2:-}")")
	oc_audit_event "upgrade.phase" "$1" "${2:-}"
}

# oc_audit_end <退出码> [备注]
oc_audit_end() {
	_ec="$1"; _note="${2:-}"
	_dur=$(( $(date +%s) - ${OC_AUDIT_T0:-0} ))
	OC_AUDIT_EXTRA=$(printf ',"scope":"%s","phase":"end","ec":%s,"dur_s":%s,"note":"%s"' \
		"${OC_AUDIT_SCOPE:-upgrade}" "$_ec" "$_dur" "$(_oc_json_esc "$_note")")
	oc_audit_event "upgrade.end" "$_ec" "$_note"
	printf '%s\n' "$_ec" > "$OC_AUDIT_RC" 2>/dev/null
	[ "$_ec" = "0" ] || oc_audit_alert err "升级命令失败 ec=$_ec（scope=${OC_AUDIT_SCOPE:-upgrade}）: $_note"
}

# oc_audit_alert <notice|warn|err|crit> <消息>
oc_audit_alert() {
	_lv="$1"; shift
	_msg="$*"
	_oc_audit_init
	printf '%s [%s] %s\n' "$(date '+%F %T')" "$_lv" "$_msg" >> "$OC_AUDIT_ALERT" 2>/dev/null
	logger -t oc-audit -p "user.$_lv" "$_msg" 2>/dev/null
	# 可选外发：uci set system.@system[0].oc_alert_webhook=<url>；失败/无 curl 时静默跳过
	_hook=$(uci -q get system.@system[0].oc_alert_webhook 2>/dev/null)
	if [ -n "${_hook:-}" ] && command -v curl >/dev/null 2>&1; then
		curl -fsS -m 5 -H 'Content-Type: application/json' \
			-d "{\"text\":\"[OneCloud] $(_oc_json_esc "$_msg")\"}" "$_hook" >/dev/null 2>&1 &
	fi
	case "$_lv" in
		err|crit) echo "$(date '+%F %T') ALERT($_lv) $_msg" >> "$OC_STATE_FILE" 2>/dev/null ;;
	esac
}
