#!/usr/bin/env python3
"""复用本机 OpenWrt VM，验证无 VNT 的 LAN 终端、子网转发及监控服务。"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import logging
from pathlib import Path
import secrets
import shlex
import threading
import time
import urllib.error
import urllib.request

import paramiko

ROOT = Path(__file__).resolve().parents[2]
DEPLOY = ROOT / "dist/openwrt-gateway"
UNC = Path(r"\\wsl.localhost\Ubuntu\home\luo\.cache\vnt-openwrt\arm-vm")
FOLDERS = {"aarch64": "20261101T133738Z-aarch64", "armv7": "20261101T134003Z-armv7", "x86_64": None}
PORT_BASE = {"aarch64": 23100, "armv7": 23200, "x86_64": 23500}
logging.getLogger("paramiko.transport").setLevel(logging.CRITICAL)
FIXTURE = "/opt/vntc-gateway-test"
HTTP = FIXTURE + "/http"
PROBE = FIXTURE + "/probe"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def wait(label, function, seconds=180):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            value = function()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(2)
    raise AssertionError(f"{label}: {last}")


class Node:
    def __init__(self, arch, index, log):
        self.arch, self.index, self.log = arch, index, log
        self.port = PORT_BASE[arch] + index
        self.local = "192.168.50" if index == 0 else "192.168.60"
        self.remote = "192.168.60" if index == 0 else "192.168.50"
        self.virtual = f"10.26.0.{index + 2}"
        self.peer = f"10.26.0.{3 - index}"
        if arch == "x86_64":
            self.folder = json.loads((DEPLOY / "live/x86_64-runtime.json").read_text(encoding="utf-8"))["folder"]
            access_path = DEPLOY / "live/x86_64-access.json"
        else:
            self.folder = FOLDERS[arch]
            access_path = ROOT / "dist/openwrt-arm/live" / (arch + "-access.json")
        access = json.loads(access_path.read_text(encoding="utf-8"))
        self.access = access["vntc"][index]
        self.connect()

    def connect(self):
        if getattr(self, "ssh", None):
            self.ssh.close()
        self.ssh = paramiko.SSHClient()
        self.ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.ssh.connect("127.0.0.1", port=self.port, username="root",
            key_filename=str(UNC / self.folder / "id_ed25519"),
            look_for_keys=False, allow_agent=False, timeout=8)

    def cmd(self, command, timeout=120, ok=True):
        channel = self.session(command, timeout)
        out, err = channel.makefile("rb"), channel.makefile_stderr("rb")
        value = out.read().decode(errors="replace") + err.read().decode(errors="replace")
        code = out.channel.recv_exit_status()
        with self.log.open("a", encoding="utf-8") as f:
            f.write(f"$ {command}\n{value}\n[exit={code}]\n")
        if ok:
            assert code == 0, f"{self.arch}/{self.index}: {command}: {value}"
        return value if ok else (code, value)

    def session(self, command, timeout):
        channel = self.ssh.get_transport().open_session(timeout=timeout)
        channel.settimeout(timeout)
        errors = []
        def request():
            try:
                channel.exec_command(command)
            except Exception as error:
                errors.append(error)
        worker = threading.Thread(target=request, daemon=True)
        worker.start()
        worker.join(min(timeout, 30))
        if worker.is_alive():
            channel.close()
            raise TimeoutError("SSH exec request was not acknowledged: " + command)
        if errors:
            channel.close()
            raise errors[0]
        return channel

    def upload(self, content, dest):
        channel = self.session("cat > " + shlex.quote(dest), 120)
        channel.sendall(content)
        channel.shutdown_write()
        code = channel.recv_exit_status()
        assert code == 0, channel.recv_stderr(4096).decode(errors="replace")
        channel.close()

    def api(self, path, method="GET", data=None, expected=200):
        req = urllib.request.Request(self.access["url"] + "api" + path, method=method,
            data=None if data is None else json.dumps(data).encode(),
            headers={"Authorization": "Bearer " + self.access["access_token"],
                     "Content-Type": "application/json"})
        try:
            response = OPENER.open(req, timeout=120)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = json.load(response)
            assert response.status == expected, (response.status, body)
            return body

    def ns(self, command, **kwargs):
        return self.cmd("ip netns exec vntc_lan sh -c " + shlex.quote(command), **kwargs)

    def running(self):
        return self.api("/status")["phase"] == "running"

    def install(self, package, video):
        self.cmd("if [ -x /etc/init.d/vntc-lan-test ]; then "
            "grep -q 'VNT isolated LAN test fixture' /etc/init.d/vntc-lan-test || exit 1; "
            "/etc/init.d/vntc-lan-test stop; fi")
        self.cmd("test -f /root/vntc-gateway-backup/config.json || "
            "{ mkdir -p /root/vntc-gateway-backup; chmod 700 /root/vntc-gateway-backup; "
            "cp /etc/vntc/config.json /etc/vntc/profiles.json /etc/config/firewall /root/vntc-gateway-backup/; }")
        self.upload(package.read_bytes(), "/tmp/vntc-gateway.ipk")
        self.cmd("opkg --force-reinstall install /tmp/vntc-gateway.ipk", timeout=180)
        wait("upgraded WebUI", lambda: self.api("/health"))
        self.api("/stop", "POST")
        conf = self.api("/config")
        conf.update(virtual_ip=self.virtual, input_routes=[self.remote + ".0/24=" + self.peer],
                    output_routes=[self.local + ".0/24"], no_nat=True)
        self.api("/config", "PUT", conf)
        self.cmd("mkdir -p " + FIXTURE)
        helper = DEPLOY / self.arch / "gateway-http"
        self.upload(helper.read_bytes(), HTTP)
        self.upload((DEPLOY / self.arch / "gateway-probe").read_bytes(), PROBE)
        payload = secrets.token_bytes(256 * 1024)
        self.payload_hash = hashlib.sha256(payload).hexdigest()
        self.upload(payload, FIXTURE + "/payload.bin")
        self.upload(video, FIXTURE + "/video.h264")
        self.cmd(f"chmod 700 {HTTP} {PROBE}")
        script = f"""#!/bin/sh /etc/rc.common
