#!/bin/sh
# ============================================================================
# vpn-cron.sh —— VPN 保活 / 断线自动重连的 cron 包装器（macOS + Linux 通用）
#
# crontab 里只需要一行（用 install-cron.sh 装，它会算好绝对路径）：
#     * * * * * /bin/sh "/绝对路径/vpn-cron.sh"
#
# 为什么要有这一层，而不是直接把 start_cli.sh 塞进 crontab
# ---------------------------------------------------------------------------
# cron 的运行环境和你的交互 shell 完全是两回事，实测踩到的差异：
#   1. PATH 只有 /usr/bin:/bin —— python3、homebrew 的 bash 都找不到。
#      连锁反应：macOS 的 `#!/usr/bin/env bash` 会落到 /bin/bash 3.2，
#      而 3.2 没有 mapfile，选节点逻辑会当场崩掉。
#   2. 不读 .zshrc / .bash_profile，rc 里设的任何变量都不存在。
#   3. locale 可能是 C/POSIX，Python 往管道写中文会 UnicodeEncodeError。
#   4. 定时任务可能重叠触发（上一轮还在换节点，下一轮又来了）。
#   5. stdout 只要有输出，cron 就尝试给你发邮件。
# 这一层把这些差异一次性抹平，好让 start_cli.sh 在两个平台上行为一致。
#
# 刻意避开的命令（macOS 上实测**都不存在**，Linux 上才有）：
#   flock / setsid / timeout / realpath -f / readlink -f
# 所以下面用的是 POSIX 等价写法：mkdir 原子锁、nohup、逐级解符号链接。
# ============================================================================

set -u

# ── 0. 自身路径 ─────────────────────────────────────────────────────
# 逐级解符号链接，不用 readlink -f（老 macOS 不支持它）
resolve_self() {
  _t="$1"
  case "$_t" in
    /*) ;;
    *) _t="$(pwd)/$_t" ;;
  esac
  while [ -L "$_t" ]; do
    _d="$(dirname "$_t")"
    _l="$(readlink "$_t" 2>/dev/null)" || break
    case "$_l" in
      /*) _t="$_l" ;;
      *)  _t="$_d/$_l" ;;
    esac
  done
  printf '%s' "$_t"
}

SCRIPT_PATH="$(resolve_self "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"

# ── 1. 环境基线 ─────────────────────────────────────────────────────
# HOME 在 cron 下是有的，但被包在容器/CI 里时可能没有，兜一下
if [ -z "${HOME:-}" ]; then
  HOME="$(cd ~ 2>/dev/null && pwd)" || HOME=/tmp
fi
export HOME

# ── 唯一根目录：~/vpn（与 start_cli.sh 同一套规则）──────────────────
# 日志统一收在 $VPN_HOME/logs/，根目录只放程序与配置。
# 必须放在 HOME 兜底之后，否则 HOME 为空时路径会退化成 /vpn。
VPN_HOME="${VPN_HOME:-$HOME/vpn}"
LOGS_DIR="$VPN_HOME/logs"
mkdir -p "$LOGS_DIR" 2>/dev/null || true
TARGET_SCRIPT="$VPN_HOME/start_cli.sh"
INSTALL_SCRIPT="$VPN_HOME/install-cron.sh"

# 显式重建 PATH：把两个平台的常见安装位置都放进去。
# 顺序上 homebrew 在前，这样 `bash`/`python3` 优先拿到 5.x / 3.1x 而不是系统旧版。
PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$PATH:$HOME/.local/bin:$HOME/bin"
export PATH

# 中文输出 + 不往仓库里写 __pycache__
export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

CRON_LOG="$LOGS_DIR/cron.log"
CRON_LOG_MAX_BYTES="${CRON_LOG_MAX_BYTES:-524288}"   # 单份日志 512KB 后轮换
HEALTH_KEEP_LINES="${HEALTH_KEEP_LINES:-20000}"      # health.log 最多保留约 13 天
CRON_BEGIN="# >>> vpn-cron >>>"
CRON_END="# <<< vpn-cron <<<"

# ── 2. 解释器定位 ───────────────────────────────────────────────────
# 优先用能被真正执行起来的那一个，而不是「文件存在」的那一个。
try_python() {
  _c="$1"
  [ -n "$_c" ] || return 1
  case "$_c" in
    */*) [ -x "$_c" ] || return 1 ;;
    *)   _c="$(command -v "$_c" 2>/dev/null)" || return 1
         [ -n "$_c" ] || return 1 ;;
  esac
  # node_stats.py 用了 dict[str, ...] 注解，实际需要 3.9+
  "$_c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null || return 1
  printf '%s' "$_c"
}

pick_python() {
  for _c in "${VPN_PYTHON:-}" \
            /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 \
            "$HOME/.workbuddy/binaries/python/versions"/*/bin/python3 \
            "$HOME/miniconda3/bin/python3" "$HOME/anaconda3/bin/python3" \
            /opt/homebrew/opt/python@3*/bin/python3 \
            python3 python; do
    _r="$(try_python "$_c" 2>/dev/null)" && { printf '%s' "$_r"; return 0; }
  done
  return 1
}

