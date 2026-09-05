# -*- coding: utf-8 -*-
# openclash-ai-guard / ai-groups-overwrite.rb
#
# 在 OpenClash 生成配置的最后一步，往配置里注入两个 AI 专用出口策略组和对应的
# 分流规则。由 OpenClash 官方钩子 openclash_custom_overwrite.sh 调用，参数是
# 本次即将启动的配置文件路径。
#
# 幂等：可以反复执行。任何异常都不写回，配置保持原样。
#
# 为什么这么设计（都是实测踩出来的，改之前请读完）：
#
#  1) 用 url-test，不要用 fallback。
#     fallback 只判断节点"活/死"，不看质量。晚高峰时大量节点处于"能回包但已经
#     1 秒多"的状态而不是干脆的死，fallback 会因为它在列表里更靠前而选中它。
#     实测过：HK-5 1131ms 和 JP4-HY2 193ms 之间，fallback 选了 HK-5，
#     客户端表现为 TLS 握手失败。url-test + 大 tolerance 才是对的。
#
#  2) 绝对不要加 expected-status。
#     一旦全部成员被判死，url-test 就再也不重新选择，永远卡在第一个成员上。
#     实测过：某个组卡在完全打不通的节点上 4 分钟纹丝不动。
#     最坑的是 /proxies/<节点>/delay 和 /group/<组>/delay 这两个 API 都不套用
#     expected-status，所以你手动测样样正常、组却是死的 —— 这个不一致是唯一线索。
#
#  3) 探测目标必须和真实用途同源。
#     用 gstatic 测出来排第一的节点，对 AI 服务实测 8 轮 0 次成功。
#     而且 ChatGPT 和 Claude 中转站要的节点不一样（同一个节点对 chatgpt 6/6 成功、
#     对中转站只有 21/32），所以拆成两个组各测各的。
#
#  4) 成员不写死名单。
#     机场的坏节点集合几小时就换一批（下午死的到晚上大半复活）。而且被剔出所有
#     url-test 组的节点没人探测，API 里 alive 字段会返回没意义的 true。
#     所以放全量进去，让健康检查自己判。
require 'yaml'

CONF_PATH = ENV['AI_GUARD_CONF'] || '/etc/openclash/ai-guard/ai-guard.conf'
path = ARGV[0]
abort 'ai-guard: 没有传配置文件路径' if path.nil? || !File.exist?(path)

# ---- 读配置：只认 KEY="值" ----
def load_conf(file)
  c = {}
  return c unless File.exist?(file)
  File.foreach(file) do |line|
    next if line =~ /\A\s*#/
    m = line.match(/\A\s*([A-Z0-9_]+)\s*=\s*"(.*)"\s*\z/)
    c[m[1]] = m[2] if m
  end
  c
end
CONF = load_conf(CONF_PATH)
def cf(k, d = '') ; v = CONF[k]; (v.nil? || v.empty?) ? d : v ; end
def ci(k, d) ; Integer(cf(k, d.to_s)) rescue d ; end
API_GROUP    = cf('AI_API_GROUP',  'AI-API')
CHAT_GROUP   = cf('AI_CHAT_GROUP', 'AI-Chat')
API_PROBE    = cf('AI_API_PROBE',  'https://cp.cloudflare.com/generate_204')
CHAT_PROBE   = cf('AI_CHAT_PROBE', 'https://chatgpt.com/cdn-cgi/trace')
API_INTERVAL = ci('AI_API_INTERVAL',  120)
CHAT_INTERVAL= ci('AI_CHAT_INTERVAL', 240)
TOLERANCE    = ci('TOLERANCE', 500)
EXCLUDE_RE   = cf('EXCLUDE_NODE_RE').empty? ? nil : Regexp.new(cf('EXCLUDE_NODE_RE'))
API_DOMAINS  = cf('AI_API_DOMAINS').split(/\s+/).reject(&:empty?)
CHAT_DOMAINS = cf('AI_CHAT_DOMAINS').split(/\s+/).reject(&:empty?)
API_ADOPT    = cf('AI_API_ADOPT_GROUPS').split(/\s+/).reject(&:empty?)
CHAT_ADOPT   = cf('AI_CHAT_ADOPT_GROUPS').split(/\s+/).reject(&:empty?)
DROP_FP      = cf('DROP_GLOBAL_FINGERPRINT', '0') == '1'

cfg = YAML.load_file(path)
abort 'ai-guard: 配置不是一个 YAML 映射' unless cfg.is_a?(Hash)
nodes  = (cfg['proxies'] || []).map { |p| p['name'] }.compact
groups = (cfg['proxy-groups'] || [])
abort 'ai-guard: 配置里没有 proxies'      if nodes.empty?
abort 'ai-guard: 配置里没有 proxy-groups' if groups.empty?

pool = EXCLUDE_RE ? nodes.reject { |n| n =~ EXCLUDE_RE } : nodes
pool = nodes if pool.empty?   # 排除规则写太狠时的兜底

