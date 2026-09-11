# openclash-ai-proxy-group

给 OpenClash 加两个专门跑 AI 服务的出口策略组，并自动绕开坏节点。

适用于任何机场订阅 —— 不依赖你的订阅用什么策略组名字、什么节点命名规则。

---

## 这个东西解决什么问题

如果你在 OpenClash 后面用 Claude Code / ChatGPT / 各种 API 中转站，大概见过这些症状：

- 聊到一半流式输出突然断掉
- Cloudflare 反复弹人机验证
- 面板上测速全绿、延迟很低，但 AI 服务就是连不上
- 时好时坏，找不到规律

**根因通常不是节点质量，是出口在不停地换。**

绝大多数订阅的默认配置里，AI 服务的流量走的是最后那条 `MATCH` 兜底规则，跟着一个
包含全部节点的 `url-test` 组跑。那个组用 `gstatic.com/generate_204` 测速，每几分钟
换一次出口 —— 换出口就是换源 IP，对 Cloudflare 后面的服务来说等于换了个人，
于是重新挑战、长连接断掉。

实测记录（56 节点的机场，50 分钟）：

```
07:06 HK-2→HK-1   07:12 HK-1→JP3-HY2   07:16 →HK-5   07:25 →SG-5
07:29 →JP-1       07:33 →JP1-HY2       07:37 →HK-5   07:45 →JP5-HY2   07:56 →JP-4
```

九次切换，跨了香港、日本、新加坡三个地区。而 mihomo 自己的日志在喊：

```
because 自动选择 failed multiple times, activate health check
```

**更麻烦的是 `gstatic` 测出来的排名和 AI 服务的实际可用性没什么关系。**
同一批节点，8 轮 × 4 个 API 端点实测：

| 节点 | gstatic 测速 | 对 AI 端点实际成功率 |
|---|---|---|
| JP3-HY2 | 96ms（被选为最快，实际在用） | **0 / 32** |
| HK-1/2/4/5 | 79–84ms 全绿 | 约 65% |
| JP1-HY2 | 排名靠后 | 32 / 32 |

所以本工具做两件事：**用对的探测目标**，以及**让出口不要乱跑**。

---

## 它具体做了什么

### 1. 两个独立的 AI 出口组

| 组 | 探测目标 | 服务谁 |
|---|---|---|
| `AI-API` | `cp.cloudflare.com/generate_204` | Claude / Anthropic / 各类 API 中转站（多在 Cloudflare 后面） |
| `AI-Chat` | `chatgpt.com/cdn-cgi/trace` | ChatGPT / OpenAI |

为什么要两个：同一批节点，某个节点对 chatgpt 6/6 成功、对 API 中转站只有 21/32；
另一个节点正好相反。**它们要的节点确实不一样**，混在一个组里必然有一边被牺牲。

两个组都是 `url-test` + `tolerance: 500`：挑当前最快的（自动绕开坏节点），
但只要差距在 500ms 内就按住不动（不来回跳）。

成员是**全部节点**，不写死名单 —— 机场的坏节点集合几小时就换一批，写死只会
把好节点冤枉关在门外。

### 2. 分流规则

把配置好的域名插到规则表最前面，优先级高于订阅自带的任何 `RULE-SET`。
默认覆盖 `anthropic.com` `claude.ai` `openai.com` `chatgpt.com` 等；
你自己用的中转站域名加到配置文件里就行。

### 3. 看护脚本（每 10 分钟）

- 踢一脚两个组强制重新排名（防止组卡在一个已经打不通的节点上）
- 全量探测，统计坏节点比例，写日志留趋势
- **坏节点超过 2/3 且连续 3 次（约 30 分钟）→ 自动重拉订阅**，机场换了节点地址时能自愈
- 自检 OpenClash 官方钩子是否被 opkg 升级覆盖，被覆盖就补回来

那两道闸（连续次数 + 4 小时冷却）是必须的。晚高峰的坏节点数是分钟级抖动的
（实测 21:02 坏 28 → 21:04 坏 31 → 21:07 坏 26），没有连续判定就会被一次抖动
骗去重启全屋。
---

## 安装前提

