#!/bin/sh
# openclash-ai-guard / hook-install.sh
# 把"调用 ai-groups-overwrite.rb"这件事挂到 OpenClash 官方钩子上。
# install.sh 和 ai-node-watch.sh 的自愈都调用这个，逻辑只维护一份。
#
# 三种情况分开处理：
#   1) 钩子里已经有我们的调用  → 什么都不用做（或按需更新）
#   2) 钩子是官方空模板        → 直接写我们的完整版
#   3) 钩子里有用户自己的逻辑  → 只在末尾追加两行，绝不覆盖用户内容
#
# 判断"空模板"时必须把结尾的 exit 0 也算作空 —— OpenClash 的默认模板就是
# 一堆注释加一个 exit 0，不排除它会导致所有人都被判成"有自定义内容"。

BASE="/etc/openclash/ai-guard"
HOOK="/etc/openclash/custom/openclash_custom_overwrite.sh"
MARK="ai-groups-overwrite.rb"
TS="$(date +%Y%m%d_%H%M%S)"

mkdir -p /etc/openclash/custom

if [ -f "$HOOK" ] && grep -q "$MARK" "$HOOK" 2>/dev/null; then
    echo "hook: 已存在本工具的调用，跳过"
    exit 0
fi

# 过滤掉注释、空行、shebang、单独的 exit N / true / : 之后还有内容吗？
HAS_USER_LOGIC=0
if [ -f "$HOOK" ] && grep -vE '^[[:space:]]*#|^[[:space:]]*$|^#!|^[[:space:]]*exit[[:space:]]+[0-9]+[[:space:]]*$|^[[:space:]]*(true|:)[[:space:]]*$' "$HOOK" | grep -q .; then
    HAS_USER_LOGIC=1
fi

[ -f "$HOOK" ] && cp -f "$HOOK" "$BASE/hook.orig.$TS" 2>/dev/null

if [ "$HAS_USER_LOGIC" = "0" ]; then
    cp -f "$BASE/hook.sh" "$HOOK" && chmod +x "$HOOK"
    echo "hook: 原文件是官方空模板，已替换为本工具的版本"
    exit 0
fi

# 有用户逻辑：在最后一条 exit N 之前插入调用；没有 exit 就追加到末尾。
awk '
  { lines[NR] = $0 }
  function snippet() {
    print ""
    print "# ---- openclash-ai-guard ---- 由 hook-install.sh 自动加入，勿删"
    print "RB=/etc/openclash/ai-guard/ai-groups-overwrite.rb"
    print "[ -f \"$RB\" ] && ruby \"$RB\" \"$1\" >> /tmp/openclash.log 2>&1"
    print ""
  }
  END {
    last = 0
    for (i = NR; i >= 1; i--) if (lines[i] ~ /[^[:space:]]/) { last = i; break }
    isexit = (last > 0 && lines[last] ~ /^[[:space:]]*exit[[:space:]]+[0-9]+[[:space:]]*$/)
    for (i = 1; i <= NR; i++) {
      if (isexit && i == last) snippet()
      print lines[i]
    }
    if (!isexit) snippet()
  }
' "$HOOK" > "$HOOK.aiguard.new" && mv "$HOOK.aiguard.new" "$HOOK" && chmod +x "$HOOK"
echo "hook: 检测到你自己的内容，已在末尾追加调用（原文件备份在 $BASE/hook.orig.$TS）"