def mk_group(name, members, probe, interval, tolerance)
  # members 必须 dup。两个组共用同一个数组对象时，Psych 会输出 YAML 锚点/别名
  # (&1 / *1)，而 OpenClash 自己的 ruby helper 用的是不带 aliases: true 的
  # YAML.load_file，之后任何一次解析都会抛 Psych::AliasesNotEnabled。
  # mihomo 本身吃得下这种配置，所以这个雷会一直埋到下次订阅更新才炸。
  { 'name'      => name,
    'type'      => 'url-test',
    'proxies'   => members.dup,
    'url'       => probe,
    'interval'  => interval,
    'tolerance' => tolerance,
    'lazy'      => false }
end

# ---- 1. 建两个出口组（同一个候选池，各自按自己的探测目标独立排名）----
groups.reject! { |g| [API_GROUP, CHAT_GROUP].include?(g['name']) }
groups << mk_group(API_GROUP,  pool, API_PROBE,  API_INTERVAL,  TOLERANCE)
groups << mk_group(CHAT_GROUP, pool, CHAT_PROBE, CHAT_INTERVAL, TOLERANCE)

# ---- 2. 接管订阅自带的分流组（存在才动，不存在就跳过）----
adopted = []
[[API_ADOPT, API_GROUP], [CHAT_ADOPT, CHAT_GROUP]].each do |names, target|
  names.each do |gn|
    g = groups.find { |x| x['name'] == gn && x['type'] == 'select' }
    next unless g
    g['proxies'] = (g['proxies'] || []).reject { |n| n == target }
    g['proxies'].unshift(target)
    adopted << "#{gn}->#{target}"
  end
end
# ---- 3. 塞进兜底组，让两个组在面板上能手选 ----
# 兜底组 = MATCH / FINAL 规则指向的那个组，不依赖任何具体名字，各家订阅都能认。
rules = cfg['rules'].is_a?(Array) ? cfg['rules'] : []
match_rule = rules.find { |r| r.to_s =~ /\A(MATCH|FINAL)[,\s]/ }
if match_rule
  parts  = match_rule.to_s.split(',').map(&:strip)
  target = parts[-1] =~ /\A(no-resolve|src)\z/ ? parts[-2] : parts[-1]
  g = groups.find { |x| x['name'] == target && x['type'] == 'select' }
  if g
    g['proxies'] = (g['proxies'] || []).reject { |n| [API_GROUP, CHAT_GROUP].include?(n) }
    g['proxies'].unshift(API_GROUP, CHAT_GROUP)
  end
end

# ---- 3.5 把排除规则也应用到订阅自带的自动/负载均衡组 ----
# EXCLUDE_NODE_RE 默认为空 → 这一步什么都不做，不会碰别人的配置。
# 只有用户明确写了排除规则时才生效 —— 既然他认定这些节点不能用，
# 那些组里留着它们只会让 url-test 时不时挑中一个坏的（实测遇到过：
# 排除规则只作用于 AI 组时，兜底组挑中了被排除的节点，YouTube 直接超时）。
# 空保护：剔完为空就整组不动。
if EXCLUDE_RE
  groups.each do |g|
    next unless %w[url-test load-balance fallback].include?(g['type'])
    next if [API_GROUP, CHAT_GROUP].include?(g['name'])
    list = g['proxies']
    next unless list.is_a?(Array) && !list.empty?
    kept = list.reject { |n| n =~ EXCLUDE_RE }
    g['proxies'] = kept unless kept.empty?
  end
end

# ---- 4. 注入分流规则，插在最前面 ----
# 唯一的例外是把 QUIC(UDP/443) 的 REJECT 留在第一条 —— 那是全局策略，别被顶掉。
new_rules  = API_DOMAINS.map  { |d| "DOMAIN-SUFFIX,#{d},#{API_GROUP}" }
new_rules += CHAT_DOMAINS.map { |d| "DOMAIN-SUFFIX,#{d},#{CHAT_GROUP}" }
unless new_rules.empty?
  # 先清掉本工具上次注入的，保证幂等
  rules = rules.reject { |r| r.to_s.end_with?(",#{API_GROUP}", ",#{CHAT_GROUP}") }
  qidx  = rules.index { |r| r.to_s =~ /NETWORK,UDP\).*REJECT/ }
  at    = qidx.nil? ? 0 : qidx + 1
  new_rules.reverse.each { |r| rules.insert(at, r) }
  cfg['rules'] = rules
end

# ---- 5. 可选：删掉新版 mihomo 已移除的 global-client-fingerprint ----
cfg.delete('global-client-fingerprint') if DROP_FP

cfg['proxy-groups'] = groups

# 原子写：先写临时文件再 rename，中途出错不会留下半个配置
tmp = path + '.aiguard.tmp'
YAML.dump(cfg, File.open(tmp, 'w'))
File.rename(tmp, path)

warn "ai-guard: ok pool=#{pool.size}/#{nodes.size} " \
     "groups=#{API_GROUP},#{CHAT_GROUP} rules=#{new_rules.size} " \
     "adopt=#{adopted.empty? ? '-' : adopted.join(',')}"