- 一台跑 OpenWrt / iStoreOS / ImmortalWrt 的设备，已经装好 **OpenClash 并能正常上网**
- 内核是 **Meta (mihomo)** —— OpenClash 里默认就是
- 有 `ruby` `ruby-yaml` `curl`（OpenClash 装了就会带 ruby；缺了脚本会提示你装）

不需要 Docker，不需要额外依赖。

---

## 安装：三条路，选一条

### 路线 A：能 SSH 进路由器（推荐）

```bash
opkg update && opkg install ruby ruby-yaml curl unzip
```

然后下载并安装（把 `forever-sweet` 换成本仓库的 GitHub 用户名，浏览器地址栏里就有）：

```bash
cd /tmp && rm -rf openclash-ai-proxy-group* && wget -O ai-guard.zip https://github.com/forever-sweet/openclash-ai-proxy-group/archive/refs/heads/main.zip && unzip -o ai-guard.zip && cd openclash-ai-proxy-group-main && sh install.sh
```

装完会自己校验配置、重启 OpenClash，并打印当前状态。

### 路线 B：不想敲命令，用文件管理器

1. 在 GitHub 页面点 `Code` → `Download ZIP`，解压
2. 用路由器后台的「文件管理」（iStoreOS 自带）把整个文件夹上传到 `/tmp/`
3. 在后台的「终端」里执行：

```bash
cd /tmp/openclash-ai-proxy-group-main && sh install.sh
```

### 路线 C：让 AI 帮你装

复制下面整段，发给 Claude / ChatGPT / 任何能连你路由器的 AI 助手：

````text
帮我在路由器上安装 openclash-ai-proxy-group 这个工具。

我的环境：
- 路由器 IP：192.168.1.1        ← 改成你的
- SSH 用户名：root
- SSH 密码：（我会在你问的时候告诉你）
- 系统：OpenWrt / iStoreOS，已装好 OpenClash 并能正常上网

项目地址：https://github.com/forever-sweet/openclash-ai-proxy-group

请按这个顺序做，每一步告诉我结果：

1. SSH 进去，确认 OpenClash 在运行：/etc/init.d/openclash status
2. 确认依赖齐了：ruby -ryaml -e 'puts 1' 和 curl --version
   缺就装：opkg update && opkg install ruby ruby-yaml curl unzip
3. 下载并解压到 /tmp，然后执行 sh install.sh
4. 安装脚本会自己在配置副本上做内核校验（clash -t），
   如果校验不通过它会中止且不重启 —— 这种情况把完整报错发给我看
5. 装完执行 /etc/openclash/ai-guard/ai-node-watch.sh --status 给我看结果
6. 最后帮我验证一下这几个域名是不是走了新出口：
   grep -E 'anthropic|claude.ai|chatgpt' /tmp/openclash.log | tail -10
   正常应该看到 "using AI-API[...]" 或 "using AI-Chat[...]"

注意事项：
- 装之前先备份：cp -a /etc/openclash/custom /tmp/custom-backup
- 我用的 AI 中转站域名是：（如果有就填在这里，没有就说没有）
  装完请把它们加到 /etc/openclash/ai-guard/ai-guard.conf 的 AI_API_DOMAINS 里，
  然后执行 /etc/openclash/ai-guard/reload.sh
- 如果中途出错，用 /etc/openclash/ai-guard/uninstall.sh 卸载干净再说
- 不要修改我订阅里已有的节点和策略组，这个工具是新增，不是替换
````

---

## 装完之后

```bash
/etc/openclash/ai-guard/ai-node-watch.sh --status
```

正常输出长这样：

```
版本     : 1.1.0
API      : http://127.0.0.1:9090
配置     : /etc/openclash/xxx.yaml
AI-API  当前出口: JP1-HY2
AI-Chat 当前出口: JP4-HY2
状态     : STREAK=0 LAST_REFRESH=0
--- 最近 25 行日志 ---
2026-09-05 21:07:20 探测 total=56 good=30 slow=0 dead=26  AI-API=JP1-HY2 AI-Chat=JP4-HY2
```

`total` 应该等于你订阅里的节点总数（减去被 `EXCLUDE_NODE_RE` 排除的）。
如果 `dead` 常年等于 `total`、`good` 长期是 0，那不是你的机场全挂了，
是你装的是 v1.0.0 —— 升级到 v1.1.0，见 [CHANGELOG](CHANGELOG.md)。

