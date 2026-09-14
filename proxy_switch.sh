#!/usr/bin/env bash
# 系统代理开关（macOS / Linux 通用）
#   ./proxy_switch.sh on|off|status
#
# 真正的实现只有一份，在 start_cli.sh 的 proxy-on / proxy-off / proxy-status：
#   macOS → networksetup（网络服务名自动探测，不再硬编码 "Wi-Fi"）
#   Linux → gsettings（有桌面会话时）+ 生成 proxy.env（headless/cron 下可用）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-status}" in
  on)      exec bash "$SCRIPT_DIR/start_cli.sh" proxy-on ;;
  off)     exec bash "$SCRIPT_DIR/start_cli.sh" proxy-off ;;
  status)  exec bash "$SCRIPT_DIR/start_cli.sh" proxy-status ;;
  *)
    echo "用法: $0 {on|off|status}" >&2
    exit 1
    ;;
esac
