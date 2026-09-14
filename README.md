# vpn

xray 代理的启动 / 节点维护 / 断线自愈工具。**macOS 与 Linux 通用**。

核心思路：**把 link.txt 的行号当作节点的唯一 ID**。
日志、选节点、命令行参数三者共用这一套编号，不再出现「序号 8 到底是文件第 8 行还是过滤后的第 8 个」这种错位。

---

## 快速开始

```bash
git clone <repo> ~/vpn && cd ~/vpn     # 自带 xray 二进制与 geo 数据，clone 完即可用

# 自动选节点启动（TCP 预筛 + 综合评分排序）
bash start_cli.sh

# 手工指定 link.txt 第 50 行
bash start_cli.sh 7890 50

# 看看各节点现在什么水平 / 整体可用率
bash start_cli.sh nodes
bash start_cli.sh health

# 环境自检（xray / python / 节点池 / 当前状态 / 定时任务）
bash start_cli.sh doctor

# 停止
bash stop_cli.sh
```

无需 `chmod +x`、无需下载二进制。项目目录**必须**是 `~/vpn`。

---

## 路径与日志

### 只有一个根目录：`~/vpn`

macOS 与 Linux 用的是**同一套规则** —— 固定在**家目录下的 `vpn`**：

| 平台 | 实际路径 |
| --- | --- |
| macOS | `/Users/<用户名>/vpn` |
| Linux | `/home/<用户名>/vpn` |

家目录在两个平台上本来就不同，所以「固定」= 固定成 `$HOME/vpn`，而不是写死绝对路径字符串（写死 `/Users/...` 到 Linux 上必然失效）。

脚本内部只有一个变量 `VPN_HOME="${VPN_HOME:-$HOME/vpn}"`，**其余所有路径都由它推导**，不存在第二个根。需要临时换位置（测试、迁移）时：

```bash
VPN_HOME=/path/to/vpn bash start_cli.sh doctor
```

`doctor` 会检查「脚本所在目录」和 `VPN_HOME` 是否一致，不一致时明确提示 —— 因为二进制、geo 数据、`link.txt` 都按 `VPN_HOME` 找。

### 所有日志都在 `logs/` 下

根目录只放程序、配置与节点文件，日志**一律**落在 `$VPN_HOME/logs/`：

| 文件 | 内容 | 大小 |
| --- | --- | --- |
| `logs/vpn.log` | **操作流水**：启动 / 换节点 / 自愈 / 代理开关。`start_cli.sh`、`stop_cli.sh` 共用一份 | 每次动作几行 |
| `logs/health.log` | 每次运行 1~2 条 `<ISO8601> <1\|0> <link.txt 行号> [<明细>]` 采样（换节点成功会为新节点补 1 条） | 自动修剪到 20000 行 |
| `logs/cron.log` | cron 包装器运行日志，UP 每分钟一行、异常展开明细 | 512KB 后轮换为 `.1` |
| `logs/xray.log` | xray 进程自身的 stdout/stderr，每次启动覆盖 | 小 |

```bash
tail -f logs/vpn.log      # 看「刚才为什么换节点」
tail -f logs/cron.log     # 看「每分钟有没有在跑」
bash start_cli.sh health  # 看可用率报告（读 logs/health.log）
```

`logs/` 整个目录都在 `.gitignore` 里（只保留一个 `.gitkeep` 占位），日志不会进仓库。

---

## 定时任务（断线自动重连）

用 **crontab + 一个 POSIX 包装器**，不用 launchd / systemd timer，两个平台同一套。

```bash
sh install-cron.sh              # 安装，每分钟触发一次
sh install-cron.sh --interval 5 # 每 5 分钟
sh install-cron.sh --show       # 查看当前托管段
sh install-cron.sh --remove     # 卸载
sh install-cron.sh --dry-run    # 只打印将写入的 crontab
```

装完长这样（`MAILTO=""` 是必要的，否则任务一有输出 cron 就尝试给你发邮件）：

```cron
# >>> vpn-cron >>>
MAILTO=""
* * * * * /bin/sh "/绝对路径/vpn-cron.sh"
# <<< vpn-cron <<<
```

自检与观察：

```bash
sh vpn-cron.sh doctor        # PATH / bash / python / crontab / cron 服务 / 运行状态
tail -f logs/cron.log        # 每分钟一行 run: UP；异常时才展开详细输出
tail -f logs/vpn.log         # 操作明细：启动 / 换节点 / 自愈
```

