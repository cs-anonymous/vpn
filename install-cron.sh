#!/bin/sh
# ============================================================================
# install-cron.sh —— 把 vpn-cron.sh 装进 crontab（macOS + Linux 通用、幂等）
#
#   sh install-cron.sh               安装，每分钟触发一次
#   sh install-cron.sh --interval 5  每 5 分钟触发一次
#   sh install-cron.sh --show        查看当前托管段
#   sh install-cron.sh --remove      卸载
#   sh install-cron.sh --dry-run     只打印将要写入的 crontab，不落盘
#
# 幂等靠「带标记的托管段」实现：每次安装先删掉旧的托管段再重新追加，
# 所以重复执行不会堆出多份任务。原 crontab 会备份到：
#     <项目目录>/crontab.backup.<时间戳>
#
# 为什么 crontab 行写成 `/bin/sh "/abs/path/vpn-cron.sh"` 而不是直接执行脚本：
#   1. /bin/sh 在两个平台上都必然存在，不依赖脚本的 shebang；
#   2. 顺带绕开「脚本没有可执行位」的情况 —— 仓库经过网盘同步、
#      从 Windows 拷过来、或者落在 noexec 挂载点上，都会丢可执行位。
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WRAPPER="$SCRIPT_DIR/vpn-cron.sh"
CRON_BEGIN="# >>> vpn-cron >>>"
CRON_END="# <<< vpn-cron <<<"

INTERVAL=1
MODE="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --interval=*) INTERVAL="${1#*=}"; shift ;;
    --remove|--uninstall) MODE="remove"; shift ;;
    --show|--list) MODE="show"; shift ;;
    --dry-run) MODE="dry"; shift ;;
    -h|--help) MODE="help"; shift ;;
    *) echo "未知参数：$1" >&2; MODE="help"; shift ;;
  esac
done

usage() {
  cat <<EOF
用法:
  sh install-cron.sh                安装（每分钟）
  sh install-cron.sh --interval 5   每 5 分钟
  sh install-cron.sh --show         查看托管段
  sh install-cron.sh --remove       卸载
  sh install-cron.sh --dry-run      只打印结果，不写入
EOF
}

# 幂等清理：删掉旧托管段，并顺手删掉任何其他引用 vpn-cron.sh 的行
strip_managed() {
  _in="$1"
  _out="$2"
  awk -v b="$CRON_BEGIN" -v e="$CRON_END" '
    $0 == b            { skip = 1 }
    skip == 1 && $0 == e { skip = 0; next }
    skip == 1          { next }
    index($0, "vpn-cron.sh") > 0 { next }
    { print }
  ' "$_in" > "$_out"
}

cron_line_for() {
  _iv="$1"
  if [ "$_iv" = "1" ]; then
    printf '* * * * * /bin/sh "%s"' "$WRAPPER"
  else
    printf '*/%s * * * * /bin/sh "%s"' "$_iv" "$WRAPPER"
  fi
}

show_cron() {
  echo "--- 当前 crontab ---"
  crontab -l 2>/dev/null || echo "(空)"
  echo
  if crontab -l 2>/dev/null | grep -q "vpn-cron"; then
    echo "✓ 已安装 vpn-cron 托管段"
  else
    echo "✗ 未安装 vpn-cron 托管段"
  fi
}

case "$MODE" in
  help) usage; exit 0 ;;
  show) show_cron; exit 0 ;;
esac

# ── 前置检查 ────────────────────────────────────────────────────────
if [ ! -f "$WRAPPER" ]; then
  echo "✗ 找不到 $WRAPPER" >&2
  exit 1
fi
case "$WRAPPER" in
  *[\"\'\`\$\\]*)
    echo "✗ 路径含特殊字符，crontab 里会出问题：$WRAPPER" >&2
    exit 1 ;;
esac

if [ "$MODE" != "remove" ]; then
  case "$INTERVAL" in
    ''|*[!0-9]*) echo "✗ --interval 必须是正整数，收到：$INTERVAL" >&2; exit 1 ;;
  esac
  if [ "$INTERVAL" -lt 1 ] || [ "$INTERVAL" -gt 30 ]; then
    echo "✗ --interval 取值 1~30，收到：$INTERVAL" >&2
    exit 1
  fi
  # 60 不能整除时会漂移（如 7 分钟），提醒一下但不阻止
  if [ $((60 % INTERVAL)) -ne 0 ]; then
    echo "! $INTERVAL 不能整除 60，触发间隔在每个小时内会不均匀" >&2
  fi
fi

