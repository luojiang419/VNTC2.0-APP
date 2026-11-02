#!/usr/bin/env python3
"""检查本轮 OpenWrt 包内容、静态 ELF 和版本，输出唯一命名的发布资产。"""
import argparse
import hashlib
import io
from pathlib import Path
import shutil
import tarfile
import tempfile

from targets import TARGETS, check_binary


def verify(folder, version, arch, client):
    prefix = "VNTC" if client else "VNTS"
    package = "vntc-openwrt" if client else "vnts2-openwrt"
    binary_name = "vntc-openwrt" if client else "vnts2-openwrt"
    revision = "2" if client else "1"
    ipk = folder / f"{package}_{version}-{revision}_{TARGETS[arch].package_arch}.ipk"
    portable = folder / f"{prefix}_OpenWrt_{version}_{arch}.tar.gz"
    with tarfile.open(ipk) as outer:
        with tarfile.open(fileobj=io.BytesIO(outer.extractfile("./control.tar.gz").read())) as control:
            metadata = control.extractfile("./control").read().decode()
            assert f"Version: {version}-{revision}\n" in metadata, "IPK 版本不一致"
            assert f"Architecture: {TARGETS[arch].package_arch}\n" in metadata, "IPK 架构不一致"
        with tarfile.open(fileobj=io.BytesIO(outer.extractfile("./data.tar.gz").read())) as payload:
            binary = payload.extractfile("./usr/bin/" + binary_name).read()
            if client:
                assert payload.extractfile("./usr/libexec/vntc-gateway").read(), "缺少网关脚本"
    with tempfile.TemporaryDirectory() as temporary:
        executable = Path(temporary) / binary_name
        executable.write_bytes(binary)
        check_binary(executable, arch)
    with tarfile.open(portable) as archive:
        top = f"{prefix}_OpenWrt_{version}_{arch}"
        assert archive.extractfile(top + "/VERSION").read().decode().strip() == version
        assert archive.extractfile(top + "/" + binary_name).read() == binary, "两种包机器码不一致"
        for line in archive.extractfile(top + "/SHA256SUMS").read().decode().splitlines():
            digest, name = line.split(maxsplit=1)
            assert hashlib.sha256(archive.extractfile(top + "/" + name).read()).hexdigest() == digest
    return ipk, portable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arch", choices=TARGETS, required=True)
    for name in ("client", "server", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    products = (*verify(args.client, args.version, args.arch, True),
                *verify(args.server, args.version, args.arch, False))
    args.output.mkdir(parents=True, exist_ok=True)
    for source in products:
        destination = args.output / source.name
        if destination.exists():
            raise FileExistsError(destination)
        shutil.copy2(source, destination)
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        destination.with_name(destination.name + ".sha256").write_text(
            f"{digest}  {destination.name}\n", encoding="utf-8")
        print(f"[OK] {destination.name} {digest}")


if __name__ == "__main__":
    main()
