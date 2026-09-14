#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import pathlib
import re
import socket
import ssl
import sys
import urllib.parse
from typing import Optional


# ── Certificate hash cache (avoids re-fetching for the same host:port) ──
_cert_cache: dict[tuple[str, int, str], Optional[str]] = {}

# Global flag: only fetch certs for the *selected* node, not during bulk parse
_enable_cert_fetch = False


def fetch_cert_sha256(host: str, port: int, sni: str = "", timeout: float = 5.0):
    """Fetch the SHA256 hash of a server's DER-encoded leaf certificate.

    Uses Python's built-in ssl module (no external openssl dependency).
    Returns the hex digest string, or None on failure.
    """
    cache_key = (host, port, sni)
    if cache_key in _cert_cache:
        return _cert_cache[cache_key]

    result = None
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=sni or host) as ssock:
                cert_der = ssock.getpeercert(binary_form=True)
        if cert_der:
            result = hashlib.sha256(cert_der).hexdigest()
    except Exception:
        pass

    _cert_cache[cache_key] = result
    return result


def _maybe_pin_cert(tls_settings: dict, host: str, port: int, sni: str):
    """When _enable_cert_fetch is True and allowInsecure was requested,
    fetch the server cert hash and add pinnedPeerCertSha256.

    Xray v26 removed allowInsecure entirely. The only way to connect to
    servers with self-signed / SNI-mismatched certificates is to pin the
    certificate hash via pinnedPeerCertSha256.
    """
    if not _enable_cert_fetch or not host or not port:
        return
    cert_hash = fetch_cert_sha256(host, port, sni)
    if cert_hash:
        tls_settings["pinnedPeerCertSha256"] = cert_hash
        print(
            f"[gen_xray_config] pinned cert {cert_hash[:16]}… for "
            f"{host}:{port}",
            file=sys.stderr,
        )
    else:
        print(
            f"[gen_xray_config] WARNING: could not fetch cert for "
            f"{host}:{port}, TLS will likely fail",
            file=sys.stderr,
        )


def _b64decode_json(link: str) -> dict:
    s = link.strip()
    s += "=" * (-len(s) % 4)
    raw = base64.urlsafe_b64decode(s.encode()).decode("utf-8", errors="strict")
    return json.loads(raw)


def _b64decode_nopad(s: str) -> bytes:
    s = s.strip()
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s.encode())


def parse_ss(link: str):
    # Supports:
    # 1) ss://BASE64(method:password)@host:port#tag
    # 2) ss://BASE64(method:password@host:port)#tag
    u = urllib.parse.urlsplit(link)
    raw = u.netloc
    if not raw:
        raise ValueError("invalid ss link")

    if "@" in raw:
        user_b64, hostport = raw.split("@", 1)
        cred = _b64decode_nopad(user_b64).decode("utf-8", errors="strict")
        if ":" not in cred:
            raise ValueError("invalid ss credential")
        method, password = cred.split(":", 1)
        host, port_str = hostport.rsplit(":", 1)
    else:
        decoded = _b64decode_nopad(raw).decode("utf-8", errors="strict")
        if "@" not in decoded:
            raise ValueError("invalid ss inline format")
        cred, hostport = decoded.split("@", 1)
        method, password = cred.split(":", 1)
        host, port_str = hostport.rsplit(":", 1)

    return {
        "protocol": "shadowsocks",
        "settings": {
            "servers": [
                {
                    "address": host,
                    "port": int(port_str),
                    "method": method,
                    "password": password,
                    "uot": True,
                }
            ]
        },
        "streamSettings": {"network": "tcp"},
    }


def _tls_or_reality_settings(query: dict, server_address: str = "", server_port: int = 0):
    security = (query.get("security", [""])[0] or "none").lower()
    settings = {"network": (query.get("type", ["tcp"])[0] or "tcp").lower(), "security": security}

    if security == "tls":
        allow_insecure = query.get("allowInsecure", ["0"])[0] in ("1", "true", "True")
        sni = query.get("sni", [""])[0] or ""
        tls_settings = {
            "serverName": sni,
            "fingerprint": query.get("fp", [""])[0] or "chrome",
        }
        if allow_insecure:
            _maybe_pin_cert(tls_settings, server_address, server_port, sni)
        settings["tlsSettings"] = tls_settings
    elif security == "reality":
        settings["realitySettings"] = {
            "serverName": query.get("sni", [""])[0] or "",
            "fingerprint": query.get("fp", [""])[0] or "chrome",
            "publicKey": query.get("pbk", [""])[0] or "",
            "shortId": query.get("sid", [""])[0] or "",
        }

    network = settings["network"]
    if network == "grpc":
        settings["grpcSettings"] = {
            "serviceName": query.get("serviceName", [""])[0] or "",
            "authority": query.get("authority", [""])[0] or "",
        }
    return settings


