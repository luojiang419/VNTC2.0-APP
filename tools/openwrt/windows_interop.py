#!/usr/bin/env python3
"""在原生 Windows Wintun 客户端与既有 ARM OpenWrt 节点间验证双向传输。"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import threading
import time
import urllib.request

import paramiko

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "dist/windows-arm-interop"
LOG = OUT / "validation"
LOG.mkdir(exist_ok=True)
CONFIG = json.loads((OUT / "state/config.json").read_text(encoding="utf-8"))
PROCESS = json.loads((OUT / "process.json").read_text(encoding="utf-8"))
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
GROUP = "VNT-WinARM-Interop-" + str(PROCESS["pid"])
UNC = Path(r"\\wsl.localhost\Ubuntu")
FOLDERS = {"aarch64": "home/luo/.cache/vnt-openwrt/arm-vm/20261101T133738Z-aarch64",
           "armv7": "home/luo/.cache/vnt-openwrt/arm-vm/20261101T134003Z-armv7"}


def api(path, method="GET", data=None):
    req = urllib.request.Request("http://127.0.0.1:18083/api" + path, method=method,
        data=None if data is None else json.dumps(data).encode(),
        headers={"Authorization": "Bearer " + CONFIG["web"]["access_token"], "Content-Type": "application/json"})
    with OPENER.open(req, timeout=120) as response:
        return json.load(response)


def wait(label, function, seconds=120):
    until = time.monotonic() + seconds
    last = None
    while time.monotonic() < until:
        try:
            value = function()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(2)
    raise AssertionError(f"{label}: {last}")


class Remote:
    def __init__(self, arch, index):
        self.name = f"{arch}-{index}"
        self.ssh = paramiko.SSHClient()
        self.ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.ssh.connect("127.0.0.1", port=(23100 if arch == "aarch64" else 23200) + index,
                         username="root", key_filename=str(UNC / FOLDERS[arch] / "id_ed25519"),
                         allow_agent=False, look_for_keys=False, timeout=8)
    def cmd(self, command, timeout=90):
        _, out, err = self.ssh.exec_command(command, timeout=timeout)
        text, error = out.read().decode(errors="replace"), err.read().decode(errors="replace")
        code = out.channel.recv_exit_status()
        with (LOG / (self.name + ".log")).open("a", encoding="utf-8") as log:
            log.write(f"$ {command}\n{text}{error}\n[exit={code}]\n")
        assert code == 0, f"{self.name}: {command}: {text}{error}"
        return text
    def upload(self, data, path):
        channel = self.ssh.get_transport().open_session(timeout=15)
        channel.settimeout(90)
        channel.exec_command("cat > " + shlex.quote(path))
        channel.sendall(data)
        channel.shutdown_write()
        assert channel.recv_exit_status() == 0
        channel.close()


def powershell(text):
    path = LOG / "firewall-action.ps1"
    path.write_text("$ErrorActionPreference='Stop'\n[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)\n" + text, encoding="utf-8-sig")
    result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(path)],
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def firewall():
    python = sys.executable.replace("'", "''")
    value = powershell(f"""
