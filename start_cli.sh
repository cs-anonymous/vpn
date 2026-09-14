#!/usr/bin/env bash
# ⚠ 本脚本必须兼容 bash 3.2。
#   cron 的 PATH 只有 /usr/bin:/bin，`#!/usr/bin/env bash` 会解析到 macOS
#   自带的 /bin/bash 3.2.57 —— 那里没有 mapfile、也没有关联数组。
#   所以全文只用 3.2 也支持的语法（数组本身可用，mapfile 不可用）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 唯一根目录：~/vpn（macOS 与 Linux 完全一致）─────────────────────
# 家目录在两个平台上本来就不同（macOS /Users/<user>、Linux /home/<user>），
# 所以「固定路径」= 固定成「家目录下的 vpn」= $HOME/vpn，而不是写死绝对
# 字符串 —— 写死 /Users/... 到 Linux 上必然失效。
# 脚本里不再出现第二个根：下面所有路径都由 VPN_HOME 推导。
# 需要临时换位置（测试 / 迁移）时覆盖 VPN_HOME 即可。
VPN_HOME="${VPN_HOME:-$HOME/vpn}"

# 所有日志集中在 $VPN_HOME/logs/，根目录只放程序、配置与节点文件
LOGS_DIR="$VPN_HOME/logs"
VPN_LOG="$LOGS_DIR/vpn.log"         # 本脚本的操作日志：启动 / 换节点 / 自愈 / 代理开关
HEALTH_LOG="$LOGS_DIR/health.log"   # 每分钟一条 1/0 采样
LOG_FILE="$LOGS_DIR/xray.log"       # xray 进程自身的 stdout/stderr

# 运行时状态（每次启动重新生成）
PID_FILE="$VPN_HOME/xray.pid"
CONF_FILE="$VPN_HOME/config.json"
SELECTED_FILE="$VPN_HOME/selected_node.txt"
LOCK_DIR="$VPN_HOME/.start_cli.lock"
PROXY_ENV="$VPN_HOME/proxy.env"

# 程序与数据
LINK_FILE="${LINK_FILE:-$VPN_HOME/link.txt}"
PROBE_SCRIPT="$VPN_HOME/node_probe.py"
NODE_STATS="$VPN_HOME/node_stats.py"
GEN_SCRIPT="$VPN_HOME/gen_xray_config.py"
BYPASS_FILE="$VPN_HOME/bypass_domains.txt"
# geosite.dat / geoip.dat 与二进制同目录；显式指定，避免受 cwd 影响
export XRAY_LOCATION_ASSET="$VPN_HOME"

HTTP_PORT="${HTTP_PORT:-7890}"
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  HTTP_PORT="$1"
fi
SOCKS_PORT="$((HTTP_PORT + 1))"
PYTHON_BIN="${PYTHON_BIN:-python3}"
# 解析成绝对路径：cron 下 PATH 极简，而且 doctor 里显示绝对路径才能看出
# 到底用的是哪一个解释器（系统/conda/托管版行为可能不同）。
PYTHON_BIN="$(command -v "$PYTHON_BIN" 2>/dev/null || printf '%s' "$PYTHON_BIN")"
# cron 下 stdout 可能落在 ASCII locale，Python 打印中文会 UnicodeEncodeError
export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

GOOGLE_PROBE_URL="https://www.google.com/generate_204"
YOUTUBE_PROBE_URL="https://www.youtube.com/"

# ── 日志目录 ───────────────────────────────────────────────────────
# best-effort：建不出来时不阻断代理启动（可用性优先），doctor 会报出来。
ensure_logs_dir() {
  [[ -d "$LOGS_DIR" ]] && return 0
  mkdir -p "$LOGS_DIR" 2>/dev/null
}

# 记录一条操作日志：终端照常显示，同时追加到 logs/vpn.log。
# 刻意不用 `exec > >(tee -a ...)`：那种写法在脚本 exit 时可能与 tee 竞争、
# 丢掉最后几行，而本脚本被 cron 每分钟调用一次，确定性比省事重要。
vlog() {
  local _ts
  _ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s  %s\n' "$_ts" "$*"
  { printf '%s  %s\n' "$_ts" "$*" >> "$VPN_LOG"; } 2>/dev/null || true
}

# 只落盘、不打到终端：给 cron 用，避免把 stdout 撑成多行触发日志展开
vlog_file() {
  local _ts
  _ts="$(date '+%Y-%m-%d %H:%M:%S')"
  { printf '%s  %s\n' "$_ts" "$*" >> "$VPN_LOG"; } 2>/dev/null || true
}

ensure_logs_dir || true

# ── xray 二进制解析（macOS / Linux 双平台）──────────────────────────
# 位置优先级：XRAY_BIN 环境变量 > xray-<os>-<arch> > xray
# 判定方式是真的执行一次 `xray version`：架构不匹配的二进制会被内核以
# "Exec format error" 拒绝，这比用 file 命令猜平台可靠得多。
XRAY_BIN=""

resolve_xray_bin() {
  local os arch suffix
  case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux)  os="linux" ;;
    *)      os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64-v8a" ;;
    x86_64|amd64)  arch="64" ;;
    *)             arch="$(uname -m)" ;;
  esac
  suffix="${os}-${arch}"

  local candidates="$VPN_HOME/xray-${suffix} $VPN_HOME/xray"
  if [[ -n "${XRAY_BIN_OVERRIDE:-}" ]]; then
    candidates="$XRAY_BIN_OVERRIDE $candidates"
  fi

  local c
  for c in $candidates; do
    [[ -f "$c" && -x "$c" ]] || continue
    if "$c" version >/dev/null 2>&1; then
      XRAY_BIN="$c"
      return 0
    fi
    echo "跳过 ${c}：无法在本机执行（架构不匹配？）" >&2
  done

  echo "找不到可用的 xray 二进制（本机 $(uname -s)/$(uname -m)）。" >&2
  echo "  期望：$VPN_HOME/xray-${suffix}   或   $VPN_HOME/xray" >&2
  echo "  下载：https://github.com/XTLS/Xray-core/releases  选 Xray-${suffix}" >&2
  return 1
}

