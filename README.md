# vpn

xray 代理的启动 / 节点维护 / 断线自愈工具。**macOS 与 Linux 通用**。

核心思路：**把 link.txt 的行号当作节点的唯一 ID**。
日志、选节点、命令行参数三者共用这一套编号，不再出现「序号 8 到底是文件第 8 行还是过滤后的第 8 个」这种错位。

---

## 快速开始

```bash
git clone <repo> ~/vpn && cd ~/vpn     # 自带 xray 二进制与 geo 数据，clone 完即可用

# 自动选节点启动（TCP 预筛 + 历史可用率排序 + 冷却过滤）
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
| `logs/health.log` | 每分钟一条 `<ISO8601> <1\|0> <link.txt 行号> [<明细>]` 采样 | 自动修剪到 20000 行 |
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

选节点的完整流程在 `fast_ping_nodes()`（`start_cli.sh`），分两轮：

**第 1 轮**（正常情况走这里）

1. `node_probe.py` 取出 `link.txt` 里**非香港**且可解析的行号，并做 TCP 可达性预筛；
2. `node_stats.py rank` 按**历史期望可用率降序**重排，并**剔除冷却中的节点**；
3. 依次尝试，第一个探测通过的节点即被采用。

**第 2 轮**（兜底）

放开 TCP 限制、把冷却中的节点放回来，再扫一遍，避免「候选全在冷却中」时无节点可用。
放回来的节点**按冷却剩余时间升序**排（而不是按历史分）—— 兜底时挑「离解除冷却最近」的，
否则 92% 的老牌节点一进冷却就会被它的历史高分重新顶到队首。

### 策略 1 —— 按历史可用率排序，而非文件顺序

`node_stats.py` 用**贝叶斯平滑**算期望可用率：

```
ratio = (窗口内 UP 数 + prior * k) / (窗口内样本数 + k)
```

- 统计窗口默认 **24h**（`RANK_WINDOW`），反映节点**最近**的质量 —— 昨天 95%、今天 20% 的节点不会被历史高分掩盖；
- 窗口内样本不足 k 条时回退到全历史再平滑；
- `k = 3`（`--min-samples`），`prior = 0.85`（`DEFAULT_NODE_RATIO`）。于是：

| 情况 | 期望可用率 |
| --- | --- |
| 24h 内 100/100 全成功 | 1.000 |
| **从未采样过的新节点** | **0.850**（先验，既不排最后也压不过优质节点） |
| 只采样 1 次且成功 | 0.888 |
| 只采样 1 次且失败 | 0.638（不判死刑） |

### 策略 2 —— 失败冷却

节点**最近一次失败**距今不足 `NODE_COOLDOWN`（默认 **3600s**）即视为冷却中，`rank` 直接剔除；冷却期满才重新进入候选。这是消除「在 1 号和 4 号之间反复横跳」的关键。

#### 冷却只管「能不能参选」，换掉「正在跑的那个」是 auto-heal 的职责

这是最容易踩空的一环：冷却名单是给**候选排序**用的，它天然碰不到**当前正在服务的那个节点**。
把在跑的节点踢掉靠的是 `auto-heal`：它一旦判定当前节点不可用，就必须真的换。

早期实现留了一条「复用存活代理」的捷径 —— 采样失败后，只要那一刻 `check_node_stable`
（2 轮连测）侥幸通过，就打印「代理已在运行」直接 `exit 0`，节点根本没换。后果是：

> `logs/health.log` 里这个节点已经在冷却名单上躺着，实际却还在服务，而且每分钟继续往它
> 头上刷 `0`。`start_cli.sh nodes` 说「冷却中」，`health.log` 说「还在用」—— 自相矛盾。

由于采样用 1 轮判定、复用复核用 2 轮判定，「记了失败但不换」是常态而非偶然：
一个真实可用率 92% 的节点，每分钟左右就会出现一次「1 轮失败 + 接着 2 轮通过」的组合。

现在两条约定锁死这件事：

1. **`HEAL_DOWN=1` 禁止复用**：`auto-heal` 确认不可用后，先停掉旧 xray 再重选，绝不给复用开口子；
2. **`0` 的含义收紧为「连续 `HEALTH_CONFIRM_ROUNDS` 轮全部失败」**（默认 2 轮）：
   任一轮通过即记 `1`。单发探测在劣化线路上抖动极大，把「抖」写成「故障」会无谓地把好节点推进冷却。

`auto-heal` 里 `NODE_STABLE_ROUNDS=2`、采样侧 `HEALTH_CONFIRM_ROUNDS=2`，两处判定方向一致（都趋严），不再互相打架。

**换节点全军覆没时回滚**：若两轮候选全部失败，脚本退回换节点之前的那个节点
（`PREV_NODE`），宁可「将就用旧节点」也不彻底断网，下一分钟再试。日志记为「回滚到原节点 N」。

调试用：`start_cli.sh nodes` 会把当前正在使用的节点标成 `← 当前使用`；一旦它处于冷却中，
报告末尾会直接打出 `⚠ 异常：当前正在使用的是 N 号节点，而它处于冷却中` —— 正常实现下不该出现。

### 策略 3 —— 香港节点过滤

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
| `bash start_cli.sh nodes` | 各节点健康报告：期望可用率 / 窗口样本 / 全历史 / 最近失败 / 冷却状态，并标出 `← 当前使用` |
| `bash start_cli.sh health` | 整体 UP ratio 报告（总体 / 1h / 24h / 逐小时） |
| `bash start_cli.sh auto-heal` | **采样 + 断线自动换节点重连**（cron 每分钟调这个） |
| `bash start_cli.sh health-probe` | 采样一次并记账，纯采集不做恢复 |
| `bash start_cli.sh health-watch` | 前台循环采样 |
| `bash start_cli.sh proxy-on\|off\|status` | 系统代理开关（macOS / Linux 自动分派） |
| `sh vpn-cron.sh [doctor]` | cron 包装器：抹平 cron 环境差异后调 auto-heal |
| `sh install-cron.sh` | 幂等写入 / 移除 crontab 托管段 |
| `python3 node_probe.py scan --out-dir D` | TCP 可达性预筛 |
| `python3 node_stats.py rank --lines F --format lines` | 输出排好序的行号，供脚本消费 |
| `python3 node_stats.py report --current N` | 健康报告，`--current` 标出正在使用的节点 |
| `python3 gen_xray_config.py --links link.txt --line 50 --out ... --selected ...` | 按行号生成配置 |

策略参数可用环境变量覆盖：

```bash
RANK_WINDOW=86400 NODE_COOLDOWN=3600 DEFAULT_NODE_RATIO=0.85 \
NODE_STABLE_ROUNDS=2 MAX_HEAL_SECONDS=180 \
HEALTH_CONFIRM_ROUNDS=2 HEALTH_INTERVAL=60 bash start_cli.sh
```

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
node_stats.py           节点健康统计与候选排序（策略 1 + 2）
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
logs/health.log         每分钟 1/0 采样，append-only，自动修剪
logs/cron.log           cron 运行日志，静默 UP 每分钟一行（轮换为 .1）
logs/xray.log           xray 进程自身的输出，每次启动覆盖
proxy.env               Linux 下生成，source 后当前 shell 可用代理
```

---

## 注意

`link.txt`、`config.json`、`selected_node.txt` 含节点凭据。本仓库是公开的，**不要把 `.env`、工作日志或任何 API Key 一起提交**（`.gitignore` 已挡住 `/.env`、`/.workbuddy/`、`logs/`、`*.log`、`crontab.backup.*`、`proxy.env`）。

`xray`、`xray-linux-64`、`geoip.dat`、`geosite.dat` **是故意入库的**，为的是 clone 后开箱可用；它们来自 XTLS/Xray-core 的公开 release（MIT/Apache-2.0 系），不含任何隐私。新增忽略规则后建议用 `git check-ignore -v <file>` 逐个验证 —— `.gitignore` 里 `#` 只有**行首**才是注释，写在模式行尾会让整条规则静默失效。

代码里也刻意避免把整条 link 打进日志：`current_node_summary()` 只输出 `node=N (proto)`，不会把含 UUID 的链接写进 `cron.log`。