# VNT isolated LAN test fixture; not part of the client package.
START=90
USE_PROCD=1
start_service() {{
    ip netns list | grep -q '^vntc_lan' || ip netns add vntc_lan
    if ! ip link show vntlan >/dev/null 2>&1; then
        ip link add vntlan type veth peer name vntc_peer
        ip link set vntc_peer netns vntc_lan
        ip -n vntc_lan link set vntc_peer name lan0
    fi
    ip addr replace {self.local}.1/24 dev vntlan
    ip link set vntlan up
    ip -n vntc_lan addr replace {self.local}.100/24 dev lan0
    ip -n vntc_lan link set lo up
    ip -n vntc_lan link set lan0 up
    ip -n vntc_lan route replace default via {self.local}.1
    procd_open_instance http
    procd_set_param command /sbin/ip netns exec vntc_lan {HTTP} 18090 {FIXTURE}/payload.bin 250000
    procd_set_param respawn
    procd_close_instance
    procd_open_instance udp
    procd_set_param command /sbin/ip netns exec vntc_lan {PROBE} udp-server 18092
    procd_set_param respawn
    procd_close_instance
    procd_open_instance rtsp
    procd_set_param command /sbin/ip netns exec vntc_lan {PROBE} rtsp-server 8554 {FIXTURE}/video.h264
    procd_set_param respawn
    procd_close_instance
}}
"""
        self.upload(script.encode(), "/etc/init.d/vntc-lan-test")
        self.cmd("chmod 755 /etc/init.d/vntc-lan-test; /etc/init.d/vntc-lan-test enable; /etc/init.d/vntc-lan-test restart")
        gateway = f"""config gateway 'main'
 option enabled '1'
 option lan_zone 'lan'
 option lan_cidr '{self.local}.0/24'
 option overlay_cidr '10.26.0.0/24'
 list remote_cidr '{self.remote}.0/24'
