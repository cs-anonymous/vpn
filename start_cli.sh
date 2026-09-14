#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_BIN="$SCRIPT_DIR/xray"
LINK_FILE="${LINK_FILE:-`echo ~/vpn/link.txt`}"
HTTP_PORT="${HTTP_PORT:-7890}"
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  HTTP_PORT="$1"
fi
SOCKS_PORT="$((HTTP_PORT + 1))"
PYTHON_BIN="${PYTHON_BIN:-python3}"

PID_FILE="$SCRIPT_DIR/xray.pid"
CONF_FILE="$SCRIPT_DIR/config.json"
LOG_FILE="$SCRIPT_DIR/xray.log"
SELECTED_FILE="$SCRIPT_DIR/selected_node.txt"
LOCK_DIR="$SCRIPT_DIR/.start_cli.lock"
# geosite.dat / geoip.dat live next to the binary; make it explicit so the
# CN-bypass rules resolve no matter which cwd start_cli.sh was invoked from.
export XRAY_LOCATION_ASSET="$SCRIPT_DIR"
GOOGLE_PROBE_URL="https://www.google.com/generate_204"
YOUTUBE_PROBE_URL="https://www.youtube.com/"

acquire_start_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi

  echo "Another vpn start is already running; refusing to start a new one." >&2
  exit 2
}

probe_url() {
  local url="$1"
  curl -s -o /dev/null -w '%{http_code}' \
    --proxy "http://127.0.0.1:${HTTP_PORT}" \
    -L --connect-timeout 3 --max-time 6 \
    "$url" 2>/dev/null || true
}