# 单实例锁。必须是 mkdir 语义 —— macOS 上没有 flock（实测 /usr/bin/flock 不存在）。
# 残留锁回收很重要：被 kill -9 或机器重启后锁目录会留下，旧实现会永久拒绝启动，
# 而 cron 每分钟跑一次，症状就是「任务在跑但代理永远起不来」。
acquire_start_lock() {
  if [[ -d "$LOCK_DIR" ]]; then
    local owner=""
    [[ -f "$LOCK_DIR/pid" ]] && owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"

    if [[ "$owner" =~ ^[0-9]+$ ]] && [[ "$owner" != "$$" ]] && kill -0 "$owner" 2>/dev/null; then
      echo "另一个 start_cli.sh 正在运行 (pid $owner)，本次跳过。" >&2
      exit 2
    fi

    local stale=0
    if [[ "$owner" =~ ^[0-9]+$ ]]; then
      stale=1   # pid 明确且进程已不存在 → 残留
    elif [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
      stale=1   # 没有 pid 文件，用锁目录年龄兜底
    fi

    if [[ "$stale" == "1" ]]; then
      echo "回收残留锁 ${LOCK_DIR}（持有者 ${owner:-未知} 已不存在）" >&2
      rm -rf "$LOCK_DIR"
    fi
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi

  echo "另一个 vpn start 正在进行中，本次跳过。" >&2
  exit 2
}

probe_url() {
  local url="$1"
  curl -s -o /dev/null -w '%{http_code}' \
    --proxy "http://127.0.0.1:${HTTP_PORT}" \
    -L --connect-timeout 3 --max-time 6 \
    "$url" 2>/dev/null || true
}

# 最近一次探测的明细，形如 google=204,youtube=200 或 google=000。
# 用逗号分隔保持「一个字段」的形态，health.log 才能既带上原因又不破坏列对齐。
PROBE_DIAG=""

check_node_ok() {
  local google_code youtube_code
  google_code="$(probe_url "$GOOGLE_PROBE_URL")"
  google_code="${google_code:-000}"
  # Google 不通就没必要再花 6s 探 YouTube —— 一次采样最多省一半时间。
  # 明细照样落 PROBE_DIAG，抖动到底卡在哪一段有据可查。
  if [[ "$google_code" != "204" ]]; then
    PROBE_DIAG="google=${google_code}"
    echo "Proxy check failed: google=${google_code}" >&2
    return 1
  fi
  youtube_code="$(probe_url "$YOUTUBE_PROBE_URL")"
  youtube_code="${youtube_code:-000}"
  PROBE_DIAG="google=204,youtube=${youtube_code}"
  if [[ "$youtube_code" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi
  echo "Proxy check failed: google=204 youtube=${youtube_code}" >&2
  return 1
}

check_node_stable() {
  # 连测 N 轮都通过才录用。瞬时探测会放过「握手成功但传不动数据」的节点，
  # 单纯依赖 1 次探测会导致在同一批烂节点之间反复横跳。
  # 交互启动用 1 轮（快）；auto-heal 用 2 轮（准），由 cron 包装器设 NODE_STABLE_ROUNDS=2。
  local rounds="${NODE_STABLE_ROUNDS:-1}"
  local i=0
  while [[ "$i" -lt "$rounds" ]]; do
    check_node_ok || return 1
    i=$((i + 1))
    [[ "$i" -lt "$rounds" ]] && sleep 1
  done
  return 0
}

check_port_listening() {
  local port="$1"
  "$PYTHON_BIN" -c "import socket; s=socket.socket(); s.settimeout(1); s.connect(('127.0.0.1',$port)); s.close()" 2>/dev/null
}

check_saved_xray_alive() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# ── 系统代理（macOS: networksetup / Linux: gsettings + proxy.env）──────
# 两个平台都没有统一的代理开关，而且 headless/cron 下拿不到桌面会话总线，
# 所以 Linux 侧额外落一份 proxy.env，source 一下即可在 shell 里用。
bypass_entries() {
  local f="$BYPASS_FILE"
  if [[ -f "$f" ]]; then
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" | grep -v '^$' || true
  else
    printf '%s\n' 127.0.0.1 localhost 192.168.0.0/16 10.0.0.0/8 \
      172.16.0.0/12 '*.local' '169.254.0.0/16'
  fi
}

# macOS 的网络服务名不一定是 "Wi-Fi"：中文系统、以太网、雷电网桥都会不同。
# 这里先按默认路由的接口反查服务名，取不到再退化为第一个启用的服务。
detect_net_service() {
  if [[ -n "${VPN_NET_SERVICE:-}" ]]; then
    printf '%s' "$VPN_NET_SERVICE"
    return 0
  fi

  local iface svc
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  if [[ -n "$iface" ]]; then
    svc="$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="$iface" '
      /^\([0-9]+\)/ { svc = $0; sub(/^\([0-9]+\)[[:space:]]*/, "", svc); next }
      $0 ~ ("Device: " dev "[,)]") { print svc; exit }')"
    [[ -n "$svc" ]] && { printf '%s' "$svc"; return 0; }
  fi

  networksetup -listallnetworkservices 2>/dev/null \
    | awk 'NR > 1 && $0 !~ /^\*/ { print; exit }' | tr -d '\n'
}

write_proxy_env() {
  local no_proxy
  no_proxy="$(bypass_entries | paste -sd, - 2>/dev/null || true)"
  cat > "$PROXY_ENV" <<EOF
# 由 start_cli.sh 自动生成：source 本文件即可在当前 shell 使用代理
export http_proxy="http://127.0.0.1:${HTTP_PORT}"
export https_proxy="\$http_proxy"
export all_proxy="socks5h://127.0.0.1:${SOCKS_PORT}"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
export ALL_PROXY="\$all_proxy"
export no_proxy="127.0.0.1,localhost,${no_proxy}"
export NO_PROXY="\$no_proxy"
EOF
}

enable_system_proxy_macos() {
  local service
  service="$(detect_net_service)"
  if [[ -z "$service" ]]; then
    echo "未能识别网络服务名，跳过系统代理设置（可 export VPN_NET_SERVICE=...）" >&2
    return 0
  fi

  networksetup -setwebproxy "$service" 127.0.0.1 "$HTTP_PORT" >/dev/null 2>&1 || true
  networksetup -setsecurewebproxy "$service" 127.0.0.1 "$HTTP_PORT" >/dev/null 2>&1 || true
  networksetup -setsocksfirewallproxy "$service" 127.0.0.1 "$SOCKS_PORT" >/dev/null 2>&1 || true

  local -a bypass=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && bypass+=("$line")
  done < <(bypass_entries)

  if [[ ${#bypass[@]} -gt 0 ]]; then
    networksetup -setproxybypassdomains "$service" "${bypass[@]}" >/dev/null 2>&1 || true
    vlog "系统代理已开启：${service}（绕过 ${#bypass[@]} 条）"
  else
    vlog "系统代理已开启：$service"
  fi
}

enable_system_proxy_linux() {
  write_proxy_env

  # gsettings 需要一个活的桌面会话总线；cron / ssh 下通常没有，静默退化
  if command -v gsettings >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    gsettings set org.gnome.system.proxy mode 'manual' >/dev/null 2>&1 || true
    for pair in "http $HTTP_PORT" "https $HTTP_PORT" "socks $SOCKS_PORT"; do
      set -- $pair
      gsettings set "org.gnome.system.proxy.$1" host '127.0.0.1' >/dev/null 2>&1 || true
      gsettings set "org.gnome.system.proxy.$1" port "$2" >/dev/null 2>&1 || true
    done
    vlog "系统代理已开启：GNOME gsettings"
  else
    vlog "已写 ${PROXY_ENV}（无桌面会话，未改全局设置）"
    vlog "  当前 shell 生效：source $PROXY_ENV"
  fi
}

enable_system_proxy() {
  case "$(uname -s)" in
    Darwin) enable_system_proxy_macos ;;
    Linux)  enable_system_proxy_linux ;;
    *)      echo "未适配的系统，跳过系统代理设置（手动用 http://127.0.0.1:${HTTP_PORT}）" ;;
  esac
  return 0
}

disable_system_proxy() {
  case "$(uname -s)" in
    Darwin)
      local service
      service="$(detect_net_service)"
      if [[ -n "$service" ]]; then
        networksetup -setwebproxystate "$service" off >/dev/null 2>&1 || true
        networksetup -setsecurewebproxystate "$service" off >/dev/null 2>&1 || true
        networksetup -setsocksfirewallproxystate "$service" off >/dev/null 2>&1 || true
        vlog "系统代理已关闭：$service"
      fi
      ;;
    Linux)
      if command -v gsettings >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        gsettings set org.gnome.system.proxy mode 'none' >/dev/null 2>&1 || true
        vlog "系统代理已关闭：GNOME gsettings"
      fi
      rm -f "$PROXY_ENV"
      vlog "已移除 proxy.env"
      ;;
  esac
  return 0
}

proxy_status() {
  case "$(uname -s)" in
    Darwin)
      local service
      service="$(detect_net_service)"
      echo "网络服务: ${service:-未识别}"
      [[ -n "$service" ]] && networksetup -getwebproxy "$service" 2>/dev/null
      [[ -n "$service" ]] && networksetup -getsecurewebproxy "$service" 2>/dev/null
      [[ -n "$service" ]] && networksetup -getsocksfirewallproxy "$service" 2>/dev/null
      ;;
    Linux)
      if command -v gsettings >/dev/null 2>&1; then
        gsettings get org.gnome.system.proxy mode 2>/dev/null || true
      fi
      if [[ -f "$PROXY_ENV" ]]; then
        echo "proxy.env 存在（source 后生效）"
      else
        echo "proxy.env 不存在"
      fi
      ;;
  esac
  return 0
}

