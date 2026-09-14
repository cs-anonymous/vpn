#!/usr/bin/env bash
# 停止 xray 并关闭系统代理（macOS / Linux 通用）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/xray.pid"

stopped=0

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null; then
    echo "xray (pid $pid) stopped"
    stopped=1
  fi
  rm -f "$PID_FILE"
fi

# 没有 pid 文件（或进程已消失）时按命令行特征兜底。
# pkill 在 macOS / Linux 上都有；-f 匹配完整命令行。
if [[ "$stopped" == "0" ]]; then
  if pkill -f "$SCRIPT_DIR/xray" 2>/dev/null || pkill -f "xray run -c" 2>/dev/null; then
    echo "xray stopped (matched by command line)"
  else
    echo "xray not running"
  fi
fi

# 系统代理的关闭逻辑统一放在 start_cli.sh 里，
# 避免 macOS(networksetup) 与 Linux(gsettings/proxy.env) 两套实现各写一份。
bash "$SCRIPT_DIR/start_cli.sh" proxy-off
