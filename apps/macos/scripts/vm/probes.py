#!/usr/bin/env python3
"""Small probes for the AI-lock VM matrix. No third-party packages.

Python 3.9. Subcommands print key=value lines and do not change PF,
resolver files, or launchd.
"""

import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time


def encode_name(name):
    labels = name.rstrip(".").split(".")
    encoded = b""
    for label in labels:
        raw = label.encode("ascii")
        if not raw or len(raw) > 63:
            raise ValueError("bad label")
        encoded += bytes([len(raw)]) + raw
    return encoded + b"\x00"


def build_query(name):
    header = os.urandom(2) + struct.pack("!HHHHH", 0x0100, 1, 0, 0, 0)
    return header + encode_name(name) + struct.pack("!HH", 1, 1)


def skip_name(data, offset):
    hops = 0
    while offset < len(data):
        length = data[offset]
        if length == 0:
            return offset + 1
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(data):
                raise ValueError("truncated pointer")
            return offset + 2
        if length & 0xC0:
            raise ValueError("bad label")
        offset += 1 + length
        hops += 1
        if hops > 128:
            raise ValueError("name loop")
    raise ValueError("truncated name")


def parse_answers(data):
    if len(data) < 12:
        raise ValueError("short header")
    rcode = data[3] & 0x0F
    ancount = struct.unpack("!H", data[6:8])[0]
    offset = skip_name(data, 12)
    offset += 4  # qtype, qclass
    answers = []
    for _ in range(ancount):
        offset = skip_name(data, offset)
        if offset + 10 > len(data):
            raise ValueError("truncated answer")
        rtype, rclass, _ttl, rdlength = struct.unpack("!HHIH", data[offset : offset + 10])
        offset += 10
        rdata = data[offset : offset + rdlength]
        offset += rdlength
        if rtype == 1 and rclass == 1 and len(rdata) == 4:
            answers.append(socket.inet_ntoa(rdata))
    return rcode, ancount, answers


def cmd_dns(argv):
    server, port_text, name = argv
    port = int(port_text)
    query = build_query(name)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)
    try:
        sock.sendto(query, (server, port))
        data, _addr = sock.recvfrom(2048)
    except socket.timeout:
        print("rcode=timeout ancount=0 answers=")
        return 1
    finally:
        sock.close()
    rcode, ancount, answers = parse_answers(data)
    print("rcode=%s ancount=%s answers=%s" % (rcode, ancount, ",".join(answers)))
    return 0


def cmd_tcp(argv):
    host, port_text, timeout_text = argv[:3]
    hold = float(argv[3]) if len(argv) > 3 else 0.0
    try:
        sock = socket.create_connection((host, int(port_text)), float(timeout_text))
    except OSError as exc:
        print("connect=fail error=%s" % exc.__class__.__name__)
        return 1
    print("connect=ok")
    if hold > 0:
        time.sleep(hold)
    sock.close()
    return 0


def cmd_udp(argv):
    """Send one datagram and wait for the same bytes back. recv=1 is a round trip."""
    host, port_text = argv[0], argv[1]
    timeout = float(argv[2]) if len(argv) > 2 else 1.0
    payload = b"segue-leak-probe"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        try:
            sock.sendto(payload, (host, int(port_text)))
        except OSError as exc:
            print("sent=0 recv=0 error=%s" % exc.__class__.__name__)
            return 1
        try:
            data, _addr = sock.recvfrom(4096)
        except socket.timeout:
            print("sent=1 recv=0")
            return 1
        except OSError as exc:
            print("sent=1 recv=0 error=%s" % exc.__class__.__name__)
            return 1
    finally:
        sock.close()
    if data == payload:
        print("sent=1 recv=1")
        return 0
    print("sent=1 recv=0 mismatch=1")
    return 1


def cmd_udp_echo(argv):
    """Echo UDP datagrams. The leak row's stand-in for an unlisted QUIC peer."""
    host, port_text = argv
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, int(port_text)))
    while True:
        data, addr = sock.recvfrom(4096)
        if not data:
            continue
        try:
            sock.sendto(data, addr)
        except OSError:
            pass


def cmd_serve(argv):
    host, port_text, banner = argv
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, int(port_text)))
    sock.listen(8)
    banner_bytes = (banner + "\n").encode("ascii", "replace")
    while True:
        client, _addr = sock.accept()
        try:
            client.sendall(banner_bytes)
        except OSError:
            pass
        finally:
            client.close()


def cmd_helper(argv):
    path, payload = argv
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2.0)
    try:
        sock.connect(path)
        sock.sendall(payload.encode("utf-8") + b"\n")
        chunks = b""
        while b"\n" not in chunks and len(chunks) < 65536:
            piece = sock.recv(4096)
            if not piece:
                break
            chunks += piece
    except OSError as exc:
        print("helper=fail error=%s" % exc.__class__.__name__)
        return 1
    finally:
        sock.close()
    line = chunks.split(b"\n", 1)[0].decode("utf-8", "replace")
    print(line)
    return 0


def established_to(port):
    try:
        output = subprocess.run(
            ["/usr/sbin/netstat", "-n", "-p", "tcp"],
            check=False,
            capture_output=True,
            text=True,
        ).stdout
    except OSError:
        return -1
    needle = "127.0.0.1.%s" % port
    count = 0
    for line in output.splitlines():
        if needle in line and "ESTABLISHED" in line:
            count += 1
    return count