# ─────────────────────────── 健康度采样 ───────────────────────────
# health.log 每行一条：<ISO8601 时间戳> <1|0> <节点行号>
#   1 = 代理可用（Google 204 且 YouTube 2xx）
#   0 = 不可用
#   节点行号 = link.txt 中第几行（从 selected_node.txt 的 source_line 字段读）
#   写不进去时记 "-"（如还没选过节点 / 代理完全没起来过）
#   老格式（只有 2 列）报告里仍兼容解析为 node="-"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"
# 采样确认轮数：一次 curl 探测在劣化线路上抖动极大，单发失败就记账会把「抖」
# 写成「故障」，进而把好节点推进冷却名单 —— 而它其实还在服务（见下方 auto-heal）。
# 规则：任一轮通过即记 1；全部轮次失败才记 0。0 从此等价于「确认不可用」。
HEALTH_CONFIRM_ROUNDS="${HEALTH_CONFIRM_ROUNDS:-2}"

# ── 选节点策略参数 ─────────────────────────────────────────────────
# 策略 1：候选节点按 health.log 的历史期望可用率降序尝试，不再按 link.txt 顺序，
#         可用率低的节点自然排到最后（node_stats.py rank 负责算）。
# 策略 2：最近一次失败距今 < NODE_COOLDOWN 的节点直接排除，冷却期满才重新参选。
RANK_WINDOW="${RANK_WINDOW:-86400}"               # 排序统计窗口：24h
NODE_COOLDOWN="${NODE_COOLDOWN:-3600}"            # 失败冷却：1h
DEFAULT_NODE_RATIO="${DEFAULT_NODE_RATIO:-0.85}"  # 未探测节点的先验可用率
# 单次自愈的总时长上限。cron 每分钟触发一次，坏节点太多时一次尝试可能拖很久，
# 后续触发会被单实例锁挡在门外（这是有意的），但也不能无限期拖着。
MAX_HEAL_SECONDS="${MAX_HEAL_SECONDS:-180}"
HEAL_DEADLINE=0