def parse_trojan(link: str):
    u = urllib.parse.urlsplit(link)
    if not u.hostname or not u.port or not u.username:
        raise ValueError("invalid trojan link")
    query = urllib.parse.parse_qs(u.query)

    outbound = {
        "protocol": "trojan",
        "settings": {
            "servers": [
                {
                    "address": u.hostname,
                    "port": int(u.port),
                    "password": urllib.parse.unquote(u.username),
                }
            ]
        },
        "streamSettings": _tls_or_reality_settings(query, server_address=u.hostname, server_port=int(u.port)),
    }
    return outbound


def parse_vmess(link: str):
    u = urllib.parse.urlsplit(link)
    payload_b64 = u.netloc or u.path.lstrip("/")
    payload = _b64decode_json(payload_b64)

    host = payload.get("add") or payload.get("address")
    port = payload.get("port")
    user_id = payload.get("id")
    if not host or not port or not user_id:
        raise ValueError("invalid vmess link")

    network = (payload.get("net") or "tcp").lower()
    security = (payload.get("tls") or "none").lower()
    if security not in ("tls", "reality"):
        security = "none"

    stream_settings = {
        "network": network,
        "security": security,
    }
    if security == "tls":
        allow_insecure = str(payload.get("allowInsecure") or "0").lower() in ("1", "true", "yes")
        sni = payload.get("sni") or payload.get("host") or ""
        tls_settings = {
            "serverName": sni,
            "fingerprint": payload.get("fp") or "chrome",
        }
        if allow_insecure:
            _maybe_pin_cert(tls_settings, host, int(port), sni)
        stream_settings["tlsSettings"] = tls_settings
    elif security == "reality":
        stream_settings["realitySettings"] = {
            "serverName": payload.get("sni") or payload.get("host") or "",
            "fingerprint": payload.get("fp") or "chrome",
            "publicKey": payload.get("pbk") or "",
            "shortId": payload.get("sid") or "",
        }

    if network == "ws":
        stream_settings["wsSettings"] = {
            "path": payload.get("path") or "/",
            "headers": {"Host": payload.get("host") or ""},
        }
    elif network == "grpc":
        stream_settings["grpcSettings"] = {
            "serviceName": payload.get("path") or payload.get("serviceName") or "",
            "authority": payload.get("host") or payload.get("authority") or "",
        }

    outbound = {
        "protocol": "vmess",
        "settings": {
            "vnext": [
                {
                    "address": host,
                    "port": int(port),
                    "users": [
                        {
                            "id": user_id,
                            "alterId": int(payload.get("aid") or 0),
                            "security": payload.get("scy") or "auto",
                        }
                    ],
                }
            ]
        },
        "streamSettings": stream_settings,
    }
    return outbound


def parse_vless(link: str):
    u = urllib.parse.urlsplit(link)
    if not u.hostname or not u.port or not u.username:
        raise ValueError("invalid vless link")
    query = urllib.parse.parse_qs(u.query)

    outbound = {
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": u.hostname,
                    "port": int(u.port),
                    "users": [
                        {
                            "id": urllib.parse.unquote(u.username),
                            "encryption": query.get("encryption", ["none"])[0],
                            "flow": query.get("flow", [""])[0],
                        }
                    ],
                }
            ]
        },
        "streamSettings": _tls_or_reality_settings(query, server_address=u.hostname, server_port=int(u.port)),
    }
    user = outbound["settings"]["vnext"][0]["users"][0]
    if not user.get("flow"):
        user.pop("flow", None)
    return outbound


def parse_link(link: str):
    link = link.strip()
    if not link:
        return None
    if link.startswith("ss://"):
        return parse_ss(link), "ss"
    if link.startswith("trojan://"):
        return parse_trojan(link), "trojan"
    if link.startswith("vless://"):
        return parse_vless(link), "vless"
    if link.startswith("vmess://"):
        return parse_vmess(link), "vmess"
    return None


def node_display_name(link: str) -> str:
    """返回节点的显示名（机场里给节点起的名字）。

    vmess 的名字藏在 base64 payload 的 ``ps`` 字段里，明文根本看不到；
    其余协议的节点名在 URL fragment（``#`` 之后），需要 percent-decode。

    香港判定必须基于本函数的返回值 —— 只匹配原始文本会漏掉全部 vmess 节点。
    """
    text = (link or "").strip()
    if not text:
        return ""
    if text.startswith("vmess://"):
        try:
            payload = _b64decode_json(text[len("vmess://"):])
        except Exception:
            return ""
        return str(payload.get("ps") or "")
    if "#" in text:
        return urllib.parse.unquote(text.split("#", 1)[1])
    return ""


_HK_TOKEN_SPLIT = re.compile(r"[^a-z0-9]+")


def _has_hongkong_marker(name: str) -> bool:
    """判断一段名字里是否含香港标记。"""
    if not name:
        return False
    if "香港" in name:
        return True
    lowered = name.lower()
    if "hongkong" in lowered or "hong kong" in lowered:
        return True
    # 独立的 HK 标记（"HK-01" / "hk 1" / "HK"）。
    # 按非字母数字切分后做整词比对，避免误伤 "hkt"、"hkust" 这类词。
    return any(tok == "hk" for tok in _HK_TOKEN_SPLIT.split(lowered))


