#!/usr/bin/env python3
"""节点健康统计与候选排序 —— 供 start_cli.sh 选节点时调用。

数据源 health.log，每行格式：

    <ISO8601 时间戳> <1|0> <link.txt 行号> [<失败明细>]

第 3 列永远是 **link.txt 的原始行号**，与 ``gen_xray_config.py --line``
使用同一套编号。日志、选节点、命令行参数三者编号一致，不会错位。
第 4 列是可选明细（如 ``google=000`` / ``google=204,youtube=403``），
只用于排查抖动卡在哪一段，排序逻辑不读它；旧的三列行照样解析。

子命令
------
rank     按评分降序列出候选节点（供 start_cli.sh 消费）
report   人类可读的健康报告（含当前使用标记）

评分：单一连续函数
------------------
    U      = Σ 0.5 ** (样本年龄 / H_score)      （UP 样本的加权和）
    D      = Σ 0.5 ** (样本年龄 / H_score)      （DOWN 样本的加权和）
    可用率 = (U + prior * K) / (U + D + K)
    折扣   = 1 - β * 0.5 ** (距最近一次失败 / H_fail)
    score  = 可用率 * 折扣

**整个仓库只有这一条公式，没有任何分支。** 没有统计窗口、没有样本数阈值、
没有被排除的节点名单。两个边界情况都自然退化，不需要特判：

* 从没采样过的节点 U = D = 0 → 可用率退化成 ``prior``；
* 从没失败过的节点「距最近一次失败」取 ∞ → 折扣退化成 1。

两个时间尺度各司其职
--------------------
* ``H_score``（``--score-half-life``，默认 24h）决定**成绩记多久**。
  越新的样本越重，一天前的样本仍有分量 —— 节点的历史水平要慢慢才能被改写。
  实测：8 号 638 条 99.4%（最近一条在 22.7h 前）得 0.978；
  1 号全历史 73.5% 但最近一小时连续掉线，只剩 0.532。
* ``H_fail``（``--fail-half-life``，默认 30min）决定**失败扣多久**。
  这一项就是原策略 2「1 小时内失败过就先用别人」的连续版本：
  刚失败的节点折扣最大，之后按半衰期迅速回升。

折扣 = 减掉的那部分分数：``β * 0.5 ** (Δt / H_fail) * 可用率``。
失败越久远减得越少 —— Δt=0 减一半，Δt=H_fail 减到四分之一，Δt=4·H_fail 只减 3%。
以可用率 0.95 的节点为例：

| 距最近一次失败 | 0 | 15m | 30m | 1h | 1.5h | 2h | 3h |
| --- | --- | --- | --- | --- | --- | --- | --- |
| score | .475 | .614 | .713 | .831 | .891 | .920 | .943 |

未探测节点的先验是 0.850：所以刚失败的节点会沉到它下面（≈1h 后追平、2h 后反超），
但它**不会被硬性剔除** —— 没有「冷却名单」这种东西，只有一条会自己爬回来的曲线。

为什么不再分段
--------------
早期实现是 ``if 窗口样本 >= k: 用窗口频率 else: 回退全历史再平滑``，
外加一条「最近一次失败 < 1h 直接剔除」的硬冷却。实测复现出两个后果：

1. **阈值断裂**：窗口 2 条全失败 → 0.977；窗口 3 条全失败 → 0.000，
   只多一条样本落差 0.977 —— 这不是平滑，是断崖。
2. **排序倒挂**：窗口 4 条里成功 2 条（真实 50%）→ 0.500，反而低于
   「只采样 1 次且失败」（真实 0%）的 0.637 —— 两种量纲混在同一张表里排序。

现在「按历史可用率排序」和「失败后先别用一阵子」不是两套机制、两条判定，
而是同一条公式的两个因子 —— 于是也不会再出现「一个说冷却中、另一个说还在用」
那种自相矛盾的状态。

参数怎么调
----------
    SCORE_HALF_LIFE  成绩记忆：调大 → 更看重长期表现，调小 → 更快遗忘旧成绩
    FAIL_HALF_LIFE   失败扣分的消退速度：调小 → 更快原谅
    FAIL_DISCOUNT    刚失败时打几折：0 = 完全不惩罚，1 = 直接扣光
    DEFAULT_NODE_RATIO  未探测节点的先验评分（默认 0.85，略低于健康节点）

用法
----
    node_stats.py rank --log health.log --lines reachable.txt --format lines
    node_stats.py report --log health.log --current 49
    node_stats.py rank --fail-half-life 900 --fail-discount 0.7 --format lines
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

DEFAULT_SCORE_HALF_LIFE = 24 * 3600  # 成绩证据的半衰期：24h
DEFAULT_FAIL_HALF_LIFE = 1800        # 失败折扣的半衰期：30min
DEFAULT_FAIL_DISCOUNT = 0.5          # 刚失败时分数打五折
DEFAULT_PRIOR_WEIGHT = 20.0          # 先验相当于几条样本的分量
DEFAULT_RATIO = 0.85                 # 未探测节点的先验评分
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


def decay_weight(age_seconds: float, half_life: float) -> float:
    """样本的计权：刚采的记 1，过了 ``half_life`` 记 0.5，以此类推。

    计时器回拨导致 age 为负时按「最新鲜」处理（记 1），不去惩罚时钟跳变。
    """
    if age_seconds <= 0:
        return 1.0
    return 0.5 ** (age_seconds / half_life)


def build_stats(rows, now, half_life: float = DEFAULT_SCORE_HALF_LIFE):
    """聚合出每个节点的统计字典，键为 link.txt 行号。

    这里不再切窗口，而是给每条样本按年龄加权后累加 ——「窗口」这个概念被
    衰减曲线取代了：一条刚采的 UP 和一条 24h 前的 UP，权重相差 2**28 倍。
    """
    stats: dict[int, dict] = {}

    for ts, ok, line in rows:
        s = stats.get(line)
        if s is None:
            s = stats[line] = {
                "up_weight": 0.0,
                "down_weight": 0.0,
                "up": 0,
                "down": 0,
                "total": 0,
                "first_seen": ts,
                "last_seen": ts,
                "last_ok": None,
                "last_fail": None,
            }
        w = decay_weight((now - ts).total_seconds(), half_life)
        s["total"] += 1
        s["last_seen"] = ts
        if ok:
            s["up"] += 1
            s["up_weight"] += w
            s["last_ok"] = ts
        else:
            s["down"] += 1
            s["down_weight"] += w
            s["last_fail"] = ts  # rows 已按时间升序 → 最后一次赋值即最近失败

    return stats


def fail_discount_factor(stat, now, fail_half_life: float = DEFAULT_FAIL_HALF_LIFE,
                         fail_discount: float = DEFAULT_FAIL_DISCOUNT) -> float:
    """失败折扣系数 ∈ ``[1-β, 1]``：1 = 没有近期失败；越小 = 刚失败扣得越狠。

    从没失败过的节点，「距最近一次失败」取 ∞ → ``0.5 ** inf == 0`` → 系数回到 1。
    这是公式自带的极限，所以这里不需要 ``if`` 分支。
    """
    age = float("inf")
    if stat is not None and stat["last_fail"] is not None:
        age = max(0.0, (now - stat["last_fail"]).total_seconds())
    return 1.0 - fail_discount * (0.5 ** (age / fail_half_life))


def node_score(stat, now, prior: float = DEFAULT_RATIO,
               prior_weight: float = DEFAULT_PRIOR_WEIGHT,
               fail_half_life: float = DEFAULT_FAIL_HALF_LIFE,
               fail_discount: float = DEFAULT_FAIL_DISCOUNT) -> float:
    """节点评分 —— 全仓库唯一的排序依据。

        score = 可用率 * 折扣
              = (U + prior*K) / (U + D + K) * (1 - β * 0.5 ** (Δt / H_fail))

    ``stat`` 为 None（从未采样）时 U = D = 0，可用率退化成 ``prior``；
    从未失败时折扣为 1。两处都是公式的自然极限，没有分支。
    """
    up_w = stat["up_weight"] if stat else 0.0
    down_w = stat["down_weight"] if stat else 0.0
    rate = (up_w + prior * prior_weight) / (up_w + down_w + prior_weight)
    return rate * fail_discount_factor(stat, now, fail_half_life, fail_discount)


def recent_down(stat) -> bool:
    """这个节点的**最后一条**样本是不是失败。

    用于报告里标出「它在扣分」。注意这不是排序条件，只是一个显示口径 ——
    真正影响排序的永远是 ``node_score`` 的连续数值。
    """
    if not stat or stat["last_fail"] is None:
        return False
    return stat["last_ok"] is None or stat["last_fail"] > stat["last_ok"]


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


def _score_kwargs(args) -> dict:
    return {"prior": args.default_ratio,
            "prior_weight": args.prior_weight,
            "fail_half_life": args.fail_half_life,
            "fail_discount": args.fail_discount}


def cmd_rank(args) -> int:
    now = datetime.datetime.now().astimezone()
    rows = read_health_log(args.log)
    stats = build_stats(rows, now, args.score_half_life)

    if args.lines:
        candidates = load_candidate_lines(args.lines)
    else:
        candidates = sorted(stats)

    kw = _score_kwargs(args)
    ranked = [(line, node_score(stats.get(line), now, **kw)) for line in candidates]
    # 评分降序 → 行号升序做稳定 tie-break（同分时靠前的行号优先）
    ranked.sort(key=lambda r: (-r[1], r[0]))

    for line, score in ranked:
        if args.format == "lines":
            print(line)
        else:
            print(f"{line}\t{score:.3f}")

    return 0


def cmd_report(args) -> int:
    now = datetime.datetime.now().astimezone()
    rows = read_health_log(args.log)
    if not rows:
        print(f"health.log 没有可用样本：{args.log}")
        return 0

    stats = build_stats(rows, now, args.score_half_life)
    kw = _score_kwargs(args)

    print(f"日志  {args.log}   ({len(rows)} 条带节点号的样本)")
    print(f"当前  {now:%Y-%m-%d %H:%M:%S}")
    print(f"参数  成绩半衰期={_fmt_ago(args.score_half_life)}  "
          f"失败折扣={args.fail_discount:g}（半衰期 {_fmt_ago(args.fail_half_life)}）  "
          f"先验={args.default_ratio:.2f}（权重 {args.prior_weight:g} 条）")
    print("      评分 = 可用率 × 折扣   —— "
          "可用率=(U+先验*K)/(U+D+K)，折扣=1-失败折扣×0.5^(距最近失败/失败半衰期)")
    print()

    ranked = [(line, node_score(stat, now, **kw), stat) for line, stat in stats.items()]
    ranked.sort(key=lambda r: (-r[1], r[0]))

    header = (f"{'行号':>5}  {'评分':>7}  {'可用率':>7}  {'折扣':>6}  "
              f"{'有效UP':>8}  {'样本UP':>6}  {'样本DOWN':>8}  {'最近失败':>8}  状态")
    print(header)
    print("-" * len(header))

    current = None
    for line, score, stat in ranked:
        factor = fail_discount_factor(stat, now, args.fail_half_life, args.fail_discount)
        rate = score / factor if factor else score
        fail_ago = (_fmt_ago((now - stat["last_fail"]).total_seconds())
                    if stat["last_fail"] else "-")
        # 状态看的是**实际折扣**，不是「最后一笔是不是失败」—— 一个 2 天前失败过、
        # 之后再没被采样的节点，折扣早已回到 1.000，不该被标成「刚失败」。
        if stat["total"] == 0:
            state = "未探测"
        elif factor < 0.99:
            state = "打折中"
        else:
            state = "可用"
        if line == args.current:
            current = (line, stat, factor)
            state = f"{state}  ← 当前使用"
        bar = "#" * round(score * 16)
        print(f"{line:>5}  {score * 100:6.1f}%  {rate * 100:6.1f}%  {factor:>6.3f}  "
              f"{stat['up_weight']:>8.2f}  {stat['up']:>6}  {stat['down']:>8}  "
              f"{fail_ago:>8}  {state:<20} {bar}")

    discounted = sum(1 for _, _, s in ranked
                     if fail_discount_factor(s, now, args.fail_half_life,
                                             args.fail_discount) < 0.99)
    print()
    print(f"合计 {len(ranked)} 个节点，其中 {discounted} 个正在打折（折扣 < 0.99）")

    # 「当前节点最后一笔是失败」两种可能：a) 换节点时所有候选都失败、回滚到它
    # （正常，下一分钟再试）；b) auto-heal 压根没换掉它（异常）。
    # 单看 health.log 分不出来，所以只提示、不武断。
    if current and recent_down(current[1]):
        ago = (now - current[1]["last_fail"]).total_seconds()
        print()
        print(f"⚠ 当前正在使用的是 {current[0]} 号节点，而它最后一笔采样是失败"
              f"（{_fmt_ago(ago)} 前）")
        print("  若这是「候选全失败后回滚」属正常；否则说明换节点没走通，"
              "检查 cron：sh install-cron.sh status")

    seen = {r[2] for r in rows}
    if args.total_lines:
        missing = args.total_lines - len(seen)
        if missing > 0:
            print(f"另有 {missing} 个 link.txt 行号从未被采样（按先验 "
                  f"{args.default_ratio:.2f} 参与排序，稳定排在健康节点之后）")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_common(sp):
        sp.add_argument("--log", default=str(DEFAULT_HEALTH_LOG),
                        help="health.log 路径")
        sp.add_argument("--score-half-life", type=float,
                        default=DEFAULT_SCORE_HALF_LIFE,
                        help=f"成绩证据的半衰期秒数（默认 {DEFAULT_SCORE_HALF_LIFE}）")
        sp.add_argument("--fail-half-life", type=float,
                        default=DEFAULT_FAIL_HALF_LIFE,
                        help=f"失败折扣的半衰期秒数（默认 {DEFAULT_FAIL_HALF_LIFE}）")
        sp.add_argument("--fail-discount", type=float,
                        default=DEFAULT_FAIL_DISCOUNT,
                        help=f"刚失败时分数打几折（默认 {DEFAULT_FAIL_DISCOUNT:g}）")
        sp.add_argument("--prior-weight", type=float, default=DEFAULT_PRIOR_WEIGHT,
                        help=f"先验相当于几条样本（默认 {DEFAULT_PRIOR_WEIGHT:g}）")
        sp.add_argument("--default-ratio", type=float, default=DEFAULT_RATIO,
                        help=f"未探测节点的先验评分（默认 {DEFAULT_RATIO}）")

    r = sub.add_parser("rank", help="按评分降序输出候选节点")
    add_common(r)
    r.add_argument("--lines", help="候选行号文件（默认用 health.log 里出现过的全部节点）")
    r.add_argument("--format", choices=("table", "lines"), default="table",
                   help="lines = 每行只打印行号，供 shell 直接消费")
    r.set_defaults(func=cmd_rank)

    rep = sub.add_parser("report", help="人类可读的节点健康报告")
    add_common(rep)
    rep.add_argument("--current", type=int, default=0,
                     help="当前正在使用的 link.txt 行号，用于标出「← 当前使用」")
    rep.add_argument("--total-lines", type=int, default=0,
                     help="link.txt 总行数，用于提示从未采样的节点数")
    rep.set_defaults(func=cmd_report)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
