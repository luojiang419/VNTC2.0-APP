#!/usr/bin/env python3
"""为现有隔离 Windows 临时版新增 x86 网关档案和专用 WSL UDP 转接。"""
import json
from pathlib import Path
import subprocess
import time
import urllib.request

from verify_gateway import wait

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "dist/windows-arm-interop"
LIVE = ROOT / "dist/openwrt-gateway/live"


def main():
    runtime_path = LIVE / "x86_64-runtime.json"
    runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
    assert runtime["success"], "请先完成 x86 VM 引导"
    access = json.loads((LIVE / "x86_64-access.json").read_text(encoding="utf-8"))
    config = json.loads((OUT / "state/config.json").read_text(encoding="utf-8"))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def api(path, method="GET", data=None):
        req = urllib.request.Request("http://127.0.0.1:18083/api" + path, method=method,
            data=None if data is None else json.dumps(data).encode(),
            headers={"Authorization": "Bearer " + config["web"]["access_token"], "Content-Type": "application/json"})
        with opener.open(req, timeout=120) as response:
            return json.load(response)

    def wsl(code, *args):
        return subprocess.check_output(["wsl.exe", "-d", "Ubuntu", "--", "python3", "-c", code, *map(str, args)],
            text=True, creationflags=subprocess.CREATE_NO_WINDOW).strip()

    assert api("/about")["platform"] == "windows/x86_64"
    guest_req = urllib.request.Request(access["vntc"][0]["url"] + "api/config",
        headers={"Authorization": "Bearer " + access["vntc"][0]["access_token"]})
    def guest_config():
        with opener.open(guest_req, timeout=15) as response:
            return json.load(response)
    guest = wait("x86 gateway config", guest_config)
    route = json.loads(wsl("import subprocess; print(subprocess.check_output(['ip','-4','-j','route','get','1.1.1.1']).decode())"))[0]
    program = wsl("import subprocess,sys; print(subprocess.check_output(['wslpath','-u',sys.argv[1]]).decode().strip())",
        Path(__file__).with_name("udp_relay.py").as_posix())
    meta_path = OUT / "process.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    existing = next((r for r in meta.get("udp_relays", []) if r["architecture"] == "x86_64"), None)
    if existing:
        alive = wsl("import pathlib,sys; p=pathlib.Path('/proc')/sys.argv[1]/'cmdline'; "
            "a=p.read_bytes().split(bytes([0])) if p.exists() else []; "
            "print(int(all(s.encode() in a for s in sys.argv[2:])))",
            existing["pid"], existing["program"], "--listen", existing["listen"], "--target-port", "23520")
        if alive != "1":
            meta["udp_relays"].remove(existing)
            existing = None
    if not existing:
        ready = OUT / "x86_64-relay-start.json"
        with ready.open("w") as output, (OUT / "x86_64-udp-relay.log").open("ab") as error:
            process = subprocess.Popen(["wsl.exe", "-d", "Ubuntu", "--", "python3", program,
                "--listen", f"{route['prefsrc']}:23620", "--target-port", "23520", "--allow", route["gateway"]],
                stdout=output, stderr=error, creationflags=subprocess.CREATE_NO_WINDOW)
        for _ in range(50):
            try:
                existing = json.loads(ready.read_text())
                break
            except (ValueError, OSError):
                if process.poll() is not None:
                    raise RuntimeError("x86 UDP 转接未启动，请查看专用日志")
                time.sleep(0.2)
        else:
            raise TimeoutError("UDP 转接未就绪")
        existing.update(architecture="x86_64", host_process_id=process.pid, program=program)
        meta.setdefault("udp_relays", []).append(existing)
        meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    profiles = api("/profiles")["profiles"]
    baseline = next(p["vnt"] for p in profiles if p["id"] == "win-aarch64-tcp")
    ids = {}
    for protocol in ("tcp", "quic"):
        name = "OpenWrt x86_64 " + protocol.upper()
        address = "tcp://127.0.0.1:23520" if protocol == "tcp" else "quic://" + existing["listen"]
        vnt = dict(baseline)
        vnt.update(network_code=guest["network_code"], password=guest["password"],
            device_name="Windows-x86-Gateway", server_addresses=[address], virtual_ip="10.26.0.10",
            input_routes=[], output_routes=[], port_mappings=[], no_nat=False, no_tun=False)
        previous = next((p for p in profiles if p["name"] == name), None)
        payload = {"name": name, "vnt": vnt}
        if previous:
            profile = previous if previous["vnt"] == vnt else api("/profiles/" + previous["id"], "PUT", payload)
        else:
            profile = api("/profiles", "POST", payload)
        ids[protocol] = profile["id"]
    runtime["windows_profiles"] = ids
    runtime_path.write_text(json.dumps(runtime, indent=2), encoding="utf-8")
    print("WINDOWS_X86_PROFILES_READY " + json.dumps(ids))


if __name__ == "__main__":
    main()
