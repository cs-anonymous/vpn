#!/usr/bin/env python3
"""节点健康统计与候选排序 —— 供 start_cli.sh 选节点时调用。

数据源 health.log，每行格式：

    <ISO8601 时间戳> <1|0> <link.txt 行号>

第 3 列永远是 **link.txt 的原始行号**，与 ``gen_xray_config.py --line``
使用同一套编号。日志、选节点、命令行参数三者编号一致，不会错位。

子命令
------
rank     按期望可用率降序列出候选节点（供 start_cli.sh 消费）
report   人类可读的健康报告（含冷却状态）

期望可用率的算法（贝叶斯平滑）
------------------------------
    ratio = (窗口内 UP 数 + prior * k) / (窗口内样本数 + k)

* ``--window`` 决定统计窗口（默认 24h），反映节点**最近**的质量 ——
  一个昨天 95%、今天 20% 的节点不会被历史高分掩盖。
* 窗口内样本不足 k 条时回退到全历史样本再做平滑。
* ``k`` = ``--min-samples``（默认 3）；``prior`` = ``--default-ratio``
  （默认 0.85）。于是：
    - 从没采样过的新节点      → 0.850（不会被排到最后，也压不过优质节点）
    - 只采样 1 次且失败       → (0 + 0.85*3) / (1 + 3) = 0.638（不判死刑）
    - 只采样 1 次且成功       → (1 + 0.85*3) / (1 + 3) = 0.888
    - 24h 内 100/100 全成功   → 1.000

冷却（策略 2）
--------------
节点「最近一次失败」距今不足 ``--cooldown``（默认 3600s）即视为冷却中，
``rank`` 默认直接剔除它，冷却期满才重新进入候选。

用法
----
    node_stats.py rank --log health.log --lines reachable.txt --format lines
    node_stats.py rank --lines reachable.txt --ignore-cooldown --format lines
    node_stats.py report --log health.log
"""

from __future__ import annotations

import argparse
import datetime
import os
import pathlib
import sys

# ── 唯一根目录：~/vpn（与 start_cli.sh 同一套规则）─────────────────────
# 日志统一在 $VPN_HOME/logs/ 下；VPN_HOME 可用环境变量覆盖。
VPN_HOME = pathlib.Path(os.environ.get("VPN_HOME") or (pathlib.Path.home() / "vpn"))
DEFAULT_HEALTH_LOG = VPN_HOME / "logs" / "health.log"

DEFAULT_WINDOW_SECONDS = 24 * 3600
DEFAULT_COOLDOWN_SECONDS = 3600  # 1 小时
DEFAULT_MIN_SAMPLES = 3
DEFAULT_RATIO = 0.85
TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S%z"


def read_health_log(path) -> list[tuple[datetime.datetime, int, int]]:
    """读取 health.log，返回按时间升序的 ``(时间戳, 0|1, link.txt 行号)``。

    自动忽略：无节点号的旧格式样本、时间戳损坏的行、节点号非数字的行。
    """
    p = pathlib.Path(path)
    if not p.exists():
        return []

    rows: list[tuple[datetime.datetime, int, int]] = []
    for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = raw.split()
        if len(parts) < 3 or parts[1] not in ("0", "1"):
            continue
        ts_str, val, node = parts[0], parts[1], parts[2]
        if not node.isdigit():
            continue
        try:
            ts = datetime.datetime.strptime(ts_str, TIMESTAMP_FORMAT)
        except ValueError:
            continue
        rows.append((ts, int(val), int(node)))

    rows.sort(key=lambda r: r[0])
    return rows


def build_stats(rows, now, window_seconds):
    """聚合出每个节点的统计字典，键为 link.txt 行号。"""
    cut = now - datetime.timedelta(seconds=window_seconds)
    stats: dict[int, dict] = {}

    for ts, ok, line in rows:
        s = stats.get(line)
        if s is None:
            s = stats[line] = {
                "total": 0,
                "up": 0,
                "window_total": 0,
                "window_up": 0,
                "first_seen": ts,
                "last_seen": ts,
                "last_ok": None,
                "last_fail": None,
            }
        s["total"] += 1
        s["up"] += ok
        s["last_seen"] = ts
        if ok:
            s["last_ok"] = ts
        else:
            s["last_fail"] = ts  # rows 已按时间升序 → 最后一次赋值即最近失败
        if ts >= cut:
            s["window_total"] += 1
            s["window_up"] += ok

    return stats


def expected_ratio(stat, prior: float = DEFAULT_RATIO, k: int = DEFAULT_MIN_SAMPLES):
    """返回 ``(期望可用率, 用于统计的样本数)``。stat 为 None 表示从未采样。"""
    if stat is None:
        return prior, 0
    if stat["window_total"] >= k:
        return stat["window_up"] / stat["window_total"], stat["window_total"]
    total, up = stat["total"], stat["up"]
    return (up + prior * k) / (total + k), total


def cooldown_remaining(stat, now, cooldown_seconds: int) -> float:
    """距冷却解除还有多少秒；0 表示不在冷却中。"""
    if not stat or stat["last_fail"] is None:
        return 0.0
    elapsed = (now - stat["last_fail"]).total_seconds()
    return max(0.0, cooldown_seconds - elapsed)


def load_candidate_lines(path) -> list[int]:
    """候选行号文件：每行或用空白分隔的若干个 link.txt 行号。"""
    text = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    return [int(tok) for tok in text.split() if tok.isdigit()]