确认流量真的走了新出口：

```bash
grep -E 'anthropic|claude.ai|chatgpt' /tmp/openclash.log | tail
```

应该看到 `match DomainSuffix(claude.ai) using AI-API[JP1-HY2]` 这样的行。
如果还是 `match Match using ...`，说明规则没生效，往下看「排查」。
---

## 配置

配置文件在 `/etc/openclash/ai-guard/ai-guard.conf`，改完执行：

```bash
/etc/openclash/ai-guard/reload.sh
```

最常改的两项：

**加自己的中转站域名**

```sh
AI_API_DOMAINS="anthropic.com claude.ai 你的中转站.com another-relay.cc"
```

填主域名就够了，子域名自动覆盖（写 `anthropic.com` 就同时管住 `api.anthropic.com`）。

**排除结构性不行的节点**

```sh
EXCLUDE_NODE_RE="^TW-"          # 排除所有 TW- 开头的
EXCLUDE_NODE_RE="台湾|下载专用"   # 排除名字里含这些字的
```

只用来排除那种长期抖动到几秒的线路。**不要拿它排除"今天测出来是坏的"节点** ——
日常好坏交给健康检查判断，写死名单一天就过期了。

⚠️ 填了值之后，它会**同时作用于你订阅自带的所有自动选择 / 负载均衡组**，不只是
本工具新建的两个组。留空（默认）则完全不碰你的原有配置。

这个设计是踩过坑之后定的：只把排除应用在 AI 组上时，兜底组照样会挑中被排除的
节点 —— 实测兜底组挑中一个被排除的 TW 节点，YouTube 直接 11 秒到超时。既然你
认定这些节点不能用，那就到处都别用。

（有空保护：如果某个组剔完会变空 —— 比如「TW自动选择」这种按地区分的组 ——
那个组会被原样保留，不会被剔成空组。）

其余参数（探测间隔、容差、阈值、冷却时间）配置文件里每一项都有注释说明。

### 可选：绕过 WAF 的白名单出口组

默认关闭。只有遇到下面这种情况才需要它：

某个站点的 WAF（典型是阿里云滑块验证）只放行一小部分出口 IP。这种情况 url-test
帮不上忙 —— 所有节点都连得通、也够快，只是**大部分节点拿回来的是验证页而不是
真内容**。延迟探测看不出任何区别。

实测碰到过一次：某中转站在 46 个节点里只有 3 个美国节点能直接返回真页面。

```sh
AI_DOCS_GROUP="AI-Docs"
AI_DOCS_DOMAINS="被拦的站点.com"
AI_DOCS_NODES="US-2 US-3 US-5"          # 实测能拿到真页面的那几个
AI_DOCS_PROBE="https://被拦的站点.com/"  # 留空则自动取第一个域名
```

怎么找出可用节点：挨个节点 curl 目标页面，看返回的是真内容还是验证页。
**不要看 HTTP 状态码** —— 滑块页也是 200，要抓页面里的关键词。

两个跟本文其他地方相反的设计，是故意的：

- **type 用 `fallback` 不是 `url-test`**。这里要的是「按我指定的顺序用」而不是
  「用最快的」—— 名单第一个能用就一直用它，挂了才顺延。
- **名单写死**。前面反复强调过别写死节点，那是因为线路质量是分钟级翻滚的；
  而「哪些 IP 被 WAF 放行」取决于机房 IP 段，是稳定的。

名单里的节点全挂时会自动退回 `AI_API_GROUP`（验证页会重新出现，但至少通）。
`AI_DOCS_GROUP` 或 `AI_DOCS_DOMAINS` 留空 = 整个功能不启用，不往配置里加任何东西。

---

## 可选：顺手调这三个 OpenClash 设置

下面三项**跟本工具无关**，不改也能用。但它们是同一批实测里发现的、对任何人都是
净收益的设置，写在这里省得你自己再踩一遍。

它们是 OpenClash 的**全局设置，影响所有流量**，改完需要重启一次 OpenClash。
不确定的话就跳过这一节。

