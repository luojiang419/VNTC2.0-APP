#!/usr/bin/env python3
"""在两台隔离 OpenWrt QEMU 虚拟机内验证实际安装包和 VNT 数据面。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import time
import urllib.error
import urllib.request
import zlib

import paramiko

# VM 引导期间 SSH 尚未就绪属于预期轮询，超时由 wait_for 统一报告。
logging.getLogger("paramiko.transport").setLevel(logging.CRITICAL)

VERSION = "24.10.5"
BASE = f"https://downloads.openwrt.org/releases/{VERSION}/targets/x86/64/"


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, capture_output=True, **kwargs).stdout


def wait_for(label, function, timeout=120):
    deadline, last = time.monotonic() + timeout, None
    while time.monotonic() < deadline:
        try:
            value = function()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(2)
    raise AssertionError(f"等待超时：{label}；最后错误：{last}")


def fetch(url, path):
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "VNTC-OpenWrt-VM-verifier"})
            with urllib.request.urlopen(request, timeout=60) as response:
                content = response.read()
            path.write_bytes(content)
            return content
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2)


def images(cache):
    cache.mkdir(parents=True, exist_ok=True)
    sums_path = cache / "sha256sums"
    sums = (sums_path.read_bytes() if sums_path.exists() else fetch(BASE + "sha256sums", sums_path)).decode()
    hashes = dict((name, digest) for digest, name in re.findall(r"^([0-9a-f]{64}) [ *](.+)$", sums, re.M))
    kernel_name = f"openwrt-{VERSION}-x86-64-generic-kernel.bin"
    rootfs_name = f"openwrt-{VERSION}-x86-64-generic-ext4-combined.img.gz"
    tun_name = next(name for name in hashes if "/kmod-tun_" in name)
    result = []
    for name in (kernel_name, rootfs_name, tun_name):
        path = cache / Path(name).name
        content = path.read_bytes() if path.exists() else fetch(BASE + name, path)
        assert hashlib.sha256(content).hexdigest() == hashes[name], f"镜像校验失败：{name}"
        result.append(path)
    return result, {name: hashes[name] for name in (kernel_name, rootfs_name, tun_name)}


class VM:
    def __init__(self, name, index, folder, key, kernel, rootfs):
        self.name, self.folder, self.key = name, folder, key
        self.ssh_port, self.web_port = 22022 + index, 18081 + index
        self.root = folder / f"{name}.img"
        self.pidfile = folder / f"{name}.pid"
        self.serial = folder / f"{name}-serial.log"
        self.transcript = folder / f"{name}-commands.log"
        self.kernel, self.ssh = kernel, None
        self.token = None
        self.host_key = None
        if rootfs is not None:
            self.prepare(rootfs)
        else:
            assert self.root.is_file(), "接力磁盘不存在"

    def prepare(self, rootfs):
        # 官方 combined.img.gz 在 gzip 数据后附加 fwtool 签名元数据。
        # 校验完整文件 SHA-256 后，只解压第一个 gzip 流（含 gzip CRC 校验）。
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        image_data = decoder.decompress(rootfs.read_bytes())
        assert decoder.eof, "OpenWrt 镜像 gzip 流不完整"
        self.root.write_bytes(image_data)
        del image_data
        with self.root.open("rb") as image:
            mbr = bytearray(image.read(512))
            assert mbr[510:512] == b"\x55\xaa", "要求带 BIOS 引导器的完整 OpenWrt 磁盘镜像"
            partitions = []
            for index in range(4):
                offset = 446 + index * 16
                start, sectors = struct.unpack_from("<II", mbr, offset + 8)
                if mbr[offset + 4] == 0x83:
                    partitions.append((sectors, start, offset))
            sectors, start, entry = max(partitions)
            partition = self.folder / f"{self.name}-rootfs.ext4"
            image.seek(start * 512)
            with partition.open("wb") as target:
                remaining = sectors * 512
                while remaining:
                    chunk = image.read(min(1024 * 1024, remaining))
                    assert chunk, "rootfs 分区不完整"
                    target.write(chunk)
                    remaining -= len(chunk)
        with partition.open("ab") as image:
            image.truncate(384 * 1024 * 1024)
        checked = subprocess.run(["e2fsck", "-fy", str(partition)], capture_output=True)
        assert checked.returncode in (0, 1), checked.stderr.decode()
        run(["resize2fs", str(partition)])
        # QEMU 用户网络只连接专用 eth0；不接触宿主和其他路由器的 LAN。
        network = self.folder / f"{self.name}-network"
        network.write_text("config interface 'loopback'\n option device 'lo'\n option proto 'static'\n"
                           " option ipaddr '127.0.0.1'\n option netmask '255.0.0.0'\n"
                           "config interface 'lan'\n option device 'eth0'\n option proto 'dhcp'\n")
        commands = self.folder / f"{self.name}-debugfs"
        commands.write_text(f"mkdir /etc/dropbear\nwrite {self.key}.pub /etc/dropbear/authorized_keys\n"
                            "set_inode_field /etc/dropbear/authorized_keys mode 0100600\n"
                            f"rm /etc/config/network\nwrite {network} /etc/config/network\n")
        run(["debugfs", "-w", "-f", str(commands), str(partition)])
        struct.pack_into("<I", mbr, entry + 12, partition.stat().st_size // 512)
        with self.root.open("r+b") as image, partition.open("rb") as source:
            image.write(mbr)
            image.seek(start * 512)
            shutil.copyfileobj(source, image)
            image.truncate()
        partition.unlink()

    def start(self):
        assert not self.pidfile.exists(), "禁止覆盖已运行 VM 的 PID 文件"
        run(["qemu-system-x86_64", "-name", f"vntc-{self.name}", "-machine", "pc,accel=tcg",
             "-cpu", "qemu64", "-m", "512", "-smp", "1", "-display", "none", "-daemonize",
             "-pidfile", str(self.pidfile), "-serial", f"file:{self.serial}",
             "-boot", "c",
             "-drive", f"file={self.root},format=raw,if=ide",
             "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{self.ssh_port}-:22,"
                        f"hostfwd=tcp:127.0.0.1:{self.web_port}-:18080",
             "-device", "e1000,netdev=net0"])
        self.connect()

    def connect(self, timeout=180):
        def connect_once():
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            try:
                client.connect("127.0.0.1", port=self.ssh_port, username="root", key_filename=str(self.key),
                               look_for_keys=False, allow_agent=False, timeout=4, banner_timeout=4, auth_timeout=4)
                fingerprint = client.get_transport().get_remote_server_key().asbytes()
                if self.host_key is not None:
                    assert self.host_key == fingerprint, "VM SSH 主机密钥意外变化"
                self.host_key = fingerprint
                self.ssh = client
                return True
            except Exception:
                client.close()
                raise
        wait_for(f"{self.name} SSH 启动", connect_once, timeout)

    def cmd(self, command, check=True, record=True, timeout=90):
        stdin, stdout, stderr = self.ssh.exec_command(command, timeout=timeout)
        stdin.close()
        output, error = stdout.read().decode(errors="replace"), stderr.read().decode(errors="replace")
        code = stdout.channel.recv_exit_status()
        if record:
            with self.transcript.open("a") as log:
                log.write(f"$ {command}\n{output}{error}\n[exit={code}]\n")
        if check and code:
            raise AssertionError(f"{self.name} 命令失败 {code}：{command}\n{output}{error}")
        return output

    def upload(self, source, remote):
        channel = self.ssh.get_transport().open_session(timeout=30)
        channel.settimeout(120)
        channel.exec_command("cat > " + shlex.quote(remote))
        with Path(source).open("rb") as data:
            while chunk := data.read(65536):
                channel.sendall(chunk)
        channel.shutdown_write()
        assert channel.recv_exit_status() == 0, f"上传失败：{remote}"
        channel.close()

    def api(self, path, method="GET", data=None, authenticated=True, expected=200):
        headers = {}
        if authenticated:
            headers["Authorization"] = f"Bearer {self.token}"
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"http://127.0.0.1:{self.web_port}{path}",
                                         data=None if data is None else json.dumps(data).encode(),
                                         headers=headers, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=45)
        except urllib.error.HTTPError as error:
            response = error
        content = response.read().decode()
        assert response.code == expected, f"{self.name} {method} {path}: HTTP {response.code} {content[:500]}"
        return json.loads(content) if response.headers.get("Content-Type", "").startswith("application/json") else content

    def healthy(self):
        return self.api("/api/health", authenticated=False)

    def running(self):
        state = self.api("/api/status")
        return state if state["phase"] == "running" and state.get("connected_server") else None

    def snapshot(self):
        return self.cmd("sha256sum /etc/vntc/config.json /etc/vntc/profiles.json /etc/vntc/settings.json")

    def stop(self):
        if self.ssh:
            self.ssh.close()
        if self.pidfile.exists():
            pid = int(self.pidfile.read_text())
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def reboot(self):
        # 使用已验证可热重启的 IDE/e1000；QEMU 进程保持不变。
        boot_id = self.cmd("cat /proc/sys/kernel/random/boot_id").strip()
        pid = int(self.pidfile.read_text())
        self.cmd("sync; (sleep 1; reboot) >/dev/null 2>&1 &")
        self.ssh.close()
        time.sleep(10)
        self.connect()
        next_boot_id = self.cmd("cat /proc/sys/kernel/random/boot_id").strip()
        assert next_boot_id != boot_id, "整机启动标识未变化"
        assert int(self.pidfile.read_text()) == pid, "QEMU 进程不应在热重启时重建"
        return {"previous_boot_id": boot_id, "new_boot_id": next_boot_id,
                "qemu_pid_unchanged": pid, "method": "guest warm reboot on IDE/e1000"}


def verify_install_lifecycle(machines, args, passed):
    a, b = machines
    preserved = a.snapshot()
    # OpenWrt /tmp 是 tmpfs，整机重启后必须重新上传待安装的包。
    a.upload(args.package, "/tmp/vntc.ipk")
    def ping(vm, ip):
        return vm.cmd(f"ping -c 4 -W 3 {ip}")
    a.cmd("opkg --force-reinstall install /tmp/vntc.ipk")
    wait_for("IPK 重装", a.running)
    assert a.snapshot() == preserved
    ping(a, "10.77.0.3")
    passed("IPK 重新安装保留配置并恢复通信")
    a.cmd("opkg remove vntc-openwrt; test ! -e /usr/bin/vntc-openwrt")
    assert a.snapshot() == preserved
    wait_for("卸载释放 TUN", lambda: a.cmd("if ip link show dev vnt0 >/dev/null 2>&1; then exit 1; else echo released; fi"))
    a.cmd("opkg install /tmp/vntc.ipk")
    wait_for("卸载后重新安装", a.running)
    ping(a, "10.77.0.3")
    passed("IPK 卸载保留业务数据、释放网络并可重新安装")
    if args.portable:
        b_preserved = b.snapshot()
        b.cmd("opkg remove vntc-openwrt")
        b.upload(args.portable, "/tmp/vntc-portable.tar.gz")
        b.cmd("mkdir -p /tmp/vntc-portable; tar -xzf /tmp/vntc-portable.tar.gz -C /tmp/vntc-portable; "
              "cd /tmp/vntc-portable/VNTC_OpenWrt_*; sh install.sh")
        wait_for("便携包安装", b.running)
        assert b.snapshot() == b_preserved
        ping(b, "10.77.0.2")
        passed("便携安装包哈希校验、升级保留数据和实际通信")
        b.cmd("cd /tmp/vntc-portable/VNTC_OpenWrt_*; sh uninstall.sh")
        assert b.snapshot() == b_preserved
        b.cmd("cd /tmp/vntc-portable/VNTC_OpenWrt_*; sh install.sh")
        wait_for("便携包卸载重装", b.running)
        ping(b, "10.77.0.2")
        passed("便携卸载保留业务数据并可重新安装")


def resume_run(args):
    """从已通过冷启动、仅因 /tmp 安装包丢失而中断的检查点继续。"""
    folder = args.resume_run
    assert folder.parent == args.work_dir, "接力目录必须在指定 VM 工作目录内"
    report_path = folder / "report.json"
    report = json.loads(report_path.read_text())
    assert not report["success"] and "/tmp/vntc.ipk" in report.get("failure", ""), "不是可恢复的安装检查点"
    assert any("整机冷启动" in c["name"] for c in report["checks"]), "尚未完成冷启动验证"
    assert hashlib.sha256(args.package.read_bytes()).hexdigest() == report["package_sha256"], "接力安装包必须完全一致"
    shutil.copy2(report_path, folder / "previous_report.json")
    report.pop("failure", None)
    report["resumed_at"] = datetime.now(timezone.utc).isoformat()
    report["resume_reason"] = "保留已通过的阶段，从安装生命周期检查点继续；新增 IDE/e1000 热重启验收"
    if args.portable:
        report["portable_sha256"] = hashlib.sha256(args.portable.read_bytes()).hexdigest()
    def passed(name, **evidence):
        report["checks"].append({"name": name, "passed": True, **evidence})
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"PASS {name}", flush=True)
    machines, server = [], None
    with (folder / "server.log").open("a") as log:
        try:
            server = subprocess.Popen([str(args.server_binary), "-c", str(folder / "server.toml")], cwd=folder,
                                      stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            time.sleep(2)
            assert server.poll() is None, "接力测试服务器启动失败"
            for index, name in enumerate(("router-a", "router-b")):
                vm = VM(name, index, folder, folder / "id_ed25519", None, None)
                machines.append(vm)
                vm.start()
                config = json.loads(vm.cmd("cat /etc/vntc/config.json", record=False))
                vm.token = config["web"]["access_token"]
                wait_for(f"{name} 接力自动组网", vm.running)
            a, b = machines
            a.cmd("ping -c 4 -W 3 10.77.0.3")
            passed("持久磁盘恢复后双 VM 实际通信")
            preserved = a.snapshot()
            evidence = a.reboot()
            wait_for("热重启后自动组网", a.running)
            assert a.snapshot() == preserved
            a.cmd("ping -c 4 -W 3 10.77.0.3")
            passed("OpenWrt IDE/e1000 整机热重启、procd 自启和配置保留", **evidence)
            verify_install_lifecycle(machines, args, passed)
            for vm in machines:
                vm.cmd("logread -e vntc | tail -100; ip -s link show dev vnt0; df -h /; free -m")
            report["success"] = True
            report["management_urls"] = [f"http://127.0.0.1:{vm.web_port}/" for vm in machines]
            report["server_pid"] = server.pid
            report["vm_pids"] = {vm.name: int(vm.pidfile.read_text()) for vm in machines}
        except Exception as error:
            report["failure"] = str(error)
            raise
        finally:
            report["finished_at"] = datetime.now(timezone.utc).isoformat()
            report["kept_running"] = bool(args.keep_running and report["success"])
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
            (args.work_dir / "latest-run.txt").write_text(str(folder) + "\n")
            print(f"验证报告：{report_path}", flush=True)
            if not report["kept_running"]:
                for vm in machines:
                    vm.stop()
                if server and server.poll() is None:
                    server.terminate()
                    server.wait(timeout=15)


def main(args):
    args.work_dir.mkdir(parents=True, exist_ok=True)
    if args.resume_run:
        resume_run(args)
        return
    folder = args.work_dir / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder.mkdir(mode=0o700)
    report = {"openwrt_version": VERSION, "architecture": "x86_64", "started_at": datetime.now(timezone.utc).isoformat(),
              "package": str(args.package), "package_sha256": hashlib.sha256(args.package.read_bytes()).hexdigest(),
              "checks": [], "success": False}
    def passed(name, **evidence):
        report["checks"].append({"name": name, "passed": True, **evidence})
        print(f"PASS {name}", flush=True)
        (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))

    machines, server = [], None
    server_log = (folder / "server.log").open("a")
    try:
        for port in (22022, 22023, 18081, 18082, args.server_port):
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", port))
        (kernel, rootfs, tun), image_hashes = images(args.work_dir.parent / "downloads")
        passed("官方镜像和 TUN 模块 SHA-256", hashes=image_hashes)
        key = folder / "id_ed25519"
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
        conf = folder / "server.toml"
        conf.write_text(f'tcp_bind = "127.0.0.1:{args.server_port}"\nquic_bind = "127.0.0.1:{args.server_port}"\n'
                        'network = "10.77.0.0/24"\npersistence = false\nwhite_list = []\n'
                        'lease_duration = 86400\n[custom_nets]\n')
        def start_server():
            return subprocess.Popen([str(args.server_binary), "-c", str(conf)], cwd=folder,
                                    stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True)
        server = start_server()
        time.sleep(2)
        assert server.poll() is None, "测试 VNTS 服务端退出，检查 server.log"
        for index, name in enumerate(("router-a", "router-b")):
            vm = VM(name, index, folder, key, kernel, rootfs)
            machines.append(vm)
            vm.start()
            release = vm.cmd("cat /etc/openwrt_release; uname -m")
            assert f"{VERSION}" in release and "x86_64" in release
            vm.upload(tun, "/tmp/kmod-tun.ipk")
            vm.upload(args.package, "/tmp/vntc.ipk")
            vm.cmd("opkg install /tmp/kmod-tun.ipk; modprobe tun; test -c /dev/net/tun")
            vm.cmd("opkg install /tmp/vntc.ipk && /etc/init.d/vntc enabled")
            wait_for(f"{name} WebUI 就绪", vm.healthy)
            local = json.loads(vm.cmd("cat /etc/vntc/config.json", record=False))
            vm.token = local["web"]["access_token"]
            assert len(vm.token) == 64 and len(local["vnt"]["device_id"]) == 32
            assert vm.cmd("ls -ld /etc/vntc/config.json").split()[0] == "-rw-------"
            assert vm.cmd("ls -ld /etc/vntc").split()[0] == "drwx------"
            vm.api("/api/status", authenticated=False, expected=401)
            assert "html" in vm.api("/", authenticated=False).lower()
            assert "import" in vm.api("/assets/js/app.js", authenticated=False)
            vnt = vm.api("/api/config")
            vnt.update(server_addresses=[f"quic://10.0.2.2:{args.server_port}"],
                       network_code="openwrt-vm-" + folder.name, device_name=name,
                       virtual_ip=f"10.77.0.{index + 2}", channel_mode="relay_only", password="vm-test-only")
            vm.api("/api/config", "PUT", vnt)
            settings = vm.api("/api/settings")
            settings["auto_connect"] = True
            vm.api("/api/settings", "PUT", settings)
            vm.api("/api/start", "POST")
            state = wait_for(f"{name} VNTS 注册", vm.running)
            assert state["virtual_ip"] == f"10.77.0.{index + 2}"
            vm.cmd(f"ip -4 addr show dev vnt0 | grep '10.77.0.{index + 2}/'")
            passed(f"{name} 实际 IPK 安装、鉴权、TUN 和 VNTS 注册", status=state)
        a, b = machines
        assert a.token != b.token
        def ping(vm, ip, size=56):
            return vm.cmd(f"ping -c 4 -W 3 -s {size} {ip}")
        ping_a = wait_for("A -> B 虚拟 IP", lambda: ping(a, "10.77.0.3"))
        ping_b = wait_for("B -> A 虚拟 IP", lambda: ping(b, "10.77.0.2"))
        ping(a, "10.77.0.3", 1300)
        passed("双 VM 加密隧道双向 ping 和 1300 字节大包", a_to_b=ping_a, b_to_a=ping_b)
        assert json.loads(a.cmd("wget -qO- -T 10 http://10.77.0.3:18080/api/health"))["message"] == "ok"
        assert json.loads(b.cmd("wget -qO- -T 10 http://10.77.0.2:18080/api/health"))["message"] == "ok"
        passed("双 VM 通过虚拟 IP 访问 TCP HTTP 服务")
        for vm in machines:
            peers, traffic = vm.api("/api/peers"), vm.api("/api/traffic")
            assert any(p["online"] for p in peers), peers
            assert sum(t["tx_bytes"] + t["rx_bytes"] for t in traffic) > 0, traffic
        passed("在线节点和真实流量计数")
        a.api("/api/stop", "POST")
        assert a.api("/api/status")["phase"] == "stopped"
        wait_for("停止释放 TUN", lambda: a.cmd("if ip link show dev vnt0 >/dev/null 2>&1; then exit 1; else echo released; fi"))
        a.api("/api/start", "POST")
        wait_for("API 重连恢复数据面", lambda: ping(a, "10.77.0.3"))
        passed("API 停止释放 TUN 和重新连接")
        before_pid = a.cmd("pidof vntc-openwrt").strip()
        a.cmd("kill -9 " + before_pid)
        wait_for("procd 进程崩溃恢复", lambda: a.running() and a.cmd("pidof vntc-openwrt").strip() != before_pid)
        ping(a, "10.77.0.3")
        passed("procd 进程崩溃自动拉起并恢复组网")
        server.terminate()
        server.wait(timeout=15)
        server = start_server()
        wait_for("服务端重启后数据面恢复", lambda: ping(a, "10.77.0.3"), 180)
        passed("VNTS 服务端重启恢复通信")
        preserved = a.snapshot()
        a.cmd("/etc/init.d/vntc restart")
        wait_for("SIGTERM 服务重启", a.running)
        assert a.snapshot() == preserved
        ping(a, "10.77.0.3")
        passed("SIGTERM 正常服务重启和配置保留")
        server.terminate()
        server.wait(timeout=15)
        a.cmd("/etc/init.d/vntc restart")
        wait_for("启动时上游不可用", lambda: a.api("/api/status")["phase"] == "error", 120)
        server = start_server()
        wait_for("上游恢复后启动重试", a.running, 180)
        wait_for("上游恢复后隧道通信", lambda: ping(a, "10.77.0.3"), 180)
        passed("启动时上游不可用，恢复后自动连接")
        boot_evidence = a.reboot()
        wait_for("开机自动组网", a.running, 180)
        assert a.snapshot() == preserved
        ping(a, "10.77.0.3")
        passed("OpenWrt 整机热重启、procd 自启和业务配置保留", **boot_evidence)
        verify_install_lifecycle(machines, args, passed)
        for vm in machines:
            vm.cmd("logread -e vntc | tail -100; ip -s link show dev vnt0; df -h /; free -m")
        report["success"] = True
        report["management_urls"] = [f"http://127.0.0.1:{vm.web_port}/" for vm in machines]
        report["server_pid"] = server.pid
        report["vm_pids"] = {vm.name: int(vm.pidfile.read_text()) for vm in machines}
    except Exception as error:
        report["failure"] = str(error)
        for vm in machines:
            try:
                vm.cmd("logread | tail -160; ip addr; ip route", check=False)
            except Exception:
                pass
        raise
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report["kept_running"] = bool(args.keep_running and report["success"])
        (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        (args.work_dir / "latest-run.txt").write_text(str(folder) + "\n")
        print(f"验证报告：{folder / 'report.json'}", flush=True)
        if not (args.keep_running and report["success"]):
            for vm in machines:
                vm.stop()
            if server and server.poll() is None:
                server.terminate()
                server.wait(timeout=15)
        server_log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--portable", type=Path)
    parser.add_argument("--server-binary", type=Path, required=True)
    parser.add_argument("--server-port", type=int, default=32972)
    parser.add_argument("--work-dir", type=Path, default=Path.home() / ".cache/vntc-openwrt/vm")
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--resume-run", type=Path, help="继续已完成冷启动的安装验收检查点")
    arguments = parser.parse_args()
    for attr in ("package", "portable", "server_binary", "work_dir", "resume_run"):
        if getattr(arguments, attr) is not None:
            setattr(arguments, attr, getattr(arguments, attr).resolve())
    main(arguments)
