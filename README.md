# vpn

macOS 下的 xray 代理启动 / 节点维护 / 断线自愈工具。

核心思路：**把 link.txt 的行号当作节点的唯一 ID**。
日志、选节点、命令行参数三者共用这一套编号，不再出现「序号 8 到底是文件第 8 行还是过滤后的第 8 个」这种错位。

---

## 快速开始

```bash
# 自动选节点启动（ping 预筛 + 历史可用率排序 + 冷却过滤）
bash start_cli.sh

# 手工指定 link.txt 第 50 行
bash start_cli.sh 7890 50

# 看看各节点现在什么水平
bash start_cli.sh nodes

# 整体可用率报告
bash start_cli.sh health

# 停止
bash stop_cli.sh
```

---

## 节点选择策略

选节点的完整流程在 `fast_ping_nodes()`（`start_cli.sh`），分两轮：

**第 1 轮**（正常情况走这里）

1. `list_candidate_lines()` 取出 `link.txt` 里**非香港**且可解析的行号；
2. 并行 ping 一遍做粗筛；
3. `node_stats.py rank` 按**历史期望可用率降序**重排，并**剔除冷却中的节点**；
4. 依次尝试，第一个探测通过的节点即被采用。

**第 2 轮**（兜底）
放开 ping 与冷却限制，按可用率重排后再扫一遍，避免「全部处于冷却中」或「服务器禁 ICMP」时无节点可用。

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

`gen_xray_config.is_hongkong_url()` 现在会：

1. 先在原始文本上粗筛（兼容明文写法）；
2. **再 base64 解码 vmess 的 `ps` 字段复核** —— vmess 链接主体是 base64，明文里根本没有「香港」两个字，只匹配原文等于没过滤；
3. `HK` 用非字母数字切分后做**整词**比对，避免误伤 `hkt` / `hkust`。

实测：`link.txt` 86 行，**排除 20 个香港节点，剩 66 个候选**。

---

## 命令参考

| 命令 | 作用 |
| --- | --- |
| `bash start_cli.sh [端口] [行号]` | 启动或复用代理（默认 7890） |
| `bash start_cli.sh nodes` | 各节点健康报告：期望可用率 / 窗口样本 / 全历史 / 最近失败 / 冷却状态 |
| `bash start_cli.sh health` | 整体 UP ratio 报告（总体 / 1h / 24h / 逐小时） |
| `bash start_cli.sh auto-heal` | **采样 + 断线自动换节点重连**（给 launchd 用） |
| `bash start_cli.sh health-probe` | 采样一次并记账，纯采集不做恢复 |
| `bash start_cli.sh health-watch` | 前台循环采样 |
| `python3 node_stats.py rank --lines FILE --format lines` | 只输出排好序的行号，供脚本消费 |
| `python3 gen_xray_config.py --links link.txt --line 50 --out ... --selected ...` | 按行号生成配置 |

策略参数可用环境变量覆盖：

```bash
RANK_WINDOW=86400 NODE_COOLDOWN=3600 DEFAULT_NODE_RATIO=0.85 bash start_cli.sh
```

---

## health.log 格式

```
<ISO8601 时间戳> <1|0> <link.txt 行号>
2026-09-14T17:46:00+0800 1 6
```

第 3 列**永远是 link.txt 的原始行号**，与 `--line` 参数、`node_stats.py` 的排名共用同一套编号。

```bash
awk '{print $2}' health.log          # 原始 1/0 序列
bash start_cli.sh nodes              # 按节点汇总
```

---

## 定时任务（自动重连）

```bash
cp com.a.vpn-health.plist.example ~/Library/LaunchAgents/com.a.vpn-health.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.a.vpn-health.plist
```

两个容易踩的坑，模板里已经处理好：

1. **必须调 `auto-heal`**。旧的 `health-probe` 只写日志然后 `exit 0`，自愈逻辑在它后面，永远不会执行 —— 表现就是「每分钟记录你又断网了，但从不去救」。
2. **必须有 `AbandonProcessGroup`**。脚本用 `nohup ... &` 拉起 xray，不加这一条 launchd 会在任务结束时回收整个进程组，xray 立刻被杀。

卸载：

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.a.vpn-health.plist
```

---

## 依赖与大文件

仓库**不含**二进制，clone 后需要自己补上（都放在 `~/vpn/` 下）：

| 文件 | 获取方式 |
| --- | --- |
| `xray` | `https://github.com/XTLS/Xray-core/releases` → macOS arm64，解压后 `chmod +x` |
| `geoip.dat` / `geosite.dat` | 同上 release 包内，或 `https://github.com/v2fly/domain-list-community` |
| `link.txt` | 你自己的订阅节点列表（每行一个 vmess/ss/trojan/vless 链接） |

需要 Python 3.9+（`dict[str, ...]` 泛型注解）。

---

## 文件说明

```
start_cli.sh            启动 / 选节点 / 自愈主流程
gen_xray_config.py      生成 xray config.json；香港过滤在这里
node_stats.py           节点健康统计与候选排序（策略 1 + 2 的实现）
stop_cli.sh             停止代理并关闭系统代理
proxy_switch.sh         切换系统代理开关
bypass_domains.txt      系统代理绕过列表
com.a.vpn-health.plist.example   launchd 定时任务模板（auto-heal）
config.json             运行时生成，每次启动覆盖
selected_node.txt       运行时生成，记录当前节点（node_id = link.txt 行号）
health.log              采样日志，append-only
```

---

## 注意

`link.txt`、`config.json`、`selected_node.txt` 含节点凭据。本仓库是公开的，**不要把 `.env`、工作日志或任何 API Key 一起提交**（`.gitignore` 已经挡住 `/.env`、`/.workbuddy/`、`*.log` 和二进制）。