def _fmt_ago(delta_seconds: float) -> str:
    if delta_seconds < 0:
        return "-"
    if delta_seconds < 60:
        return f"{int(delta_seconds)}s"
    if delta_seconds < 3600:
        return f"{int(delta_seconds // 60)}m"
    if delta_seconds < 86400:
        return f"{delta_seconds / 3600:.1f}h"
    return f"{delta_seconds / 86400:.1f}d"


def cmd_rank(args) -> int:
    now = datetime.datetime.now().astimezone()
    rows = read_health_log(args.log)
    stats = build_stats(rows, now, args.window)

    if args.lines:
        candidates = load_candidate_lines(args.lines)
    else:
        candidates = sorted(stats)

    ranked = []
    for line in candidates:
        stat = stats.get(line)
        ratio, samples = expected_ratio(stat, args.default_ratio, args.min_samples)
        remaining = cooldown_remaining(stat, now, args.cooldown)
        if remaining > 0 and not args.ignore_cooldown:
            continue
        ranked.append((line, ratio, samples, remaining))

    # 期望可用率降序 → 冷却剩余少的优先 → 行号稳定排序
    ranked.sort(key=lambda r: (-r[1], r[3], r[0]))

    for line, ratio, samples, _remaining in ranked:
        if args.format == "lines":
            print(line)
        else:
            print(f"{line}\t{ratio:.3f}\t{samples}")

    return 0


def cmd_report(args) -> int:
    now = datetime.datetime.now().astimezone()
    rows = read_health_log(args.log)
    if not rows:
        print(f"health.log 没有可用样本：{args.log}")
        return 0

    stats = build_stats(rows, now, args.window)

    print(f"日志  {args.log}   ({len(rows)} 条带节点号的样本)")
    print(f"当前  {now:%Y-%m-%d %H:%M:%S}")
    print(f"参数  窗口={args.window / 3600:.1f}h  冷却={args.cooldown / 60:.0f}min  "
          f"样本下限={args.min_samples}  新节点先验={args.default_ratio:.2f}")
    print()

    ranked = []
    for line, stat in stats.items():
        ratio, samples = expected_ratio(stat, args.default_ratio, args.min_samples)
        remaining = cooldown_remaining(stat, now, args.cooldown)
        ranked.append((line, ratio, samples, remaining, stat))
    ranked.sort(key=lambda r: (-r[1], r[3], r[0]))

    header = (f"{'行号':>5}  {'期望可用率':>10}  {'窗口样本':>8}  "
              f"{'全历史':>8}  {'最近失败':>8}  状态")
    print(header)
    print("-" * len(header))

    for line, ratio, samples, remaining, stat in ranked:
        lifetime = (f"{100 * stat['up'] / stat['total']:.0f}%"
                    if stat["total"] else "-")
        fail_ago = (_fmt_ago((now - stat["last_fail"]).total_seconds())
                    if stat["last_fail"] else "-")
        if remaining > 0:
            state = f"冷却中 {_fmt_ago(remaining)} 后重试"
        elif stat["total"] == 0:
            state = "未探测"
        else:
            state = "可用"
        bar = "#" * round(ratio * 16)
        print(f"{line:>5}  {ratio * 100:9.1f}%  {samples:>8}  {lifetime:>8}  "
              f"{fail_ago:>8}  {state:<22} {bar}")

    cool = sum(1 for *_, remaining, _ in ranked if remaining > 0)
    print()
    print(f"合计 {len(ranked)} 个节点，其中 {cool} 个处于冷却中")

    seen = {r[2] for r in rows}
    if args.total_lines:
        missing = args.total_lines - len(seen)
        if missing > 0:
            print(f"另有 {missing} 个 link.txt 行号从未被采样（新节点将按 "
                  f"{args.default_ratio:.2f} 的先验参与排序）")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_common(sp):
        sp.add_argument("--log", default=str(DEFAULT_HEALTH_LOG),
                        help="health.log 路径")
        sp.add_argument("--window", type=int, default=DEFAULT_WINDOW_SECONDS,
                        help=f"统计窗口秒数（默认 {DEFAULT_WINDOW_SECONDS}）")
        sp.add_argument("--cooldown", type=int, default=DEFAULT_COOLDOWN_SECONDS,
                        help=f"失败后冷却秒数（默认 {DEFAULT_COOLDOWN_SECONDS}）")
        sp.add_argument("--min-samples", type=int, default=DEFAULT_MIN_SAMPLES,
                        help=f"平滑常数 k（默认 {DEFAULT_MIN_SAMPLES}）")
        sp.add_argument("--default-ratio", type=float, default=DEFAULT_RATIO,
                        help=f"新节点先验可用率（默认 {DEFAULT_RATIO}）")

    r = sub.add_parser("rank", help="按期望可用率降序输出候选节点")
    add_common(r)
    r.add_argument("--lines", help="候选行号文件（默认用 health.log 里出现过的全部节点）")
    r.add_argument("--ignore-cooldown", action="store_true",
                   help="忽略冷却（全部节点都被冷却时的兜底轮）")
    r.add_argument("--format", choices=("table", "lines"), default="table",
                   help="lines = 每行只打印行号，供 shell 直接消费")
    r.set_defaults(func=cmd_rank)

    rep = sub.add_parser("report", help="人类可读的节点健康报告")
    add_common(rep)
    rep.add_argument("--total-lines", type=int, default=0,
                     help="link.txt 总行数，用于提示从未采样的节点数")
    rep.set_defaults(func=cmd_report)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
