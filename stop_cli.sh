#!/usr/bin/env bash
# Stop xray proxy and disable system proxy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/xray.pid"

# Kill xray
if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null && echo "xray (pid $pid) stopped" || echo "xray not running"
  rm -f "$PID_FILE"
else
  pkill -f "xray run -c" 2>/dev/null && echo "xray stopped" || echo "xray not running"
fi

# Disable system proxy on macOS
if [[ "$(uname)" == "Darwin" ]]; then
  svc="Wi-Fi"
  networksetup -setwebproxystate "$svc" off 2>/dev/null
  networksetup -setsecurewebproxystate "$svc" off 2>/dev/null
  networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
  echo "System proxy disabled"
fi