heal_start_clock() {
  HEAL_DEADLINE=$(( $(date +%s) + MAX_HEAL_SECONDS ))
}

heal_expired() {
  [[ "$HEAL_DEADLINE" -eq 0 ]] && return 1
  [[ "$(date +%s)" -ge "$HEAL_DEADLINE" ]]
}

# 从 selected_node.txt 读出当前选中的 link.txt 行号；读不到返回 "-"
current_node_id() {
  local f="$SELECTED_FILE"
  [[ -f "$f" ]] || { echo "-"; return; }
  # node_id 是主字段（值 = link.txt 行号）；source_line 是旧字段，同值，兼容读取
  awk -F= '$1=="node_id"{print $2; exit}' "$f" 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$' \
    || awk -F= '$1=="source_line"{print $2; exit}' "$f" 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$' \
    || echo "-"
}

# 安全的节点摘要：只输出 node_id / protocol，**不**输出 link 行本身。
# selected_node.txt 里存的 link 含 UUID/密码，而 print_success 的输出会被
# cron 包装器写进 cron.log —— 直接 tr 出来等于把凭据落到日志文件里。
current_node_summary() {
  local f="$SELECTED_FILE"
  [[ -f "$f" ]] || { echo "node=-"; return; }
  local id proto
  id="$(current_node_id)"
  proto="$(awk -F= '$1=="protocol"{print $2; exit}' "$f" 2>/dev/null | tr -d '[:space:]')"
  echo "node=${id}${proto:+ (${proto})}"
}

# link.txt 的行数。用 Python 的 splitlines 而不是 wc -l：
# 末行没有换行符时 wc -l 会少算一行，而行号体系必须与它严格一致。
link_total_lines() {
  "$PYTHON_BIN" -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()))' "$LINK_FILE" 2>/dev/null \
    || echo 0
}

# 本次运行已经为哪个节点记过账、记的是什么值。
# log_health_after_switch 靠它判断要不要补样本，避免同一分钟给同一节点记两条。
HEALTH_LOGGED_NODE=""
HEALTH_LOGGED_OK=""

log_health() {
  # 参数 1：1/0   参数 2：节点行号（可选，默认 "-"）   参数 3：失败明细（可选）
  local ok="${1:-0}" node="${2:-$(current_node_id)}" diag="${3:-}"
  if [[ -n "$diag" ]]; then
    printf '%s %s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$ok" "$node" "$diag" >> "$HEALTH_LOG"
  else
    printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$ok" "$node" >> "$HEALTH_LOG"
  fi
  HEALTH_LOGGED_NODE="$node"
  HEALTH_LOGGED_OK="$ok"
}

# ── 采样状态（直接写全局，避免 $( ) 子 shell 把明细丢掉）────────────
# HEALTH_OK   1/0
# HEALTH_DIAG 探测明细；port-closed 表示 xray 本地端口都没在监听
HEALTH_OK="0"
HEALTH_DIAG=""

health_check_state() {
  local rounds="${HEALTH_CONFIRM_ROUNDS:-2}" i=0
  HEALTH_OK="0"
  HEALTH_DIAG="port-closed"
  if ! check_port_listening "$HTTP_PORT"; then
    return 0
  fi
  while [[ "$i" -lt "$rounds" ]]; do
    i=$((i + 1))
    if check_node_ok 2>/dev/null; then
      HEALTH_OK="1"
      HEALTH_DIAG="$PROBE_DIAG"
      return 0
    fi
    HEALTH_DIAG="$PROBE_DIAG"
    if [[ "$i" -lt "$rounds" ]]; then
      sleep 1
    fi
  done
  return 0
}

# 采样一次并追加到 health.log（自动带上当前节点行号与失败明细）
health_probe_once() {
  health_check_state
  log_health "$HEALTH_OK" "$(current_node_id)" "$HEALTH_DIAG"
}

# 换节点成功后补记一条样本 —— 一次运行写 1~2 条 health 里的第 2 条。
#
# 为什么需要它：主流程开头（或 auto-heal 的 case 里）已经记过一条，那是
# 「这一分钟开始时，旧节点是否可用」。如果它是 0，脚本会去换节点；换成功了
# 却不落盘，health.log 里就只留着旧节点的失败，新节点永远是「未探测」——
# node_stats.py 只能拿 prior(0.85) 给它打分，一个「它其实能用」的证据都攒不下，
# 下一轮排序它还得吃亏。
#
# 两种情况补记：
#   1. 最终节点 ≠ 已记账节点 —— 正常换节点成功；
#   2. 最终节点 = 已记账节点，但已记账的值是 0 —— 全军覆没后回滚，
#      复用原节点并且这次真的通了。
# 已经有一条 1 的节点直接跳过：同一分钟给同一节点刷两条相同样本会把 UP ratio
# 灌水（cron 每分钟一次，多出来的那条等于双倍权重）。
log_health_after_switch() {
  local node
  node="$(current_node_id)"
  [[ "$node" =~ ^[0-9]+$ ]] || return 0
  if [[ "$node" == "$HEALTH_LOGGED_NODE" && "$HEALTH_LOGGED_OK" == "1" ]]; then
    return 0
  fi
  health_check_state
  log_health "$HEALTH_OK" "$node" "$HEALTH_DIAG"
  vlog_file "health: 切换后补记 node=${node} ${HEALTH_OK} [${HEALTH_DIAG}]"
}