### 为什么要多一层 vpn-cron.sh

cron 的运行环境和你的交互 shell 完全是两回事，实测踩到的差异：

| 差异 | 后果 | 包装器的处理 |
| --- | --- | --- |
| `PATH` 只有 `/usr/bin:/bin` | 找不到 `python3`、homebrew 的 `bash` | 显式重建 PATH，并逐个验证解释器真能跑起来 |
| `#!/usr/bin/env bash` 落到 macOS 自带 3.2 | 3.2 **没有 `mapfile`**，选节点逻辑当场崩 | `start_cli.sh` 全文改成 3.2 兼容语法 |
| 不读 `.zshrc` / `.bash_profile` | rc 里设的变量全都不存在 | 所有配置项走环境变量，并在脚本里给默认值 |
| locale 可能是 `C`/`POSIX` | Python 往管道写中文 `UnicodeEncodeError` | 导出 `PYTHONIOENCODING=utf-8` |
| 任务可能重叠触发 | 上一轮还在换节点，下一轮又来了 | `start_cli.sh` 用 `mkdir` 原子锁 + 残留锁自动回收 |
| stdout 有输出就发邮件 | 邮箱被刷屏 | 包装器自己写日志，并把 `MAILTO=""` 写进 crontab |
| 日志无限增长 | `logs/health.log` 每年涨 15MB | `logs/cron.log` 512KB 轮换、`logs/health.log` 保留最近 20000 行 |

### 跨平台踩过的坑（都已规避）

| 命令 | macOS | Linux | 替代方案 |
| --- | --- | --- | --- |
| `flock` | ✗ 没有 | ✓ | `mkdir` 原子锁 |
| `setsid` | ✗ 没有 | ✓ | `nohup ... &` |
| `timeout` | ✗ 没有 | ✓ | 脚本内自算 deadline（`MAX_HEAL_SECONDS`） |
| `readlink -f` | 老版本不支持 | ✓ | 逐级解符号链接 |
| `ping -W` | **毫秒** | **秒** | 不用 ping，见下 |
| `ping -t` | 总超时 | TTL | 同上 |
| `wc -l` 计末行 | 末行无换行符时少算 | 同 | 用 Python `splitlines()` |
| 系统代理 | `networksetup` | `gsettings` / `proxy.env` | `start_cli.sh` 内自动分派 |
| `$var` 后紧跟中文 | locale 缺失时**多字节字符被算进变量名** | 同 | 一律写 `${var}`（`doctor` 会扫这个） |

最后一行是真踩到的：`echo "$label（$count 个）"` 在 cron 的剥离环境里报 `label: 未绑定的变量`，让自动重连静默失败；交互 shell 因为有 locale 所以永远复现不出来。`bash start_cli.sh doctor` 现在会扫描这类写法并报行号。

### 启用定时任务前的两点提示

- **macOS**：cron 默认已启用，增删自己的 crontab 不需要 sudo。只有当项目目录位于**桌面 / 文稿 / 下载**等受保护位置时，才需要给 `/usr/sbin/cron` 授予「完全磁盘访问权限」，否则任务会静默失败。`~/vpn` 不在其中。
- **Linux**：确认守护进程在跑 —— `sudo systemctl enable --now cron`（Debian 系是 `cron`，RHEL 系是 `crond`）。

---

## 节点选择策略

候选顺序完全由 `node_stats.py` 的**一条公式**决定：没有窗口、没有样本数阈值、
没有被排除的节点名单 —— 只有一条会自己爬回来的曲线。

### 评分公式

```
U      = Σ 0.5 ^ (样本年龄 / 成绩半衰期)        # UP 样本的衰减加权和
D      = Σ 0.5 ^ (样本年龄 / 成绩半衰期)        # DOWN 样本的衰减加权和
可用率 = (U + 先验 * K) / (U + D + K)
折扣   = 1 - 失败折扣 * 0.5 ^ (距最近一次失败 / 失败半衰期)
评分   = 可用率 * 折扣
```

默认参数：成绩半衰期 **24h**（`SCORE_HALF_LIFE`）、失败半衰期 **30min**
（`FAIL_HALF_LIFE`）、失败折扣 **0.5**（`FAIL_DISCOUNT`）、先验 **0.85**
（`DEFAULT_NODE_RATIO`，权重 `K = 20` 条）。

公式**没有任何分支**，两个边界都自然退化、不需要特判：