### 1. `find-process-mode` 改成 `off`

进程匹配只对路由器自己发起的流量有效，**转发流量根本查不到进程**。但很多订阅的
模板里带着 `find-process-mode: strict`，于是每条连接都白做一次进程查找。
OpenClash 自己的界面说明写的就是：*"Only Works on Routerself, If You Are Not
Sure, Please Choose off Which Useful in Router Environment"*。

先确认你的配置里有没有 `PROCESS-NAME` / `PROCESS-PATH` 规则：

```bash
grep -cE 'PROCESS-NAME|PROCESS-PATH' /etc/openclash/$(basename $(uci -q get openclash.config.config_path))
```

返回 0 就说明这功能对你毫无用处，关掉：

```bash
uci set openclash.config.find_process_mode='off' && uci commit openclash && /etc/init.d/openclash restart
```

### 2. 打开订阅自动更新

**这条和本工具直接相关**：看护脚本判定机场整体崩了会去重拉订阅，但如果你从没让
OpenClash 拉过新订阅，它拉回来的还是同一份缓存 —— 机场换了节点地址你也拿不到。

设成每天凌晨 3 点（geo 那几个任务默认在 4 点，不冲突）：

```bash
uci set openclash.config.auto_update='1' && uci set openclash.config.config_auto_update_mode='0' && uci set openclash.config.config_update_week_time='*' && uci set openclash.config.auto_update_time='3' && uci commit openclash && /etc/init.d/openclash restart
```

### 3. 健康检查换成 Cloudflare 的连通性端点，间隔别设太长

OpenClash 默认给所有 url-test 组用 `http://www.gstatic.com/generate_204`。
两个问题：

**明文 HTTP 测出来的延迟和真实 TLS 路径质量脱节** —— 一个节点明文能通、TLS 被干扰
的情况很常见。

**gstatic 这个目标本身也不可靠。** 实测同一时刻同一批节点：

| 节点 | gstatic | cp.cloudflare.com | github.com |
|---|---|---|---|
| HK-6 | 6318ms | 179ms | 310ms |
| HK-2 | 失败 | 2497ms | 356ms |

gstatic 判 HK-6 快废了、判 HK-2 死了，而这两个节点当时访问 GitHub 都是正常的。
按 gstatic 排名会把好节点当坏的踢掉、把坏的选上来。
`cp.cloudflare.com/generate_204` 是 Cloudflare 官方的连通性检测端点，走 anycast，
和大多数境外站点的实际路径更接近。

**间隔也别设太长。** 机场节点是分钟级翻滚的，`interval` 设成 600 意味着组可能在一个
已经打不通的节点上停留最多 10 分钟 —— 实测撞上过：兜底组停在一个死掉的 HK 节点上，
GitHub 和 YouTube 全部超时，直到下一次健康检查才恢复。180 秒是个比较平衡的值。

```bash
uci set openclash.config.urltest_address_mod='https://cp.cloudflare.com/generate_204' && uci set openclash.config.urltest_interval_mod='180' && uci set openclash.config.tolerance='300' && uci commit openclash && /etc/init.d/openclash restart
```

`tolerance='300'` 的作用是：大家延迟都差不多时按住不动，只有明显更快（差 300ms 以上）
才切换，避免没必要的出口跳动打断长连接。

> 注意这三个 UCI 项只影响**订阅自带的**那些 url-test 组。本工具新建的两个 AI 组
> 用的是 `ai-guard.conf` 里的独立设置，不受它们影响 —— 这是故意的：通用浏览和
> AI 服务对"多久探一次、多大差距才换"的需求本来就不一样。

---

## 常用命令

```bash
/etc/openclash/ai-guard/ai-node-watch.sh --status   # 看状态和最近日志
```

```bash
/etc/openclash/ai-guard/ai-node-watch.sh --dry      # 只探测，绝不刷订阅
```

```bash
/etc/openclash/ai-guard/reload.sh                   # 改完配置后重新应用
```

```bash
/etc/openclash/ai-guard/uninstall.sh                # 干净卸载
```

---

## 升级

重新跑一次 `install.sh` 就行，它是幂等的。**你的 `ai-guard.conf` 不会被覆盖** ——
新版配置会存成 `ai-guard.conf.new` 供你对比（新增的键需要自己手动搬过去）。