health_watch() {
  echo "每 ${HEALTH_INTERVAL}s 采样一次（连续 ${HEALTH_CONFIRM_ROUNDS} 轮）-> $HEALTH_LOG （Ctrl-C 停止）"
  while true; do
    health_check_state
    log_health "$HEALTH_OK" "$(current_node_id)" "$HEALTH_DIAG"
    if [[ "$HEALTH_OK" == "1" ]]; then
      printf '%s  UP    (http://127.0.0.1:%s, node=%s)  %s\n' "$(date '+%H:%M:%S')" "$HTTP_PORT" "$(current_node_id)" "$HEALTH_DIAG"
    else
      printf '%s  DOWN  (node=%s)  %s\n' "$(date '+%H:%M:%S')" "$(current_node_id)" "$HEALTH_DIAG"
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
    # 兼容 3 种格式：
    #   2 列老格式  <ts> <1|0>
    #   3 列带节点  <ts> <1|0> <link.txt行号>
    #   4 列带明细  <ts> <1|0> <link.txt行号> <google=..,youtube=..>
    if len(parts) >= 3 and parts[1] in ("0", "1"):
        ts_str, val, node = parts[0], parts[1], parts[2]
    elif len(parts) == 2 and parts[1] in ("0", "1"):
        ts_str, val, node = parts[0], parts[1], "-"
    else:
        skipped += 1
        continue
    if node != "-" and not node.isdigit():
        node = "-"
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

# ── 自检 ───────────────────────────────────────────────────────────
doctor() {
  local ok="✓" bad="✗" warn="!"
  local script_dir_note=""

  echo "=== 环境 ==="
  echo "  系统        $(uname -s) $(uname -m)"
  echo "  系统根目录  $VPN_HOME"
  if [[ "$SCRIPT_DIR" != "$VPN_HOME" ]]; then
    echo "  脚本位置    ${warn} 脚本在 ${SCRIPT_DIR}，与根目录不一致"
    echo "              本工具只认 $VPN_HOME 这一个路径。请把整个目录放到"
    echo "              ${VPN_HOME} 下，或运行前 export VPN_HOME=$SCRIPT_DIR"
  fi
  [[ -w "$VPN_HOME" ]] && echo "  目录可写    $ok" || echo "  目录可写    ${bad}（无法写日志/配置）"
  if [[ -d "$LOGS_DIR" && -w "$LOGS_DIR" ]]; then
    echo "  日志目录    $LOGS_DIR  $ok"
  else
    echo "  日志目录    ${bad} $LOGS_DIR 不存在或不可写"
  fi

  local bv
  bv="$(bash --version 2>/dev/null | head -1)"
  echo "  bash        $BASH_VERSION"
  case "$BASH_VERSION" in
    3.2*) echo "              ${warn} 3.2 —— 本脚本已做兼容（不用 mapfile），但建议装 bash 5" ;;
  esac

  echo "  PYTHON_BIN  $PYTHON_BIN"
  if [[ ! -x "$PYTHON_BIN" ]] && ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "  python      ${bad} 找不到解释器。cron 的 PATH 只有 /usr/bin:/bin，"
    echo "              请通过 vpn-cron.sh 调用，或在 crontab 里显式设 PYTHON_BIN。"
  elif "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info>=(3,9) else 1)' 2>/dev/null; then
    echo "  python      $("$PYTHON_BIN" -V 2>&1)  $ok"
  else
    echo "  python      ${bad} 需要 3.9+（node_stats.py 用了 dict[str, ...] 注解）"
  fi

  local missing=""
  for f in gen_xray_config.py node_stats.py node_probe.py link.txt; do
    [[ -r "$VPN_HOME/$f" ]] || missing="$missing $f"
  done
  if [[ -z "$missing" ]]; then
    echo "  依赖文件    $ok"
  else
    echo "  依赖文件    $bad 缺失:$missing"
  fi
  if [[ ! -r "$PROBE_SCRIPT" ]]; then
    echo "              ${warn} node_probe.py 不可读，TCP 预筛会退化为全量候选"
  fi

  # 脚本卫生：`$var` 后面紧跟中文/全角字符时，在**没有 locale** 的环境里
  # （正是 cron）bash 会把多字节字符当成变量名的一部分，报「未绑定的变量」
  # 并让自愈静默失败。这个坑只在剥离环境里暴露，所以固定放进自检。
  local bad_expand=""
  bad_expand="$("$PYTHON_BIN" - "$VPN_HOME" <<'PY'
import pathlib, re, sys
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])')
out = []
for name in ('start_cli.sh', 'vpn-cron.sh', 'install-cron.sh',
             'stop_cli.sh', 'proxy_switch.sh'):
    p = pathlib.Path(sys.argv[1]) / name
    if not p.exists():
        continue
    for i, line in enumerate(p.read_text(encoding='utf-8').splitlines(), 1):
        # 纯注释行跳过：$var 在注释里不会被 shell 展开，报出来只是噪音
        if line.lstrip().startswith('#'):
            continue
        if pat.search(line):
            out.append(f'{name}:{i}')
print(' '.join(out))
PY
)"
  if [[ -n "$bad_expand" ]]; then
    echo "  脚本卫生    ${warn} \$var 后紧跟非 ASCII 字符，cron 下会被解析成变量名："
    echo "              $bad_expand"
    echo "              修法：改用 \${var} 形式"
  else
    echo "  脚本卫生    $ok"
  fi

  echo
  echo "=== xray ==="
  if resolve_xray_bin 2>/dev/null; then
    echo "  二进制      $XRAY_BIN"
    echo "  版本        $("$XRAY_BIN" version 2>/dev/null | head -2 | tr '\n' ' ')"
    script_dir_note="$XRAY_BIN"
  else
    echo "  二进制      $bad 未找到可执行文件（详见下方报错）"
    resolve_xray_bin 2>&1 | sed 's/^/              /'
  fi
  for f in geoip.dat geosite.dat; do
    [[ -f "$VPN_HOME/$f" ]] && echo "  $f  $ok" || echo "  $f  $bad 缺失（分流规则会失效）"
  done

  echo
  echo "=== 节点池 ==="
  if [[ -r "$PROBE_SCRIPT" ]]; then
    local total cand
    total="$(link_total_lines)"
    cand="$("$PYTHON_BIN" "$PROBE_SCRIPT" list --links "$LINK_FILE" 2>/dev/null | wc -l | tr -d ' ')"
    echo "  link.txt    $total 行"
    echo "  候选        $cand 个（已排除香港）"
  else
    echo "  候选        $bad node_probe.py 缺失，无法统计"
  fi

  echo
  echo "=== 运行状态 ==="
  if check_port_listening "$HTTP_PORT"; then
    echo "  端口 $HTTP_PORT  监听中 $ok"
  else
    echo "  端口 $HTTP_PORT  未监听 $bad"
  fi
  if check_saved_xray_alive; then
    echo "  xray 进程   pid=$(cat "$PID_FILE" 2>/dev/null) $ok"
  else
    echo "  xray 进程   未运行（或 pid 文件缺失）"
  fi
  if [[ -f "$SELECTED_FILE" ]]; then
    echo "  当前节点    $(current_node_summary)"
  fi
  [[ -d "$LOCK_DIR" ]] && echo "  锁          ${warn} $LOCK_DIR 存在（若有进程持有则属正常）"

  echo
  echo "=== 健康采样 ==="
  if [[ -s "$HEALTH_LOG" ]]; then
    echo "  样本        $(wc -l < "$HEALTH_LOG" | tr -d ' ') 条"
    echo "  最新         $(tail -1 "$HEALTH_LOG")"
    local age
    age="$("$PYTHON_BIN" - "$HEALTH_LOG" <<'PY'
