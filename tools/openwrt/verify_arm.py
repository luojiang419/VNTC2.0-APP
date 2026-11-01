#!/usr/bin/env python3
"""在官方 OpenWrt ARM 虚拟机内验证 VNTS 与 VNTC 的真实安装和数据面。"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
import tomllib
import urllib.error
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vntc_vm", ROOT / "VntcApp1.0/openwrt/verify_vm.py")
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
run, wait_for = legacy.run, legacy.wait_for
VERSION = "24.10.5"
PLATFORMS = {
    "aarch64": ("armv8", "qemu-system-aarch64", "cortex-a53", "aarch64_generic", "aarch64"),
    "armv7": ("armv7", "qemu-system-arm", "cortex-a15", "arm_cortex-a15_neon-vfpv4", "armv7l"),
}


def images(arch, cache):
    subtarget = PLATFORMS[arch][0]
    base = f"https://downloads.openwrt.org/releases/{VERSION}/targets/armsr/{subtarget}/"
    cache = cache / subtarget
    cache.mkdir(parents=True, exist_ok=True)
    sums = cache / "sha256sums"
    content = sums.read_bytes() if sums.exists() else legacy.fetch(base + "sha256sums", sums)
    hashes = {name: digest for digest, name in re.findall(r"^([0-9a-f]{64}) [ *](.+)$", content.decode(), re.M)}
    prefix = f"openwrt-{VERSION}-armsr-{subtarget}-generic"
    names = [prefix + "-kernel.bin", prefix + "-ext4-rootfs.img.gz",
             next(name for name in hashes if "/kmod-tun_" in name)]
    paths = []
    for name in names:
        path = cache / Path(name).name
        data = path.read_bytes() if path.exists() else legacy.fetch(base + name, path)
        assert hashlib.sha256(data).hexdigest() == hashes[name], f"SHA-256 不匹配：{name}"
        paths.append(path)
    return paths, {name: hashes[name] for name in names}


class ARMVM(legacy.VM):
    def __init__(self, arch, index, folder, key, kernel, rootfs, port_base):
        self.arch, self.index, self.port_base = arch, index, port_base
        super().__init__(f"{arch}-{index}", index, folder, key, kernel, rootfs)
        self.ssh_port = port_base + index
        self.web_port = port_base + 10 + index
        self.server_port = port_base + 20
        self.server_web_port = port_base + 21

    def connect(self):
        # ARM32 在本机 TCG 中热重启已进入新内核，但完整用户态恢复可能超过三分钟。
        super().connect(timeout=420 if self.arch == "armv7" else 180)

    def stop(self):
        # 正常结束先刷盘，避免将 QEMU 直接退出变成未声明的安装后断电测试。
        if self.ssh is not None:
            try:
                self.cmd("sync", check=False, record=False, timeout=30)
            except Exception:
                pass
        super().stop()

    def prepare(self, rootfs):
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        self.root.write_bytes(decoder.decompress(rootfs.read_bytes()))
        assert decoder.eof, "不完整的 rootfs gzip"
        with self.root.open("ab") as image:
            image.truncate(384 * 1024 * 1024)
        result = subprocess.run(["e2fsck", "-fy", str(self.root)], capture_output=True)
        assert result.returncode in (0, 1), result.stderr.decode()
        run(["resize2fs", str(self.root)])
        network = self.folder / f"{self.name}-network"
        network.write_text("config interface 'loopback'\n option device 'lo'\n option proto 'static'\n"
                           " option ipaddr '127.0.0.1'\n option netmask '255.0.0.0'\n"
                           "config interface 'lan'\n option device 'eth0'\n option proto 'dhcp'\n")
        commands = self.folder / f"{self.name}-debugfs"
        commands.write_text(f"mkdir /etc/dropbear\nwrite {self.key}.pub /etc/dropbear/authorized_keys\n"
                            "set_inode_field /etc/dropbear/authorized_keys mode 0100600\n"
                            f"rm /etc/config/network\nwrite {network} /etc/config/network\n")
        run(["debugfs", "-w", "-f", str(commands), str(self.root)])

    def start(self):
        _, executable, cpu, _, _ = PLATFORMS[self.arch]
        assert not self.pidfile.exists()
        net = (f"user,id=net0,hostfwd=tcp:127.0.0.1:{self.ssh_port}-:22,"
               f"hostfwd=tcp:127.0.0.1:{self.web_port}-:18080")
        if self.index == 0:
            net += (f",hostfwd=tcp:127.0.0.1:{self.server_port}-:29872,"
                    f"hostfwd=udp:127.0.0.1:{self.server_port}-:29872,"
                    f"hostfwd=tcp:127.0.0.1:{self.server_web_port}-:29871")
        machine = "virt,accel=tcg" + (",virtualization=on" if self.arch == "armv7" else "")
        run([executable, "-name", f"vnt-arm-{self.name}", "-machine", machine,
             "-cpu", cpu, "-m", "256", "-smp", "1", "-display", "none", "-daemonize",
             "-pidfile", str(self.pidfile), "-serial", f"file:{self.serial}",
             "-kernel", str(self.kernel), "-append", "root=/dev/vda rootwait console=ttyAMA0,115200",
             "-drive", f"file={self.root},format=raw,if=none,id=rootfs",
             "-device", "virtio-blk-device,drive=rootfs", "-netdev", net,
             "-device", "virtio-net-device,netdev=net0"])
        self.connect()

    def server_api(self, path, data=None, token=None, expected=200):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(f"http://127.0.0.1:{self.server_web_port}{path}",
                                         data=None if data is None else json.dumps(data).encode(), headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        body = response.read().decode()
        assert response.code == expected, f"VNTS {path}: HTTP {response.code} {body[:200]}"
        return json.loads(body) if response.headers.get("Content-Type", "").startswith("application/json") else body

    def reboot(self):
        boot_id = self.cmd("cat /proc/sys/kernel/random/boot_id").strip()
        pid = int(self.pidfile.read_text())
        self.cmd("sync; (sleep 1; reboot) >/dev/null 2>&1 &")
        self.ssh.close()
        time.sleep(8)
        self.connect()
        new_id = self.cmd("cat /proc/sys/kernel/random/boot_id").strip()
        assert boot_id != new_id and int(self.pidfile.read_text()) == pid
        return {"previous_boot_id": boot_id, "new_boot_id": new_id, "qemu_pid_unchanged": pid}


def finish_lifecycle(machines, args, passed, client_hash, server_hash, data_plane):
    a, b = machines
    reboot = a.reboot()
    wait_for("重启自动组网", a.running, 180)
    data_plane()
    assert a.snapshot() == client_hash
    assert a.cmd("sha256sum /etc/vnts2/config.toml") == server_hash
    passed("真实客户机热重启、自启、配置保留和双向通信", **reboot)
    rss = {}
    for vm in machines:
        rss[vm.name] = vm.cmd("for p in $(pidof vntc-openwrt vnts2-openwrt); do grep -E '^(Name|VmRSS|VmHWM|Threads):' /proc/$p/status; done; grep -E '^(MemTotal|MemAvailable|SwapTotal):' /proc/meminfo")
    passed("256MiB 无 swap 内存快照", samples=rss)
    # 在节点 A 验证真实卸载和离线重装，业务目录保持原样。
    a.upload(args.client_portable, "/tmp/client.tar.gz")
    a.upload(args.server_portable, "/tmp/server.tar.gz")
    a.cmd("opkg remove vnts2-openwrt vntc-openwrt")
    assert a.snapshot() == client_hash
    assert a.cmd("sha256sum /etc/vnts2/config.toml") == server_hash
    a.cmd("mkdir -p /tmp/portable; tar xzf /tmp/client.tar.gz -C /tmp/portable; tar xzf /tmp/server.tar.gz -C /tmp/portable")
    a.cmd("cd /tmp/portable/VNTS_OpenWrt_* && sh install.sh")
    a.cmd("cd /tmp/portable/VNTC_OpenWrt_* && sh install.sh")
    wait_for("离线安装重连", a.running)
    data_plane()
    assert a.snapshot() == client_hash
    assert a.cmd("sha256sum /etc/vnts2/config.toml") == server_hash
    a.cmd("cd /tmp/portable/VNTS_OpenWrt_* && sh uninstall.sh && sh install.sh")
    a.cmd("cd /tmp/portable/VNTC_OpenWrt_* && sh uninstall.sh && sh install.sh")
    wait_for("离线卸载重装恢复", a.running)
    data_plane()
    passed("IPK 卸载、离线安装与离线卸载重装保留全部业务配置")


def resume_run(args):
    folder = args.resume_run.resolve()
    report_path = folder / "report.json"
    report = json.loads(report_path.read_text())
    assert report["architecture"] == args.arch and not report["success"]
    assert len(report["checks"]) >= 8 and all(check["passed"] for check in report["checks"])
    for name, evidence in report["packages"].items():
        assert hashlib.sha256(getattr(args, name).read_bytes()).hexdigest() == evidence["sha256"], "接力禁止更换未验收的安装包"
    suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    shutil.copy2(report_path, folder / f"previous-report-{suffix}.json")
    report.pop("error", None)
    report["resumed_at"] = datetime.now(timezone.utc).isoformat()
    report["resume_reason"] = "保留已完成阶段；ARMv7 virt 启用 virtualization=on，SSH 等待适配 TCG 慢启动；独立热重启已通过"
    def save():
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    def passed(name, **details):
        report["checks"] = [check for check in report["checks"] if check["name"] != name]
        report["checks"].append({"name": name, "passed": True, **details})
        save()
        print(f"PASS {args.arch}: {name}", flush=True)
    machines = []
    paths, _ = images(args.arch, args.work_dir.parent / "downloads")
    try:
        for index in range(2):
            vm = ARMVM(args.arch, index, folder, folder / "id_ed25519", paths[0], None,
                       23100 if args.arch == "aarch64" else 23200)
            vm.serial = folder / f"{vm.name}-resume-{suffix}-serial.log"
            vm.transcript = folder / f"{vm.name}-resume-{suffix}-commands.log"
            machines.append(vm)
            vm.start()
            wait_for("接力客户端启动", vm.healthy)
            vm.token = json.loads(vm.cmd("cat /etc/vntc/config.json", record=False))["web"]["access_token"]
            wait_for("接力自动组网", vm.running, 180)
        a, b = machines
        def data_plane():
            for vm, ip in ((a, "10.26.0.3"), (b, "10.26.0.2")):
                def ready():
                    output = vm.cmd(f"ping -c 3 -W 3 -s 1300 {ip}", timeout=30)
                    return output if re.search(r", 0(?:\.0+)?% packet loss", output) else None
                wait_for("接力双向大包", ready)
                assert json.loads(vm.cmd(f"wget -qO- -T 15 http://{ip}:18080/api/health"))["message"] == "ok"
        data_plane()
        client_hash = a.snapshot()
        server_hash = a.cmd("sha256sum /etc/vnts2/config.toml")
        passed("保留磁盘接力冷启动、自动组网和双向通信")
        finish_lifecycle(machines, args, passed, client_hash, server_hash, data_plane)
        report["success"] = True
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        save()
        print(f"REPORT {report_path}", flush=True)
    except Exception as error:
        report["error"] = str(error)
        save()
        raise
    finally:
        if not args.keep_running or not report["success"]:
            for vm in machines:
                vm.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=PLATFORMS, required=True)
    parser.add_argument("--client-package", type=Path)
    parser.add_argument("--server-package", type=Path)
    parser.add_argument("--client-portable", type=Path)
    parser.add_argument("--server-portable", type=Path)
    parser.add_argument("--work-dir", type=Path, default=Path.home() / ".cache/vnt-openwrt/arm-vm")
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--resume-run", type=Path, help="从已完成安装与数据面检查的隔离 VM 目录继续；禁止更换包")
    args = parser.parse_args()
    paths, image_hashes = images(args.arch, args.work_dir.parent / "downloads")
    if args.download_only:
        print(json.dumps(image_hashes, indent=2), flush=True)
        return
    for name in ("client_package", "server_package", "client_portable", "server_portable"):
        path = getattr(args, name)
        if path is None or not path.is_file():
            parser.error(f"缺少有效的 --{name.replace('_', '-')}")
    if args.resume_run:
        resume_run(args)
        return
    port_base = 23100 if args.arch == "aarch64" else 23200
    for port in (port_base, port_base + 1, port_base + 10, port_base + 11, port_base + 20, port_base + 21):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", port))
    folder = args.work_dir / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + args.arch)
    folder.mkdir(parents=True, mode=0o700)
    report = {"architecture": args.arch, "openwrt_version": VERSION, "memory_mib": 256,
              "images": image_hashes, "checks": [], "success": False,
              "packages": {name: {"file": str(getattr(args, name)), "sha256": hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
                           for name in ("client_package", "server_package", "client_portable", "server_portable")}}
    def save():
        (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    def passed(name, **details):
        report["checks"].append({"name": name, "passed": True, **details})
        save()
        print(f"PASS {args.arch}: {name}", flush=True)
    machines = []
    try:
        key = folder / "id_ed25519"
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
        kernel, rootfs, tun = paths
        for index in range(2):
            vm = ARMVM(args.arch, index, folder, key, kernel, rootfs, port_base)
            machines.append(vm)
            vm.start()
            assert PLATFORMS[args.arch][4] in vm.cmd("uname -m")
            assert PLATFORMS[args.arch][3] in vm.cmd("opkg print-architecture")
            vm.upload(tun, "/tmp/tun.ipk")
            vm.cmd("opkg install /tmp/tun.ipk && modprobe tun && test -c /dev/net/tun")
            vm.upload(args.client_package, "/tmp/vntc.ipk")
            vm.cmd("opkg install /tmp/vntc.ipk && /etc/init.d/vntc enabled")
            wait_for("客户端健康检查", vm.healthy)
            conf = json.loads(vm.cmd("cat /etc/vntc/config.json", record=False))
            vm.token = conf["web"]["access_token"]
            vm.api("/api/status", authenticated=False, expected=401)
            assert "html" in vm.api("/", authenticated=False).lower()
            passed(f"节点 {index + 1} 原生 ARM IPK 安装、鉴权和 TUN")
        a, b = machines
        other_arch = "armv7" if args.arch == "aarch64" else "aarch64"
        other_dir = args.client_package.parent.parent / other_arch
        other_packages = list(other_dir.glob("vntc-openwrt_*.ipk"))
        if len(other_packages) == 1:
            b.upload(other_packages[0], "/tmp/wrong-arch.ipk")
            b.cmd("if opkg --force-reinstall install /tmp/wrong-arch.ipk >/tmp/wrong-arch.log 2>&1; then cat /tmp/wrong-arch.log; exit 1; else cat /tmp/wrong-arch.log; fi")
            wait_for("错误架构拒绝后客户端仍正常", b.healthy)
            passed("opkg 拒绝另一 CPU 架构的安装包")
        a.upload(args.server_package, "/tmp/vnts.ipk")
        a.cmd("opkg install /tmp/vnts.ipk && /etc/init.d/vnts2 enabled")
        wait_for("VNTS Web", lambda: a.server_api("/api/status", expected=401))
        credentials = tomllib.loads(a.cmd("cat /etc/vnts2/config.toml", record=False))
        def server_login():
            return a.server_api("/api/login", {"username": credentials["username"], "password": credentials["password"]})["data"]["token"]
        token = server_login()
        assert a.server_api("/api/status", token=token)["code"] == 200
        assert "html" in a.server_api("/").lower()
        assert a.cmd("ls -ld /etc/vnts2/config.toml").split()[0] == "-rw-------"
        passed("原生 ARM VNTS 安装、随机密码、管理鉴权和内嵌页面")
        def connect_clients(protocol="quic"):
            for index, vm in enumerate(machines):
                vnt = vm.api("/api/config")
                vnt.update(server_addresses=[f"{protocol}://10.0.2.2:{a.server_port}"],
                           network_code="arm-vm-" + folder.name, device_name=f"{args.arch}-{index}",
                           virtual_ip=f"10.26.0.{index + 2}", channel_mode="relay_only", password="vm-test-only")
                vm.api("/api/config", "PUT", vnt)
                settings = vm.api("/api/settings")
                settings["auto_connect"] = True
                vm.api("/api/settings", "PUT", settings)
                vm.api("/api/start", "POST")
                wait_for("ARM VNTS 注册", vm.running, 180)
        def ping(vm, ip, size=1300):
            return vm.cmd(f"ping -c 3 -W 3 -s {size} {ip}", timeout=30)
        def data_plane():
            def ready(vm, ip):
                output = ping(vm, ip)
                return output if re.search(r", 0(?:\.0+)?% packet loss", output) else None
            wait_for("A -> B", lambda: ready(a, "10.26.0.3"), 120)
            wait_for("B -> A", lambda: ready(b, "10.26.0.2"), 120)
            for vm, ip in ((a, "10.26.0.3"), (b, "10.26.0.2")):
                assert json.loads(vm.cmd(f"wget -qO- -T 15 http://{ip}:18080/api/health"))["message"] == "ok"
        connect_clients()
        data_plane()
        passed("ARM 服务端 + 双 ARM 客户端 QUIC 中继、双向 1300 字节大包与 TCP HTTP")
        for vm in machines:
            vm.api("/api/stop", "POST")
        connect_clients("tcp")
        data_plane()
        passed("TLS/TCP 协议注册和双向数据面")
        devices_path = "/api/devices?code=arm-vm-" + folder.name
        assert len(a.server_api(devices_path, token=token)["data"]) >= 2
        a.cmd("test -s /etc/vnts2/network_control.db; test ! -d /etc/vnts2/logs")
        client_hash = a.snapshot()
        server_hash = a.cmd("sha256sum /etc/vnts2/config.toml")
        a.cmd("opkg --force-reinstall install /tmp/vnts.ipk /tmp/vntc.ipk")
        assert a.snapshot() == client_hash
        assert a.cmd("sha256sum /etc/vnts2/config.toml") == server_hash
        wait_for("重装自连", a.running)
        data_plane()
        token = server_login()
        assert len(a.server_api(devices_path, token=token)["data"]) >= 2
        passed("重装保留密码、客户端配置和 SQLite 节点数据，无闪存日志目录")
        old = a.cmd("pidof vnts2-openwrt").strip()
        a.cmd("kill -9 $(pidof vnts2-openwrt)")
        wait_for("procd 服务端恢复", lambda: a.cmd("pidof vnts2-openwrt").strip() not in ("", old))
        data_plane()
        old = b.cmd("pidof vntc-openwrt").strip()
        b.cmd("kill -9 $(pidof vntc-openwrt)")
        wait_for("procd 客户端恢复", lambda: b.cmd("pidof vntc-openwrt").strip() not in ("", old))
        wait_for("客户端重连", b.running)
        data_plane()
        passed("procd 服务端和客户端崩溃恢复")
        finish_lifecycle(machines, args, passed, client_hash, server_hash, data_plane)
        report["success"] = True
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        save()
        print(f"REPORT {folder / 'report.json'}", flush=True)
    except Exception as error:
        report["error"] = str(error)
        save()
        raise
    finally:
        if not args.keep_running or not report["success"]:
            for vm in machines:
                vm.stop()


if __name__ == "__main__":
    main()