```bash
cd /tmp && rm -rf openclash-ai-proxy-group* && wget -O ai-guard.zip https://github.com/forever-sweet/openclash-ai-proxy-group/archive/refs/heads/main.zip && unzip -o ai-guard.zip && cd openclash-ai-proxy-group-main && sh install.sh
```

每版改了什么见 [CHANGELOG.md](CHANGELOG.md)。当前版本用 `--status` 第一行确认。

---

## 排查

**改了 ai-guard.conf 但好像没生效**

一定要跑 `reload.sh`，不要只 `/etc/init.d/openclash restart`。

`/etc/init.d/openclash restart` **不一定会重新走配置生成流程** —— 订阅和设置都没变
时它可能直接拿现成的配置把内核拉起来，钩子根本不会被调用。`reload.sh` 会先把注入
就地做到运行中的配置上再重启，所以一定生效（改动前的配置备份成
`<配置名>.aiguard.bak`）。

**面板里看不到 AI-API / AI-Chat 两个组**

钩子没跑。检查：

```bash
grep -c ai-groups-overwrite /etc/openclash/custom/openclash_custom_overwrite.sh
```

返回 0 就是钩子被覆盖了（OpenClash 的 opkg 升级会干这事，它的 conffiles 列表是
空的，`custom/` 下的官方文件会被还原成默认版）。补回来：

```bash
/etc/openclash/ai-guard/hook-install.sh && /etc/openclash/ai-guard/reload.sh
```

或者什么都不做，等看护脚本自愈 —— 它每 10 分钟检查一次。

顺便提醒：同一次升级也会把 **`openclash_custom_rules.list` 还原成默认版**，
你自己写的自定义规则会一起消失。这跟本工具无关，但值得你知道。

**你自己写的自定义规则整个失效了（一条都不生效）**

不是本工具引起的，但这个坑很值得知道，因为**它不报任何错**。

`/etc/openclash/custom/openclash_custom_rules.list` 是被 OpenClash 用
`YAML.load_file` 读取的，所以它必须是**顶层 `rules:` 键 + 每行 `- ` 前缀**：

```yaml
rules:
- DOMAIN-SUFFIX,example.com,DIRECT
- DOMAIN-KEYWORD,foo,DIRECT
```

如果写成纯文本行（少了 `rules:` 或少了 `- `），YAML 会把整个文件解析成**一个字符串**，
OpenClash 取到的规则数组是空的 → **整个文件被静默丢弃，日志里连一句警告都没有**。

自查：

```bash
ruby -ryaml -e "puts YAML.load_file('/etc/openclash/custom/openclash_custom_rules.list').class"
```

输出 `Hash` 才是对的。输出 `String` 或 `Array` 就是格式错了。

也可以数一下运行配置里的规则条数，正常应该包含你写的那些：

```bash
ruby -ryaml -e "puts YAML.load_file('/etc/openclash/$(basename $(uci -q get openclash.config.config_path))')['rules'].size"
```

**日志里 `dead` 几乎等于 `total`，但节点其实能用**

如果你的节点名带空格（`🇭🇰 香港 01` 这种），你装的是 v1.0.0。那一版用
`awk '$1==名字'` 查延迟表，awk 按空白分字段、`$1` 只拿到第一个词，于是名字带
空格的节点一律查不到、全被记成 dead。升级到 v1.1.0。

判断方法：`--status` 第一行有没有版本号。没有就是 v1.0.0。

**订阅被反复重拉**

同上，是上面那个 bug 的连带后果：坏节点率常驻 100% → 连续 3 次过阈值 →
每过 4 小时冷却就重拉一次。升级即止。

**组在，但域名还是走兜底规则**

看规则有没有注入进去：

```bash
grep -nE 'AI-API|AI-Chat' /etc/openclash/$(basename $(uci -q get openclash.config.config_path)) | head
```

**日志里出现 `Psych::AliasesNotEnabled`**

配置里有 YAML 锚点/别名。本工具自己不会产生（数组都做了 `dup`），
如果出现说明是别的脚本或订阅模板带进来的。

**订阅更新后组消失了**