import datetime, pathlib, sys
line = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").strip().splitlines()[-1]
ts = datetime.datetime.strptime(line.split()[0], "%Y-%m-%dT%H:%M:%S%z")
print(int((datetime.datetime.now().astimezone() - ts).total_seconds() // 60))
PY
)"
    if [[ "$age" =~ ^[0-9]+$ ]] && [[ "$age" -le 5 ]]; then
      echo "  采样间隔    ${age} 分钟前 $ok"
    else
      echo "  采样间隔    ${age:-?} 分钟前 ${warn}（>5 分钟说明定时任务可能没在跑）"
    fi
  else
    echo "  样本        ${warn} 还没有采样数据，先跑一次 auto-heal"
  fi
  return 0
}

# auto-heal 分支会自己记账，用它标记避免脚本末尾重复采样
PROBE_DONE=0
# auto-heal 已经确认「当前节点不可用」时置 1。
# 它的唯一作用：禁止下面走「复用存活代理」的捷径 —— 见那一段的注释。
HEAL_DOWN=0
# 换节点之前的那个节点。全部换失败时用它回滚，避免「踢掉坏节点反而彻底断网」。
PREV_NODE=""

case "${1:-}" in
  health)
    health_report
    exit 0
    ;;
  nodes)
    # --current 必须是整数：还没选过节点时 current_node_id 返回 "-"，
    # argparse 会直接报错，所以在这里退化成 0（0 永不等于任何行号）。
    _cur="$(current_node_id)"
    [[ "$_cur" =~ ^[0-9]+$ ]] || _cur=0
    "$PYTHON_BIN" "$NODE_STATS" report \
      --log "$HEALTH_LOG" \
      --window "$RANK_WINDOW" \
      --cooldown "$NODE_COOLDOWN" \
      --default-ratio "$DEFAULT_NODE_RATIO" \
      --current "$_cur" \
      --total-lines "$(link_total_lines)"
    exit 0
    ;;
  health-probe)
    health_probe_once
    exit 0
    ;;
  auto-heal)
    # 给定时任务用：先记一次账，UP 就直接退出；
    # DOWN 则顺势落到下面的启动流程 —— 重新排序候选、换节点、把 xray 拉起来。
    # 这里默认要求连测 2 轮（比交互启动严），因为 cron 每分钟才给一次机会，
    # 误判成 UP 会白等一分钟。
    NODE_STABLE_ROUNDS="${NODE_STABLE_ROUNDS:-2}"
    health_check_state
    log_health "$HEALTH_OK" "$(current_node_id)" "$HEALTH_DIAG"
    if [[ "$HEALTH_OK" == "1" ]]; then
      printf '%s  UP    (node=%s)  %s\n' "$(date '+%H:%M:%S')" "$(current_node_id)" "$HEALTH_DIAG"
      exit 0
    fi
    printf '%s  DOWN  (node=%s)  %s — 触发自动重连\n' "$(date '+%H:%M:%S')" "$(current_node_id)" "$HEALTH_DIAG"
    vlog_file "auto-heal: DOWN node=$(current_node_id) [${HEALTH_DIAG}] — 触发自动重连"
    HEAL_DOWN=1
    PROBE_DONE=1
    ;;
  proxy-on)
    enable_system_proxy
    exit 0
    ;;
  proxy-off)
    disable_system_proxy
    exit 0
    ;;
  proxy-status)
    proxy_status
    exit 0
    ;;
  doctor)
    doctor
    exit 0
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
     省略则自动选：TCP 可达 + 未冷却 + 历史可用率最高的节点。
  bash start_cli.sh nodes                 各节点健康报告(期望可用率 / 冷却状态)
  bash start_cli.sh health                整体 UP ratio 报告
  bash start_cli.sh health-probe          采样一次并追加 1/0 到 health.log(纯记账)
  bash start_cli.sh auto-heal             采样 + 断线时自动换节点重连(定时任务用)
  bash start_cli.sh health-watch          前台循环采样(间隔 HEALTH_INTERVAL 秒)
  bash start_cli.sh proxy-on|off|status   系统代理开关(macOS / Linux 自动分派)
  bash start_cli.sh doctor                自检：xray / python / 节点池 / 当前状态

路径: 唯一根目录 \${VPN_HOME}(默认 \$HOME/vpn)，日志全在其下的 logs/
      logs/vpn.log 操作流水  logs/health.log 采样  logs/xray.log 进程输出
logs/health.log 格式: <ISO8601> <1|0> <link.txt行号> [<失败明细>]
      明细形如 google=000 或 google=204,youtube=403，用于定位抖动卡在哪一段；
      0 的含义是「连续 \${HEALTH_CONFIRM_ROUNDS} 轮全部失败」= 确认不可用。
      一次运行写 1~2 条：先记「开始时当前节点是否可用」；若它是 0，
      脚本换了节点并启动成功，会为新节点再补 1 条。
