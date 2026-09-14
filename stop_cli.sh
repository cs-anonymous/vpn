#!/usr/bin/env bash
# 停止 xray 并关闭系统代理（macOS / Linux 通用）
set -uo pipefail

# ── 唯一根目录：~/vpn（与 start_cli.sh 同一套规则）──────────────────
VPN_HOME="${VPN_HOME:-$HOME/vpn}"
LOGS_DIR="$VPN_HOME/logs"
PID_FILE="$VPN_HOME/xray.pid"

# 停止动作也记进 logs/vpn.log，与 start_cli.sh 共用同一份操作流水
say() {
  printf '%s\n' "$*"
  mkdir -p "$LOGS_DIR" 2>/dev/null || true
  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGS_DIR/vpn.log"; } 2>/dev/null || true
}

stopped=0

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null; then
    say "xray (pid $pid) 已停止"
    stopped=1
  fi
  rm -f "$PID_FILE"
fi

# 没有 pid 文件（或进程已消失）时按命令行特征兜底。
# pkill 在 macOS / Linux 上都有；-f 匹配完整命令行。
if [[ "$stopped" == "0" ]]; then
  if pkill -f "$VPN_HOME/xray" 2>/dev/null || pkill -f "xray run -c" 2>/dev/null; then
    say "xray 已停止（按命令行特征匹配）"
  else
    say "xray 未在运行"
  fi
fi

# 系统代理的关闭逻辑统一放在 start_cli.sh 里，
# 避免 macOS(networksetup) 与 Linux(gsettings/proxy.env) 两套实现各写一份。
bash "$VPN_HOME/start_cli.sh" proxy-off