check_node_ok() {
  local google_code youtube_code
  google_code="$(probe_url "$GOOGLE_PROBE_URL")"
  youtube_code="$(probe_url "$YOUTUBE_PROBE_URL")"
  if [[ "$google_code" == "204" && "$youtube_code" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi
  echo "Proxy check failed: google=${google_code:-000} youtube=${youtube_code:-000}" >&2
  return 1
}

check_node_stable() {
  check_node_ok || return 1
  # sleep 1
  # check_node_ok || return 1
}

check_port_listening() {
  local port="$1"
  python3 -c "import socket; s=socket.socket(); s.settimeout(1); s.connect(('127.0.0.1',$port)); s.close()" 2>/dev/null
}

check_saved_xray_alive() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

enable_system_proxy() {
  if [[ "$(uname)" == "Darwin" ]]; then
    local service="Wi-Fi"
    networksetup -setwebproxy "$service" 127.0.0.1 "$HTTP_PORT"
    networksetup -setsecurewebproxy "$service" 127.0.0.1 "$HTTP_PORT"
    networksetup -setsocksfirewallproxy "$service" 127.0.0.1 "$SOCKS_PORT"

    local bypass_file="$SCRIPT_DIR/bypass_domains.txt"
    if [[ -f "$bypass_file" ]]; then
      local -a bypass=()
      local line
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [[ -n "$line" ]] && bypass+=("$line")
      done < "$bypass_file"
      if [[ ${#bypass[@]} -gt 0 ]]; then
        networksetup -setproxybypassdomains "$service" "${bypass[@]}"
        echo "Bypass list applied: ${#bypass[@]} entries from bypass_domains.txt"
      fi
    else
      networksetup -setproxybypassdomains "$service" 127.0.0.1 localhost \
        192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 "*.local" "169.254.0.0/16"
    fi
    echo "System proxy enabled (browser will use proxy automatically)"
  fi
}

# ─────────────────────────── 健康度采样 ───────────────────────────
# health.log 每行一条：<ISO8601 时间戳> <1|0> <节点行号>
#   1 = 代理可用（Google 204 且 YouTube 2xx）
#   0 = 不可用
#   节点行号 = link.txt 中第几行（从 selected_node.txt 的 source_line 字段读）
#   写不进去时记 "-"（如还没选过节点 / 代理完全没起来过）
#   老格式（只有 2 列）报告里仍兼容解析为 node="-"
HEALTH_LOG="$SCRIPT_DIR/health.log"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"

# ── 选节点策略参数 ─────────────────────────────────────────────────
# 策略 1：候选节点按 health.log 的历史期望可用率降序尝试，不再按 link.txt 顺序，
#         可用率低的节点自然排到最后（node_stats.py rank 负责算）。
# 策略 2：最近一次失败距今 < NODE_COOLDOWN 的节点直接排除，冷却期满才重新参选。
NODE_STATS="$SCRIPT_DIR/node_stats.py"
RANK_WINDOW="${RANK_WINDOW:-86400}"               # 排序统计窗口：24h
NODE_COOLDOWN="${NODE_COOLDOWN:-3600}"            # 失败冷却：1h
DEFAULT_NODE_RATIO="${DEFAULT_NODE_RATIO:-0.85}"  # 未探测节点的先验可用率

# 从 selected_node.txt 读出当前选中的 link.txt 行号；读不到返回 "-"
current_node_id() {
  local f="$SCRIPT_DIR/selected_node.txt"
  [[ -f "$f" ]] || { echo "-"; return; }
  # node_id 是主字段（值 = link.txt 行号）；source_line 是旧字段，同值，兼容读取
  awk -F= '$1=="node_id"{print $2; exit}' "$f" 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$' \
    || awk -F= '$1=="source_line"{print $2; exit}' "$f" 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$' \
    || echo "-"
}

log_health() {
  # 参数 1：1/0   参数 2：节点行号（可选，默认 "-"）
  local ok="${1:-0}" node="${2:-$(current_node_id)}"
  printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$ok" "$node" >> "$HEALTH_LOG"
}

# 采样一次，输出 1 或 0（不写日志）
health_sample() {
  if check_port_listening "$HTTP_PORT" && check_node_ok 2>/dev/null; then
    echo 1
  else
    echo 0
  fi
}

# 采样一次并追加到 health.log（自动带上当前节点行号）
health_probe_once() {
  log_health "$(health_sample)"
}

health_watch() {
  echo "每 ${HEALTH_INTERVAL}s 采样一次 -> $HEALTH_LOG （Ctrl-C 停止）"
  while true; do
    local ok
    ok="$(health_sample)"
    log_health "$ok"
    if [[ "$ok" == "1" ]]; then
      printf '%s  UP    (http://127.0.0.1:%s, node=%s)\n' "$(date '+%H:%M:%S')" "$HTTP_PORT" "$(current_node_id)"
    else
      printf '%s  DOWN  (node=%s)\n' "$(date '+%H:%M:%S')" "$(current_node_id)"
    fi
    sleep "$HEALTH_INTERVAL"
  done
}

health_report() {
  python3 - "$HEALTH_LOG" <<'PY'
import datetime, pathlib, sys

path = pathlib.Path(sys.argv[1])
if not path.exists() or path.stat().st_size == 0:
    print(f"还没有采样数据：{path}")
    print("先跑一次：bash start_cli.sh health-probe")
    raise SystemExit(0)

rows, skipped = [], 0
for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
    parts = line.split()
    # 兼容 2 列老格式和 3 列新格式
    if len(parts) == 2 and parts[1] in ("0", "1"):
        ts_str, val, node = parts[0], parts[1], "-"
    elif len(parts) == 3 and parts[1] in ("0", "1"):
        ts_str, val, node = parts
    else:
        skipped += 1
        continue
    try:
        ts = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        skipped += 1
        continue
    rows.append((ts, int(val), node))

if not rows:
    print("日志里没有可用样本")
    raise SystemExit(0)

rows.sort(key=lambda r: r[0])
now = datetime.datetime.now().astimezone()

def line_out(label, rs, width=14):
    if not rs:
        print(f"{label:<{width}}    —（无样本）")
        return
    up = sum(v for _, v, _ in rs)
    print(f"{label:<{width}} {up / len(rs) * 100:6.1f}%   up={up:<5} n={len(rs)}")

def since(delta):
    cut = now - delta
    return [r for r in rows if r[0] >= cut]

print(f"日志  {path}   ({len(rows)} 条样本" + (f", {skipped} 行忽略" if skipped else "") + ")")
print(f"区间  {rows[0][0]:%Y-%m-%d %H:%M} ~ {rows[-1][0]:%Y-%m-%d %H:%M}")
flag = "" if rows[-1][0] >= now - datetime.timedelta(minutes=5) else "  ⚠ 最近 5 分钟无采样，监控可能没在跑"
node_latest = rows[-1][2]
print(f"最新  {rows[-1][0]:%Y-%m-%d %H:%M:%S}  {'UP' if rows[-1][1] else 'DOWN'}   node={node_latest}{flag}")
print()
line_out("总体 UP ratio", rows)
line_out("过去 1 小时", since(datetime.timedelta(hours=1)))
line_out("过去 24 小时", since(datetime.timedelta(hours=24)))
line_out("今天", [r for r in rows if r[0].date() == now.date()])

last = rows[-1][1]
streak = 0
for _, v, _ in reversed(rows):
    if v != last:
        break
    streak += 1
print()
print(f"当前连续 {'UP' if last else 'DOWN'}：{streak} 次")

buckets = {}
for ts, v, _ in since(datetime.timedelta(hours=24)):
    buckets.setdefault(ts.replace(minute=0, second=0, microsecond=0), []).append(v)
if buckets:
    print("\n过去 24 小时逐小时：")
    for k in sorted(buckets):
        vs = buckets[k]
        r = sum(vs) / len(vs)
        bar = "█" * round(r * 20)
        print(f"  {k:%m-%d %H:00}  {r * 100:5.1f}%  {bar:<20} ({sum(vs)}/{len(vs)})")

# 按节点行号统计 UP ratio——只统计 source_line 明确写出的样本（node != "-"）
print("\n按节点行号统计（过去 24 小时，按 UP ratio 升序，最差的在最上面）：")
by_node = {}
for ts, v, n in since(datetime.timedelta(hours=24)):
    if n == "-":
        continue
    by_node.setdefault(n, []).append((ts, v))
if not by_node:
    print("  过去 24 小时没有带节点行号的样本（等几轮自动采样即可）")
else:
    rows_node = []
    for n, rs in by_node.items():
        up = sum(v for _, v in rs)
        n_total = len(rs)
        # 最近一次是否还在用
        last_ts = max(t for t, _ in rs)
        latest = sorted(rs, key=lambda r: r[0])[-1][1]
        rows_node.append((n, up, n_total, last_ts, latest))
    rows_node.sort(key=lambda r: (r[1] / r[2], -r[3]))  # UP ratio 升序，再按最近时间降序
    for n, up, n_total, last_ts, latest in rows_node:
        r = up / n_total
        bar = "█" * round(r * 20)
        flag_node = "  ← 当前节点" if n == node_latest else ""
        print(f"  link.txt 第 {n:>3} 行   {r*100:5.1f}%  {bar:<20} ({up}/{n_total})  最近 {last_ts:%m-%d %H:%M} {'UP' if latest else 'DOWN'}{flag_node}")

# 连续 DOWN 段（>=2 次）用于定位抖动的时段
outages, run = [], []
for ts, v, _ in rows:
    if v == 0:
        run.append((ts, v))
    elif run:
        if len(run) >= 2:
            outages.append((run[0][0], run[-1][0], len(run)))
        run = []
if len(run) >= 2:
    outages.append((run[0][0], run[-1][0], len(run)))
if outages:
    print("\n最近的断线片段（连续 DOWN ≥2 次）：")
    for a, b, n in outages[-8:]:
        print(f"  {a:%m-%d %H:%M:%S} → {b:%m-%d %H:%M:%S}   {n} 次")
PY
}

# auto-heal 分支会自己记账，用它标记避免脚本末尾重复采样
PROBE_DONE=0

case "${1:-}" in
  health)
    health_report
    exit 0
    ;;
  nodes)
    "$PYTHON_BIN" "$NODE_STATS" report \
      --log "$HEALTH_LOG" \
      --window "$RANK_WINDOW" \
      --cooldown "$NODE_COOLDOWN" \
      --default-ratio "$DEFAULT_NODE_RATIO" \
      --total-lines "$(wc -l < "$LINK_FILE" | tr -d ' ')"
    exit 0
    ;;
  health-probe)
    health_probe_once
    exit 0
    ;;
  auto-heal)
    # 给定时任务用：先记一次账，UP 就直接退出；
    # DOWN 则顺势落到下面的启动流程 —— 重新排序候选、换节点、把 xray 拉起来。
    HEAL_OK="$(health_sample)"
    log_health "$HEAL_OK"
    if [[ "$HEAL_OK" == "1" ]]; then
      printf '%s  UP    (node=%s)\n' "$(date '+%H:%M:%S')" "$(current_node_id)"
      exit 0
    fi
    printf '%s  DOWN  (node=%s) — 触发自动重连\n' "$(date '+%H:%M:%S')" "$(current_node_id)"
    PROBE_DONE=1
    ;;
  health-watch)
    health_watch
    exit 0
    ;;
  -h|--help)
    cat <<EOF
