# openclash-ai-guard

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

然后下载并安装（把 `你的用户名` 换成实际的 GitHub 用户名）：

```bash
cd /tmp && rm -rf openclash-ai-guard* && wget -O ai-guard.zip https://github.com/你的用户名/openclash-ai-guard/archive/refs/heads/main.zip && unzip -o ai-guard.zip && cd openclash-ai-guard-main && sh install.sh
```

装完会自己校验配置、重启 OpenClash，并打印当前状态。

### 路线 B：不想敲命令，用文件管理器

1. 在 GitHub 页面点 `Code` → `Download ZIP`，解压
2. 用路由器后台的「文件管理」（iStoreOS 自带）把整个文件夹上传到 `/tmp/`
3. 在后台的「终端」里执行：

```bash
cd /tmp/openclash-ai-guard-main && sh install.sh
```

### 路线 C：让 AI 帮你装

复制下面整段，发给 Claude / ChatGPT / 任何能连你路由器的 AI 助手：

````text
帮我在路由器上安装 openclash-ai-guard 这个工具。

我的环境：
- 路由器 IP：192.168.1.1        ← 改成你的
- SSH 用户名：root
- SSH 密码：（我会在你问的时候告诉你）
- 系统：OpenWrt / iStoreOS，已装好 OpenClash 并能正常上网

项目地址：https://github.com/你的用户名/openclash-ai-guard

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
API      : http://127.0.0.1:9090
配置     : /etc/openclash/xxx.yaml
AI-API  当前出口: JP1-HY2
AI-Chat 当前出口: JP4-HY2
状态     : STREAK=0 LAST_REFRESH=0
--- 最近 25 行日志 ---
2026-09-05 21:07:20 探测 total=56 good=30 slow=0 dead=26  AI-API=JP1-HY2 AI-Chat=JP4-HY2
```

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

## 三个踩过的坑（如果你要改这份代码，请先读）

**1. 不要用 `type: fallback`**

`fallback` 只判断"活/死"，不看质量。晚高峰时大量节点处于「能回包但已经 1 秒多」
的状态而不是干脆的死，`fallback` 会因为它在成员列表里更靠前而选中它。
实测：`HK-5 1131ms` 和 `JP4-HY2 193ms` 之间，fallback 选了 HK-5，
客户端表现是 TLS 握手失败。所以本工具用 `url-test` + 大 `tolerance`。

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

## 许可

MIT


