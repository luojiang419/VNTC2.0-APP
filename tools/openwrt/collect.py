#!/usr/bin/env python3
"""校验两个 ARM 架构的产物与通过的 VM 报告，汇总到交付目录。"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile

from targets import check_binary, package_architecture

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/openwrt-arm")
    parser.add_argument("--client-version", default="4.8.40")
    parser.add_argument("--server-version", default="2.0.0")
    parser.add_argument("--report", type=Path, action="append", required=True)
    args = parser.parse_args()
    reports = [json.loads(path.read_text(encoding="utf-8")) for path in args.report]
    assert {r["architecture"] for r in reports} == {"aarch64", "armv7"}
    assert all(r["success"] and all(c["passed"] for c in r["checks"]) for r in reports)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"products": [], "verification": []}
    for arch in ("aarch64", "armv7"):
        report = next(r for r in reports if r["architecture"] == arch)
        out = output / arch
        out.mkdir(exist_ok=True)
        for product, source, prefix, version, program in (
            ("vntc", ROOT / "VntcApp1.0/release/openwrt-arm" / arch, "VNTC", args.client_version, "vntc-openwrt"),
            ("vnts", ROOT / "vnts2.0服务端开发包/dist/openwrt" / arch, "VNTS", args.server_version, "vnts2-openwrt"),
        ):
            package_arch = package_architecture(arch)
            package_name = f"{program}_{version}-1_{package_arch}.ipk"
            archive_name = f"{prefix}_OpenWrt_{version}_{arch}.tar.gz"
            checksums = {line.split(maxsplit=1)[1]: line.split(maxsplit=1)[0]
                         for line in (source / "SHA256SUMS").read_text().splitlines()}
            for name in (package_name, archive_name):
                path = source / name
                actual = digest(path)
                assert checksums[name] == actual, f"产物清单不匹配：{name}"
                assert any(Path(p["file"]).name == name and p["sha256"] == actual
                           for p in report["packages"].values()), f"VM 未验收当前产物：{name}"
                shutil.copy2(path, out / name)
                manifest["products"].append({"product": product, "architecture": arch,
                                             "file": f"{arch}/{name}", "sha256": actual,
                                             "bytes": path.stat().st_size})
            with tarfile.open(source / package_name) as ipk:
                with tarfile.open(fileobj=io.BytesIO(ipk.extractfile("./control.tar.gz").read())) as control:
                    text = control.extractfile("./control").read().decode()
                    assert f"Architecture: {package_arch}\n" in text
                with tarfile.open(fileobj=io.BytesIO(ipk.extractfile("./data.tar.gz").read())) as data:
                    binary = data.extractfile(f"./usr/bin/{program}").read()
            with tempfile.TemporaryDirectory() as temporary:
                binary_path = Path(temporary) / program
                binary_path.write_bytes(binary)
                check_binary(binary_path, arch)
            with tarfile.open(source / archive_name) as archive:
                top = f"{prefix}_OpenWrt_{version}_{arch}/"
                assert archive.extractfile(top + program).read() == binary
                assert archive.extractfile(top + "ARCH").read().decode().strip() == arch
                for line in archive.extractfile(top + "SHA256SUMS").read().decode().splitlines():
                    expected, name = line.split(maxsplit=1)
                    assert hashlib.sha256(archive.extractfile(top + name).read()).hexdigest() == expected
        (out / "SHA256SUMS").write_text("".join(
            f"{item['sha256']}  {Path(item['file']).name}\n" for item in manifest["products"] if item["architecture"] == arch))
        (out / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        manifest["verification"].append({"architecture": arch, "checks": len(report["checks"]),
                                          "success": True, "memory_mib": report["memory_mib"]})
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