用法:
  bash start_cli.sh [端口] [link.txt行号]  启动/复用代理(默认 7890)
     第 2 个参数是 link.txt 的行号(1-based)，与 health.log 第 3 列同一套编号。
     省略则自动选：ping 可达 + 未冷却 + 历史可用率最高的节点。
  bash start_cli.sh nodes                 各节点健康报告(期望可用率 / 冷却状态)
  bash start_cli.sh health                整体 UP ratio 报告
  bash start_cli.sh health-probe          采样一次并追加 1/0 到 health.log(纯记账)
  bash start_cli.sh auto-heal             采样 + 断线时自动换节点重连(推荐给 launchd)
  bash start_cli.sh health-watch          前台循环采样(间隔 HEALTH_INTERVAL 秒)

health.log 格式: <ISO8601> <1|0> <link.txt行号>
策略参数可用环境变量覆盖：RANK_WINDOW=86400 NODE_COOLDOWN=3600 DEFAULT_NODE_RATIO=0.85
EOF
    exit 0
    ;;
esac

# ── 健康样本自动记录 ───────────────────────────────────────────────
# 落在 case 之后、任何重启动作之前：
#   - 度量「这一分钟开始时代理是否可用」→ 真实 UP ratio
#   - 即使脚本随后被杀/卡住，样本已落盘，不会漏记
#   - 子命令 health / nodes / health-probe / auto-heal / health-watch 不会重复记账
if [[ "$PROBE_DONE" != "1" ]]; then
  health_probe_once
