#!/usr/bin/env python3
"""在 WSL 内新建两台独立 x86_64 OpenWrt 网关测试机，不触碰现有 VM。"""
from datetime import datetime, timezone
import bz2
import hashlib
import importlib.util
import json
import lzma
from pathlib import Path
import secrets
import socket
import tomllib
import urllib.error
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "dist/openwrt-gateway"
LIVE = OUT / "live"
BASE = 23500
spec = importlib.util.spec_from_file_location("legacy_gateway_vm", ROOT / "VntcApp1.0/openwrt/verify_vm.py")
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


def kernel_elf(kernel, folder):
    """提取已核对官方哈希的 bzImage 中的原始 ELF，使用其 PVH 启动入口。"""
    raw = kernel.read_bytes()
    for magic, decode in ((b"\x1f\x8b\x08", lambda data: zlib.decompress(data, 31)),
                          (b"\xfd7zXZ\0", lzma.decompress), (b"BZh", bz2.decompress)):
        offset = -1
        while True:
            offset = raw.find(magic, offset + 1)
            if offset < 0:
                break
            try:
                data = decode(raw[offset:])
            except (EOFError, ValueError, OSError, zlib.error, lzma.LZMAError):
                continue
            if data.startswith(b"\x7fELF"):
                target = folder / "kernel-uncompressed.elf"
                target.write_bytes(data)
                return target
    raise ValueError("无法提取官方 x86 内核 ELF")


class X86VM(legacy.VM):
    def __init__(self, index, folder, kernel, rootfs):
        super().__init__(f"x86_64-{index}", index, folder, folder / "id_ed25519", kernel, rootfs)
        self.index = index
        self.ssh_port, self.web_port = BASE + index, BASE + 10 + index

    def start(self):
        assert not self.pidfile.exists()
        network = (f"user,id=net0,hostfwd=tcp:127.0.0.1:{self.ssh_port}-:22,"
                   f"hostfwd=tcp:127.0.0.1:{self.web_port}-:18080")
        if self.index == 0:
            network += (f",hostfwd=tcp:127.0.0.1:{BASE+20}-:29872,"
                        f"hostfwd=udp:127.0.0.1:{BASE+20}-:29872,"
                        f"hostfwd=tcp:127.0.0.1:{BASE+21}-:29871")
        boot_kernel = kernel_elf(self.kernel, self.folder)
        legacy.run(["qemu-system-x86_64", "-name", self.name + "-gateway", "-machine", "pc", "-accel", "tcg,thread=single,tb-size=8",
            "-cpu", "max", "-m", "512", "-smp", "1", "-display", "none", "-daemonize",
            "-pidfile", str(self.pidfile), "-serial", "file:" + str(self.serial),
            "-kernel", str(boot_kernel), "-append", "root=/dev/sda2 rootwait console=ttyS0,115200n8 nokaslr tsc=reliable clocksource=tsc reboot=k",
            "-no-hpet", "-monitor", f"unix:{self.folder}/{self.name}.monitor,server=on,wait=off",
            "-drive", f"file={self.root},format=raw,if=ide", "-netdev", network,
            "-device", "e1000,netdev=net0"])
        self.connect(timeout=420)


