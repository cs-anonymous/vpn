#!/bin/bash
# Toggle macOS system proxy on/off for Wi-Fi
# Usage: ./proxy_switch.sh on|off|status

SERVICE="Wi-Fi"
HTTP_PORT=7890
SOCKS_PORT=7891

case "$1" in
  on)
    networksetup -setwebproxy "$SERVICE" 127.0.0.1 $HTTP_PORT
    networksetup -setsecurewebproxy "$SERVICE" 127.0.0.1 $HTTP_PORT
    networksetup -setsocksfirewallproxy "$SERVICE" 127.0.0.1 $SOCKS_PORT
    networksetup -setproxybypassdomains "$SERVICE" 127.0.0.1 localhost 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 "*.local" "169.254.0.0/16"
    echo "✅ System proxy ON (HTTP:$HTTP_PORT SOCKS:$SOCKS_PORT)"
    ;;
  off)
    networksetup -setwebproxystate "$SERVICE" off
    networksetup -setsecurewebproxystate "$SERVICE" off
    networksetup -setsocksfirewallproxystate "$SERVICE" off
    echo "❌ System proxy OFF"
    ;;
  status)
    echo "=== HTTP ===" && networksetup -getwebproxy "$SERVICE"
    echo "=== HTTPS ===" && networksetup -getsecurewebproxy "$SERVICE"
    echo "=== SOCKS ===" && networksetup -getsocksfirewallproxy "$SERVICE"
    ;;
  *)
    echo "Usage: $0 {on|off|status}"
    exit 1
    ;;
esac