fi

acquire_start_lock

if [[ ! -x "$XRAY_BIN" ]]; then
  echo "xray binary not found: $XRAY_BIN" >&2
  exit 1
fi
if [[ ! -f "$LINK_FILE" ]]; then
  echo "link file not found: $LINK_FILE" >&2
  exit 1
fi

# Reuse a live local proxy only when real Google and YouTube traffic works.
if check_port_listening "$HTTP_PORT" && check_saved_xray_alive; then
  if ! check_node_stable; then
    echo "Existing proxy is locally alive but upstream is unhealthy; restarting..." >&2
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
    sleep 1
  else
    enable_system_proxy
    echo "Proxy already running (local port and xray process are healthy)"
    echo "http://127.0.0.1:${HTTP_PORT}"
    echo "socks5://127.0.0.1:${SOCKS_PORT}"
    echo "pid=$(cat "$PID_FILE")"
    if [[ -f "$SELECTED_FILE" ]]; then
      echo "node=$(tr '\n' ' ' < "$SELECTED_FILE")"
    fi
    exit 0
  fi
fi

if check_port_listening "$HTTP_PORT"; then
  echo "Port $HTTP_PORT is occupied but saved xray is not alive; refusing to replace it." >&2
  exit 2
fi
rm -f "$PID_FILE"