不会。钩子在 OpenClash 每次生成配置时都跑，订阅更新也会触发。
如果真消失了，就是钩子文件被覆盖了，见上面第一条。

---

## 四个踩过的坑（如果你要改这份代码，请先读）

**0. 解析 JSON 一定要用 ruby，不要用 sed / tr / awk 拆**

`ruby-yaml` 已经是硬依赖，JSON 又是 YAML 的子集，所以解析是零成本的。
自己拆字符串的代价见 v1.1.0 的修复记录 —— 一个 `awk '$1==k'` 让所有带空格的
节点名全被误判成 dead，而且**不报任何错**，只是统计数字悄悄全错。

用 ruby 解析还有一个好处：拿不到的东西就是拿不到，不会给你半截字符串。

**1. 不要用 `type: fallback`（唯一的例外是 AI-Docs）**

`fallback` 只判断"活/死"，不看质量。晚高峰时大量节点处于「能回包但已经 1 秒多」
的状态而不是干脆的死，`fallback` 会因为它在成员列表里更靠前而选中它。
实测：`HK-5 1131ms` 和 `JP4-HY2 193ms` 之间，fallback 选了 HK-5，
客户端表现是 TLS 握手失败。所以本工具用 `url-test` + 大 `tolerance`。

唯一的例外是上面那个可选的 AI-Docs 组，它**故意**用 `fallback`：那里要的不是
"最快"，是"按我指定的顺序用"，而"哪些 IP 被 WAF 放行"这件事跟延迟无关。
换句话说，只有当你**确实想要"按名单顺序、能用就用第一个"**时才该写 `fallback`，
其他任何情况下都用 `url-test`。

**2. 绝对不要加 `expected-status`**

一旦全部成员被判死，`url-test` 就再也不重新选择，**永远卡在第一个成员上**。
实测过一个组卡在完全打不通的节点上 4 分钟纹丝不动，`interval` 和 `lazy: false`
都不起作用。

最坑的地方：`/proxies/<节点>/delay` 和 `/group/<组>/delay` 这两个 API **都不套用**
`expected-status`。所以你手动测样样正常、组却是死的 —— 这个不一致是唯一的线索。

**3. 数组一定要 `dup`**

两个策略组共用同一个 Ruby 数组对象时，Psych 会输出 YAML 锚点/别名（`&1` / `*1`）。
mihomo 本身吃得下，`clash -t` 也能过 —— 但 OpenClash 自己的 ruby helper 用的是
不带 `aliases: true` 的 `YAML.load_file`，之后任何一次 OpenClash 侧解析都会抛
`Psych::AliasesNotEnabled`。这个雷会一直埋到下次订阅更新才炸。

顺便一个 shell 的坑：busybox 的 `.`（source）对不存在的文件是**致命错误**，
`2>/dev/null` 只是把报错藏了、脚本照样直接退出。必须先 `[ -f ]` 判断。

---

## 它不能做什么

**这个工具不会让你的节点变得更耐用。** 节点活多久是机场服务器和线路的事，
路由器这边管不着。实测同一个节点下午 32/32 全成功、晚上直接打不通；
晚高峰 56 个节点里 34 个不可用。

它能做的只是：**在坏节点里尽快找到还能用的那个，并且不要没事乱换。**

如果你的机场晚高峰整体崩掉，这个工具会记录下来、并在确认不是抖动之后帮你重拉
订阅 —— 但换机场是你的决定，不是脚本的。

---

## 我在用的机场

> **利益披露：下面是我自己的推广链接，我会拿到返利。**

本文所有实测数据（节点延迟、对 AI 端点的成功率、晚高峰坏节点比例）都来自
[mitce](https://mitce.io/aff.php?aff=52428)。这既是数据的来源，也是数据的局限 ——
换一家机场，具体数字和结论都未必一样，别把这里的节点名当成什么通用结论。

需要说清楚的是：**这个工具不依赖任何特定机场**，它读的是你自己订阅里的节点，
用你自己配的探测目标排名。你用别家一样能跑，没有任何绑定。

如果你已经有机场且用着没问题，不用换 —— 本文档对你的价值在前面那些实测和踩坑，
不在这一节。

---

## 许可

MIT


