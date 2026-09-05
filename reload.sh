#!/bin/sh
# openclash-ai-guard / reload.sh
# 改完 ai-guard.conf 之后执行这个。
#   reload.sh           校验 → 就地应用 → 重启 OpenClash → 指派分流组
#   reload.sh --adopt   只做最后那步（不重启）
#
# 为什么要"就地应用"而不是只靠钩子：
#   /etc/init.d/openclash restart 并不一定会重新走一遍配置生成流程 —— 订阅和
#   设置都没变时它可能直接拿现成的配置把内核拉起来，钩子根本不会被调用。
#   实测过：改完 ai-guard.conf 后 restart，配置里的组还是旧的。
#   所以这里先把注入直接做到运行中的配置上，再重启。脚本是幂等的，
#   万一 OpenClash 真的重新生成了，钩子会再做一遍，结果一样。

BASE="/etc/openclash/ai-guard"
CONF="$BASE/ai-guard.conf"
[ -f "$CONF" ] && . "$CONF"
AI_API_GROUP="${AI_API_GROUP:-AI-API}"
AI_CHAT_GROUP="${AI_CHAT_GROUP:-AI-Chat}"

CFG_SRC="$(uci -q get openclash.config.config_path)"
RUN_CFG="/etc/openclash/$(basename "$CFG_SRC" 2>/dev/null)"
EC="$(sed -n 's/^external-controller:[[:space:]]*["'\'']\?\([^"'\'' ]*\).*/\1/p' "$RUN_CFG" 2>/dev/null | head -1)"
SECRET="$(sed -n 's/^secret:[[:space:]]*["'\'']\?\([^"'\'']*\)["'\'']\?[[:space:]]*$/\1/p' "$RUN_CFG" 2>/dev/null | head -1)"
[ -z "$EC" ] && EC="127.0.0.1:9090"
EC="$(echo "$EC" | sed -e 's/^0\.0\.0\.0:/127.0.0.1:/' -e 's/^\[::\]:/127.0.0.1:/' -e 's/^:/127.0.0.1:/')"
API="http://$EC"
urlenc() { ruby -rcgi -e 'print CGI.escape(ARGV[0])' "$1" </dev/null 2>/dev/null || echo "$1"; }

# 把订阅自带的分流组指到我们的出口组。必须走 API 而不是只改配置文件：
# profile.store-selected: true 时，面板上"上次选的那个"会覆盖配置里的第一项。
adopt() {
    for pair in "$AI_API_ADOPT_GROUPS|$AI_API_GROUP" "$AI_CHAT_ADOPT_GROUPS|$AI_CHAT_GROUP"; do
        list="${pair%|*}"; target="${pair##*|}"
        for g in $list; do
            code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
                   ${SECRET:+-H "Authorization: Bearer $SECRET"} \
                   -H 'Content-Type: application/json' \
                   -X PUT -d "{\"name\":\"$target\"}" \
                   "$API/proxies/$(urlenc "$g")" 2>/dev/null)
            [ "$code" = "204" ] && echo "  [OK]   分流组 $g 已指向 $target"
        done
    done
}
[ "$1" = "--adopt" ] && { adopt; exit 0; }

core_path() {
    for c in /etc/openclash/clash /etc/openclash/core/clash_meta; do
        [ -x "$c" ] && echo "$c" && return
    done
}
[ -f "$RUN_CFG" ] || { echo "  [失败] 读不到运行中的配置 $RUN_CFG"; exit 1; }
CORE="$(core_path)"

echo "[1/4] 在副本上校验"
T="/tmp/aiguard-reload.$$.yaml"
cp -f "$RUN_CFG" "$T" || { echo "  [失败] 复制配置失败"; exit 1; }
AI_GUARD_CONF="$CONF" ruby "$BASE/ai-groups-overwrite.rb" "$T" </dev/null || {
    rm -f "$T"; echo "  [失败] 注入脚本报错，已中止，什么都没改"; exit 1; }
if grep -qE '^\s*-\s+\*[0-9]' "$T" 2>/dev/null; then
    rm -f "$T"; echo "  [失败] 生成的配置里出现 YAML 别名，已中止"; exit 1
fi
if [ -n "$CORE" ]; then
    if ! SAFE_PATHS=/usr/share/openclash:/etc/ssl "$CORE" -t -d /etc/openclash -f "$T" 2>&1 \
         | grep -q 'test is successful'; then
        SAFE_PATHS=/usr/share/openclash:/etc/ssl "$CORE" -t -d /etc/openclash -f "$T" 2>&1 | tail -6
        rm -f "$T"; echo "  [失败] 内核校验未通过，已中止，什么都没改"; exit 1
    fi
fi
rm -f "$T"
echo "  [OK]   校验通过"

echo "[2/4] 就地应用到运行中的配置"
cp -f "$RUN_CFG" "$RUN_CFG.aiguard.bak"
if AI_GUARD_CONF="$CONF" ruby "$BASE/ai-groups-overwrite.rb" "$RUN_CFG" </dev/null; then
    echo "  [OK]   已写入（原文件备份为 $(basename "$RUN_CFG").aiguard.bak）"
else
    cp -f "$RUN_CFG.aiguard.bak" "$RUN_CFG"
    echo "  [失败] 写入失败，已回滚"; exit 1
fi

echo "[3/4] 重启 OpenClash"
/etc/init.d/openclash restart >/dev/null 2>&1 &
n=0
while [ $n -lt 24 ]; do
    sleep 5; n=$((n+1))
    [ "$(/etc/init.d/openclash status 2>/dev/null)" = "running" ] && break
done
echo "  [OK]   状态: $(/etc/init.d/openclash status 2>/dev/null)"

echo "[4/4] 指派分流组"
sleep 3
adopt
echo ""
"$BASE/ai-node-watch.sh" --status 2>/dev/null || true
