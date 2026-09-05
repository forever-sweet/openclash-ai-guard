#!/bin/sh
# openclash-ai-guard / ai-node-watch.sh
#
# 每 10 分钟由 cron 调用，做三件 mihomo 自己做不到的事：
#
#   1) 主动踢一脚两个 AI 出口组，强制立即重新排名。
#      针对实测过的故障：组有可能卡在一个已经打不通的节点上不动，
#      只有手动触发一次组探测才会恢复。当作保险。
#   2) 全量探测所有候选节点，统计坏节点比例并写日志留趋势。
#   3) 坏节点比例连续 N 次超过阈值 → 重新拉订阅（机场可能换了节点地址）。
#      带"连续次数"和"冷却时间"两道闸，避免晚高峰抖一下就去重启全屋。
#   另外：自愈 —— 检查 OpenClash 官方钩子里的调用是否还在，不在就补回去。
#
# 用法:
#   ai-node-watch.sh            正常跑（cron 用这个）
#   ai-node-watch.sh --dry      只探测和打印，绝不刷新订阅
#   ai-node-watch.sh --status   打印当前状态和最近日志
#
# 依赖: curl / sed / awk / ruby —— OpenClash 环境全都自带，不需要 docker。

BASE="/etc/openclash/ai-guard"
CONF="$BASE/ai-guard.conf"
HOOK="/etc/openclash/custom/openclash_custom_overwrite.sh"
HOOK_MARK="ai-groups-overwrite.rb"

STATE="/tmp/ai-guard.state"
LOG="/tmp/ai-guard.log"
LOG_KEEP=500

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# busybox 的 . (source) 对不存在的文件是致命错误，2>/dev/null 只是把报错藏了、
# shell 照样直接退出，所以必须先判存在。
[ -f "$CONF" ] && . "$CONF"

AI_API_GROUP="${AI_API_GROUP:-AI-API}"
AI_CHAT_GROUP="${AI_CHAT_GROUP:-AI-Chat}"
AI_API_PROBE="${AI_API_PROBE:-https://cp.cloudflare.com/generate_204}"
AI_CHAT_PROBE="${AI_CHAT_PROBE:-https://chatgpt.com/cdn-cgi/trace}"
BAD_MS="${BAD_MS:-2000}"
BAD_RATIO_NUM="${BAD_RATIO_NUM:-2}"
BAD_RATIO_DEN="${BAD_RATIO_DEN:-3}"
NEED_STREAK="${NEED_STREAK:-3}"
COOLDOWN="${COOLDOWN:-14400}"
SELF_HEAL="${SELF_HEAL:-1}"
# ---- 定位运行中的配置、API 地址和密钥 ----
# 从配置文件里读而不是从 UCI 读：external-controller / secret 最终生效的值在这里，
# 别人可能改过端口或用了 dashboard 之外的 secret。
CFG_SRC="$(uci -q get openclash.config.config_path)"
RUN_CFG="/etc/openclash/$(basename "$CFG_SRC" 2>/dev/null)"
if [ ! -f "$RUN_CFG" ]; then
    log "ERROR 找不到运行中的配置 ($RUN_CFG)，退出"; exit 1
fi