# ── 候选节点来源 ───────────────────────────────────────────────────
# 候选 = link.txt 里「非香港」且「可解析」的行。identity 用 link.txt 行号，
# 与 health.log 第 3 列、node_stats.py 的排名、--line 参数完全一致。
# 香港过滤由 gen_xray_config.is_hongkong_url 负责 —— 它会 base64 解码
# vmess 的 ps 字段再判断，明文匹配做不到这件事。
list_candidate_lines() {
  "$PYTHON_BIN" - "$LINK_FILE" <<PYEOF
import pathlib, sys
sys.path.insert(0, '$SCRIPT_DIR')
from gen_xray_config import parse_link, is_hongkong_url

lines = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
for i, line in enumerate(lines, start=1):
    if not is_hongkong_url(line) and parse_link(line.strip()):
        print(i)
PYEOF
}

# 策略 1 + 策略 2 的落点：把候选丢给 node_stats.py，
# 返回「按期望可用率降序、且剔除了冷却中节点」的行号列表。
# 额外参数（如 --ignore-cooldown）会原样透传。
rank_candidates() {
  local candidate_file="$1"; shift
  "$PYTHON_BIN" "$NODE_STATS" rank \
    --log "$HEALTH_LOG" \
    --lines "$candidate_file" \
    --window "$RANK_WINDOW" \
    --cooldown "$NODE_COOLDOWN" \
    --default-ratio "$DEFAULT_NODE_RATIO" \
    --format lines "$@" 2>/dev/null
}

try_node() {
  local line_no="$1"

  # 按 link.txt 行号寻址（与 health.log 第 3 列同一套编号）
  "$PYTHON_BIN" "$SCRIPT_DIR/gen_xray_config.py" \
    --links "$LINK_FILE" \
    --line "$line_no" \
    --http-port "$HTTP_PORT" \
    --socks-port "$SOCKS_PORT" \
    --out "$CONF_FILE" \
    --selected "$SELECTED_FILE" || return 1

  nohup "$XRAY_BIN" run -c "$CONF_FILE" >"$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  sleep 1

  if ! check_port_listening "$HTTP_PORT"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi

  if check_node_stable; then
    return 0
  else
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
}

# 并行 ping 预筛 + 按历史可用率排序后依次尝试。
#   第 1 轮：ping 可达 且 未冷却，按期望可用率降序 —— 策略 1 + 策略 2
#   第 2 轮：放开 ping 与冷却限制兜底，避免「全部处于冷却中」或
#            「服务器禁 ICMP」时无节点可用
fast_ping_nodes() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'" RETURN

  echo "Parallel-pinging candidate nodes..."

  "$PYTHON_BIN" - "$LINK_FILE" "$tmpdir" <<PYEOF
import concurrent.futures
import pathlib
import subprocess
import sys

sys.path.insert(0, '$SCRIPT_DIR')
from gen_xray_config import parse_link, is_hongkong_url

link_file, tmpdir = sys.argv[1], sys.argv[2]
lines = pathlib.Path(link_file).read_text(encoding='utf-8').splitlines()
BATCH_SIZE = 12
PING_TIMEOUT = 3


def server_address(outbound):
    settings = outbound.get('settings', {})
    if 'vnext' in settings:
        return settings['vnext'][0].get('address')
    if 'servers' in settings:
        return settings['servers'][0].get('address')
    return None