Get-NetFirewallRule -Group '{GROUP}' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$adapter = Get-NetIPAddress -IPAddress '10.26.0.10' -AddressFamily IPv4
if ($adapter.InterfaceAlias -notlike 'VNT-App-TUN-VNT-WinARM-Test*') {{ throw 'Unexpected test interface' }}
New-NetFirewallRule -DisplayName '{GROUP}-Ping' -Group '{GROUP}' -Direction Inbound -Action Allow -Profile Any -InterfaceAlias $adapter.InterfaceAlias -LocalAddress '10.26.0.10' -RemoteAddress '10.26.0.2','10.26.0.3' -Protocol ICMPv4 -IcmpType 8 | Out-Null
New-NetFirewallRule -DisplayName '{GROUP}-File' -Group '{GROUP}' -Direction Inbound -Action Allow -Profile Any -InterfaceAlias $adapter.InterfaceAlias -LocalAddress '10.26.0.10' -RemoteAddress '10.26.0.2','10.26.0.3' -Protocol TCP -LocalPort 18093 -Program '{python}' | Out-Null
$adapter | Select-Object InterfaceAlias,InterfaceIndex,IPAddress,PrefixLength | ConvertTo-Json
""")
    return json.loads(value)


def win_ping(address, count):
    result = subprocess.run(["ping.exe", "-n", str(count), "-w", "3000", "-l", "1300", address],
                             capture_output=True, text=True, errors="replace", timeout=count * 4 + 30)
    assert result.returncode == 0 and "(0% loss)" in result.stdout, result.stdout
    return result.stdout


def main():
    report = {"native_platform": api("/about"), "cases": [], "success": False, "pid": PROCESS["pid"]}
    report_path = OUT / "interop-report.json"
    def save():
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    remotes = []
    remote_dir = "/tmp/vnt-win-interop-" + str(PROCESS["pid"])
    helper_pids = {}
    try:
        for arch in ("aarch64", "armv7"):
            peers = [Remote(arch, i) for i in range(2)]
            remotes += peers
            expected = {}
            helper = (UNC / FOLDERS[arch] / "live-20261101T143721Z/transfer-http").read_bytes()
            for peer in peers:
                body = secrets.token_bytes(1024 * 1024)
                expected[peer.name] = hashlib.sha256(body).hexdigest()
                peer.cmd("mkdir -p " + remote_dir)
                peer.upload(helper, remote_dir + "/http")
                peer.upload(body, remote_dir + "/payload.bin")
                peer.cmd(f"chmod 700 {remote_dir}/http; (trap '' HUP; exec {remote_dir}/http 18090 {remote_dir}/payload.bin) >{remote_dir}/http.log 2>&1 </dev/null & echo $! >{remote_dir}/http.pid")
                helper_pids[peer.name] = peer.cmd("cat " + remote_dir + "/http.pid").strip()
            for protocol in ("tcp", "quic"):
                print(f"CONNECT {arch} {protocol}", flush=True)
                api(f"/profiles/win-{arch}-{protocol}/connect", "POST")
                wait("Windows registration", lambda: api("/status")["phase"] == "running")
                interface = firewall()
                for index, peer in enumerate(peers):
                    ip = f"10.26.0.{index + 2}"
                    wait("Windows -> ARM ping", lambda: win_ping(ip, 3))
                    wait("ARM -> Windows ping", lambda: ", 0% packet loss" in peer.cmd("ping -c 3 -W 3 -s 1300 10.26.0.10"))
                payload = secrets.token_bytes(1024 * 1024)
                payload_hash = hashlib.sha256(payload).hexdigest()
                class Handler(BaseHTTPRequestHandler):
                    def do_GET(self):
                        if self.path != "/payload.bin":
                            self.send_error(404)
                            return
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload)
                    def log_message(self, *args):
                        pass
                server = ThreadingHTTPServer(("10.26.0.10", 18093), Handler)
                worker = threading.Thread(target=server.serve_forever, daemon=True)
                worker.start()
                case = {"architecture": arch, "protocol": protocol, "interface": interface,
                        "success": False, "rounds_per_peer": 10, "bytes_per_file": len(payload)}
                report["cases"].append(case)
                save()
                started = time.monotonic()
                def transfer(peer, ip):
                    ticks = []
                    for turn in range(10):
                        tick = time.monotonic()
                        with OPENER.open(f"http://{ip}:18090/payload.bin", timeout=45) as response:
                            data = response.read()
                        assert len(data) == len(payload) and hashlib.sha256(data).hexdigest() == expected[peer.name]
                        remote_hash = peer.cmd(f"wget -qO {remote_dir}/received.bin -T 45 http://10.26.0.10:18093/payload.bin && sha256sum {remote_dir}/received.bin").split()[0]
                        assert remote_hash == payload_hash
                        ticks.append({"round": turn + 1, "sha256_both_directions": True,
                                      "seconds": round(time.monotonic() - tick, 3)})
                        delay = started + (turn + 1) * 6 - time.monotonic()
                        if delay > 0:
                            time.sleep(delay)
                    return {"peer": peer.name, "bytes": 20 * len(payload), "rounds": ticks}
                try:
                    with ThreadPoolExecutor(max_workers=6) as pool:
                        transfers = [pool.submit(transfer, peer, f"10.26.0.{i + 2}") for i, peer in enumerate(peers)]
                        pings = [pool.submit(win_ping, f"10.26.0.{i + 2}", 60) for i in range(2)]
                        reverse = [pool.submit(peer.cmd, "ping -c 60 -i 1 -W 3 -s 1300 10.26.0.10", 240) for peer in peers]
                        case["transfers"] = [future.result() for future in transfers]
                        case["windows_ping"] = [future.result() for future in pings]
                        case["arm_ping"] = [future.result() for future in reverse]
                        assert all(", 0% packet loss" in text for text in case["arm_ping"])
                    case.update(success=True, elapsed_seconds=round(time.monotonic() - started, 3), status=api("/status"))
                    assert case["status"]["phase"] == "running" and case["status"]["online_peer_count"] >= 2
                    save()
                    print(f"PASS {arch} {protocol}: 40MiB SHA-256 verified, four ping paths zero loss", flush=True)
                finally:
                    server.shutdown()
                    server.server_close()
                    worker.join(5)
        api("/profiles/win-aarch64-tcp/connect", "POST")
        wait("final ARM64 connection", lambda: api("/status")["phase"] == "running")
        final_interface = firewall()
        powershell(f"Get-NetFirewallRule -Group '{GROUP}' | Where-Object DisplayName -Like '*-File' | Remove-NetFirewallRule")
        report.update(success=True, total_transfer_bytes=sum(d["bytes"] for case in report["cases"] for d in case["transfers"]),
                      final_status=api("/status"), firewall_group=GROUP, final_interface=final_interface)
        save()
        PROCESS["firewall_group"] = GROUP
        (OUT / "process.json").write_text(json.dumps(PROCESS, ensure_ascii=False, indent=2), encoding="utf-8")
        print("ALL_WINDOWS_ARM_TESTS_PASSED", flush=True)
    except Exception as error:
        report["error"] = str(error)
        save()
        raise
    finally:
        for peer in remotes:
            if peer.name in helper_pids:
                try:
                    peer.cmd(f"if grep -q '{remote_dir}/http' /proc/{helper_pids[peer.name]}/cmdline 2>/dev/null; then kill {helper_pids[peer.name]}; fi; rm -f {remote_dir}/http {remote_dir}/payload.bin {remote_dir}/received.bin {remote_dir}/http.log {remote_dir}/http.pid; rmdir {remote_dir}")
                except Exception:
                    pass
            peer.ssh.close()


if __name__ == "__main__":
    main()
