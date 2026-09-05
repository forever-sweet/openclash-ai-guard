#!/bin/sh
# openclash-ai-guard / hook.sh
# 安装后位于 /etc/openclash/custom/openclash_custom_overwrite.sh
#
# 这是 OpenClash 的官方钩子：它在生成配置完成后调用本脚本，
# $1 = 本次即将启动的配置文件路径。
#
# 注意网上流传的模板常见一个错误：忽略 $1、去 sed 改订阅源文件和上一次的成品文件。
# 那样既改不到本次真正启动的配置（等于空转），还会污染订阅缓存。一定要用 $1。

CFG="$1"
if [ -z "$CFG" ]; then
    CFG="/etc/openclash/$(basename "$(uci -q get openclash.config.config_path)" 2>/dev/null)"
fi
[ -f "$CFG" ] || exit 0

RB="/etc/openclash/ai-guard/ai-groups-overwrite.rb"
[ -f "$RB" ] || exit 0

# ai-groups-overwrite.rb（openclash-ai-guard）
ruby "$RB" "$CFG" 2>&1 | while read -r line; do
    [ -n "$line" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') $line" >> /tmp/openclash.log
done

exit 0
