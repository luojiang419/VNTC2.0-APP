#!/usr/bin/env python3
"""生成 OpenWrt 24.10 opkg 安装包和无需包管理器的离线安装包。"""
import argparse
import hashlib
import io
from pathlib import Path
import re
import shutil
import tarfile


def tar_bytes(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.GNU_FORMAT) as archive:
        for name, (content, mode) in entries.items():
            info = tarfile.TarInfo("./" + name)
            info.size, info.mode, info.mtime = len(content), mode, 0
            archive.addfile(info, io.BytesIO(content))
    return output.getvalue()


def package(binary, version, output):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[.-][a-zA-Z0-9.-]+)?", version):
        raise ValueError("版本格式必须为 x.y.z")
    source = Path(__file__).resolve().parent
    output.mkdir(parents=True, exist_ok=True)
    name = f"VNTC_OpenWrt_{version}_x86_64"
    stage = output / name
    stage.mkdir(exist_ok=True)
    (stage / "files").mkdir(exist_ok=True)
    shutil.copy2(binary, stage / "vntc-openwrt")
    (stage / "vntc-openwrt").chmod(0o755)
    (stage / "ARCH").write_text("x86_64\n")
    (stage / "VERSION").write_text(version + "\n")
    for relative in ("install.sh", "uninstall.sh", "files/vntc.init", "files/vntc-setup", "files/vntc-firewall", "README.md"):
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
        "lib/upgrade/keep.d/vntc": (b"/etc/vntc/\n", 0o644),
    }
    control = (
        f"Package: vntc-openwrt\nVersion: {version}-1\nArchitecture: x86_64\n"
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
[ "${1:-remove}" != remove ] || /usr/libexec/vntc-firewall remove
exit 0
'''
    ipk = output / f"vntc-openwrt_{version}-1_x86_64.ipk"
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
    return ipk


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "release/openwrt")
    args = parser.parse_args()
    package(args.binary.resolve(), args.version, args.output.resolve())
