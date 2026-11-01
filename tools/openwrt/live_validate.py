#!/usr/bin/env python3
"""部署已交付 ARM 包，执行持续双向传输检查并保留管理页面供用户确认。"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import shlex
import tarfile
import time
import tomllib

from verify_arm import ARMVM, ROOT, images, run, wait_for


def binary_hash(package, program):
    with tarfile.open(package) as outer:
        with tarfile.open(fileobj=io.BytesIO(outer.extractfile("./data.tar.gz").read())) as payload:
            return hashlib.sha256(payload.extractfile("./usr/bin/" + program).read()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--duration", type=int, default=300, help="两个协议阶段合计的计划秒数，至少 60")
    parser.add_argument("--rounds", type=int, default=30, help="每协议、每方向的文件传输次数")
    args = parser.parse_args()
    assert args.duration >= 60 and args.rounds >= 2
    folder = args.run.resolve()
    previous = json.loads((folder / "report.json").read_text())
    assert previous["success"], "需要先完成基础验收"
    arch = previous["architecture"]
    args.output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    private = folder / ("live-" + stamp)
    private.mkdir(mode=0o700)
    report_path = args.output / (arch + "-live-report.json")
    report = {"architecture": arch, "started_at": datetime.now(timezone.utc).isoformat(),
              "planned_seconds": args.duration, "payload_bytes": 1024 * 1024,
              "phases": [], "success": False, "kept_running": False}
    def save():
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    def progress(message):
        report["progress"] = message
        save()
        print(f"{arch}: {message}", flush=True)
    machines = []
    remote = "/tmp/vnt-live-" + stamp
    helper_pid = {}
    try:
        progress("校验交付包与构建临时传输工具")
        artifacts = {}
        for name in ("client_package", "server_package"):
            old = previous["packages"][name]
            package = ROOT / "dist/openwrt-arm" / arch / Path(old["file"]).name
            assert hashlib.sha256(package.read_bytes()).hexdigest() == old["sha256"]
            artifacts[name] = package
        report["packages"] = {name: {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                              for name, path in artifacts.items()}
        expected = {"vntc-openwrt": binary_hash(artifacts["client_package"], "vntc-openwrt"),
                    "vnts2-openwrt": binary_hash(artifacts["server_package"], "vnts2-openwrt")}
        helper = private / "transfer-http"
        target = "aarch64-linux-musl" if arch == "aarch64" else "arm-linux-musleabihf"
        command = ["zig", "cc", "-target", target, "-static", "-Os", "-Wall", "-Wextra", "-Werror"]
        if arch == "armv7":
            command += ["-mcpu=generic+v7a+vfp3-d32+thumb2-neon"]
        run(command + [str(ROOT / "tools/openwrt/transfer_http.c"), "-o", str(helper)])
        files, _ = images(arch, folder.parent.parent / "downloads")
        for index in range(2):
            vm = ARMVM(arch, index, folder, folder / "id_ed25519", files[0], None,
                       23100 if arch == "aarch64" else 23200)
            vm.serial = private / f"{vm.name}-serial.log"
            vm.transcript = private / f"{vm.name}-commands.log"
            machines.append(vm)
            progress(f"启动 OpenWrt 节点 {index + 1}")
            vm.start()
            vm.upload(artifacts["client_package"], "/tmp/vntc-live.ipk")
            if index == 0:
                vm.upload(artifacts["server_package"], "/tmp/vnts-live.ipk")
                vm.cmd("opkg --force-reinstall install /tmp/vnts-live.ipk /tmp/vntc-live.ipk")
            else:
                vm.cmd("opkg --force-reinstall install /tmp/vntc-live.ipk")
            wait_for("vntc 管理页面", vm.healthy)
            vm.token = json.loads(vm.cmd("cat /etc/vntc/config.json", record=False))["web"]["access_token"]
            for program in (expected if index == 0 else ("vntc-openwrt",)):
                assert vm.cmd("sha256sum /usr/bin/" + program).split()[0] == expected[program]
            vm.cmd("rm -f /tmp/vntc-live.ipk /tmp/vnts-live.ipk; sync")
        a, b = machines
        wait_for("VNTs 管理页面", lambda: a.server_api("/api/status", expected=401))
        credentials = tomllib.loads(a.cmd("cat /etc/vnts2/config.toml", record=False))
        login = a.server_api("/api/login", {"username": credentials["username"], "password": credentials["password"]})
        server_token = login["data"]["token"]
        assert a.server_api("/api/status", token=server_token)["code"] == 200
        report["urls"] = {"vntc": [f"http://127.0.0.1:{v.web_port}/" for v in machines],
                          "vnts": f"http://127.0.0.1:{a.server_web_port}/"}
        # 随机测试数据和临时 HTTP 工具仅保存在本轮 /tmp，不写入业务目录。
        payload_hashes = {}
        for vm in machines:
            payload = private / (vm.name + ".bin")
            with open("/dev/urandom", "rb") as source:
                payload.write_bytes(source.read(report["payload_bytes"]))
            payload_hashes[vm.name] = hashlib.sha256(payload.read_bytes()).hexdigest()
            vm.cmd("mkdir -p " + shlex.quote(remote))
            vm.upload(helper, remote + "/transfer-http")
            vm.upload(payload, remote + "/payload.bin")
            vm.cmd(f"chmod 700 {remote}/transfer-http; (trap '' HUP; exec {remote}/transfer-http 18090 {remote}/payload.bin) >{remote}/http.log 2>&1 </dev/null & echo $! >{remote}/http.pid")
            helper_pid[vm.name] = vm.cmd("cat " + remote + "/http.pid").strip()
        report["payload_sha256"] = payload_hashes
        for protocol in ("tcp", "quic"):
            progress(f"配置 {protocol.upper()} 中继并等待路由稳定")
            for vm in machines:
                vm.api("/api/stop", "POST")
                config = vm.api("/api/config")
                config["server_addresses"] = [f"{protocol}://10.0.2.2:{a.server_port}"]
                config["channel_mode"] = "relay_only"
                vm.api("/api/config", "PUT", config)
                vm.api("/api/start", "POST")
            for vm in machines:
                wait_for("客户端注册", vm.running, 180)
            for vm, address in ((a, "10.26.0.3"), (b, "10.26.0.2")):
                def ready():
                    output = vm.cmd(f"ping -c 5 -W 3 -s 1300 {address}", check=False, timeout=40)
                    return output if ", 0% packet loss" in output else None
                wait_for("双向路由稳定", ready, 180)
            before = {vm.name: vm.cmd("pidof vntc-openwrt vnts2-openwrt").strip() for vm in machines}
            seconds = args.duration // 2
            phase = {"protocol": protocol, "planned_seconds": seconds, "directions": [], "success": False}
            report["phases"].append(phase)
            progress(f"{protocol.upper()} 持续双向文件传输和大包检测（计划 {seconds} 秒）")
            def transfer(vm, peer, address):
                started = time.monotonic()
                rounds = []
                for count in range(args.rounds):
                    tick = time.monotonic()
                    output = vm.cmd(f"wget -qO {remote}/received.bin -T 45 http://{address}:18090/payload.bin && sha256sum {remote}/received.bin", timeout=60)
                    assert output.split()[0] == payload_hashes[peer.name], "传输内容 SHA-256 不一致"
                    rounds.append({"round": count + 1, "seconds": round(time.monotonic() - tick, 3), "sha256_ok": True})
                    delay = started + (count + 1) * seconds / args.rounds - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)
                return {"from": peer.name, "to": vm.name, "bytes": args.rounds * report["payload_bytes"],
                        "rounds": rounds, "elapsed_seconds": round(time.monotonic() - started, 3)}
            def ping(vm, address):
                output = vm.cmd(f"ping -c {seconds} -i 1 -W 3 -s 1300 {address}", check=False,
                                timeout=seconds * 3 + 120)
                assert ", 0% packet loss" in output, output[-800:]
                return output
            started = time.monotonic()
            with ThreadPoolExecutor(max_workers=4) as pool:
                transfers = [pool.submit(transfer, a, b, "10.26.0.3"), pool.submit(transfer, b, a, "10.26.0.2")]
                pings = [pool.submit(ping, a, "10.26.0.3"), pool.submit(ping, b, "10.26.0.2")]
                phase["directions"] = [future.result() for future in transfers]
                phase["ping"] = [future.result() for future in pings]
            assert before == {vm.name: vm.cmd("pidof vntc-openwrt vnts2-openwrt").strip() for vm in machines}, "传输期间服务进程发生变化"
            assert all(vm.running() for vm in machines)
            phase.update(success=True, elapsed_seconds=round(time.monotonic() - started, 3), pids_unchanged=before)
            save()
            progress(f"{protocol.upper()} 阶段通过：双向内容校验一致，大包零丢失，服务未重启")
        report["final_status"] = {vm.name: vm.api("/api/status") for vm in machines}
        report["memory"] = {vm.name: vm.cmd("for p in $(pidof vntc-openwrt vnts2-openwrt); do grep -E '^(Name|VmRSS|VmHWM|Threads):' /proc/$p/status; done; grep -E '^(MemTotal|MemAvailable|SwapTotal):' /proc/meminfo") for vm in machines}
        report["server_status"] = a.server_api("/api/status", token=server_token)
        report["qemu"] = [{"pid": int(vm.pidfile.read_text()), "root": str(vm.root), "ssh_port": vm.ssh_port} for vm in machines]
        access = {"architecture": arch, "vnts": {"url": report["urls"]["vnts"],
                  "username": credentials["username"], "password": credentials["password"]},
                  "vntc": [{"url": url, "access_token": vm.token} for vm, url in zip(machines, report["urls"]["vntc"])]}
        access_path = args.output / (arch + "-access.json")
        access_path.write_text(json.dumps(access, ensure_ascii=False, indent=2), encoding="utf-8")
        access_path.chmod(0o600)
        report.update(success=True, kept_running=True, finished_at=datetime.now(timezone.utc).isoformat(),
                      transfer_bytes=sum(d["bytes"] for p in report["phases"] for d in p["directions"]))
        progress("验证全部通过，保留 VNTs 和 vntc 管理页面运行")
    except Exception as error:
        report["error"] = str(error)
        save()
        raise
    finally:
        for vm in machines:
            if vm.name in helper_pid:
                try:
                    vm.cmd(f"if grep -q '{remote}/transfer-http' /proc/{helper_pid[vm.name]}/cmdline 2>/dev/null; then kill {helper_pid[vm.name]}; fi; rm -f {remote}/transfer-http {remote}/payload.bin {remote}/received.bin {remote}/http.log {remote}/http.pid; rmdir {remote}", check=False)
                except Exception:
                    pass
            if not report["success"]:
                vm.stop()


if __name__ == "__main__":
    main()
