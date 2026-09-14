#!/usr/bin/env python3
"""候选节点枚举 + 可达性预筛 —— 供 start_cli.sh 在选节点前调用。

为什么把 `ping` 换掉
--------------------
原来的 `fast_ping_nodes()` 用 `ping -c 1 -W 3 <addr>` 做粗筛，有两个问题：

1. **参数语义跨平台不一致**。macOS（BSD ping）的 `-W` 是**毫秒**，Linux 是**秒**；
   而 Linux 的 `-t` 是 TTL，只有 macOS 的 `-t` 才是总超时。
   同一行命令不可能在两个平台上都表达「等 3 秒」。
2. **很多节点禁 ICMP**，用 ping 筛会误杀。实测 `ip.jkcnin.com`
   （DNS CNAME → iepl.gtm-host.com，IEPL 专线，池子里 30 个节点）
   TCP 三次握手 62~93ms 稳定可达，但 ICMP 完全不回 —— ping 预筛把最好的
   线路整批剔除了，日志里表现为「这些节点从未被探测过」。

这里改用 TCP connect 到节点的**真实服务端口**：语义上更接近
「这个节点现在能不能连」，而且只用 Python 标准库，不依赖外部命令，
macOS / Linux 行为完全一致。

子命令
------
    node_probe.py list                   列出候选行号（非香港 且 可解析）
    node_probe.py reach --in FILE        对给定行号做 TCP 探测，输出可达子集
    node_probe.py scan --out-dir DIR     一把梭：写 candidates.txt / reachable.txt
"""

from __future__ import annotations

import argparse
import concurrent.futures
import pathlib
import socket
import sys

# 允许以脚本方式直接调用，无论 cwd 在哪
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from gen_xray_config import is_hongkong_url, parse_link  # noqa: E402

DEFAULT_TIMEOUT = 3.0
DEFAULT_WORKERS = 16
# TCP 握手成功即算可达。不在这里做「能不能翻墙」的判断 —— 那是 try_node
# 的职责，本模块只负责用一秒钟把明显连不上的节点筛掉。
DEFAULT_PORT_FALLBACK = 443


def read_lines(path) -> list[str]:
    return pathlib.Path(path).read_text(encoding="utf-8", errors="replace").splitlines()


def endpoint_of(outbound) -> tuple[str, int] | None:
    """从 outbound 配置里取出 (address, port)。取不到返回 None。"""
    settings = outbound.get("settings", {}) if isinstance(outbound, dict) else {}

    for key in ("vnext", "servers"):
        entries = settings.get(key)
        if not isinstance(entries, list) or not entries:
            continue
        first = entries[0]
        if not isinstance(first, dict):
            continue
        address = first.get("address") or first.get("host")
        port = first.get("port", DEFAULT_PORT_FALLBACK)
        if address:
            try:
                return str(address), int(port)
            except (TypeError, ValueError):
                continue
    return None


def candidate_lines(links_path) -> list[int]:
    """候选 = 非香港 且 能解析出 outbound 的行号。编号 = link.txt 原始行号。"""
    lines = read_lines(links_path)
    out = []
    for i, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        if is_hongkong_url(line):
            continue
        if parse_link(line.strip()):
            out.append(i)
    return out


def tcp_reachable(address: str, port: int, timeout: float) -> tuple[bool, float]:
    """TCP connect 探测。返回 (是否可达, 耗时毫秒)。"""
    import time

    start = time.monotonic()
    try:
        with socket.create_connection((address, port), timeout=timeout):
            pass
    except (OSError, ValueError):
        return False, (time.monotonic() - start) * 1000
    return True, (time.monotonic() - start) * 1000


def reach(lines: list[int], links_path, timeout: float, workers: int, verbose: bool):
    """并行探测，返回 (可达行号有序列表, 总候选数)。"""
    all_lines = read_lines(links_path)
    endpoints: dict[int, tuple[str, int]] = {}

    for line_no in lines:
        if not 1 <= line_no <= len(all_lines):
            continue
        parsed = parse_link(all_lines[line_no - 1].strip())
        if not parsed:
            continue
        ep = endpoint_of(parsed[0])
        if ep:
            endpoints[line_no] = ep

    ok: list[int] = []

    def probe(item):
        line_no, (address, port) = item
        alive, ms = tcp_reachable(address, port, timeout)
        if verbose:
            mark = "OK  " if alive else "FAIL"
            print(f"  {mark} 行{line_no:<4} {address}:{port}  {ms:.0f}ms",
                  file=sys.stderr)
        return line_no if alive else None

    if not endpoints:
        return [], 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for result in pool.map(probe, sorted(endpoints.items())):
            if result is not None:
                ok.append(result)

    return sorted(ok), len(endpoints)


def write_numbers(path, numbers) -> None:
    pathlib.Path(path).write_text(
        "\n".join(str(n) for n in numbers) + ("\n" if numbers else ""),
        encoding="utf-8",
    )


def cmd_list(args) -> int:
    for line_no in candidate_lines(args.links):
        print(line_no)
    return 0


def cmd_reach(args) -> int:
    if args.input:
        raw = pathlib.Path(args.input).read_text(encoding="utf-8", errors="replace")
        lines = [int(tok) for tok in raw.split() if tok.lstrip("-").isdigit()]
    else:
        lines = candidate_lines(args.links)

    ok, total = reach(lines, args.links, args.timeout, args.workers, args.verbose)
    if args.out:
        write_numbers(args.out, ok)
    for line_no in ok:
        print(line_no)
    print(f"TCP 可达 {len(ok)}/{total}", file=sys.stderr)
    return 0


def cmd_scan(args) -> int:
    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    candidates = candidate_lines(args.links)
    write_numbers(out_dir / "candidates.txt", candidates)

    ok, total = reach(candidates, args.links, args.timeout, args.workers, args.verbose)
    write_numbers(out_dir / "reachable.txt", ok)

    print(f"候选 {len(candidates)} 个 / TCP 可达 {len(ok)} 个（探测 {total} 个）",
          file=sys.stderr)
    return 0


def main(argv=None) -> int:
    default_links = str(pathlib.Path(__file__).resolve().parent / "link.txt")
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_links(sp):
        # 挂在子命令上，这样 `scan --out-dir D --links F` 才是合法写法
        sp.add_argument("--links", default=default_links, help="link.txt 路径")

    lst = sub.add_parser("list", help="列出候选行号")
    add_links(lst)
    lst.set_defaults(func=cmd_list)

    def add_probe_args(sp):
        add_links(sp)
        sp.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help=f"单个节点 TCP 超时秒数（默认 {DEFAULT_TIMEOUT}）")
        sp.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help=f"并发数（默认 {DEFAULT_WORKERS}）")
        sp.add_argument("--verbose", action="store_true", help="逐节点打印探测结果")

    r = sub.add_parser("reach", help="对给定行号做 TCP 可达性探测")
    r.add_argument("--in", dest="input", help="待探测的行号文件；省略则用全部候选")
    r.add_argument("--out", help="把可达行号写入该文件")
    add_probe_args(r)
    r.set_defaults(func=cmd_reach)

    s = sub.add_parser("scan", help="产出 candidates.txt / reachable.txt")
    s.add_argument("--out-dir", required=True)
    add_probe_args(s)
    s.set_defaults(func=cmd_scan)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