"""
        for name, proto, listen, target in (("http", "tcp", 18081, 18090), ("video", "tcp", 18554, 8554), ("udp", "udp", 18082, 18092)):
            gateway += f"\nconfig service '{name}'\n option proto '{proto}'\n option listen_port '{listen}'\n option dest_ip '{self.local}.100'\n option dest_port '{target}'\n"
        self.upload(gateway.encode(), "/etc/config/vntc_gateway")
        self.cmd("test \"$(uci get firewall.@zone[0].name)\" = lan; "
            "uci -q del_list firewall.@zone[0].device=vntlan || true; "
            "uci add_list firewall.@zone[0].device=vntlan; uci commit firewall; "
            "/usr/libexec/vntc-gateway apply; /etc/init.d/firewall reload")
        self.api("/start", "POST")
        wait("gateway registration", self.running)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=FOLDERS, required=True)
    parser.add_argument("--skip-deploy", action="store_true")
    parser.add_argument("--finish-only", action="store_true", help="包哈希不变且两组数据面已通过时，仅续测边界与重启")
    args = parser.parse_args()
    folder = DEPLOY / "validation" / args.arch
    folder.mkdir(parents=True, exist_ok=True)
    report_path = folder / "report.json"
    report = {"architecture": args.arch, "checks": [], "cases": [], "success": False}
    if args.finish_only:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        assert len(report["cases"]) == 2 and all(c["success"] for c in report["cases"])
        report.pop("error", None)
        report["success"] = False
    def save():
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    def passed(name, **evidence):
        report["checks"] = [c for c in report["checks"] if c["name"] != name]
        report["checks"].append({"name": name, "passed": True, **evidence})
        save()
        print(f"PASS {args.arch}: {name}", flush=True)
    nodes = [Node(args.arch, i, folder / f"node-{i}.log") for i in range(2)]
    video = (ROOT / "tmp/gateway-video.h264").read_bytes()
    video_hash = hashlib.sha256(video).hexdigest()
    try:
        package = next((DEPLOY / args.arch).glob("vntc-openwrt_*-2_*.ipk"))
        digest = hashlib.sha256(package.read_bytes()).hexdigest()
        if args.finish_only:
            assert report["package_sha256"] == digest, "接力禁止替换未验收的包"
        report["package_sha256"] = digest
        for node in nodes:
            if not (args.skip_deploy or args.finish_only):
                node.install(package, video)
            else:
                node.payload_hash = node.cmd("sha256sum " + FIXTURE + "/payload.bin").split()[0]
                wait("resumed WebUI", lambda n=node: n.api("/health"))
                wait("resumed VNT", node.running)
        passed("部署网关版、两个独立 LAN 网络命名空间及无 VNT 的服务终端")
        for node in nodes:
            devices = node.ns("ip -o link; ip route")
            assert "vnt0" not in devices and "default via " + node.local + ".1" in devices
            local = node.ns(f"wget -qO- -T 5 http://{node.local}.1:18080/api/health")
            assert json.loads(local)["message"] == "ok"
            node.cmd("cp /etc/config/firewall /tmp/vntcg-expected; /usr/libexec/vntc-gateway apply; cmp /etc/config/firewall /tmp/vntcg-expected")
        passed("终端只有 LAN 与默认网关，访问本地路由器正常；规则重复应用无变化")
        for protocol in (() if args.finish_only else ("tcp", "quic")):
            print(f"CONNECT {args.arch} {protocol}", flush=True)
            for node in nodes:
                node.api("/stop", "POST")
                assert "186" not in node.cmd("ip route show proto 186")
                config = node.api("/config")
                config["server_addresses"] = [f"{protocol}://10.0.2.2:{PORT_BASE[args.arch] + 20}"]
                node.api("/config", "PUT", config)
                node.api("/start", "POST")
                wait("registered", node.running)
                assert node.remote + ".0/24" in node.cmd("ip route show proto 186")
            for node in nodes:
                wait("LAN to peer", lambda n=node: n.ns(f"ping -c 3 -W 3 -s 1300 {n.peer}"), 120)
            before = {n.index: n.cmd("pidof vntc-openwrt vnts2-openwrt").strip() for n in nodes}
            case = {"protocol": protocol, "success": False, "directions": []}
            report["cases"].append(case)
            save()
            started = time.monotonic()
            def transfer(node):
                peer = nodes[1 - node.index]
                checks = []
                for turn in range(3):
                    for address, port, route in ((peer.local + ".100", 18090, "remote_lan"), (peer.virtual, 18081, "virtual_ip_port")):
                        result = node.ns(f"wget -qO /tmp/vntcg-http-{route} -T 30 http://{address}:{port}/payload.bin && sha256sum /tmp/vntcg-http-{route}")
                        assert result.split()[0] == peer.payload_hash
                    checks.append({"round": turn + 1, "two_files_sha256": True})
                return {"source_lan": node.local + ".100", "file_bytes": 6 * 256 * 1024, "checks": checks}
            def stream(node, mapped):
                peer = nodes[1 - node.index]
                ip, port = (peer.virtual, 18554) if mapped else (peer.local + ".100", 8554)
                path = f"/tmp/vntcg-video-{int(mapped)}.h264"
                text = node.ns(f"{PROBE} rtsp-get {ip} {port} {path} && sha256sum {path}", timeout=100)
                assert video_hash in text and "RTSP_PASS" in text, text
                return {"source": node.local + ".100", "destination": f"rtsp://{ip}:{port}/live", "sha256": video_hash, "rtp_result": text}
            def udp(node, mapped):
                peer = nodes[1 - node.index]
                ip, port = (peer.virtual, 18082) if mapped else (peer.local + ".100", 18092)
                # 每包仍由探针独立校验并限制接收等待；总时限需容纳 TCG 调度延迟。
                return node.ns(f"{PROBE} udp-client {ip} {port} 60", timeout=180)
            with ThreadPoolExecutor(max_workers=12) as pool:
                transfers = [pool.submit(transfer, n) for n in nodes]
                datagrams = [pool.submit(udp, n, mapped) for n in nodes for mapped in (False, True)]
                pings = [pool.submit(n.ns, f"ping -c 80 -i 1 -W 5 -s 1300 {n.peer}", timeout=180) for n in nodes]
                case["directions"] = [f.result() for f in transfers]
                # 避免用单 vCPU TCG 的无节制满速下载遮蔽转发功能验收。
                # 文件源限速约 64KiB/s；视频分别验证两条双向通路，UDP/ping 持续并发。
                case["streams"] = []
                for mapped in (False, True):
                    streams = [pool.submit(stream, n, mapped) for n in nodes]
                    case["streams"].extend(f.result() for f in streams)
                case["udp"] = [f.result() for f in datagrams]
                case["pings"] = [f.result() for f in pings]
                assert all(", 0% packet loss" in text for text in case["pings"])
            assert before == {n.index: n.cmd("pidof vntc-openwrt vnts2-openwrt").strip() for n in nodes}
            case.update(success=True, elapsed_seconds=round(time.monotonic() - started, 3))
            save()
            passed(protocol.upper() + "：双向 LAN/虚拟端口文件、RTSP 视频、UDP、大包及进程稳定性")
        a, b = nodes
        original = a.cmd("sha256sum /etc/config/firewall").split()[0]
        a.cmd("uci set vntc_gateway.invalid=service; uci set vntc_gateway.invalid.proto=tcp; "
              "uci set vntc_gateway.invalid.listen_port=19000; uci set vntc_gateway.invalid.dest_port=80; "
              "uci set vntc_gateway.invalid.dest_ip=203.0.113.1; uci commit vntc_gateway")
        code, text = a.cmd("/usr/libexec/vntc-gateway apply", ok=False)
        assert code != 0 and original == a.cmd("sha256sum /etc/config/firewall").split()[0], text
        assert not a.cmd("uci changes firewall").strip()
        a.cmd("uci delete vntc_gateway.invalid; uci commit vntc_gateway; /usr/libexec/vntc-gateway apply")
        passed("拒绝映射到本地 LAN 以外的设备，失败时防火墙保持原样")
        b.cmd("uci set vntc_gateway.main.enabled=0; uci commit vntc_gateway; /usr/libexec/vntc-gateway apply")
        code, _ = b.ns("wget -qO /tmp/vntcg-disabled -T 3 http://10.26.0.2:18081/payload.bin", ok=False)
        assert code != 0
        assert json.loads(b.ns(f"wget -qO- -T 5 http://{b.local}.1:18080/api/health"))["message"] == "ok"
        b.cmd("uci set vntc_gateway.main.enabled=1; uci commit vntc_gateway; /usr/libexec/vntc-gateway apply")
        passed("关闭网关后远端访问被阻止、本地路由器仍可访问；重新启用成功")
        b.api("/stop", "POST")
        b.cmd(f"ip route add {b.remote}.0/24 dev eth0 proto 187")
        b.api("/start", "POST", expected=500)
        existing = b.cmd("ip route show proto 187")
        assert b.remote + ".0/24" in existing and "dev eth0" in existing
        b.cmd(f"ip route del {b.remote}.0/24 dev eth0 proto 187")
        b.api("/start", "POST")
        wait("route recovery", b.running)
        passed("已有系统路由冲突时拒绝启动且不覆盖；解除冲突后恢复")
        for n in nodes:
            n.cmd("/etc/init.d/firewall reload")
        before_boot = b.cmd("cat /proc/sys/kernel/random/boot_id").strip()
        qemu_pidfile = UNC / b.folder / f"{args.arch}-1.pid"
        before_qemu = qemu_pidfile.read_text().strip()
        b.cmd("sync; (sleep 1; reboot) >/dev/null 2>&1 &")
        b.ssh.close()
        time.sleep(12)
        def reboot_ready():
            b.connect()
            return b.cmd("cat /proc/sys/kernel/random/boot_id").strip() != before_boot
        wait("guest reboot SSH and new boot_id", reboot_ready, 420)
        assert qemu_pidfile.read_text().strip() == before_qemu
        wait("guest reboot VNT", b.running, 240)
        result = wait("guest reboot forwarding", lambda: b.ns(f"wget -qO /tmp/vntcg-after-boot -T 15 http://{a.virtual}:18081/payload.bin && sha256sum /tmp/vntcg-after-boot"), 180)
        assert result.split()[0] == a.payload_hash
        assert b.remote + ".0/24" in b.cmd("ip route show proto 186")
        report["reboot_method"] = "reboot"
        passed("真实 OpenWrt 热重启后 LAN、网关规则、输入路由及远端服务自动恢复", qemu_pid_unchanged=True, reboot_method="reboot")
        report["native_routes"] = {str(n.index): n.cmd("ip route; uci show firewall | grep vntcg_") for n in nodes}
        report.update(success=True, video_sha256=video_hash,
            total_file_bytes=sum(d["file_bytes"] for c in report["cases"] for d in c["directions"]))
        save()
        print("ALL_GATEWAY_TESTS_PASSED " + args.arch, flush=True)
    except Exception as error:
        report["success"] = False
        report["error"] = str(error)
        save()
        raise
    finally:
        for n in nodes:
            n.ssh.close()


if __name__ == "__main__":
    main()
