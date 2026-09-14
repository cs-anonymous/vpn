# vpn

xray 代理的启动 / 节点维护 / 断线自愈工具。**macOS 与 Linux 通用**。

核心思路：**把 link.txt 的行号当作节点的唯一 ID**。
日志、选节点、命令行参数三者共用这一套编号，不再出现「序号 8 到底是文件第 8 行还是过滤后的第 8 个」这种错位。

---

## 快速开始

```bash
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
tail -f cron.log             # 每分钟一行 run: UP；异常时才展开详细输出
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
| 日志无限增长 | `health.log` 每年涨 15MB | `cron.log` 512KB 轮换、`health.log` 保留最近 20000 行 |

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
放开 TCP 与冷却限制，按可用率重排后再扫一遍，避免「候选全在冷却中」时无节点可用。

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
| `bash start_cli.sh nodes` | 各节点健康报告：期望可用率 / 窗口样本 / 全历史 / 最近失败 / 冷却状态 |
| `bash start_cli.sh health` | 整体 UP ratio 报告（总体 / 1h / 24h / 逐小时） |
| `bash start_cli.sh auto-heal` | **采样 + 断线自动换节点重连**（cron 每分钟调这个） |
| `bash start_cli.sh health-probe` | 采样一次并记账，纯采集不做恢复 |
| `bash start_cli.sh health-watch` | 前台循环采样 |
| `bash start_cli.sh proxy-on\|off\|status` | 系统代理开关（macOS / Linux 自动分派） |
| `sh vpn-cron.sh [doctor]` | cron 包装器：抹平 cron 环境差异后调 auto-heal |
| `sh install-cron.sh` | 幂等写入 / 移除 crontab 托管段 |
| `python3 node_probe.py scan --out-dir D` | TCP 可达性预筛 |
| `python3 node_stats.py rank --lines F --format lines` | 输出排好序的行号，供脚本消费 |
| `python3 gen_xray_config.py --links link.txt --line 50 --out ... --selected ...` | 按行号生成配置 |

策略参数可用环境变量覆盖：

```bash
RANK_WINDOW=86400 NODE_COOLDOWN=3600 DEFAULT_NODE_RATIO=0.85 \
NODE_STABLE_ROUNDS=2 MAX_HEAL_SECONDS=180 bash start_cli.sh
```

cron 不继承 shell 环境，要改这些值就写进 crontab 的环境行（放在托管段里即可）。

---

## health.log 格式

```
<ISO8601 时间戳> <1|0> <link.txt 行号>
2026-09-14T18:47:02+0800 1 5
```

第 3 列**永远是 link.txt 的原始行号**，与 `--line` 参数、`node_stats.py` 的排名共用同一套编号。

```bash
awk '{print $2}' health.log          # 原始 1/0 序列
bash start_cli.sh nodes              # 按节点汇总
```

`health.log` 会被包装器自动修剪到最近 20000 行（约 13 天），排序窗口只有 24h，不影响判断。

---

## 依赖与大文件

仓库**不含**二进制，clone 后需要自己补上（都放在项目目录下）：

| 文件 | 获取方式 |
| --- | --- |
| `xray` | `https://github.com/XTLS/Xray-core/releases` → 选对应平台，解压后 `chmod +x`，放成 `xray` |
| `xray-<os>-<arch>` | 想同时放多个平台的二进制时用这个命名（如 `xray-linux-64`、`xray-macos-arm64-v8a`）。脚本会真的执行 `xray version` 来确认架构匹配，装错的那份会被自动跳过 |
| `geoip.dat` / `geosite.dat` | 同上 release 包内 |
| `link.txt` | 你自己的订阅节点列表（每行一个 vmess/ss/trojan/vless 链接） |

运行时依赖：**Python 3.9+**（`dict[str, ...]` 泛型注解）、`bash`（已兼容 3.2）、`curl`。
`xray` 二进制的查找顺序是 `XRAY_BIN_OVERRIDE` 环境变量 → `xray-<os>-<arch>` → `xray`。

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
config.json             运行时生成，每次启动覆盖
selected_node.txt       运行时生成，记录当前节点（node_id = link.txt 行号）
health.log              采样日志，append-only
cron.log                cron 运行日志，静默 UP 每分钟一行
proxy.env               Linux 下生成，source 后当前 shell 可用代理
```

---

## 注意

`link.txt`、`config.json`、`selected_node.txt` 含节点凭据。本仓库是公开的，**不要把 `.env`、工作日志或任何 API Key 一起提交**（`.gitignore` 已挡住 `/.env`、`/.workbuddy/`、`*.log`、`crontab.backup.*`、`proxy.env` 和二进制）。

代码里也刻意避免把整条 link 打进日志：`current_node_summary()` 只输出 `node=N (proto)`，不会把含 UUID 的链接写进 `cron.log`。
