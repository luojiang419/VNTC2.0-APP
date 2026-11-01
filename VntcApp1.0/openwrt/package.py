#!/usr/bin/env python3
"""生成 OpenWrt 24.10 opkg 安装包和无需包管理器的离线安装包。"""
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


def package(binary, version, output, arch="x86_64", package_arch=None, revision=1):
    if not isinstance(revision, int) or revision < 1:
        raise ValueError("包修订号必须为正整数")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[.-][a-zA-Z0-9.-]+)?", version):
        raise ValueError("版本格式必须为 x.y.z")
    source = Path(__file__).resolve().parent
    check_binary(binary, arch)
    package_arch = package_architecture(arch, package_arch)
    output.mkdir(parents=True, exist_ok=True)
    name = f"VNTC_OpenWrt_{version}_{arch}"
    stage = output / name
    stage.mkdir(exist_ok=True)
    (stage / "files").mkdir(exist_ok=True)
    shutil.copy2(binary, stage / "vntc-openwrt")
    (stage / "vntc-openwrt").chmod(0o755)
    (stage / "ARCH").write_text(arch + "\n")
    (stage / "PACKAGE_ARCH").write_text(package_arch + "\n")
    (stage / "VERSION").write_text(version + "\n")
    for relative in ("install.sh", "uninstall.sh", "files/vntc.init", "files/vntc-setup", "files/vntc-firewall", "files/vntc-gateway", "files/vntc-gateway.conf", "README.md"):
        content = (source / relative).read_bytes().replace(b"\r\n", b"\n")
        (stage / relative).write_bytes(content)
        (stage / relative).chmod(0o644 if relative.endswith(".md") else 0o755)
    files = sorted(p for p in stage.rglob("*") if p.is_file() and p.name != "SHA256SUMS")
    (stage / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(stage).as_posix()}\n" for p in files))
    payload = {
        "usr/bin/vntc-openwrt": (binary.read_bytes(), 0o755),
        "etc/init.d/vntc": ((stage / "files/vntc.init").read_bytes(), 0o755),
        "usr/libexec/vntc-setup": ((stage / "files/vntc-setup").read_bytes(), 0o755),
        "usr/libexec/vntc-firewall": ((stage / "files/vntc-firewall").read_bytes(), 0o755),
        "usr/libexec/vntc-gateway": ((stage / "files/vntc-gateway").read_bytes(), 0o755),
        "etc/config/vntc_gateway": ((stage / "files/vntc-gateway.conf").read_bytes(), 0o600),
        "lib/upgrade/keep.d/vntc": (b"/etc/vntc/\n/etc/config/vntc_gateway\n", 0o644),
    }
    control = (
        f"Package: vntc-openwrt\nVersion: {version}-{revision}\nArchitecture: {package_arch}\n"
        "Maintainer: VNTC developers\nSection: net\nPriority: optional\n"
        f"Installed-Size: {sum(len(v[0]) for v in payload.values())}\n"
        "Depends: kmod-tun\nDescription: VNTC headless client with embedded WebUI and procd service\n"
    )
    postinst = b'''#!/bin/sh
set -e
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
/usr/libexec/vntc-setup
/usr/libexec/vntc-firewall install
/etc/init.d/vntc enable
/etc/init.d/vntc start
'''
    prerm = b'''#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
/etc/init.d/vntc stop
/etc/init.d/vntc disable
[ "${1:-remove}" != remove ] || /usr/libexec/vntc-gateway remove
[ "${1:-remove}" != remove ] || /usr/libexec/vntc-firewall remove
exit 0
'''
    ipk = output / f"vntc-openwrt_{version}-{revision}_{package_arch}.ipk"
    ipk.write_bytes(tar_bytes({
        "debian-binary": (b"2.0\n", 0o644),
        "control.tar.gz": (tar_bytes({"control": (control.encode(), 0o644),
                                      "postinst": (postinst, 0o755), "prerm": (prerm, 0o755),
                                      "conffiles": (b"/etc/config/vntc_gateway\n", 0o644)}), 0o644),
        "data.tar.gz": (tar_bytes(payload), 0o644),
    }))
    portable = output / f"{name}.tar.gz"
    with tarfile.open(portable, "w:gz", format=tarfile.GNU_FORMAT) as archive:
        archive.add(stage, arcname=name)
    (output / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in (ipk, portable)))
    print(f"已生成：{ipk}\n已生成：{portable}", flush=True)
    return ipk


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arch", choices=TARGETS, default="x86_64")
    parser.add_argument("--package-arch", help="必须匹配路由器 opkg print-architecture；不指定时用于 armsr 通用虚拟机")
    parser.add_argument("--revision", type=int, default=1, help="opkg 包修订号，不递增正式应用版本")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "release/openwrt")
    args = parser.parse_args()
    package(args.binary.resolve(), args.version, args.output.resolve(), args.arch, args.package_arch, args.revision)
