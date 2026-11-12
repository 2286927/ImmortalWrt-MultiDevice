#!/bin/sh
# ============================================================
# autoupdate-maint — 值守升级镜像列表的自动维护（设备侧）
#
# 作用：定期实测候选镜像，按速度降序重排 autoupdate.sh 里的
#       get_mirrors() 候选，并提交到仓库（仅此一个文件）。
#
# 用法：
#   autoupdate-maint selftest   测速 + 打印将改内容，不提交、不写状态
#   autoupdate-maint run        正常流程（cron 调用，含 7 天闸门）
#   autoupdate-maint force      忽略 7 天闸门，立即执行
#   autoupdate-maint status     查看状态与上次结果
#
# 依赖：curl、openssl(3.x, base64)、awk、sort、flock、wc
# 配置：/etc/config/autoupdate-maint
# 部署：随固件出厂自带（scripts/common + diy-part2），token 需用户自行放置
# 状态：/etc/autoupdate-maint.state
# ============================================================

set -u

CONF="/etc/config/autoupdate-maint"
WORK="/tmp/am"
LOCK="/tmp/autoupdate-maint.lock"
MODE="${1:-run}"

umask 022

log() { logger -t autoupdate-maint "$*" 2>/dev/null; echo "autoupdate-maint: $*"; }

[ -f "$CONF" ] || { log "配置缺失：$CONF"; exit 1; }
. "$CONF"

: "${REPO_OWNER:?}" "${REPO_NAME:?}" "${FILE_PATH:?}" "${BRANCH:=main}"
: "${INTERVAL_DAYS:=7}" "${COOLDOWN_HOURS:=6}" "${TOKEN_FILE:?}"
: "${PROBE_TIMEOUT:=12}" "${MIN_SPEED_KBPS:=80}"
: "${BIGFILE_BYTES:=10000000}" "${FALLBACK:=keep_last}" "${CANDIDATES:?}"
: "${ASSET_TAG:=autoupdate}" "${ASSET_PREFIX:=autoupdate-R68S-25.12}"
: "${SPEED_ROUNDS:=2}"
: "${STATE:=/etc/autoupdate-maint.state}"

# 镜像前缀语法：https://<mirror>/<完整 GitHub URL>
GH_ASSET_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${ASSET_TAG}"
ASSET="${GH_ASSET_BASE}/${ASSET_PREFIX}-version.txt"
BIG="${GH_ASSET_BASE}/${ASSET_PREFIX}-sysupgrade.gz"
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/${FILE_PATH}"

now_s() { date +%s; }

# ---------------- 状态 ----------------
load_state() {
    LAST_SUCCESS=""; LAST_ATTEMPT=""; LAST_RESULT=""; LAST_COMMIT=""; FAIL_STREAK=0
    [ -f "$STATE" ] && . "$STATE"
}

