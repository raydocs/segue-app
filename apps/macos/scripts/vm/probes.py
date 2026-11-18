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


def http_exchange(host, port, method, path, extra_headers, timeout):
    """One HTTP/1.1 request. Returns (status, body). Host is the loopback name."""
    sock = socket.create_connection((host, int(port)), timeout)
    try:
        lines = [
            "%s %s HTTP/1.1" % (method, path),
            "Host: %s" % host,
            "Connection: close",
        ]
        for key, value in extra_headers:
            lines.append("%s: %s" % (key, value))
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("ascii"))
        chunks = []
        while True:
            block = sock.recv(8192)
            if not block:
                break
            chunks.append(block)
    finally:
        sock.close()
    raw = b"".join(chunks)
    head, _, body = raw.partition(b"\r\n\r\n")
    status = 0
    first = head.split(b"\r\n", 1)[0].split(b" ")
    if len(first) >= 2 and first[1].isdigit():
        status = int(first[1])
    return status, body


def metric_value(port, name):
    """segue_relay_<name> from the relay's metrics port, or None."""
    try:
        status, body = http_exchange("127.0.0.1", port, "GET", "/", [], 1.0)
    except OSError:
        return None
    if status != 200:
        return None
    prefix = ("segue_relay_%s " % name).encode("ascii")
    for line in body.splitlines():
        if line.startswith(prefix):
            rest = line[len(prefix) :].strip()
            if rest.isdigit():
                return int(rest)
    return None


def cmd_kernel_status(argv):
    """GET /v1/status using control.json. Prints the JSON body, never the token."""
    path = argv[0]
    try:
        with open(path, "r", encoding="utf-8") as handle:
            token = json.load(handle)
        addr = token["addr"]
        secret = token["token"]
    except (OSError, ValueError, KeyError, TypeError):
        print("error=no-control-token")
        return 1
    host, sep, port = addr.rpartition(":")
    if not sep or not port.isdigit():
        print("error=bad-control-addr")
        return 1
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    try:
        status, body = http_exchange(
            host,
            port,
            "GET",
            "/v1/status",
            [("Authorization", "Bearer " + secret)],
            1.0,
        )
    except OSError as exc:
        print("error=%s" % exc.__class__.__name__)
        return 1
    text = body.decode("utf-8", "replace")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    return 0 if status == 200 else 1


def cmd_relay_metrics(argv):
    port = argv[0]
    try:
        status, body = http_exchange("127.0.0.1", port, "GET", "/", [], 1.0)
    except OSError as exc:
        print("error=%s" % exc.__class__.__name__)
        return 1
    text = body.decode("utf-8", "replace")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    return 0 if status == 200 else 1


def _pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def _splice(client, host, port):
    try:
        upstream = socket.create_connection((host, port), 5.0)
    except OSError:
        client.close()
        return
    thread = threading.Thread(target=_pump, args=(client, upstream))
    thread.daemon = True
    thread.start()
    _pump(upstream, client)
    client.close()
    upstream.close()


def cmd_forward(argv):
    """Splice TCP from listen_host:listen_port to dest_host:dest_port.

    The kernel pins carrier sockets to the physical NIC, which cannot
    connect to 127.0.0.1. The relay still listens on loopback; this
    forwarder is the address the kernel dials.
    """
    listen_host, listen_port, dest_host, dest_port = argv[:4]
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((listen_host, int(listen_port)))
    server.listen(64)
    print(
        "forward %s:%s -> %s:%s" % (listen_host, listen_port, dest_host, dest_port),
        flush=True,
    )
    while True:
        client, _addr = server.accept()
        thread = threading.Thread(
            target=_splice, args=(client, dest_host, int(dest_port))
        )
        thread.daemon = True
        thread.start()


def held_connect(host, port, hold, timeout):
    try:
        sock = socket.create_connection((host, int(port)), timeout)
    except OSError as exc:
        return exc.__class__.__name__
    try:
        time.sleep(hold)
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return "ok"


def _delta(before, after):
    if before is None or after is None:
        return "missing"
    return str(after - before)


def cmd_egress(argv):
    """AI flow should move segue_relay_connects_home; a non-AI flow should not."""
    fake_ip, fake_port, metrics_port, other_host, other_port, loopback_port = argv[:6]
    home_before = metric_value(metrics_port, "connects_home")
    overseas_before = metric_value(metrics_port, "connects_overseas")
    ai_connect = held_connect(fake_ip, fake_port, 1.5, 5.0)
    ai_home = _delta(home_before, metric_value(metrics_port, "connects_home"))
    ai_overseas = _delta(
        overseas_before, metric_value(metrics_port, "connects_overseas")
    )
    other_home_before = metric_value(metrics_port, "connects_home")
    other_overseas_before = metric_value(metrics_port, "connects_overseas")
    other_connect = held_connect(other_host, other_port, 0.2, 1.5)
    other_home = _delta(
        other_home_before, metric_value(metrics_port, "connects_home")
    )
    other_overseas = _delta(
        other_overseas_before, metric_value(metrics_port, "connects_overseas")
    )
    try:
        sock = socket.create_connection(("127.0.0.1", int(loopback_port)), 2.0)
        sock.close()
        loopback = "ok"
    except OSError as exc:
        loopback = exc.__class__.__name__
    print("ai_connect=%s" % ai_connect)
    print("ai_home_delta=%s" % ai_home)
    print("ai_overseas_delta=%s" % ai_overseas)
    print("other_connect=%s" % other_connect)
    print("other_home_delta=%s" % other_home)
    print("other_overseas_delta=%s" % other_overseas)
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
        "forward": (4, cmd_forward),
        "kernel-status": (1, cmd_kernel_status),
        "relay-metrics": (1, cmd_relay_metrics),
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