# ── 读写 crontab ────────────────────────────────────────────────────
TMP_IN="$(mktemp)"
TMP_OUT="$(mktemp)"
TMP_NEW="$(mktemp)"
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_IN" "$TMP_OUT" "$TMP_NEW" "$TMP_ERR" "$TMP_NEW.clean"' EXIT

crontab -l > "$TMP_IN" 2>/dev/null || : > "$TMP_IN"
strip_managed "$TMP_IN" "$TMP_OUT"

if [ "$MODE" = "remove" ]; then
  cp "$TMP_OUT" "$TMP_NEW"
else
  {
    cat "$TMP_OUT"
    printf '%s\n' "$CRON_BEGIN"
    printf '%s\n' 'MAILTO=""'
    cron_line_for "$INTERVAL"
    printf '\n%s\n' "$CRON_END"
  } > "$TMP_NEW"
fi

# 去掉文件开头的空行（crontab 不太喜欢，且看着脏）
sed -e '/./,$!d' "$TMP_NEW" > "$TMP_NEW.clean" && mv -f "$TMP_NEW.clean" "$TMP_NEW"

if [ "$MODE" = "dry" ]; then
  echo "--- 将要写入的 crontab ---"
  cat "$TMP_NEW"
  echo "--------------------------"
  echo "(dry-run，未写入)"
  exit 0
fi

# 备份原 crontab（仅当非空）
if [ -s "$TMP_IN" ]; then
  BACKUP="$SCRIPT_DIR/crontab.backup.$(date '+%Y%m%d%H%M%S')"
  cp "$TMP_IN" "$BACKUP"
  echo "原 crontab 已备份：$BACKUP"
fi

if ! crontab "$TMP_NEW" 2>"$TMP_ERR"; then
  echo "✗ 写入 crontab 失败：" >&2
  cat "$TMP_ERR" >&2
  if [ -s "$TMP_IN" ]; then
    echo "尝试回滚..." >&2
    crontab "$TMP_IN" 2>/dev/null && echo "已回滚到原 crontab" >&2
  fi
  exit 1
fi

# ── 校验 ────────────────────────────────────────────────────────────
if [ "$MODE" = "remove" ]; then
  if crontab -l 2>/dev/null | grep -q "vpn-cron"; then
    echo "✗ 卸载不彻底，请手动检查：crontab -e" >&2
    exit 1
  fi
  echo "✓ 已从 crontab 移除 vpn-cron"
  exit 0
fi

COUNT="$(crontab -l 2>/dev/null | grep -c "vpn-cron.sh" | tr -d ' ')"
echo
echo "✓ 已安装"
crontab -l 2>/dev/null | grep -A2 -B1 "vpn-cron" | sed 's/^/    /'
echo
echo "  触发间隔  $( [ "$INTERVAL" = "1" ] && echo "每分钟" || echo "每 $INTERVAL 分钟" )"
echo "  包装器    $WRAPPER"
echo "  任务条数  ${COUNT}（应为 1）"

case "$(uname -s)" in
  Darwin)
    echo
    if launchctl print system/com.vix.cron >/dev/null 2>&1 || pgrep -x cron >/dev/null 2>&1; then
      echo "  ✓ cron 守护进程在运行（/usr/sbin/cron）"
    else
      echo "  ✗ 未检测到 cron。启用：sudo launchctl enable system/com.vix.cron"
    fi
    echo "  macOS 提示："
    echo "    · cron 默认已启用；增删自己的 crontab 不需要 sudo。"
    echo "    · 只有当本目录位于桌面/文稿/下载等受保护位置时，才需要给"
    echo "      /usr/sbin/cron 授予「完全磁盘访问权限」。"
    case "$SCRIPT_DIR" in
      "$HOME"/Desktop/*|"$HOME"/Documents/*|"$HOME"/Downloads/*)
        echo "    · ⚠ 本目录正好在受保护位置：$SCRIPT_DIR"
        echo "      打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」，"
        echo "      添加 /usr/sbin/cron 并勾选，否则任务会静默失败。" ;;
      *) echo "    · 本目录不在受保护位置，无需额外授权。" ;;
    esac
    ;;
  Linux)
    echo
    if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
      echo "  ✓ cron 守护进程在运行"
    else
      echo "  ✗ 未检测到 cron/crond，请先启动：sudo systemctl enable --now cron"
    fi
    ;;
esac

echo
echo "  下一步："
echo "    sh \"$WRAPPER\" doctor      # 自检"
echo "    tail -f \"$SCRIPT_DIR/cron.log\"   # 观察运行情况"