def ping(line_no):
    parsed = parse_link(lines[line_no - 1].strip())
    if not parsed:
        return None
    addr = server_address(parsed[0])
    if not addr:
        return None
    rc = subprocess.run(
        ['ping', '-c', '1', '-W', str(PING_TIMEOUT), addr],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode
    return line_no if rc == 0 else None


candidates = [i for i, l in enumerate(lines, start=1)
              if not is_hongkong_url(l) and parse_link(l.strip())]

with concurrent.futures.ThreadPoolExecutor(max_workers=BATCH_SIZE) as ex:
    reachable = sorted(r for r in ex.map(ping, candidates) if r is not None)

pathlib.Path(tmpdir, 'candidates.txt').write_text('\n'.join(map(str, candidates)))
pathlib.Path(tmpdir, 'reachable.txt').write_text('\n'.join(map(str, reachable)))
print(f"候选 {len(candidates)} 个 / ping 可达 {len(reachable)} 个", file=sys.stderr)
PYEOF

  local cand="$tmpdir/candidates.txt"
  local reach="$tmpdir/reachable.txt"

  if [[ ! -s "$cand" ]]; then
    echo "没有可用候选节点（link.txt 里没有非香港且可解析的行）" >&2
    return 1
  fi

  local tried=" "
  local n
  local -a round1=()
  local -a round2=()

  if [[ -s "$reach" ]]; then
    mapfile -t round1 < <(rank_candidates "$reach")
  fi

  echo "第 1 轮：ping 可达 + 未冷却 + 历史可用率降序（${#round1[@]} 个）"
  for n in ${round1[@]+"${round1[@]}"}; do
    printf '  link.txt 第 %-4s 行 ' "$n"
    if try_node "$n"; then echo "OK"; return 0; fi
    echo "FAIL"
    tried="$tried$n "
  done

  mapfile -t round2 < <(rank_candidates "$cand" --ignore-cooldown)
  echo "第 2 轮：放开 ping / 冷却限制兜底（${#round2[@]} 个候选）"
  for n in ${round2[@]+"${round2[@]}"}; do
    if [[ "$tried" == *" $n "* ]]; then continue; fi
    printf '  link.txt 第 %-4s 行 ' "$n"
    if try_node "$n"; then echo "OK"; return 0; fi
    echo "FAIL"
    tried="$tried$n "
  done

  return 1
}

print_success() {
  enable_system_proxy
  echo "CLI proxy started"
  echo "http://127.0.0.1:${HTTP_PORT}"
  echo "socks5://127.0.0.1:${SOCKS_PORT}"
  echo "pid=$(cat "$PID_FILE")"
  echo "node=$(tr '\n' ' ' < "$SELECTED_FILE")"
}

if [[ -n "${2:-}" ]]; then
  # 手工指定 link.txt 行号
  echo "Trying link.txt line $2..."
  if try_node "$2"; then
    print_success
  else
    echo "link.txt 第 $2 行连接失败，详见 $LOG_FILE" >&2
    exit 3
  fi
else
  # 自动选节点：ping 预筛 → 历史可用率排序 → 冷却过滤
  if fast_ping_nodes; then
    print_success
    exit 0
  fi

  # 兜底：全部候选（不限 ping 结果、忽略冷却）按历史可用率再扫一轮
  echo "自动选节点未成功，改为全量候选 + 忽略冷却再扫一轮..." >&2
  cand_file="$(mktemp)"
  list_candidate_lines > "$cand_file"
  mapfile -t all_candidates < <(rank_candidates "$cand_file" --ignore-cooldown)
  rm -f "$cand_file"

  for n in ${all_candidates[@]+"${all_candidates[@]}"}; do
    printf '  link.txt 第 %-4s 行 ' "$n"
    if try_node "$n"; then
      echo "OK"
      print_success
      exit 0
    fi
    echo "FAIL"
  done

  echo "所有候选节点均失败，详见 $LOG_FILE" >&2
  exit 3
fi