EC="$(sed -n 's/^external-controller:[[:space:]]*["'\'']\?\([^"'\'' ]*\).*/\1/p' "$RUN_CFG" | head -1)"
SECRET="$(sed -n 's/^secret:[[:space:]]*["'\'']\?\([^"'\'']*\)["'\'']\?[[:space:]]*$/\1/p' "$RUN_CFG" | head -1)"
[ -z "$EC" ] && EC="127.0.0.1:9090"
# 0.0.0.0 / :: 不能当客户端地址用，换成本机
EC="$(echo "$EC" | sed -e 's/^0\.0\.0\.0:/127.0.0.1:/' -e 's/^\[::\]:/127.0.0.1:/' -e 's/^:/127.0.0.1:/')"
API="http://$EC"

api() {
    if [ -n "$SECRET" ]; then
        curl -s -m "${2:-40}" -H "Authorization: Bearer $SECRET" "$API$1"
    else
        curl -s -m "${2:-40}" "$API$1"
    fi
}
urlenc() { ruby -rcgi -e 'print CGI.escape(ARGV[0])' "$1" </dev/null 2>/dev/null || echo "$1"; }
# 把 {"A":1,"B":2} 拍平成每行 "名字 延迟"
flatten() { sed 's/[{}"]//g' | tr ',' '\n' | sed 's/:/ /'; }
now_of() { api "/proxies/$(urlenc "$1")" 10 | sed -n 's/.*"now":"\([^"]*\)".*/\1/p'; }

if [ "$1" = "--status" ]; then
    echo "API      : $API"
    echo "配置     : $RUN_CFG"
    echo "$AI_API_GROUP  当前出口: $(now_of "$AI_API_GROUP")"
    echo "$AI_CHAT_GROUP 当前出口: $(now_of "$AI_CHAT_GROUP")"
    echo "状态     : $(cat "$STATE" 2>/dev/null | tr '\n' ' ')"
    echo "--- 最近 25 行日志 ---"
    tail -25 "$LOG" 2>/dev/null
    exit 0
fi

# ---- 0. 自愈：官方钩子会被 opkg 升级覆盖回默认版，检查并补回来 ----
# 交给 hook-install.sh，它会区分"空模板"和"用户自己有内容"两种情况，
# 后者只追加两行，不会覆盖别人写的东西。
if [ "$SELF_HEAL" = "1" ]; then
    if [ ! -f "$HOOK" ] || ! grep -q "$HOOK_MARK" "$HOOK" 2>/dev/null; then
        if [ -x "$BASE/hook-install.sh" ]; then
            R="$("$BASE/hook-install.sh" 2>&1)"
            log "自愈 官方钩子丢失或被覆盖，已处理：$R"
        else
            log "ERROR 钩子丢失且找不到 $BASE/hook-install.sh，请重新运行 install.sh"
        fi
    fi
fi
# ---- 1. 踢一脚两个组，强制重新排名 ----
API_G_ENC="$(urlenc "$AI_API_GROUP")"
CHAT_G_ENC="$(urlenc "$AI_CHAT_GROUP")"
API_PROBE_ENC="$(urlenc "$AI_API_PROBE")"
CHAT_PROBE_ENC="$(urlenc "$AI_CHAT_PROBE")"

API_BEFORE="$(now_of "$AI_API_GROUP")"
CHAT_BEFORE="$(now_of "$AI_CHAT_GROUP")"
PROBE_JSON="/tmp/ai-guard-probe.$$"
api "/group/$API_G_ENC/delay?timeout=6000&url=$API_PROBE_ENC" 60 | flatten > "$PROBE_JSON"
api "/group/$CHAT_G_ENC/delay?timeout=6000&url=$CHAT_PROBE_ENC" 60 >/dev/null
sleep 2
API_NOW="$(now_of "$AI_API_GROUP")"
CHAT_NOW="$(now_of "$AI_CHAT_GROUP")"
[ "$API_BEFORE"  != "$API_NOW"  ] && log "$AI_API_GROUP 重选 ${API_BEFORE:-?} -> ${API_NOW:-?}"
[ "$CHAT_BEFORE" != "$CHAT_NOW" ] && log "$AI_CHAT_GROUP 重选 ${CHAT_BEFORE:-?} -> ${CHAT_NOW:-?}"

if [ -z "$API_NOW" ] && [ -z "$CHAT_NOW" ]; then
    rm -f "$PROBE_JSON"
    log "ERROR 读不到出口组状态。API=$API 是否正确？secret 是否匹配？两个组是否已注入？"
    exit 1
fi

# ---- 2. 统计坏节点 ----
# 直接复用上面对 AI-API 组的探测结果：这个组的成员就是全部候选节点，
# 所以不需要依赖订阅里任何具体的组名。
TOTAL=0; GOOD=0; SLOW=0; DEAD=0
MEMBERS="/tmp/ai-guard-mem.$$"
api "/proxies/$API_G_ENC" 15 | sed 's/.*"all":\[//; s/\].*//' | tr ',' '\n' | sed 's/"//g' > "$MEMBERS"
while IFS= read -r n; do
    [ -z "$n" ] && continue
    TOTAL=$((TOTAL+1))
    d=$(awk -v k="$n" '$1==k {print $2; exit}' "$PROBE_JSON")
    if [ -z "$d" ]; then
        DEAD=$((DEAD+1))
    elif [ "$d" -gt "$BAD_MS" ] 2>/dev/null; then
        SLOW=$((SLOW+1))
    else
        GOOD=$((GOOD+1))
    fi
done < "$MEMBERS"
rm -f "$PROBE_JSON" "$MEMBERS"

if [ "$TOTAL" -lt 1 ]; then
    log "ERROR 取不到 $AI_API_GROUP 的成员列表，退出"; exit 1
fi
BAD=$((DEAD+SLOW))
log "探测 total=$TOTAL good=$GOOD slow=$SLOW dead=$DEAD  $AI_API_GROUP=$API_NOW $AI_CHAT_GROUP=$CHAT_NOW"
# ---- 3. 连续超阈值 + 过了冷却 → 重新拉订阅 ----
[ -f "$STATE" ] && . "$STATE"
STREAK=${STREAK:-0}; LAST_REFRESH=${LAST_REFRESH:-0}

if [ $((BAD * BAD_RATIO_DEN)) -ge $((TOTAL * BAD_RATIO_NUM)) ]; then
    STREAK=$((STREAK+1))
    log "坏节点 $BAD/$TOTAL 超过 $BAD_RATIO_NUM/$BAD_RATIO_DEN 阈值，连续第 $STREAK 次"
else
    [ "$STREAK" -gt 0 ] && log "已恢复到阈值以下，连续计数清零（原 $STREAK）"
    STREAK=0
fi

NOW=$(date +%s)
if [ "$STREAK" -ge "$NEED_STREAK" ]; then
    AGE=$((NOW - LAST_REFRESH))
    if [ "$1" = "--dry" ]; then
        log "DRY-RUN 已达到刷新条件（连续 $STREAK 次，距上次 ${AGE}s），实际不执行"
    elif [ "$AGE" -lt "$COOLDOWN" ]; then
        log "已达刷新条件但在冷却期内（距上次 ${AGE}s < ${COOLDOWN}s），跳过"
    else
        MD5_BEFORE=$(md5sum "$CFG_SRC" 2>/dev/null | awk '{print $1}')
        log "开始重新拉取订阅（坏节点 $BAD/$TOTAL 已连续 $STREAK 次）"
        /usr/share/openclash/openclash.sh >/dev/null 2>&1
        MD5_AFTER=$(md5sum "$CFG_SRC" 2>/dev/null | awk '{print $1}')
        if [ "$MD5_BEFORE" = "$MD5_AFTER" ]; then
            log "订阅内容无变化，OpenClash 不会重启 —— 说明是机场当前负载问题，不是换了节点地址"
        else
            log "订阅已更新，OpenClash 会自行重启并重新生成配置"
        fi
        LAST_REFRESH=$NOW; STREAK=0
    fi
fi

printf 'STREAK=%s\nLAST_REFRESH=%s\n' "$STREAK" "$LAST_REFRESH" > "$STATE"
if [ -f "$LOG" ]; then
    tail -n "$LOG_KEEP" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi
exit 0


