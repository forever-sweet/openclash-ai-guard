#!/bin/sh
# openclash-ai-guard / uninstall.sh
# 干净卸载：撤掉定时任务、还原官方钩子、删掉自己的文件，然后重启 OpenClash。
# 不会动你的订阅、不会动 OpenClash 的任何设置。

BASE="/etc/openclash/ai-guard"
HOOK="/etc/openclash/custom/openclash_custom_overwrite.sh"
CRON="/etc/crontabs/root"

echo ""
echo "=============================================="
echo " openclash-ai-guard 卸载"
echo "=============================================="

echo ""
echo "[1/4] 撤掉定时任务"
if [ -f "$CRON" ]; then
    grep -v 'ai-node-watch.sh' "$CRON" > /tmp/aiguard.uncron.$$ 2>/dev/null || true
    cat /tmp/aiguard.uncron.$$ > "$CRON"; rm -f /tmp/aiguard.uncron.$$
    /etc/init.d/cron restart >/dev/null 2>&1 || true
fi
echo "  [OK]   已移除"

echo ""
echo "[2/4] 还原官方钩子"
ORIG="$(ls -1t "$BASE"/hook.orig.* 2>/dev/null | head -1)"
if [ -n "$ORIG" ] && [ -f "$ORIG" ]; then
    cp -f "$ORIG" "$HOOK"; chmod +x "$HOOK"
    echo "  [OK]   已还原为安装前的版本 ($ORIG)"
elif grep -q 'ai-groups-overwrite.rb' "$HOOK" 2>/dev/null; then
    # 没有备份但确认是本工具装的，写回一个空模板
    cat > "$HOOK" <<'EOS'
#!/bin/sh
# OpenClash Overwrite Script
# $1 = 本次即将启动的配置文件路径
exit 0
EOS
    chmod +x "$HOOK"
    echo "  [OK]   已写回空模板"
else
    echo "  [跳过] 钩子里不是本工具的内容，没有动它"
fi

echo ""
echo "[3/4] 删除文件"
rm -rf "$BASE"
rm -f /tmp/ai-guard.log /tmp/ai-guard.state
echo "  [OK]   已删除 $BASE"

echo ""
echo "[4/4] 重启 OpenClash 让两个 AI 组消失"
/etc/init.d/openclash restart >/dev/null 2>&1 &
n=0; while [ $n -lt 24 ]; do sleep 5; n=$((n+1))
    [ "$(/etc/init.d/openclash status 2>/dev/null)" = "running" ] && break; done
echo "  [OK]   状态: $(/etc/init.d/openclash status 2>/dev/null)"
echo ""
echo " 卸载完成。被接管过的分流组（如 OpenAI）现在会自动回落到列表第一项，"
echo " 需要的话去面板手动选一下。"
echo ""