save_state() {
    {
        echo "LAST_SUCCESS=${LAST_SUCCESS:-}"
        echo "LAST_ATTEMPT=${LAST_ATTEMPT:-}"
        echo "LAST_RESULT=${1:-unknown}"
        echo "LAST_COMMIT=${LAST_COMMIT:-}"
        echo "FAIL_STREAK=${FAIL_STREAK:-0}"
        echo "LAST_MIRRORS=\"${NEW_LIST:-}\""
        echo "LAST_RUN_AT=\"$(date '+%Y-%m-%d %H:%M:%S')\""
    } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# ---------------- 网络预检 ----------------
net_ready() {
    waited=0
    while [ "$waited" -lt 120 ]; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
               https://api.github.com/zen 2>/dev/null)
        [ "$code" = "200" ] && return 0
        sleep 10; waited=$((waited + 10))
    done
    return 1
}

# ---------------- 单镜像探测 ----------------
probe_one() {
    idx="$1"; mirror="$2"
    base="https://${mirror}/"
    diag=""
    ok=1
    for r in 1 2; do
        code=$(curl -sS -o "${WORK}/b_${idx}" -w '%{http_code}' \
              --connect-timeout 6 --max-time "$PROBE_TIMEOUT" "${base}${ASSET}" 2>/dev/null)
        if [ "$code" != "200" ]; then ok=0; diag="HTTP ${code:-000}"; break; fi
        if ! grep -q '^RUN_ID=' "${WORK}/b_${idx}" 2>/dev/null; then
            ok=0; diag="200 但内容异常"; break
        fi
    done
    sp=0
    if [ "$ok" = "1" ]; then
        # 多轮取最大值：CDN 节点/瞬时拥塞会让单次结果偏低，取最大更接近真实能力
        best=0
        t=0
        while [ "$t" -lt "${SPEED_ROUNDS:-2}" ]; do
            raw=$(curl -sS -o /dev/null -w '%{speed_download}' -r "0-${BIGFILE_BYTES}" \
                  --connect-timeout 6 --max-time 60 "${base}${BIG}" 2>/dev/null)
            cur=$(printf '%s' "${raw:-0}" | awk '{printf "%d", $1 + 0}')
            [ "$cur" -gt "$best" ] && best=$cur
            t=$((t + 1))
        done
        sp=$best
        if [ "$sp" -le 0 ]; then diag="小文件通，取流失败"; else diag="ok"; fi
    fi
    echo "${idx}|${mirror}|${sp}|${diag}" > "${WORK}/r_${idx}"
}

do_probe() {
    idx=0
    for m in $CANDIDATES; do
        idx=$((idx + 1))
        probe_one "$idx" "$m" &
    done
    wait
    cat "${WORK}"/r_* 2>/dev/null | sort -t'|' -k3 -nr > "${WORK}/detail.txt"
    awk -F'|' -v min="$MIN_SPEED_KBPS" \
        '$3 > 0 && ($3 / 1024) >= min { print $3"|"$2 }' "${WORK}/detail.txt" \
        | sort -t'|' -k1 -nr
}

# ---------------- 取仓库当前文件 ----------------
fetch_current() {
    curl -fsSL --max-time 40 -H "Authorization: Bearer $TOKEN" \
        -H 'Accept: application/vnd.github.raw' "$API" -o "${WORK}/cur.sh" 2>/dev/null \
        && [ -s "${WORK}/cur.sh" ]
}

fetch_sha() {
    curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
        -H 'Accept: application/vnd.github+json' "$API" 2>/dev/null \
        | sed -n 's/.*"sha": *"\([a-f0-9]\{40\}\)".*/\1/p' | head -n 1
}

# ---------------- 生成新块 ----------------
build_block() {
    ranked="$1"
    {
        echo '        auto|"")'
        echo '            # 上次成功的镜像优先（重启后记忆失效，重新探测）'
        echo '            [ -s "$MIRROR_MEM_FILE" ] && cat "$MIRROR_MEM_FILE"'
        echo "            # 由 autoupdate-maint 自动维护（$(date '+%Y-%m-%d')，设备侧 10MB 分段实测，快→慢）"
        while IFS='|' read -r sp m; do
            [ -n "${m:-}" ] || continue
            printf '            #   %-26s %6d KB/s\n' "$m" $((sp / 1024))
        done < "$ranked"
        echo "            printf '%s\\n' \\"
        while IFS='|' read -r sp m; do
            [ -n "${m:-}" ] || continue
            echo "                \"https://${m}/\" \\"
        done < "$ranked"
        echo '                "-"'
        echo '            ;;'
    }
}

# ---------------- 替换 auto 段 ----------------
replace_block() {
    awk -v blk="${WORK}/newblock" '
        BEGIN { nb = ""; while ((getline l < blk) > 0) nb = nb l "\n"; inblk = 0; done = 0 }
        {
            if (inblk) {
                if ($0 ~ /^[[:space:]]*;;/) { inblk = 0; printf "%s", nb }
                next
            }
            if (!done && index($0, "auto|\"\")") > 0) { inblk = 1; done = 1; next }
            print
        }
    ' "$1" > "$2"
}

# ---------------- 结构校验 ----------------
validate() {
    f="$1"
    sh -n "$f" 2>/dev/null || { log "语法检查失败，放弃"; return 1; }
    grep -q 'auto|"")' "$f" || { log "锚点 auto 段丢失，放弃"; return 1; }
    grep -q 'none|direct)' "$f" || { log "锚点 none|direct 丢失，放弃"; return 1; }
    grep -q '自定义加速前缀优先' "$f" || { log "锚点自定义前缀丢失，放弃"; return 1; }
    grep -q 'MIRROR_MEM_FILE' "$f" || { log "MIRROR_MEM_FILE 引用丢失，放弃"; return 1; }
    oldl=$(awk 'END{print NR}' "${WORK}/cur.sh")
    newl=$(awk 'END{print NR}' "$f")
    d=$((newl - oldl)); [ "$d" -lt 0 ] && d=$((-d))
    [ "$d" -le 15 ] || { log "行数变化异常（$oldl → $newl），放弃"; return 1; }
    return 0
}

# ---------------- 提交 ----------------
commit_new() {
    b64=$(openssl base64 -A -in "$1")
    [ -n "$b64" ] || { log "base64 编码为空，放弃"; return 1; }
    msg="chore(autoupdate): 镜像按设备实测重排 $(date '+%Y-%m-%d')"
    payload="${WORK}/payload.json"
    printf '{"message":"%s","content":"%s","sha":"%s","branch":"%s"}' \
        "$msg" "$b64" "$CUR_SHA" "$BRANCH" > "$payload"
    resp=$(curl -sS -X PUT --max-time 90 \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Accept: application/vnd.github+json' \
        -H 'Content-Type: application/json' \
        --data-binary "@${payload}" "$API" 2>/dev/null)
    # 成功响应结构：{"content":{"sha":"<文件sha>"},"commit":{"sha":"<提交sha>"},...}
    # 注意 API 返回带缩进的 JSON（"sha": "..." 中间有空格），匹配要允许空格
    NEW_SHA=$(printf '%s' "$resp" | grep -o '"sha": *"[a-f0-9]\{40\}"' | sed -n '2p' | grep -o '[a-f0-9]\{40\}')
    if [ -n "$NEW_SHA" ]; then
        log "已提交 ${NEW_SHA}"
        return 0
    fi
    if printf '%s' "$resp" | grep -q '"commit"'; then
        log "提交成功但未解析到 commit sha（响应格式变化）"
        NEW_SHA="unknown"
        return 0
    fi
    log "提交失败：$(printf '%s' "$resp" | tr -d '\n' | cut -c1-180)"
    return 1
}

show_detail() {
    [ -f "${WORK}/detail.txt" ] || return 0
    echo "-- 候选实测明细 --"
    while IFS='|' read -r i m sp dg; do
        [ -n "${m:-}" ] || continue
        printf '   %-28s %8d KB/s  %s\n' "$m" $((sp / 1024)) "${dg:-}"
    done < "${WORK}/detail.txt"
}

show_status() {
    load_state
    echo "== autoupdate-maint 状态 =="
    echo "last_success : ${LAST_SUCCESS:-（无）}"
    echo "last_attempt : ${LAST_ATTEMPT:-（无）}"
    echo "last_result  : ${LAST_RESULT:-（无）}"
    echo "last_commit  : ${LAST_COMMIT:-（无）}"
    echo "fail_streak  : ${FAIL_STREAK:-0}"
    echo "interval     : 每 ${INTERVAL_DAYS} 天（冷却 ${COOLDOWN_HOURS} 小时）"
    echo "fallback     : ${FALLBACK}"
    echo "token        : $([ -s "$TOKEN_FILE" ] && echo 存在 || echo 缺失)"
    if [ -n "${LAST_SUCCESS:-}" ]; then
        echo "距上次成功   : $(( ($(now_s) - LAST_SUCCESS) / 86400 )) 天"
    fi
    echo "-- 最近日志 --"
    logread 2>/dev/null | grep autoupdate-maint | tail -n 5 || echo "（无）"
}

main() {
    [ "$MODE" = "status" ] && { show_status; exit 0; }

    TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d ' \r\n')
    if [ -z "$TOKEN" ]; then
        # 只提示一次，避免无 token 的设备每天刷一条日志
        if [ ! -f /etc/autoupdate-maint.notoken ]; then
            log "token 缺失：$TOKEN_FILE"
            log "出厂固件不含凭据。请放置 fine-grained PAT（该仓库 Contents: Read and write）："
            log "  printf %s \"github_pat_xxx\" > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
            touch /etc/autoupdate-maint.notoken
        fi
        exit 1
    fi
    rm -f /etc/autoupdate-maint.notoken

    exec 9>"$LOCK" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || { log "已有实例在运行，退出"; exit 0; }
    fi

    load_state
    if [ "$MODE" != "selftest" ]; then
        now=$(now_s); due=0
        if [ "$MODE" = "force" ]; then
            due=1
        elif [ -z "${LAST_SUCCESS:-}" ]; then due=1
        elif [ "$now" -lt "$LAST_SUCCESS" ]; then due=1
        elif [ $((now - LAST_SUCCESS)) -ge $((INTERVAL_DAYS * 86400)) ]; then due=1
        fi
        if [ "$due" = "0" ]; then
            log "未到期（距上次成功 $(( (now - LAST_SUCCESS) / 86400 )) 天），跳过"
            exit 0
        fi
        if [ "$MODE" != "force" ] && [ -n "${LAST_ATTEMPT:-}" ] &&
           [ $((now - LAST_ATTEMPT)) -lt $((COOLDOWN_HOURS * 3600)) ]; then
            log "冷却期内（<${COOLDOWN_HOURS}h），跳过"
            exit 0
        fi
        LAST_ATTEMPT=$now
        save_state "attempt"
    fi

    net_ready || { log "网络不可用（等待 120s 超时），本次放弃，不写状态"; exit 2; }

    rm -rf "$WORK"; mkdir -p "$WORK"

    log "开始测速（两轮小文件 + 10MB 分段，阈值 ${MIN_SPEED_KBPS} KB/s）"
    do_probe > "${WORK}/ranked.txt"
    n=$(awk 'END{print NR}' "${WORK}/ranked.txt")
    log "达标镜像 ${n} 个"
    show_detail

    if [ "$n" = "0" ]; then
        FAIL_STREAK=$((FAIL_STREAK + 1))
        log "全部候选不可用（fail_streak=${FAIL_STREAK}）"
        if [ "$MODE" = "selftest" ]; then
            echo "（selftest：未提交、未写状态）"; exit 3
        fi
        if [ "$FALLBACK" = "direct_only" ]; then
            : > "${WORK}/ranked.txt"
        else
            log "按 keep_last 保持现有列表不动"
            save_state "all_failed"; exit 3
        fi
    fi

    build_block "${WORK}/ranked.txt" > "${WORK}/newblock"

    if ! fetch_current; then
        log "取仓库当前文件失败（token 或网络）"
        if [ "$MODE" = "selftest" ]; then
            echo "-- 拟生成的新块（无法与仓库对比）--"
            cat "${WORK}/newblock"
            echo "（selftest：未提交、未写状态）"
            exit 4
        fi
        exit 4
    fi

    replace_block "${WORK}/cur.sh" "${WORK}/new.sh"
    validate "${WORK}/new.sh" || exit 5

    if cmp -s "${WORK}/cur.sh" "${WORK}/new.sh"; then
        log "列表与仓库一致，无需提交"
        [ "$MODE" = "selftest" ] || { LAST_SUCCESS=$(now_s); FAIL_STREAK=0; save_state "unchanged"; }
        exit 0
    fi

    if [ "$MODE" = "selftest" ]; then
        echo "-- 当前 auto 段 --"
        sed -n '/auto|"")/,/;;/p' "${WORK}/cur.sh" | head -n 18
        echo "-- 拟替换为 --"
        cat "${WORK}/newblock"
        echo "-- 行数：$(awk 'END{print NR}' "${WORK}/cur.sh") → $(awk 'END{print NR}' "${WORK}/new.sh") --"
        echo "（selftest：未提交、未写状态）"
        exit 0
    fi

    CUR_SHA=$(fetch_sha)
    [ -n "$CUR_SHA" ] || { log "取文件 sha 失败，放弃"; exit 6; }

    if commit_new "${WORK}/new.sh"; then
        LAST_SUCCESS=$(now_s); FAIL_STREAK=0; LAST_COMMIT="$NEW_SHA"
        NEW_LIST=$(sed -n '/auto|"")/,/;;/p' "${WORK}/new.sh" | grep -o 'https://[^"]*' | tr '\n' '|')
        save_state "committed"
        exit 0
    fi
    log "提交失败，不更新 last_success"
    exit 7
}

main "$@"