策略参数可用环境变量覆盖：RANK_WINDOW=86400 NODE_COOLDOWN=3600 DEFAULT_NODE_RATIO=0.85
                         NODE_STABLE_ROUNDS=2 MAX_HEAL_SECONDS=180
                         HEALTH_CONFIRM_ROUNDS=2 HEALTH_INTERVAL=60
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
heal_start_clock

if [[ ! -f "$LINK_FILE" ]]; then
  vlog "ERROR 找不到节点文件：$LINK_FILE" >&2
  exit 1
fi

resolve_xray_bin || exit 1

# ── auto-heal 判定 DOWN：先停掉旧 xray，禁止复用 ────────────────────
# 这是「冷却期名存实亡」的根因所在。
#   旧的复用路径只看 check_node_stable（N 轮连测）：节点在抖动时，很可能是
#   「采样那一刻不通 → 已经记了一条 0 → 复核的 2 轮又恰好都通」，
#   于是脚本打印「代理已在运行」直接 exit 0，节点换都没换。
#   结果就是 health.log 里它已经在冷却名单上躺着，实际却还在服务，
#   而且每分钟继续往它头上刷 0 —— 报告说「冷却中」，日志说「还在用」。
# 现在的约定很干脆：采样确认不可用 ⇒ 一律换节点，不再给「复用」开口子。
if [[ "$HEAL_DOWN" == "1" ]]; then
  PREV_NODE="$(current_node_id)"
  if check_saved_xray_alive; then
    _old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    vlog "auto-heal 已确认不可用 [${HEALTH_DIAG}] → 停掉旧 xray (pid=${_old_pid:-?}) 重新选节点"
    kill "$_old_pid" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  # 等端口真正释放（SIGTERM 到内核回收有几十毫秒到数秒的窗口）。
  # 只等 5s：等不到就交给下一分钟的 cron，绝不在这里无限期挂着。
  _wait=0
  while check_port_listening "$HTTP_PORT" && [[ "$_wait" -lt 5 ]]; do
    _wait=$((_wait + 1))
    sleep 1
  done
  if check_port_listening "$HTTP_PORT"; then
    vlog "端口 $HTTP_PORT 仍未释放（wait ${_wait}s），本分钟放弃，下一轮重试" >&2
    exit 2
  fi
fi

# Reuse a live local proxy only when real Google and YouTube traffic works.
# HEAL_DOWN=1 时整段跳过 —— 上面的约定不允许「确认坏了还接着用」。
if [[ "$HEAL_DOWN" != "1" ]] && check_port_listening "$HTTP_PORT" && check_saved_xray_alive; then
  if ! check_node_stable; then
    vlog "代理本地端口在监听但上游不通，重启 xray"
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
    sleep 1
  else
    enable_system_proxy
    vlog "代理已在运行（端口与 xray 进程均正常）"
    vlog "http://127.0.0.1:${HTTP_PORT}"
    vlog "socks5://127.0.0.1:${SOCKS_PORT}"
    vlog "pid=$(cat "$PID_FILE")"
    if [[ -f "$SELECTED_FILE" ]]; then
      vlog "$(current_node_summary)"
    fi
    exit 0
  fi
fi

if check_port_listening "$HTTP_PORT"; then
  vlog "端口 $HTTP_PORT 被占用，但保存的 xray 不存活；拒绝接管" >&2
  exit 2
fi
rm -f "$PID_FILE"

