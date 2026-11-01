#!/usr/bin/env python3
"""仅用于 Windows/WSL NAT 联调的 UDP 端口转接，保留每个客户端的独立上游。"""
import argparse
import json
import os
import selectors
import socket
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--listen", required=True)
parser.add_argument("--target-port", type=int, required=True)
parser.add_argument("--allow", required=True)
args = parser.parse_args()
host, port = args.listen.rsplit(":", 1)
front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
front.bind((host, int(port)))
front.setblocking(False)
selector = selectors.DefaultSelector()
selector.register(front, selectors.EVENT_READ, None)
upstreams = {}
print(json.dumps({"pid": os.getpid(), "listen": args.listen, "target": f"127.0.0.1:{args.target_port}"}), flush=True)
try:
    while True:
        for key, _ in selector.select(5):
            if key.data is None:
                packet, address = front.recvfrom(65535)
                if address[0] != args.allow:
                    continue
                if address not in upstreams:
                    upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    upstream.connect(("127.0.0.1", args.target_port))
                    upstream.setblocking(False)
                    upstreams[address] = [upstream, time.monotonic()]
                    selector.register(upstream, selectors.EVENT_READ, address)
                upstream, _ = upstreams[address]
                upstreams[address][1] = time.monotonic()
                upstream.send(packet)
            else:
                try:
                    packet = key.fileobj.recv(65535)
                    front.sendto(packet, key.data)
                    upstreams[key.data][1] = time.monotonic()
                except ConnectionRefusedError:
                    pass
        expired = [address for address, (_, tick) in upstreams.items() if time.monotonic() - tick > 600]
        for address in expired:
            upstream, _ = upstreams.pop(address)
            selector.unregister(upstream)
            upstream.close()
finally:
    for upstream, _ in upstreams.values():
        upstream.close()
    front.close()
    selector.close()
