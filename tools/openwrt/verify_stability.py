#!/usr/bin/env python3
"""复用已验收 ARM 磁盘，等待隧道稳定后检查连续双向大包零丢失。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil

from verify_arm import ARMVM, images, wait_for


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    args = parser.parse_args()
    folder = args.run.resolve()
    path = folder / "report.json"
    report = json.loads(path.read_text())
    assert len(report["checks"]) >= 11 and all(c["passed"] for c in report["checks"])
    for package in report["packages"].values():
        assert hashlib.sha256(Path(package["file"]).read_bytes()).hexdigest() == package["sha256"]
    arch = report["architecture"]
    suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    shutil.copy2(path, folder / f"report-before-stability-{suffix}.json")
    report.pop("error", None)
    recovery = folder / "environment-recovery.json"
    if recovery.is_file():
        report["test_environment_recovery"] = json.loads(recovery.read_text())
    report["success"] = False
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    files, _ = images(arch, folder.parent.parent / "downloads")
    machines = []
    try:
        for index in range(2):
            vm = ARMVM(arch, index, folder, folder / "id_ed25519", files[0], None,
                       23100 if arch == "aarch64" else 23200)
            vm.serial = folder / f"{vm.name}-stability-{suffix}-serial.log"
            vm.transcript = folder / f"{vm.name}-stability-{suffix}-commands.log"
            machines.append(vm)
            vm.start()
            wait_for("客户端恢复", vm.healthy)
            vm.token = json.loads(vm.cmd("cat /etc/vntc/config.json", record=False))["web"]["access_token"]
            wait_for("客户端注册", vm.running)
        results = {}
        for vm, ip in ((machines[0], "10.26.0.3"), (machines[1], "10.26.0.2")):
            def ready():
                output = vm.cmd(f"ping -c 5 -W 3 -s 1300 {ip}", check=False, timeout=35)
                return output if re.search(r", 0(?:\.0+)?% packet loss", output) else None
            wait_for("等待路由稳定，5 包零丢失", ready, 180)
            output = vm.cmd(f"ping -c 20 -W 3 -s 1300 {ip}", timeout=90)
            assert re.search(r", 0(?:\.0+)?% packet loss", output), output
            results[vm.name] = output
        report["checks"].append({"name": "连接稳定后双向 20 个 1300 字节包零丢失", "passed": True,
                                  "results": results})
        report["success"] = True
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"PASS {arch}: 双向各 20 个 1300 字节包，0% packet loss", flush=True)
    except Exception as error:
        report["error"] = str(error)
        path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        raise
    finally:
        for vm in machines:
            vm.stop()


if __name__ == "__main__":
    main()