def main():
    LIVE.mkdir(parents=True, exist_ok=True)
    metadata = LIVE / "x86_64-runtime.json"
    assert not metadata.exists(), "已存在 x86 网关部署记录，禁止覆盖或重复启动"
    for port in (BASE, BASE+1, BASE+10, BASE+11, BASE+20, BASE+21):
        with socket.socket() as check:
            check.bind(("127.0.0.1", port))
    with socket.socket(type=socket.SOCK_DGRAM) as check:
        check.bind(("127.0.0.1", BASE+20))
    (kernel, rootfs, tun), hashes = legacy.images(Path.home() / ".cache/vntc-openwrt/downloads")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = Path.home() / ".cache/vnt-openwrt/arm-vm" / (stamp + "-x86_64-gateway")
    folder.mkdir(parents=True)
    legacy.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(folder / "id_ed25519")])
    report = {"folder": folder.name, "vm_directory": str(folder), "architecture": "x86_64",
              "port_base": BASE, "memory_mib": 512, "acceleration": "TCG", "boot_method": "PVH-official-kernel-ELF",
              "images": hashes, "success": False}
    metadata.write_text(json.dumps(report, indent=2))
    machines = []
    access = {"vntc": [], "vnts": {}}
    try:
        for index in range(2):
            vm = X86VM(index, folder, kernel, rootfs)
            machines.append(vm)
            vm.start()
            assert vm.cmd("uname -m").strip() == "x86_64"
            print(f"X86_VM_BOOTED {index}", flush=True)
            vm.upload(tun, "/tmp/gateway-tun.ipk")
            vm.cmd("opkg install /tmp/gateway-tun.ipk; modprobe tun; test -c /dev/net/tun")
            vm.cmd("opkg update >/tmp/gateway-deps.log 2>&1 && opkg install ip-full kmod-veth >>/tmp/gateway-deps.log 2>&1", timeout=240)
            client = next((OUT / "x86_64").glob("vntc-openwrt_*-2_*.ipk"))
            vm.upload(client, "/tmp/gateway-client.ipk")
            vm.cmd("opkg install /tmp/gateway-client.ipk")
            legacy.wait_for("x86 vntc WebUI", vm.healthy)
            vm.token = json.loads(vm.cmd("cat /etc/vntc/config.json", record=False))["web"]["access_token"]
            access["vntc"].append({"url": f"http://127.0.0.1:{vm.web_port}/", "access_token": vm.token})
            print(f"X86_CLIENT_INSTALLED {index}", flush=True)
        a = machines[0]
        server = OUT / "x86_64/vnts2-openwrt_2.0.0-1_x86_64.ipk"
        legacy.wait_for("x86 server package", lambda: server.is_file(), 600)
        a.upload(server, "/tmp/gateway-server.ipk")
        a.cmd("opkg install /tmp/gateway-server.ipk")
        credentials = tomllib.loads(a.cmd("cat /etc/vnts2/config.toml", record=False))
        access["vnts"] = {"url": f"http://127.0.0.1:{BASE+21}/", "username": credentials["username"], "password": credentials["password"]}
        def server_api(path, data=None, token=None):
            req = urllib.request.Request(access["vnts"]["url"] + path,
                data=None if data is None else json.dumps(data).encode(),
                headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
            with urllib.request.urlopen(req, timeout=20) as response:
                return json.load(response)
        login = legacy.wait_for("x86 VNTs login", lambda: server_api("api/login", {
            "username": credentials["username"], "password": credentials["password"]}))
        assert server_api("api/status", token=login["data"]["token"])["code"] == 200
        network_code, password = "x86-gateway-" + secrets.token_hex(5), secrets.token_hex(16)
        for index, vm in enumerate(machines):
            config = vm.api("/api/config")
            config.update(server_addresses=[f"tcp://10.0.2.2:{BASE+20}"], network_code=network_code,
                password=password, device_name=f"x86-gateway-{index}", virtual_ip=f"10.26.0.{index+2}", channel_mode="relay_only")
            vm.api("/api/config", "PUT", config)
            settings = vm.api("/api/settings")
            settings["auto_connect"] = True
            vm.api("/api/settings", "PUT", settings)
            vm.api("/api/start", "POST")
            legacy.wait_for("x86 VNT registration", vm.running)
        (LIVE / "x86_64-access.json").write_text(json.dumps(access, indent=2))
        (LIVE / "x86_64-access.json").chmod(0o600)
        report.update(success=True, qemu_pids=[int(vm.pidfile.read_text()) for vm in machines],
            packages={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (client, server)})
        metadata.write_text(json.dumps(report, indent=2))
        print("X86_GATEWAY_ENVIRONMENT_READY", flush=True)
    except Exception as error:
        report["error"] = str(error)
        metadata.write_text(json.dumps(report, indent=2))
        raise
    finally:
        # 保留本次 VM 及诊断文件，不影响原有 ARM/x86 演示环境。
        for vm in machines:
            vm.ssh.close()


if __name__ == "__main__":
    main()