def is_hongkong_url(link: str) -> bool:
    """判断节点是否为香港节点。

    两步：
      1. 先在原始文本上粗筛 —— 兼容明文写法与未编码的链接；
      2. 再解码链接里的节点名复核 —— 这一步才能覆盖 vmess，
         因为 vmess 的主体是 base64，明文里没有「香港」两个字。
    """
    text = (link or "").strip()
    if not text:
        return False
    if _has_hongkong_marker(text):
        return True
    return _has_hongkong_marker(node_display_name(text))


def build_routing_rules(bypass_cn: bool):
    """Ordered routing rules. First match wins; the default outbound is `proxy`.

    `direct` must therefore be declared before anything that would swallow
    mainland traffic.
    """
    rules = [
        # Loopback / RFC1918 / link-local never leave the machine.
        {"type": "field", "domain": ["geosite:private"], "outboundTag": "direct"},
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
    ]
    if bypass_cn:
        rules += [
            # Mainland domains -> direct (no proxy, no pollution risk).
            {"type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"},
            # Mainland IPs (covers bare-IP destinations and unlisted domains).
            {"type": "field", "ip": ["geoip:cn"], "outboundTag": "direct"},
        ]
    return rules


def main():
    p = argparse.ArgumentParser(description="Generate xray config from link list")
    p.add_argument("--links", required=True)
    p.add_argument(
        "--line",
        type=int,
        default=None,
        help="link.txt 行号（1-based）。推荐的寻址方式，与 health.log 第 3 列、"
             "node_stats.py 的排名结果共用同一套编号。",
    )
    p.add_argument(
        "--index",
        type=int,
        default=None,
        help="兼容旧用法：过滤香港后的候选序号（1-based）。同时给出 --line 时以 --line 为准。",
    )
    p.add_argument("--http-port", type=int, default=7897)
    p.add_argument("--socks-port", type=int, default=7898)
    p.add_argument("--out", required=True)
    p.add_argument("--selected", required=True)
    p.add_argument(
        "--bypass-cn",
        dest="bypass_cn",
        action="store_true",
        default=True,
        help="route CN domains/IPs direct (default: on)",
    )
    p.add_argument(
        "--no-bypass-cn",
        dest="bypass_cn",
        action="store_false",
        help="send everything through the proxy",
    )
    args = p.parse_args()

    all_lines = pathlib.Path(args.links).read_text(encoding="utf-8").splitlines()

    # Phase 1: 批量粗解析（不取证书，保证速度）。
    # 香港节点在这里被过滤，但 **link.txt 的原始行号保持不动** —— 这个行号
    # 就是 health.log 第 3 列、selected_node.txt 的 source_line，
    # 以及 node_stats.py 排名输出所用的那个编号。
    by_line = {}
    supported = []
    for i, line in enumerate(all_lines, start=1):
        if is_hongkong_url(line):
            continue
        parsed = parse_link(line)
        if parsed:
            outbound, proto = parsed
            by_line[i] = (outbound, proto)
            supported.append(i)

    if not supported:
        raise SystemExit("No supported links found (supported: ss/trojan/vless)")

    # 选节点：优先按 link.txt 行号（--line），其次兼容旧的候选序号（--index）
    if args.line is not None:
        src_line_no = args.line
        if src_line_no not in by_line:
            raise SystemExit(
                f"link.txt 第 {src_line_no} 行不可用：该行不存在、解析失败，"
                f"或是被排除的香港节点"
            )
    else:
        idx = args.index if args.index is not None else 1
        if idx < 1 or idx > len(supported):
            raise SystemExit(
                f"supported index 超出范围: {idx} (supported_count={len(supported)})"
            )
        src_line_no = supported[idx - 1]

    src_line = all_lines[src_line_no - 1]
    sup_index = supported.index(src_line_no) + 1

    # Phase 2: re-parse ONLY the selected link WITH cert fetching enabled
    global _enable_cert_fetch
    _enable_cert_fetch = True
    reparsed = parse_link(src_line)
    if reparsed:
        outbound, proto = reparsed
    else:
        outbound, proto = by_line[src_line_no]

    config = {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "http-in",
                "listen": "127.0.0.1",
                "port": args.http_port,
                "protocol": "http",
                "settings": {},
            },
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": args.socks_port,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True},
            },
        ],
        "outbounds": [
            {**outbound, "tag": "proxy"},
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"},
        ],
        "routing": {
            # IPIfNonMatch: match domain rules first, only resolve to IP when
            # no domain rule matched. Needed so geoip:cn can catch CN hosts
            # that geosite:cn does not list.
            "domainStrategy": "IPIfNonMatch",
            "rules": build_routing_rules(args.bypass_cn),
        },
    }

    pathlib.Path(args.out).write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
    pathlib.Path(args.selected).write_text(
        f"node_id={src_line_no}\n"
        f"source_line={src_line_no}\n"
        f"supported_index={sup_index}\n"
        f"protocol={proto}\n"
        f"link={src_line}\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