- 从没采样过的节点 `U = D = 0` → 可用率退化成先验 `0.85`；
- 从没失败过的节点「距最近一次失败」取 ∞ → `0.5 ** inf == 0` → 折扣退化成 `1`。

两个因子各自承担原来的一个策略，**不再是两套可以互相打架的判定**：

- **可用率**（原「策略 1：按历史可用率排序」）—— 越新的样本越重，但一天前的样本
  仍有分量，所以节点的历史水平要慢慢才能被改写。实测 8 号（638 条 99.4%，最近一条
  在 22.7h 前）得 0.978；1 号（全历史 73.5%，最近一小时连续掉线）只剩 0.532。
- **折扣**（原「策略 2：失败后 1 小时内不考虑」）—— 失败不是被**排除**，而是
  **扣分**，扣多少由失败有多新决定。

### 折扣随失败变旧而自动消退

| 距最近一次失败 | 0 | 15m | 30m | 1h | 90m | 2h | 3h | 6h |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 折扣 | 0.500 | 0.646 | 0.750 | 0.875 | 0.938 | 0.969 | 0.992 | 1.000 |

即：1 小时消掉 3/4 的折扣，2 小时消掉 94%，3 小时基本归零。拿线上真实节点举例
（把「距最近一次失败」人为推后，其余不动）：

| 行号 | 可用率 | now | +15m | +30m | +1h | +2h | +6h |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 49（当前使用） | 86.4% | **.432** | .558 | .648 | .756 | .837 | .863 |
| 6 | 91.4% | **.457** | .591 | .685 | .799 | .885 | .914 |

先验 `0.850` 是未探测节点的位置 —— 刚失败的节点沉到它下面，1~2 小时后升回来。
**它不会被硬性剔除**，所以不存在「候选全被排除、一个都没有」的状态：
`rank` 永远返回全部候选，只是在队尾。

### 为什么不再分段

早期实现是 `if 窗口样本 >= k: 用窗口频率 else: 回退全历史再平滑`，外加一条
「最近一次失败 < 1h 直接剔除」的硬冷却。实测复现出两个后果：

1. **阈值断裂** —— 历史 100 条全成功时，窗口内 2 条失败得 0.977、3 条失败得
   **0.000**，只多一条样本落差 0.977。这不是平滑，是断崖。
2. **排序倒挂** —— 「4 条里成功 2 条」（真实 50%）得 0.500，反而低于「只采样
   1 次且失败」（真实 0%）的 0.637：两种量纲混在同一张表里排序。

同一份 `health.log`、同一批 66 个候选，两种实现的差别集中在队尾：

| | 参选 | 被剔除 |
| --- | --- | --- |
| 旧实现 | 60 个 | **6 个**（近 1h 失败过，直接消失） |
| 新实现 | **66 个** | 0 个（同样 6 个扣 17~29% 分，落到 58~64 名） |

### 评分只管「谁更该被选」，换掉「正在跑的那个」是 auto-heal 的职责

这是最容易踩空的一环：评分是给**候选排序**用的，它天然碰不到**当前正在服务的那个节点**。
把在跑的节点踢掉靠的是 `auto-heal`：它一旦判定当前节点不可用，就必须真的换。


早期实现留了一条「复用存活代理」的捷径 —— 采样失败后，只要那一刻 `check_node_stable`
（2 轮连测）侥幸通过，就打印「代理已在运行」直接 `exit 0`，节点根本没换。后果是：

> `logs/health.log` 里这个节点已经被扣了分、评分沉到队尾，实际却还在服务，而且每分钟继续
> 往它头上刷 `0`。`start_cli.sh nodes` 说它在打折，`health.log` 说它还在用 —— 自相矛盾。

由于采样用 1 轮判定、复用复核用 2 轮判定，「记了失败但不换」是常态而非偶然：
一个真实可用率 92% 的节点，每分钟左右就会出现一次「1 轮失败 + 接着 2 轮通过」的组合。

现在两条约定锁死这件事：

1. **`HEAL_DOWN=1` 禁止复用**：`auto-heal` 确认不可用后，先停掉旧 xray 再重选，绝不给复用开口子；
2. **`0` 的含义收紧为「连续 `HEALTH_CONFIRM_ROUNDS` 轮全部失败」**（默认 2 轮）：
   任一轮通过即记 `1`。单发探测在劣化线路上抖动极大，把「抖」写成「故障」会无谓地给好节点扣分。