# ── 候选节点来源 ───────────────────────────────────────────────────
# 候选 = link.txt 里「非香港」且「可解析」的行。identity 用 link.txt 行号，
# 与 health.log 第 3 列、node_stats.py 的排名、--line 参数完全一致。
# 香港过滤由 gen_xray_config.is_hongkong_url 负责 —— 它会 base64 解码
# vmess 的 ps 字段再判断，明文匹配做不到这件事。
# 枚举逻辑统一收在 node_probe.py 里，避免同一套规则散在两个地方。
list_candidate_lines() {
  "$PYTHON_BIN" "$PROBE_SCRIPT" list --links "$LINK_FILE"
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

# 还原 selected_node.txt。参数 1 是调用前的快照内容；
# 空字符串表示「原本就不存在」，那就删掉而不是留一个空文件。
restore_selected_file() {
  if [[ -n "$1" ]]; then
    printf '%s\n' "$1" > "$SELECTED_FILE"
  else
    rm -f "$SELECTED_FILE"
  fi
}

# 起 xray 并验证。成功 0，失败 1。
# 提到 MAX_HEAL_SECONDS 就立刻放弃，把这一分钟的时间留给下一次 cron 触发。
try_node() {
  local line_no="$1"

  if heal_expired; then
    echo "已达自愈时长上限 ${MAX_HEAL_SECONDS}s，停止继续尝试" >&2
    return 1
  fi

  # gen_xray_config.py 把「写配置」和「写 selected_node.txt」做成一件事，
  # 但配置写出来不等于节点可用。失败必须还原 selected_node.txt：
  # 否则它会停在最后一个失败节点上，而下一次采样（此刻端口是关的，必然记 0）
  # 就把这个 0 记到一个根本没在服务的节点头上，白送它进冷却。
  local _sel_backup=""
  [[ -f "$SELECTED_FILE" ]] && _sel_backup="$(cat "$SELECTED_FILE" 2>/dev/null)"

  # 按 link.txt 行号寻址（与 health.log 第 3 列同一套编号）
  if ! "$PYTHON_BIN" "$GEN_SCRIPT" \
    --links "$LINK_FILE" \
    --line "$line_no" \
    --http-port "$HTTP_PORT" \
    --socks-port "$SOCKS_PORT" \
    --out "$CONF_FILE" \
    --selected "$SELECTED_FILE"; then
    restore_selected_file "$_sel_backup"
    return 1
  fi

  # 后台拉起并脱离当前会话，cron 任务结束时 xray 必须活着。
  # macOS 没有 setsid，nohup 两个平台都有。
  nohup "$XRAY_BIN" run -c "$CONF_FILE" >"$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  sleep 1

  if ! check_port_listening "$HTTP_PORT"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    restore_selected_file "$_sel_backup"
    return 1
  fi

  if check_node_stable; then
    return 0
  else
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    restore_selected_file "$_sel_backup"
    return 1
  fi
}

# 依次尝试一个排好序的行号文件，命中即返回 0。
# 刻意不用数组也不用 mapfile —— bash 3.2（macOS 自带）没有 mapfile。
# $2 是描述文本，$3 是透传给 node_stats.py rank 的额外参数（如 --ignore-cooldown）。
try_ranked_list() {
  local list_file="$1" label="$2" extra="${3:-}"
  local ranked_file n count

  ranked_file="$(mktemp)"
  # shellcheck disable=SC2086
  rank_candidates "$list_file" $extra > "$ranked_file" || true

  count="$(wc -l < "$ranked_file" | tr -d ' ')"
  vlog "${label}（${count} 个）"

  while IFS= read -r n || [[ -n "$n" ]]; do
    [[ -n "$n" ]] || continue
    [[ "$TRIED" == *" $n "* ]] && continue
    if try_node "$n"; then
      vlog "  link.txt 第 ${n} 行 → OK"
      rm -f "$ranked_file"
      return 0
    fi
    vlog "  link.txt 第 ${n} 行 → FAIL"
    TRIED="$TRIED$n "
  done < "$ranked_file"

  rm -f "$ranked_file"
  return 1
}

# 预筛 + 排序后依次尝试（函数名沿用了历史的 fast_ping_nodes）。
#   第 1 轮：TCP 可达 且 未冷却，按期望可用率降序 —— 策略 1 + 策略 2
#   第 2 轮：放开 TCP 与冷却限制兜底，避免「候选全在冷却中」时无节点可用
#
# 预筛为什么不是 ICMP ping：macOS 的 `ping -W` 是毫秒、Linux 是秒，
# Linux 的 `-t` 是 TTL 而 macOS 的 `-t` 才是总超时，同一行命令无法两边都对；
# 更要紧的是大量节点禁 ICMP —— 实测 ip.jkcnin.com 那批 IEPL 节点
# TCP 44~70ms 稳定可达却完全不回 ping，用 ping 筛会把最好的线路整批误杀。
# 现在交给 node_probe.py 用 TCP connect 探真实服务端口，纯标准库、跨平台一致。
fast_ping_nodes() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'" RETURN

  vlog "TCP 预筛候选节点..."

  "$PYTHON_BIN" "$PROBE_SCRIPT" scan --links "$LINK_FILE" --out-dir "$tmpdir"

  local cand="$tmpdir/candidates.txt"
  local reach="$tmpdir/reachable.txt"

  if [[ ! -s "$cand" ]]; then
    vlog "没有可用候选节点（link.txt 里没有非香港且可解析的行）" >&2
    return 1
  fi

  TRIED=" "
  if [[ -s "$reach" ]]; then
    try_ranked_list "$reach" "第 1 轮：TCP 可达 + 未冷却 + 历史可用率降序" && return 0
  fi
  if heal_expired; then
    vlog "已达自愈时长上限，跳过第 2 轮" >&2
    return 1
  fi
  try_ranked_list "$cand" "第 2 轮：兜底——放开 TCP 限制，冷却中的节点排到最后" "--ignore-cooldown" && return 0

  return 1
}

print_success() {
  enable_system_proxy
  vlog "代理已启动"
  vlog "http://127.0.0.1:${HTTP_PORT}"
  vlog "socks5://127.0.0.1:${SOCKS_PORT}"
  vlog "pid=$(cat "$PID_FILE")"
  vlog "$(current_node_summary)"
  # 真正启动成功才可能补第 2 条样本 —— 三条成功路径（手工指定 / 自动选 /
  # 回滚）都汇集在这里；「复用存活代理」那条不经过它，本来也只有 1 条。
  log_health_after_switch
}

if [[ -n "${2:-}" ]]; then
  # 手工指定 link.txt 行号
  vlog "手工指定 link.txt 第 $2 行"
  if try_node "$2"; then
    print_success
  else
    vlog "link.txt 第 $2 行连接失败，详见 $LOG_FILE" >&2
    exit 3
  fi
else
  # 自动选节点：TCP 预筛 → 历史可用率排序 → 冷却过滤
  if fast_ping_nodes; then
    print_success
    exit 0
  fi

  # 原先这里还有「第 3 轮：全量候选 + 忽略冷却」。它和第 2 轮的候选集合
  # 完全等价（node_probe.py list 与 scan 产出的 candidates.txt 是同一批
  # 非香港可解析行），而 TRIED 会记住已失败的节点，所以那一轮实际什么新节点
  # 都试不到 —— 已删掉，换成下面真正有价值的回滚。

  # ── 回滚：换节点全军覆没时，宁可「将就用旧节点」也不要彻底断网 ──
  # 只在 auto-heal 强制换节点、且原节点可寻址时才有意义。
  # 这里刻意给 30s 预算：一旦某轮把 heal_expired 拖到界外，try_node 会直接
  # 拒跑，回滚就白写了 —— 而回滚恰恰是最需要成功的那一次尝试。
  if [[ "$HEAL_DOWN" == "1" ]] && [[ "$PREV_NODE" =~ ^[0-9]+$ ]]; then
    vlog "换节点全部失败，回滚到原节点 ${PREV_NODE}（下一分钟再试）" >&2
    TRIED=" "
    HEAL_DEADLINE=$(( $(date +%s) + 30 ))
    if try_node "$PREV_NODE"; then
      print_success
      exit 0
    fi
  fi

  vlog "所有候选节点均失败，详见 $LOG_FILE" >&2
  exit 3
fi
