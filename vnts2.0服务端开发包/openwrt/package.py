#!/usr/bin/env python3
"""生成 VNTS OpenWrt 静态安装包和离线包。"""
import argparse
import hashlib
import io
from pathlib import Path
import re
import shutil
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/openwrt"))
from targets import TARGETS, check_binary, package_architecture


def tar_bytes(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.GNU_FORMAT) as archive:
        for name, (content, mode) in entries.items():
            info = tarfile.TarInfo("./" + name)
            info.size, info.mode, info.mtime = len(content), mode, 0
            archive.addfile(info, io.BytesIO(content))
    return output.getvalue()


def package(binary, version, output, arch, package_arch=None):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[.-][a-zA-Z0-9.-]+)?", version):
        raise ValueError("版本格式必须为 x.y.z")
    check_binary(binary, arch)
    package_arch = package_architecture(arch, package_arch)
    source = Path(__file__).resolve().parent
    output.mkdir(parents=True, exist_ok=True)
    name = f"VNTS_OpenWrt_{version}_{arch}"
    stage = output / name
    (stage / "files").mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, stage / "vnts2-openwrt")
    (stage / "vnts2-openwrt").chmod(0o755)
    (stage / "ARCH").write_text(arch + "\n")
    (stage / "PACKAGE_ARCH").write_text(package_arch + "\n")
    (stage / "VERSION").write_text(version + "\n")
    for relative in ("install.sh", "uninstall.sh", "files/vnts2.init", "files/vnts2-setup", "README.md"):
        path = stage / relative
        path.write_bytes((source / relative).read_bytes().replace(b"\r\n", b"\n"))
        path.chmod(0o644 if relative.endswith(".md") else 0o755)
    (stage / "NOTICE").write_bytes((source.parent / "official-vnts-source-2.0.0/NOTICE").read_bytes())
    files = sorted(p for p in stage.rglob("*") if p.is_file() and p.name != "SHA256SUMS")
    (stage / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(stage).as_posix()}\n" for p in files))
    payload = {
        "usr/bin/vnts2-openwrt": (binary.read_bytes(), 0o755),
        "etc/init.d/vnts2": ((stage / "files/vnts2.init").read_bytes(), 0o755),
        "usr/libexec/vnts2-setup": ((stage / "files/vnts2-setup").read_bytes(), 0o755),
        "lib/upgrade/keep.d/vnts2": (b"/etc/vnts2/\n", 0o644),
        "usr/share/vnts2/NOTICE": ((stage / "NOTICE").read_bytes(), 0o644),
    }
    control = (f"Package: vnts2-openwrt\nVersion: {version}-1\nArchitecture: {package_arch}\n"
               "Maintainer: VNTS developers\nSection: net\nPriority: optional\n"
               f"Installed-Size: {sum(len(v[0]) for v in payload.values())}\n"
               "Description: VNTS 2.0 server with embedded management console and procd service\n")
    postinst = b'''#!/bin/sh
set -e
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
/usr/libexec/vnts2-setup
/etc/init.d/vnts2 enable
/etc/init.d/vnts2 start
'''
    prerm = b'''#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
/etc/init.d/vnts2 stop
/etc/init.d/vnts2 disable
exit 0
'''
    ipk = output / f"vnts2-openwrt_{version}-1_{package_arch}.ipk"
    ipk.write_bytes(tar_bytes({
        "debian-binary": (b"2.0\n", 0o644),
        "control.tar.gz": (tar_bytes({"control": (control.encode(), 0o644),
                                     "postinst": (postinst, 0o755), "prerm": (prerm, 0o755)}), 0o644),
        "data.tar.gz": (tar_bytes(payload), 0o644),
    }))
    portable = output / f"{name}.tar.gz"
    with tarfile.open(portable, "w:gz", format=tarfile.GNU_FORMAT) as archive:
        archive.add(stage, arcname=name)
    (output / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in (ipk, portable)))
    print(f"已生成：{ipk}\n已生成：{portable}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--arch", choices=TARGETS, required=True)
    parser.add_argument("--package-arch")
    args = parser.parse_args()
    package(args.binary.resolve(), args.version, args.output.resolve(), args.arch, args.package_arch)
