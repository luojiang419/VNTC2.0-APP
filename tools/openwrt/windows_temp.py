#!/usr/bin/env python3
"""本机 Windows 临时验证版的启动/停止入口；配置保留在忽略的 dist 目录。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "stop", "status"))
    parser.add_argument("--deployment", type=Path,
                        default=Path(__file__).resolve().parents[2] / "dist/windows-arm-interop")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("此入口仅在 Windows 宿主运行")
    folder = args.deployment.resolve()
    meta_path = folder / "process.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    config_path = folder / "state/config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    exe = folder / "bin/vntc-windows-arm-test.exe"
    assert Path(meta["exe"]).resolve() == exe, "部署元信息与程序路径不符"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def save():
        meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    def api(path, method="GET", data=None):
        request = urllib.request.Request(meta["ui_url"] + "api" + path, method=method,
            data=None if data is None else json.dumps(data).encode(),
            headers={"Authorization": "Bearer " + config["web"]["access_token"],
                     "Content-Type": "application/json"})
        with opener.open(request, timeout=120) as response:
            return json.load(response)

    def ps(command):
        return subprocess.check_output(["powershell.exe", "-NoProfile", "-Command",
            "$ErrorActionPreference='Stop'; " + command], text=True, encoding="utf-8",
            creationflags=subprocess.CREATE_NO_WINDOW).strip()

    def process_matches():
        process_id = int(meta["pid"])
        actual = ps(f"$p=Get-CimInstance Win32_Process -Filter 'ProcessId={process_id}'; "
                    "if($p){$p.ExecutablePath}")
        if not actual:
            return False
        if Path(actual).resolve() != exe:
            raise RuntimeError("PID 已被其他进程复用，拒绝操作")
        return True

    def wsl_python(code, *values):
        return subprocess.check_output(["wsl.exe", "-d", "Ubuntu", "--", "python3", "-c", code,
                                        *map(str, values)], text=True,
                                       creationflags=subprocess.CREATE_NO_WINDOW).strip()

    def remove_firewall():
        group = meta.get("firewall_group", "VNT-WinARM-Interop-" + str(int(meta["pid"])))
        assert group == "VNT-WinARM-Interop-" + str(int(meta["pid"]))
        ps(f"$rules=@(Get-NetFirewallRule | Where-Object Group -eq '{group}'); "
           "if($rules.Count -gt 0){$rules | Remove-NetFirewallRule}")

    def stop_relays():
        for relay in meta.get("udp_relays", []):
            wsl_python("import os,sys; from pathlib import Path; "
                "p=Path('/proc')/str(int(sys.argv[1]))/'cmdline'; "
                "a=p.read_bytes().split(bytes([0])) if p.exists() else []; "
                "expected=[s.encode() for s in sys.argv[2:]]; "
                "ok=all(s in a for s in expected); "
                "os.kill(int(sys.argv[1]),15) if ok else None; "
                "print('stopped' if ok else 'absent or changed')",
                relay["pid"], relay["program"], "--listen", relay["listen"],
                "--target-port", relay["target"].rsplit(":", 1)[1])
        meta["udp_relays"] = []
        save()

    running = process_matches()
    if args.action == "status":
        print(json.dumps({"process_running": running, "ui_url": meta["ui_url"],
                          "status": api("/status") if running else None}, ensure_ascii=False))
        return
    if args.action == "stop":
        if running:
            api("/stop", "POST")
            if process_matches():
                # 已确认 PID 对应隔离程序；关闭控制面前先通过 API 释放测试 TUN。
                ps(f"Stop-Process -Id {int(meta['pid'])}")
        remove_firewall()
        stop_relays()
        print("临时客户端、专用 UDP 转接及测试防火墙规则已停止；配置已保留。")
        return
    if running:
        print("临时版已运行：" + meta["ui_url"])
        return
    remove_firewall()
    stop_relays()
    with (folder / "windows-client.log").open("ab") as log:
        child = subprocess.Popen([str(exe), "--config", str(config_path)], cwd=exe.parent,
            stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
    meta.update(pid=child.pid, firewall_group="VNT-WinARM-Interop-" + str(child.pid))
    save()
    for _ in range(60):
        if child.poll() is not None:
            raise RuntimeError("临时客户端启动失败，请查看 windows-client.log")
        try:
            api("/health")
            break
        except OSError:
            time.sleep(1)
    else:
        raise TimeoutError("管理页面未就绪")
    route = json.loads(wsl_python("import json,subprocess; "
        "print(subprocess.check_output(['ip','-4','-j','route','get','1.1.1.1']).decode())"))[0]
    address = route["prefsrc"]
    gateway = route["gateway"]
    program = wsl_python("import subprocess,sys; "
        "print(subprocess.check_output(['wslpath','-u',sys.argv[1]]).decode().strip())",
        Path(__file__).with_name("udp_relay.py").as_posix())
    targets = [("aarch64", 23320, 23120, "win-aarch64-quic"), ("armv7", 23420, 23220, "win-armv7-quic")]
    x86_runtime = folder.parent / "openwrt-gateway/live/x86_64-runtime.json"
    if x86_runtime.exists():
        runtime = json.loads(x86_runtime.read_text(encoding="utf-8"))
        if runtime.get("windows_profiles"):
            targets.append(("x86_64", 23620, 23520, runtime["windows_profiles"]["quic"]))
    for arch, port, target, profile_id in targets:
        log_path = folder / (arch + "-relay-start.json")
        with log_path.open("w") as output, (folder / (arch + "-udp-relay.log")).open("ab") as error:
            relay_process = subprocess.Popen(["wsl.exe", "-d", "Ubuntu", "--", "python3", program,
                "--listen", f"{address}:{port}", "--target-port", str(target), "--allow", gateway],
                stdout=output, stderr=error, creationflags=subprocess.CREATE_NO_WINDOW)
        for _ in range(50):
            try:
                relay = json.loads(log_path.read_text())
                break
            except (ValueError, OSError):
                if relay_process.poll() is not None:
                    raise RuntimeError("UDP 转接启动失败，请查看 " + arch + "-udp-relay.log")
                time.sleep(0.2)
        else:
            raise TimeoutError("UDP 转接未就绪")
        relay.update(architecture=arch, host_process_id=relay_process.pid, program=program)
        meta["udp_relays"].append(relay)
        save()
        profile = api("/profiles/" + profile_id)
        profile["vnt"]["server_addresses"] = [f"quic://{address}:{port}"]
        api("/profiles/" + profile["id"], "PUT", {"name": profile["name"], "vnt": profile["vnt"]})
    api("/profiles/win-aarch64-tcp/connect", "POST")
    group = meta["firewall_group"]
    ps("$adapter=Get-NetIPAddress -IPAddress '10.26.0.10' -AddressFamily IPv4; "
       "if($adapter.InterfaceAlias -notlike 'VNT-App-TUN-VNT-WinARM-Test*'){throw 'Unexpected interface'}; "
       f"New-NetFirewallRule -DisplayName '{group}-Ping' -Group '{group}' "
       "-Direction Inbound -Action Allow -Profile Any -InterfaceAlias $adapter.InterfaceAlias "
       "-LocalAddress '10.26.0.10' -RemoteAddress '10.26.0.2','10.26.0.3' "
       "-Protocol ICMPv4 -IcmpType 8 | Out-Null")
    print("临时版已启动并连接 ARM64 TCP：" + meta["ui_url"])


if __name__ == "__main__":
    main()