def held_connect(host, port, hold, socks_port):
    result = {"connect": "fail"}

    def run():
        try:
            sock = socket.create_connection((host, port), 2.0)
        except OSError as exc:
            result["connect"] = exc.__class__.__name__
            return
        result["connect"] = "ok"
        time.sleep(hold)
        try:
            sock.close()
        except OSError:
            pass

    baseline = established_to(socks_port)
    thread = threading.Thread(target=run)
    thread.start()
    peak = baseline
    for _ in range(20):
        peak = max(peak, established_to(socks_port))
        time.sleep(0.1)
    thread.join(timeout=3.0)
    if baseline < 0 or peak < 0:
        delta = -1
    else:
        delta = peak - baseline
    return result["connect"], delta


def cmd_egress(argv):
    fake_ip, fake_port, socks_port, other_host, other_port, loopback_port = argv
    ai_connect, ai_delta = held_connect(fake_ip, int(fake_port), 1.2, int(socks_port))
    other_connect, other_delta = held_connect(
        other_host, int(other_port), 0.4, int(socks_port)
    )
    try:
        sock = socket.create_connection(("127.0.0.1", int(loopback_port)), 2.0)
        sock.close()
        loopback = "ok"
    except OSError as exc:
        loopback = exc.__class__.__name__
    print("ai_connect=%s" % ai_connect)
    print("ai_socks_delta=%s" % ai_delta)
    print("other_connect=%s" % other_connect)
    print("other_socks_delta=%s" % other_delta)
    print("loopback=%s" % loopback)
    return 0


def cmd_counter(argv):
    del argv
    text = sys.stdin.read()
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if "segue-ai-0" not in line:
            continue
        window = "\n".join(lines[index : index + 4])
        packets = _field(window, "Packets:")
        evaluations = _field(window, "Evaluations:")
        print("found=yes packets=%s evaluations=%s" % (packets, evaluations))
        return 0
    print("found=no packets=0 evaluations=0")
    return 0


def _field(window, label):
    """Read the integer after 'Packets:' or 'Evaluations:' in a pfctl -v rule."""
    key = label[:-1] if label.endswith(":") else label
    flattened = window.replace("\n", " ").replace("[", " ").replace("]", " ")
    tokens = flattened.split()
    for index, token in enumerate(tokens):
        if token.startswith(label) and token != label:
            rest = token[len(label) :]
            if rest.isdigit():
                return rest
        bare = token.rstrip(":")
        if bare == key and index + 1 < len(tokens):
            maybe = tokens[index + 1]
            if maybe.isdigit():
                return maybe
    return "0"


def cmd_leak_rules(argv):
    del argv
    text = sys.stdin.read()
    blocks = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        lowered = line.lower()
        if "block drop all" in lowered or "block drop out quick all" in lowered:
            print("ok=no")
            print("reason=broad-block %s" % line)
            return 0
        if lowered.startswith("block"):
            blocks.append(line)
    if not blocks:
        print("ok=no")
        print("reason=no-block-rules")
        return 0
    for line in blocks:
        if "198.51.100.0/24" not in line:
            print("ok=no")
            print("reason=extra-block %s" % line)
            return 0
    print("ok=yes")
    print("reason=blocks-only-fixture-cidr count=%s" % len(blocks))
    return 0


def current_dns_services():
    listing = subprocess.run(
        ["/usr/sbin/networksetup", "-listallnetworkservices"],
        check=False,
        capture_output=True,
        text=True,
    )
    services = []
    for line in listing.stdout.splitlines()[1:]:
        name = line[1:] if line.startswith("*") else line
        if not name or name.startswith("An asterisk"):
            continue
        got = subprocess.run(
            ["/usr/sbin/networksetup", "-getdnsservers", name],
            check=False,
            capture_output=True,
            text=True,
        )
        text = got.stdout.strip()
        if (not text) or ("aren't any" in text) or ("any DNS" in text):
            servers = []
        else:
            servers = [item.strip() for item in text.splitlines() if item.strip()]
        services.append({"name": name, "servers": servers})
    return services


def cmd_dns_save(argv):
    path = argv[0]
    services = current_dns_services()
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(services, handle)
    print("saved=%s" % len(services))
    return 0


def cmd_dns_match(argv):
    """Compare live resolvers to the snapshot save_dns wrote before arm."""
    path = argv[0]
    with open(path, "r", encoding="utf-8") as handle:
        saved = json.load(handle)
    current = {}
    for item in current_dns_services():
        current[item["name"]] = item["servers"]
    bad = []
    for item in saved:
        name = item.get("name") or ""
        wanted = item.get("servers") or []
        if current.get(name) != wanted:
            bad.append(name)
    if bad:
        print("match=no")
        print("services=%s" % ",".join(bad))
        return 1
    print("match=yes")
    return 0


def cmd_dns_restore(argv):
    path = argv[0]
    with open(path, "r", encoding="utf-8") as handle:
        services = json.load(handle)
    for item in services:
        args = ["/usr/sbin/networksetup", "-setdnsservers", item["name"]]
        servers = item.get("servers") or []
        if not servers:
            args.append("Empty")
        else:
            args.extend(servers)
        subprocess.run(args, check=False)
    print("restored=%s" % len(services))
    return 0


def main(argv):
    if len(argv) < 2:
        return 2
    command = argv[1]
    rest = argv[2:]
    commands = {
        "dns": (3, cmd_dns),
        "tcp": (3, cmd_tcp),
        "udp": (2, cmd_udp),
        "udp-echo": (2, cmd_udp_echo),
        "serve": (3, cmd_serve),
        "helper": (2, cmd_helper),
        "egress": (6, cmd_egress),
        "counter": (0, cmd_counter),
        "leak-rules": (0, cmd_leak_rules),
        "dns-save": (1, cmd_dns_save),
        "dns-match": (1, cmd_dns_match),
        "dns-restore": (1, cmd_dns_restore),
    }
    if command not in commands:
        return 2
    need, func = commands[command]
    if len(rest) < need:
        return 2
    return func(rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