`auto-heal` 里 `NODE_STABLE_ROUNDS=2`、采样侧 `HEALTH_CONFIRM_ROUNDS=2`，两处判定方向一致（都趋严），不再互相打架。

换来之后还要**记账**：换成功了却不落盘，`health.log` 里就只剩旧节点那条失败，
新节点永远是「未探测」。见 [一次运行写 1~2 条](#一次运行写-12-条)。

**换节点全军覆没时回滚**：若两轮候选全部失败，脚本退回换节点之前的那个节点
（`PREV_NODE`），宁可「将就用旧节点」也不彻底断网，下一分钟再试。日志记为「回滚到原节点 N」。

调试用：`start_cli.sh nodes` 会把当前正在使用的节点标成 `← 当前使用`，并给出
「评分 / 可用率 / 折扣」三列 —— 一眼看出它是被历史成绩拖低还是被最近失败打折。
若当前节点最后一笔采样是失败，报告末尾会提示一句：可能是「候选全失败后回滚」（正常），
也可能是换节点没走通（异常），两者要靠 `logs/vpn.log` 区分。

### 香港节点过滤（原「策略 3」，唯一一条硬规则）

`gen_xray_config.is_hongkong_url()`：

1. 先在原始文本上粗筛（兼容明文写法）；
2. **再 base64 解码 vmess 的 `ps` 字段复核** —— vmess 链接主体是 base64，明文里根本没有「香港」两个字，只匹配原文等于没过滤；
3. `HK` 用非字母数字切分后做**整词**比对，避免误伤 `hkt` / `hkust`。

实测：`link.txt` 87 行 = 1 个空行 + **20 个香港节点被排除** + 66 个候选。

### 预筛为什么从 ICMP ping 改成 TCP connect

`node_probe.py` 用 `socket.create_connection()` 探节点的**真实服务端口**，两个原因：

1. **参数语义跨平台不一致**：macOS 的 `ping -W` 是毫秒、Linux 是秒；Linux 的 `-t` 是 TTL，只有 macOS 的 `-t` 才是总超时。同一行命令不可能两边都表达「等 3 秒」。
2. **大量节点禁 ICMP**，用 ping 筛会误杀。实测 `ip.jkcnin.com`（DNS CNAME → `iepl.gtm-host.com`，IEPL 专线，池子里 27 个）TCP 44~70ms 稳定可达，但 ICMP 完全不回 —— ping 预筛把这批**延迟最低的线路整批剔除**了，历史日志里表现为「这些节点从未被探测过」。

换成 TCP 后：66 个候选全部可达、总耗时 **0.6 秒**，且 IEPL 那批重新进入候选池。

---

## 命令参考

| 命令 | 作用 |
| --- | --- |
| `bash start_cli.sh [端口] [行号]` | 启动或复用代理（默认 7890） |
| `bash start_cli.sh doctor` | 环境自检 |
| `bash start_cli.sh nodes` | 各节点健康报告：评分 / 可用率 / 折扣 / 样本 / 最近失败 / 状态，并标出 `← 当前使用` |
| `bash start_cli.sh health` | 整体 UP ratio 报告（总体 / 1h / 24h / 逐小时） |
| `bash start_cli.sh auto-heal` | **采样 + 断线自动换节点重连**（cron 每分钟调这个） |
| `bash start_cli.sh health-probe` | 采样一次并记账，纯采集不做恢复 |
| `bash start_cli.sh health-watch` | 前台循环采样 |
| `bash start_cli.sh proxy-on\|off\|status` | 系统代理开关（macOS / Linux 自动分派） |
| `sh vpn-cron.sh [doctor]` | cron 包装器：抹平 cron 环境差异后调 auto-heal |
| `sh install-cron.sh` | 幂等写入 / 移除 crontab 托管段 |
| `python3 node_probe.py scan --out-dir D` | TCP 可达性预筛 |
| `python3 node_stats.py rank --lines F --format lines` | 按评分降序输出行号（始终是全量候选），供脚本消费 |
| `python3 node_stats.py report --current N` | 健康报告，`--current` 标出正在使用的节点 |
| `python3 gen_xray_config.py --links link.txt --line 50 --out ... --selected ...` | 按行号生成配置 |

策略参数可用环境变量覆盖：

```bash
SCORE_HALF_LIFE=86400 FAIL_HALF_LIFE=1800 FAIL_DISCOUNT=0.5 \
DEFAULT_NODE_RATIO=0.85 NODE_STABLE_ROUNDS=2 MAX_HEAL_SECONDS=180 \
HEALTH_CONFIRM_ROUNDS=2 HEALTH_INTERVAL=60 bash start_cli.sh
```

四个旋钮的含义与调法：

| 变量 | 默认 | 调大 / 调小会怎样 |
| --- | --- | --- |
| `SCORE_HALF_LIFE` | 86400（24h） | 调大 → 更看重长期表现；调小 → 更快遗忘旧成绩 |
| `FAIL_HALF_LIFE` | 1800（30min） | 调小 → 更快原谅一次失败（折扣消退得更快） |
| `FAIL_DISCOUNT` | 0.5 | 调大 → 刚失败扣得更狠；`0` 等于完全不惩罚失败 |
| `DEFAULT_NODE_RATIO` | 0.85 | 未探测节点的先验分。调高 → 更愿意探索没试过的节点 |

cron 不继承 shell 环境，要改这些值就写进 crontab 的环境行（放在托管段里即可）。

---

## logs/health.log 格式

```
<ISO8601 时间戳> <1|0> <link.txt 行号> [<探测明细>]
2026-09-14T18:47:02+0800 1 5 google=204,youtube=200
2026-09-14T18:47:02+0800 0 5 google=000
```

第 3 列**永远是 link.txt 的原始行号**，与 `--line` 参数、`node_stats.py` 的排名共用同一套编号。
第 4 列是可选明细（`google=204,youtube=403` 这类），用来定位抖动到底卡在哪一段；排序逻辑不读它，
旧的三列行照样解析。`port-closed` 表示 xray 本地端口都没在监听。

`0` 的含义是**连续 `HEALTH_CONFIRM_ROUNDS`（默认 2）轮全部失败 = 确认不可用**，
不是「这一秒抖了一下」。任一轮通过即记 `1`。

### 一次运行写 1~2 条

| 场景 | 记几条 | 内容 |
| --- | --- | --- |
| 采样通过（或走了「复用存活代理」） | **1** | `<1> <当前节点>` |
| 采样失败 → 换节点成功 | **2** | `<0> <旧节点>` + `<1> <新节点>` |

第 1 条落在主流程最前面（`auto-heal` 则在自己的分支里），记的是**这一分钟开始时
旧节点还能不能用** —— 放在重启动作之前，脚本就算随后被杀，样本也已经落盘。

第 2 条由 `log_health_after_switch()` 在 `print_success()` 末尾补记。**换成功了不落盘，
新节点就永远是「未探测」**：`node_stats.py` 只能拿先验 0.85 给它打分，一个「它其实能用」
的证据都攒不下来，下一轮排序它还得吃亏。补记的两种情况：

1. 最终节点 ≠ 已记账节点 —— 正常换节点成功；
2. 最终节点 = 已记账节点，但已记账的值是 `0` —— 两轮候选全军覆没后回滚，
   复用原节点并且这次真的通了。

已经有一条 `1` 的节点不重复记 —— 同一分钟给同一节点刷两条相同样本，等于给它双倍
权重把 UP ratio 灌水。

配套的一条约束：`try_node` 失败时会**还原 `selected_node.txt`**。
`gen_xray_config.py` 把「写配置」和「写 selected」做成了一件事，但配置写出来不等于
节点可用；不还原的话它会停在最后一个失败节点上，而下一次采样（此刻端口是关的，
必然记 0）就白送那个节点一笔不该有的失败。`logs/vpn.log` 里记为「切换后补记 node=N ...」。

```bash
awk '{print $2}' logs/health.log     # 原始 1/0 序列
awk '$2=="0"{print $4}' logs/health.log | sort | uniq -c | sort -rn   # 失败都卡在哪
bash start_cli.sh nodes              # 按节点汇总
```

`logs/health.log` 会被包装器自动修剪到最近 20000 行（约 13 天），排序窗口只有 24h，不影响判断。

---

## 二进制与地理数据

**仓库自带全部运行时依赖，clone 之后不需要下载任何东西，直接就能起。**

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `xray` | 36 MB | macOS x86_64（Apple Silicon 走 Rosetta 2）。脚本按 `xray-<os>-<arch>` → `xray` 顺序查找，并真的执行一次 `xray version` 验证架构 |
| `xray-linux-64` | 37 MB | Linux x86_64 静态链接 ELF。命名对应 `linux-64` 后缀，在 Linux 上会被优先选中 |
| `geoip.dat` / `geosite.dat` | 30 MB | 分流规则数据。`start_cli.sh` 导出 `XRAY_LOCATION_ASSET=$SCRIPT_DIR`，所以不依赖 cwd |
| `Xray-linux-64.zip` | 21 MB | 上游原始 release 包，`xray-linux-64` 即从中解出。内容与顶层文件一致（geo 数据 sha256 相同），只是留档 |
| `link.txt` | 22 KB | 节点列表，每行一个 vmess/ss/trojan/vless 链接 |

二进制由 git 以可执行位（mode `100755`）保存，clone 后即可运行，不需要 `chmod +x`。
`.gitattributes` 把 `xray*` / `*.dat` / `*.zip` 标为 `binary`，避免在 Windows 上被行尾转换损坏。

想要更瘦的仓库：删掉 `Xray-linux-64.zip`（`git rm --cached`）可省 21 MB，代价是 `xray-linux-64` 失去上游留档。

**更新 xray** 时替换对应文件并提交即可。注意 git 每个版本都会留一份历史副本（约 +36 MB/次），频繁更新可考虑改挂 Git LFS。

运行时依赖：**Python 3.9+**（`dict[str, ...]` 泛型注解）、`bash`（已兼容 3.2）、`curl`。
`xray` 二进制的查找顺序是 `XRAY_BIN_OVERRIDE` 环境变量 → `$VPN_HOME/xray-<os>-<arch>` → `$VPN_HOME/xray`。

路径相关环境变量：

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `VPN_HOME` | `$HOME/vpn` | **唯一根目录**，日志在其 `logs/` 下 |
| `LINK_FILE` | `$VPN_HOME/link.txt` | 节点列表位置 |
| `XRAY_BIN_OVERRIDE` | 空 | 指定 xray 二进制路径 |

---

## 文件说明

```
start_cli.sh            启动 / 选节点 / 自愈主流程（bash 3.2 兼容）
vpn-cron.sh             cron 包装器：修 PATH、定位解释器、日志、调用 auto-heal
install-cron.sh         crontab 幂等安装 / 卸载 / 查看
gen_xray_config.py      生成 xray config.json；香港过滤在这里
node_stats.py           节点评分与候选排序（时间衰减 × 失败折扣，单一公式）
node_probe.py           候选枚举 + TCP 可达性预筛（跨平台的 ping 替代）
stop_cli.sh             停止代理并关闭系统代理
proxy_switch.sh         系统代理开关（转发到 start_cli.sh proxy-*）
bypass_domains.txt      系统代理绕过列表
link.txt                节点列表（节点 ID = 本文件行号）
xray                    macOS x86_64 二进制（已在库内）
xray-linux-64           Linux x86_64 二进制（已在库内）
geoip.dat geosite.dat   分流规则数据（已在库内）
Xray-linux-64.zip       上游原始 release 包（留档）
.gitattributes          二进制保护 + 脚本统一 LF
config.json             运行时生成，每次启动覆盖
selected_node.txt       运行时生成，记录当前节点（node_id = link.txt 行号）
logs/                   全部日志目录（整目录被 gitignore）
logs/vpn.log            操作流水：启动 / 换节点 / 自愈 / 代理开关
logs/health.log         每次运行 1~2 条 1/0 采样，append-only，自动修剪
logs/cron.log           cron 运行日志，静默 UP 每分钟一行（轮换为 .1）
logs/xray.log           xray 进程自身的输出，每次启动覆盖
proxy.env               Linux 下生成，source 后当前 shell 可用代理
```

---

## 注意

`link.txt`、`config.json`、`selected_node.txt` 含节点凭据。本仓库是公开的，**不要把 `.env`、工作日志或任何 API Key 一起提交**（`.gitignore` 已挡住 `/.env`、`/.workbuddy/`、`logs/`、`*.log`、`crontab.backup.*`、`proxy.env`）。

`xray`、`xray-linux-64`、`geoip.dat`、`geosite.dat` **是故意入库的**，为的是 clone 后开箱可用；它们来自 XTLS/Xray-core 的公开 release（MIT/Apache-2.0 系），不含任何隐私。新增忽略规则后建议用 `git check-ignore -v <file>` 逐个验证 —— `.gitignore` 里 `#` 只有**行首**才是注释，写在模式行尾会让整条规则静默失效。

代码里也刻意避免把整条 link 打进日志：`current_node_summary()` 只输出 `node=N (proto)`，不会把含 UUID 的链接写进 `cron.log`。
