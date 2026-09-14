#!/bin/sh
# ============================================================
# rax-autoupdate — CMCC RAX3000M 值守式固件检查/升级
# 数据源：本仓库 GitHub Releases 固定资产 URL（releases/latest/download）
# 依赖：curl（或 uclient-fetch + libustream）、sha256sum、sysupgrade
# 用法：
#   rax-autoupdate check        检查更新（cron 调用，含随机延迟）
#   rax-autoupdate check now    立即检查（不延迟）
#   rax-autoupdate apply        下载 + sha256 校验 + 刷写（保留配置，自动重启）
#   rax-autoupdate status       查看状态与配置
#   rax-autoupdate enable       启用每日自动检查
#   rax-autoupdate disable      停用自动检查（手动 check/apply 仍可用）
# 配置：/etc/config/autoupdate（notify_url 支持 ntfy/Bark 等 POST 文本接口）
# ============================================================

UCI_CFG="/etc/config/autoupdate"
LOCAL_BUILD_FILE="/etc/autoupdate.build"
PENDING_FILE="/tmp/autoupdate.pending"
VERSION_FILE="/tmp/autoupdate.version"
LOCK_FILE="/tmp/rax-autoupdate.lock"

log() { logger -t rax-autoupdate "$*"; echo "rax-autoupdate: $*"; }

get_opt() {
    if command -v uci >/dev/null 2>&1; then
        uci -q get "autoupdate.main.$1" 2>/dev/null && return 0
    fi
    sed -n "s/^[[:space:]]*option[[:space:]]*$1[[:space:]]*'\\([^']*\\)'.*/\\1/p" "$UCI_CFG" 2>/dev/null | head -n 1
}

fetch() { # fetch <url> <outfile> [timeout_sec]
    local url="$1" out="$2" tmo="${3:-60}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time "$tmo" -o "$out" "$url"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q --timeout="$tmo" -O "$out" "$url" 2>/dev/null
    else
        return 1
    fi
}

notify() {
    local msg="$1" url
    url=$(get_opt notify_url)
    [ -z "$url" ] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    curl -fsS -m 15 -H "Title: RAX3000M firmware update" --data-binary "$msg" "$url" >/dev/null 2>&1 || true
}

local_run_id() {
    if [ -f "$LOCAL_BUILD_FILE" ]; then
        tr -d '[:space:]' < "$LOCAL_BUILD_FILE"
    else
        echo ""
    fi
}

do_check() {
    local base prefix remote local_run
    [ "$(get_opt enabled)" = "1" ] || { log "自动检查已禁用（rax-autoupdate enable 可启用）"; exit 0; }
    base=$(get_opt base_url)
    prefix=$(get_opt prefix)
    if [ -z "$base" ] || [ -z "$prefix" ]; then
        log "配置不完整（base_url/prefix），检查 /etc/config/autoupdate"
        exit 1
    fi
    local_run=$(local_run_id)
    if [ -z "$local_run" ]; then
        log "本地构建标记缺失：$LOCAL_BUILD_FILE"
        exit 1
    fi

    # cron 场景随机延迟（最多 8 分钟），避免整点请求扎堆
    [ "$1" = "now" ] || sleep $(( $(date +%s) % 480 ))

    if ! fetch "$base/$prefix-version.txt" "$VERSION_FILE" 30; then
        log "检查失败：无法下载 $prefix-version.txt（网络或仓库地址问题）"
        exit 1
    fi
    remote=$(sed -n 's/^RUN_ID=//p' "$VERSION_FILE" | tr -d '[:space:]')
    if [ -z "$remote" ]; then
        log "version.txt 内容异常"
        exit 1
    fi

    if [ "$remote" -gt "$local_run" ] 2>/dev/null; then
        echo "$remote" > "$PENDING_FILE"
        local msg
        msg="发现新固件 build#$remote（当前 build#$local_run）。SSH 执行 rax-autoupdate apply 开始升级"
        log "$msg"
        notify "$msg"
        if [ "$(get_opt auto_apply)" = "1" ]; then
            log "auto_apply=1，自动开始升级"
            do_apply
        fi
    else
        rm -f "$PENDING_FILE"
        log "已是最新构建（build#$local_run）"
    fi
}

do_apply() {
    local base prefix remote fw shasum need avail
    base=$(get_opt base_url)
    prefix=$(get_opt prefix)
    remote=$(cat "$PENDING_FILE" 2>/dev/null)
    if [ -z "$remote" ]; then
        log "暂无待升级记录，先执行一次检查"
        do_check now
    fi
    remote=$(cat "$PENDING_FILE" 2>/dev/null)
    if [ -z "$remote" ]; then
        exit 0
    fi

    fw="/tmp/$prefix-sysupgrade.itb"
    shasum="$fw.sha256"

    log "下载新固件 build#$remote ..."
    fetch "$base/$prefix-sysupgrade.itb" "$fw" 900 || { log "固件下载失败"; exit 1; }
    fetch "$base/$prefix-sysupgrade.itb.sha256" "$shasum" 30 || { log "校验文件下载失败"; rm -f "$fw"; exit 1; }

    need=$(du -k "$fw" 2>/dev/null | awk '{print $1}')
    avail=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$need" ] && [ -n "$avail" ] && [ "$avail" -lt $((need + need / 2)) ]; then
        log "/tmp 空间不足（需约 $((need * 3 / 2))KB，可用 ${avail}KB）"
        exit 1
    fi

    if ( cd /tmp && sha256sum -c "$prefix-sysupgrade.itb.sha256" >/dev/null 2>&1 ); then
        log "sha256 校验通过，开始刷写（保留配置），设备将自动重启..."
        rm -f "$PENDING_FILE"
        sleep 2
        exec sysupgrade "$fw"
    else
        log "sha256 校验失败！已删除下载文件，请稍后重试或检查仓库资产"
        rm -f "$fw" "$shasum"
        exit 1
    fi
}

do_status() {
    echo "== rax-autoupdate 状态 =="
    echo "enabled:     $(get_opt enabled)"
    echo "base_url:    $(get_opt base_url)"
    echo "prefix:      $(get_opt prefix)"
    echo "notify_url:  $(get_opt notify_url)"
    echo "auto_apply:  $(get_opt auto_apply)"
    echo "local build: $(local_run_id)"
    if [ -f "$PENDING_FILE" ]; then
        echo "pending:     build#$(cat "$PENDING_FILE" 2>/dev/null)（可执行 rax-autoupdate apply）"
    else
        echo "pending:     无"
    fi
    echo "-- 最近日志 --"
    logread 2>/dev/null | grep rax-autoupdate | tail -n 5 || echo "（无）"
}

set_enabled() {
    if command -v uci >/dev/null 2>&1; then
        uci set autoupdate.main.enabled="$1"
        uci commit autoupdate
    else
        sed -i "s/^\\([[:space:]]*option[[:space:]]*enabled[[:space:]]*\\).*/\\1'$1'/" "$UCI_CFG"
    fi
    log "自动检查已$([ "$1" = "1" ] && echo "启用" || echo "停用")"
}

[ "$(id -u)" = "0" ] || { echo "请以 root 运行（SSH 默认即 root）"; exit 1; }

if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE" 2>/dev/null
    flock -n 9 || { log "另一个实例正在运行，退出"; exit 1; }
fi

case "$1" in
    check)   shift; do_check "$@" ;;
    apply)   do_apply ;;
    status)  do_status ;;
    enable)  set_enabled 1 ;;
    disable) set_enabled 0 ;;
    *)       sed -n '2,17p' "$0"; exit 0 ;;
esac
