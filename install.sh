#!/bin/sh
# openclash-ai-guard 安装脚本
# 用法:  sh install.sh
# 特点:  幂等（可重复执行）、装前校验、失败不重启、附带一键卸载

set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
BASE="/etc/openclash/ai-guard"
HOOK="/etc/openclash/custom/openclash_custom_overwrite.sh"
HOOK_MARK="ai-groups-overwrite.rb"
CRON="/etc/crontabs/root"
CRON_MARK="#ai-guard-watch"
TS="$(date +%Y%m%d_%H%M%S)"

say()  { echo "  $*"; }
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [注意] $*"; }
die()  { echo "  [失败] $*"; exit 1; }

echo ""
echo "=============================================="
echo " openclash-ai-guard 安装"
echo "=============================================="

# ---------- 1. 环境检查 ----------
echo ""
echo "[1/6] 检查环境"
[ -f /etc/openclash/custom/openclash_custom_rules.list ] || [ -d /etc/openclash ] \
    || die "没找到 /etc/openclash，这台设备上似乎没装 OpenClash"
command -v ruby  >/dev/null 2>&1 || die "缺少 ruby。装一下：opkg update && opkg install ruby ruby-yaml"
command -v curl  >/dev/null 2>&1 || die "缺少 curl。装一下：opkg update && opkg install curl"
command -v uci   >/dev/null 2>&1 || die "缺少 uci，这不像 OpenWrt 系统"
ruby -ryaml -e 'exit 0' </dev/null 2>/dev/null || die "ruby 缺少 yaml 模块：opkg install ruby-yaml"
ok "ruby / curl / uci 都在"

CFG_SRC="$(uci -q get openclash.config.config_path)"
[ -n "$CFG_SRC" ] || die "OpenClash 还没选订阅配置文件，先在面板里选好并启动一次"
RUN_CFG="/etc/openclash/$(basename "$CFG_SRC")"
[ -f "$RUN_CFG" ] || die "找不到运行中的配置 $RUN_CFG，先让 OpenClash 正常启动一次"
ok "运行中的配置: $RUN_CFG"

CORE=""
for c in /etc/openclash/clash /etc/openclash/core/clash_meta /etc/openclash/clash_meta; do
    [ -x "$c" ] && CORE="$c" && break
done
[ -n "$CORE" ] && ok "内核: $CORE" || warn "没找到内核可执行文件，将跳过配置校验"
# ---------- 2. 复制文件 ----------
echo ""
echo "[2/6] 安装文件到 $BASE"
mkdir -p "$BASE"
for f in ai-groups-overwrite.rb ai-node-watch.sh hook.sh hook-install.sh reload.sh uninstall.sh; do
    [ -f "$SRC/$f" ] || die "安装包里缺少 $f"
    cp -f "$SRC/$f" "$BASE/$f"
done
chmod +x "$BASE/ai-node-watch.sh" "$BASE/hook.sh" "$BASE/hook-install.sh" "$BASE/reload.sh" "$BASE/uninstall.sh"

if [ -f "$BASE/ai-guard.conf" ]; then
    cp -f "$SRC/ai-guard.conf" "$BASE/ai-guard.conf.new"
    warn "已有配置文件，保留你的。新版本存为 ai-guard.conf.new，可自行对比"
else
    cp -f "$SRC/ai-guard.conf" "$BASE/ai-guard.conf"
    ok "已写入默认配置 $BASE/ai-guard.conf"
fi
. "$BASE/ai-guard.conf"
AI_API_GROUP="${AI_API_GROUP:-AI-API}"
AI_CHAT_GROUP="${AI_CHAT_GROUP:-AI-Chat}"

# ---------- 3. 装官方钩子 ----------
echo ""
echo "[3/6] 挂上 OpenClash 官方钩子"
OUT="$("$BASE/hook-install.sh" 2>&1)"
say "$OUT"
grep -q "$HOOK_MARK" "$HOOK" 2>/dev/null && ok "钩子就位" || die "钩子安装失败: $OUT"

# ---------- 4. 装 cron ----------
echo ""
echo "[4/6] 添加定时任务（每 10 分钟）"
touch "$CRON"
grep -v 'ai-node-watch.sh' "$CRON" > /tmp/aiguard.cron.$$ 2>/dev/null || true
echo "7,17,27,37,47,57 * * * * $BASE/ai-node-watch.sh $CRON_MARK" >> /tmp/aiguard.cron.$$
cat /tmp/aiguard.cron.$$ > "$CRON"; rm -f /tmp/aiguard.cron.$$
/etc/init.d/cron restart >/dev/null 2>&1 || true
ok "已加入 crontab（标记 $CRON_MARK，OpenClash 重启不会删它）"
# ---------- 5. 校验 + 应用 + 重启（交给 reload.sh，逻辑只维护一份）----------
echo ""
echo "[5/6] 校验并应用"
if [ "$HOOK_MANUAL" = "1" ]; then
    warn "钩子需要你手动加那两行，这次先不应用。加完后执行： $BASE/reload.sh"
else
    # reload.sh 里做了：副本试跑 → 内核 clash -t 校验 → 就地写入 → 重启 → 指派分流组
    # 校验不过它会直接退出且不重启，你的网络不受影响
    "$BASE/reload.sh" || die "应用失败，上面有原因；已装好的文件不影响现有网络，修好后执行 $BASE/reload.sh"
fi

# ---------- 6. 收尾 ----------
echo ""
echo "[6/6] 完成"

echo ""
echo "=============================================="
echo " 装好了"
echo "=============================================="
echo ""
echo "  配置文件   $BASE/ai-guard.conf"
echo "  改完执行   $BASE/reload.sh"
echo "  看状态     $BASE/ai-node-watch.sh --status"
echo "  只测不改   $BASE/ai-node-watch.sh --dry"
echo "  卸载       $BASE/uninstall.sh"
echo "  日志       /tmp/ai-guard.log"
echo ""
echo "  下一步：把你自己在用的中转站域名加到 ai-guard.conf 的"
echo "  AI_API_DOMAINS 里，然后跑一次 reload.sh。"
echo ""