try_bash() {
  _c="$1"
  [ -n "$_c" ] || return 1
  case "$_c" in
    */*) [ -x "$_c" ] || return 1 ;;
    *)   _c="$(command -v "$_c" 2>/dev/null)" || return 1
         [ -n "$_c" ] || return 1 ;;
  esac
  "$_c" -c 'exit 0' 2>/dev/null || return 1
  printf '%s' "$_c"
}

pick_bash() {
  # start_cli.sh 已做 bash 3.2 兼容，所以 /bin/bash 兜底也能跑；
  # 但 5.x 的报错信息更清楚，能拿到就用。
  for _c in "${VPN_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash bash /bin/bash; do
    _r="$(try_bash "$_c" 2>/dev/null)" && { printf '%s' "$_r"; return 0; }
  done
  return 1
}

PY_BIN="$(pick_python)" || PY_BIN=""
BASH_BIN="$(pick_bash)" || BASH_BIN=""

# ── 3. 日志 ─────────────────────────────────────────────────────────
log_line() {
  printf '%s\n' "$1" >> "$CRON_LOG"
}

rotate_log() {
  [ -f "$CRON_LOG" ] || return 0
  _size="$(wc -c < "$CRON_LOG" 2>/dev/null | tr -d ' ')"
  [ -n "$_size" ] || return 0
  [ "$_size" -le "$CRON_LOG_MAX_BYTES" ] && return 0
  mv -f "$CRON_LOG" "$CRON_LOG.1" 2>/dev/null || : > "$CRON_LOG"
}

# health.log 只保留最近 N 行：排序窗口是 24h，留 13 天余量足够，
# 同时把文件稳定压在几百 KB，不会随年增长。
prune_health() {
  _f="$LOGS_DIR/health.log"
  [ -f "$_f" ] || return 0
  _n="$(wc -l < "$_f" 2>/dev/null | tr -d ' ')"
  [ -n "$_n" ] || return 0
  [ "$_n" -le "$HEALTH_KEEP_LINES" ] && return 0
  if tail -n "$HEALTH_KEEP_LINES" "$_f" > "$_f.tmp" 2>/dev/null; then
    mv -f "$_f.tmp" "$_f"
    log_line "$(date '+%Y-%m-%d %H:%M:%S')  health.log 超过 $HEALTH_KEEP_LINES 行，已修剪"
  else
    rm -f "$_f.tmp"
  fi
}

# ── 4. 主流程 ───────────────────────────────────────────────────────
run_heal() {
  if [ -z "$BASH_BIN" ]; then
    log_line "$(date '+%Y-%m-%d %H:%M:%S')  ✗ 找不到可用的 bash，无法执行"
    return 1
  fi
  if [ ! -f "$TARGET_SCRIPT" ]; then
    log_line "$(date '+%Y-%m-%d %H:%M:%S')  ✗ 找不到 $TARGET_SCRIPT"
    return 1
  fi
  if [ -z "$PY_BIN" ]; then
    log_line "$(date '+%Y-%m-%d %H:%M:%S')  ✗ 找不到 Python 3.9+，请设 VPN_PYTHON 或把 python3 放进 PATH"
    return 1
  fi

  _start="$(date '+%s')"
  _out="$(
    cd "$VPN_HOME" || exit 1
    # PYTHON_BIN 显式传给 start_cli.sh：它内部所有子进程都用这个绝对路径
    PYTHON_BIN="$PY_BIN" \
    NODE_STABLE_ROUNDS="${NODE_STABLE_ROUNDS:-2}" \
    MAX_HEAL_SECONDS="${MAX_HEAL_SECONDS:-180}" \
    "$BASH_BIN" "$TARGET_SCRIPT" auto-heal 2>&1
  )"
  _rc=$?
  _elapsed=$(( $(date '+%s') - _start ))

  _lines="$(printf '%s\n' "$_out" | wc -l | tr -d ' ')"

  # 正常 UP 时 auto-heal 只吐一行，不展开（否则 cron.log 每天被 1440 行
  # "UP" 灌满，真出事时反而翻不到重点）；异常/重连则把完整输出附上。
  if [ "$_rc" -eq 0 ] && [ "$_lines" -le 1 ]; then
    log_line "$(date '+%Y-%m-%d %H:%M:%S')  run: UP  (${_elapsed}s)"
  elif [ "$_rc" -eq 2 ]; then
    # start_cli.sh 的单实例锁或端口占用 —— 上一轮还在跑，属预期
    log_line "$(date '+%Y-%m-%d %H:%M:%S')  run: 跳过，已有实例在运行  (${_elapsed}s)"
  elif [ "$_rc" -eq 0 ]; then
    # 断线后换节点成功：值得留完整记录，但不要标成「需要处理」
    {
      log_line "$(date '+%Y-%m-%d %H:%M:%S')  run: 已自动恢复  (${_elapsed}s)"
      printf '%s\n' "$_out" | sed 's/^/    /' >> "$CRON_LOG"
    }
  else
    {
      log_line "$(date '+%Y-%m-%d %H:%M:%S')  run: 未能恢复 rc=$_rc  (${_elapsed}s)"
      printf '%s\n' "$_out" | sed 's/^/    /' >> "$CRON_LOG"
    }
  fi

  return "$_rc"
}

# ── 5. 自检 ─────────────────────────────────────────────────────────
doctor() {
  _lines_of() { [ -f "$1" ] && wc -l < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

  echo "=== cron 包装器 ==="
  echo "  脚本        $SCRIPT_PATH"
  echo "  系统根目录  $VPN_HOME"
  if [ "$SCRIPT_DIR" != "$VPN_HOME" ]; then
    echo "  脚本位置    ! 脚本在 ${SCRIPT_DIR}，与根目录不一致"
    echo "              本工具只认 $VPN_HOME 这一个路径"
  fi
  echo "  日志目录    $LOGS_DIR"
  echo "  系统        $(uname -s) $(uname -m)"
  echo "  PATH        $PATH"
  echo "  bash        ${BASH_BIN:-✗ 未找到}"
  [ -n "$BASH_BIN" ] && echo "  bash 版本   $("$BASH_BIN" --version 2>/dev/null | head -1)"
  echo "  python      ${PY_BIN:-✗ 未找到}"
  [ -n "$PY_BIN" ] && echo "  python 版本 $("$PY_BIN" -V 2>&1)"
  echo "  cron.log    $( _lines_of "$CRON_LOG" ) 行  ($CRON_LOG)"
  echo "  health.log  $( _lines_of "$LOGS_DIR/health.log" ) 行"
  echo "  vpn.log     $( _lines_of "$LOGS_DIR/vpn.log" ) 行"
  echo "  xray.log    $( _lines_of "$LOGS_DIR/xray.log" ) 行"

  echo
  echo "=== crontab 托管段 ==="
  if crontab -l 2>/dev/null | grep -q "vpn-cron"; then
    crontab -l 2>/dev/null | sed -n "/$(echo "$CRON_BEGIN" | sed 's/[][\\.*^$]/\\&/g')/,/$(echo "$CRON_END" | sed 's/[][\\.*^$]/\\&/g')/p" | sed 's/^/  /'
  else
    echo "  ✗ 未安装。执行：sh \"$INSTALL_SCRIPT\""
  fi

  echo
  echo "=== cron 服务 ==="
  case "$(uname -s)" in
    Darwin)
      # 注意：launchctl list 只看用户域，看不到系统守护进程，
      # 必须用 `launchctl print system/...`，否则会误报「没在运行」。
      if launchctl print system/com.vix.cron >/dev/null 2>&1 || pgrep -x cron >/dev/null 2>&1; then
        echo "  ✓ cron 守护进程在运行（/usr/sbin/cron）"
      else
        echo "  ✗ 未检测到 cron。启用：sudo launchctl enable system/com.vix.cron"
      fi
      echo "  提示：只有当脚本位于桌面/文稿/下载等受保护目录时，才需要给"
      echo "        /usr/sbin/cron 授予「完全磁盘访问权限」。本目录不在其中。"
      ;;
    Linux)
      if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
        echo "  ✓ cron 守护进程在运行"
      else
        echo "  ✗ 没检测到 cron/crond。启动：sudo systemctl enable --now cron"
      fi
      ;;
  esac

  echo
  echo "=== 交给 start_cli.sh 自检 ==="
  if [ -n "$BASH_BIN" ]; then
    PYTHON_BIN="$PY_BIN" "$BASH_BIN" "$TARGET_SCRIPT" doctor
  fi
  return 0
}

usage() {
  cat <<EOF
用法:
  vpn-cron.sh              采样 + 断线自动重连（cron 每分钟调用，无需参数）
  vpn-cron.sh doctor       环境自检（PATH / bash / python / crontab / 运行状态）
  vpn-cron.sh -h           本帮助

安装到 crontab:
  sh "$INSTALL_SCRIPT"            # 每分钟一次
  sh "$INSTALL_SCRIPT" --remove   # 卸载

可用环境变量（cron 不继承 shell 环境，需要就写进 crontab 的环境行）:
  VPN_PYTHON=/abs/path/python3     指定解释器（默认自动查找 3.9+）
  VPN_BASH=/abs/path/bash          指定 bash
  NODE_STABLE_ROUNDS=2             录用节点前连测几轮
  MAX_HEAL_SECONDS=180             单次自愈时长上限
  VPN_HOME=$HOME/vpn               固定根目录（日志在其下的 logs/）
  CRON_LOG_MAX_BYTES=524288        cron.log 轮换阈值
  HEALTH_KEEP_LINES=20000          health.log 保留行数上限
EOF
}

case "${1:-}" in
  ""|heal)
    rotate_log
    prune_health
    run_heal
    exit $?
    ;;
  doctor)
    doctor
    exit $?
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "未知参数：$1" >&2
    usage >&2
    exit 2
    ;;
esac
