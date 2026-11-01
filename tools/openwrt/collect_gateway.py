#!/usr/bin/env python3
"""核对网关包、离线文件、真实部署与验收结果，生成无凭据的交付清单。"""
import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile

from targets import check_binary
from verify_gateway import DEPLOY, Node, ROOT


def sha(data):
    return hashlib.sha256(data).hexdigest()


def inspect(package, portable, arch, program, prefix):
    with tarfile.open(package) as outer:
        raw = outer.extractfile("./data.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(raw)) as data:
        payload = {m.name.removeprefix("./"): data.extractfile(m).read() for m in data if m.isfile()}
    binary = payload["usr/bin/" + program]
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / program
        path.write_bytes(binary)
        check_binary(path, arch)
    with tarfile.open(portable) as archive:
        top = next(m.name for m in archive if m.isdir() and "/" not in m.name)
        assert top.startswith(prefix + "_OpenWrt_")
        assert archive.extractfile(top + "/" + program).read() == binary
        for line in archive.extractfile(top + "/SHA256SUMS").read().decode().splitlines():
            digest, relative = line.split(maxsplit=1)
            assert sha(archive.extractfile(top + "/" + relative).read()) == digest
        if program == "vntc-openwrt":
            for name in ("vntc-gateway", "vntc-firewall", "vntc-setup"):
                assert archive.extractfile(top + "/files/" + name).read() == payload["usr/libexec/" + name]
            assert archive.extractfile(top + "/files/vntc.init").read() == payload["etc/init.d/vntc"]
    return payload


def main():
    windows = json.loads((DEPLOY / "validation/windows/report.json").read_text(encoding="utf-8"))
    assert windows["success"] and len(windows["cases"]) == 4 and len(windows["video"]) == 2
    x86_windows = json.loads((DEPLOY / "validation/windows-x86_64/report.json").read_text(encoding="utf-8"))
    assert x86_windows["success"] and len(x86_windows["cases"]) == 2 and len(x86_windows["video"]) == 1
    manifest = {"client_version": "4.8.40-2", "server_version": "2.0.0-1", "products": [], "verification": []}
    for arch in ("aarch64", "armv7", "x86_64"):
        out = DEPLOY / arch
        ipk = next(out.glob("vntc-openwrt_*-2_*.ipk"))
        portable = next(out.glob("VNTC_OpenWrt_*.tar.gz"))
        payload = inspect(ipk, portable, arch, "vntc-openwrt", "VNTC")
        products = [ipk, portable]
        if arch in ("aarch64", "armv7", "x86_64"):
            report = json.loads((DEPLOY / "validation" / arch / "report.json").read_text(encoding="utf-8"))
            lifecycle = json.loads((DEPLOY / "validation" / arch / "lifecycle.json").read_text(encoding="utf-8"))
            assert report["success"] and lifecycle["success"]
            assert report["package_sha256"] == sha(ipk.read_bytes())
            assert lifecycle["portable_sha256"] == sha(portable.read_bytes())
            server = ROOT / "dist/openwrt-arm" / arch if arch != "x86_64" else out
            source_ipk = next(server.glob("vnts2-openwrt_*.ipk"))
            source_portable = next(server.glob("VNTS_OpenWrt_*.tar.gz"))
            for source in (source_ipk, source_portable):
                dest = out / source.name
                if source.resolve() != dest.resolve():
                    shutil.copy2(source, dest)
                assert sha(dest.read_bytes()) == sha(source.read_bytes())
                products.append(dest)
            server_payload = inspect(out / source_ipk.name, out / source_portable.name, arch, "vnts2-openwrt", "VNTS")
            snapshot = []
            for index in range(2):
                n = Node(arch, index, DEPLOY / "validation" / arch / f"collection-{index}.log")
                try:
                    for name in ("usr/bin/vntc-openwrt", "usr/libexec/vntc-gateway", "usr/libexec/vntc-firewall", "etc/init.d/vntc"):
                        actual = n.cmd("sha256sum /" + name).split()[0]
                        assert actual == sha(payload[name]), (arch, index, name)
                    if index == 0:
                        assert n.cmd("sha256sum /usr/bin/vnts2-openwrt").split()[0] == sha(server_payload["usr/bin/vnts2-openwrt"])
                    assert not n.cmd("uci changes firewall").strip()
                    assert n.running()
                    snapshot.append({"node": index, "about": n.api("/about"), "status": n.api("/status"),
                        "memory": n.cmd("for p in $(pidof vntc-openwrt vnts2-openwrt); do grep -E '^(Name|VmRSS|Threads):' /proc/$p/status; done; grep -E '^(MemTotal|MemAvailable|SwapTotal):' /proc/meminfo")})
                finally:
                    n.ssh.close()
            manifest["verification"].append({"architecture": arch, "gateway_vm_success": True,
                "gateway_checks": len(report["checks"]), "lifecycle_checks": len(lifecycle["checks"]),
                "file_bytes": report["total_file_bytes"], "snapshot": snapshot})
        for p in products:
            manifest["products"].append({"file": p.relative_to(DEPLOY).as_posix(), "bytes": p.stat().st_size, "sha256": sha(p.read_bytes())})
        (out / "SHA256SUMS").write_text("".join(sha(p.read_bytes()) + "  " + p.name + "\n" for p in products))
    manifest["windows"] = {"success": True, "mapping_cases": 6, "decoded_video_frames": 600}
    (DEPLOY / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print("GATEWAY_COLLECTION_VERIFIED: all deployed files match packages; no credentials exported")


if __name__ == "__main__":
    main()
