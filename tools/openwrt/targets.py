"""OpenWrt 包架构和静态 ELF 校验；服务端、客户端共用。"""
from dataclasses import dataclass
import re
import struct


@dataclass(frozen=True)
class Target:
    rust: str
    package_arch: str
    machine: int
    elf_class: int


TARGETS = {
    "x86_64": Target("x86_64-unknown-linux-musl", "x86_64", 62, 2),
    "aarch64": Target("aarch64-unknown-linux-musl", "aarch64_generic", 183, 2),
    "armv7": Target("armv7-unknown-linux-musleabihf", "arm_cortex-a15_neon-vfpv4", 40, 1),
}


def package_architecture(arch, override=None):
    value = override or TARGETS[arch].package_arch
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", value):
        raise ValueError("包架构名称包含无效字符")
    matches = (value == "x86_64" if arch == "x86_64" else
               value.startswith("aarch64_") if arch == "aarch64" else
               bool(re.match(r"arm_(?:cortex-a(?:5|7|8|9|15|17)(?:_|$)|armv7)", value)))
    if not matches:
        raise ValueError(f"包架构 {value} 与 {arch} 不匹配")
    return value


def check_binary(path, arch):
    target = TARGETS[arch]
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[5] != 1:
        raise ValueError("要求 little-endian ELF 可执行文件")
    if data[4] != target.elf_class or struct.unpack_from("<H", data, 18)[0] != target.machine:
        raise ValueError(f"ELF CPU 架构与 {arch} 不匹配，拒绝打包")
    if struct.unpack_from("<H", data, 16)[0] not in (2, 3):
        raise ValueError("要求可执行 ELF")
    if data[4] == 2:
        offset = struct.unpack_from("<Q", data, 32)[0]
        size, count = struct.unpack_from("<HH", data, 54)
        minimum = 56
    else:
        offset = struct.unpack_from("<I", data, 28)[0]
        size, count = struct.unpack_from("<HH", data, 42)
        minimum = 32
        if not struct.unpack_from("<I", data, 36)[0] & 0x400:
            raise ValueError("ARMv7 包要求 hard-float EABI，拒绝混用 soft-float")
    if not count or size < minimum or offset + size * count > len(data):
        raise ValueError("ELF 程序头不完整")
    if any(struct.unpack_from("<I", data, offset + i * size)[0] == 3 for i in range(count)):
        raise ValueError("要求静态 musl 程序，不能包含 PT_INTERP 动态加载器")
