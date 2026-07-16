#!/usr/bin/env python3
"""Verify that Android ELF LOAD segments are compatible with 16 KB pages."""

from __future__ import annotations

import argparse
import struct
import sys
import zipfile
from pathlib import Path
from typing import Iterable


PT_LOAD = 1
DEFAULT_MINIMUM_ALIGNMENT = 16 * 1024


class AlignmentError(ValueError):
    pass


def _read_int(data: bytes, offset: int, size: int, endian: str) -> int:
    end = offset + size
    if offset < 0 or end > len(data):
        raise AlignmentError("ELF header is truncated")
    return int.from_bytes(data[offset:end], endian)


def load_segment_alignments(data: bytes) -> list[int]:
    if len(data) < 16 or data[:4] != b"\x7fELF":
        raise AlignmentError("not an ELF file")

    elf_class = data[4]
    endian_marker = data[5]
    if endian_marker == 1:
        endian = "little"
    elif endian_marker == 2:
        endian = "big"
    else:
        raise AlignmentError(f"unsupported ELF endianness: {endian_marker}")

    if elf_class == 1:
        program_header_offset = _read_int(data, 28, 4, endian)
        program_header_size = _read_int(data, 42, 2, endian)
        program_header_count = _read_int(data, 44, 2, endian)
        alignment_offset = 28
        alignment_size = 4
    elif elf_class == 2:
        program_header_offset = _read_int(data, 32, 8, endian)
        program_header_size = _read_int(data, 54, 2, endian)
        program_header_count = _read_int(data, 56, 2, endian)
        alignment_offset = 48
        alignment_size = 8
    else:
        raise AlignmentError(f"unsupported ELF class: {elf_class}")

    if program_header_size <= alignment_offset:
        raise AlignmentError("invalid ELF program header size")

    alignments: list[int] = []
    for index in range(program_header_count):
        offset = program_header_offset + index * program_header_size
        program_type = _read_int(data, offset, 4, endian)
        if program_type != PT_LOAD:
            continue
        alignments.append(
            _read_int(
                data,
                offset + alignment_offset,
                alignment_size,
                endian,
            )
        )

    if not alignments:
        raise AlignmentError("ELF file has no LOAD segments")
    return alignments


def _iter_inputs(paths: Iterable[Path]) -> Iterable[tuple[str, bytes]]:
    for path in paths:
        if path.is_dir():
            for library in sorted(path.rglob("*.so")):
                yield str(library), library.read_bytes()
            continue

        if path.suffix.lower() in {".apk", ".zip"}:
            with zipfile.ZipFile(path) as archive:
                names = sorted(
                    name
                    for name in archive.namelist()
                    if name.startswith("lib/") and name.endswith(".so")
                )
                for name in names:
                    yield f"{path}!/{name}", archive.read(name)
            continue

        yield str(path), path.read_bytes()


def verify_paths(paths: Iterable[Path], minimum_alignment: int) -> int:
    checked = 0
    failures: list[str] = []
    for label, data in _iter_inputs(paths):
        checked += 1
        try:
            alignments = load_segment_alignments(data)
        except AlignmentError as error:
            failures.append(f"{label}: {error}")
            continue

        below_minimum = [value for value in alignments if value < minimum_alignment]
        rendered = ", ".join(f"0x{value:x}" for value in alignments)
        if below_minimum:
            failures.append(
                f"{label}: LOAD alignment [{rendered}] is below "
                f"0x{minimum_alignment:x}"
            )
        else:
            print(f"[OK] {label}: LOAD alignment [{rendered}]")

    if checked == 0:
        failures.append("no Android shared libraries were found")
    if failures:
        for failure in failures:
            print(f"[FAIL] {failure}", file=sys.stderr)
        return 1
    print(f"[OK] verified {checked} shared libraries for 16 KB page compatibility")
    return 0


def _synthetic_elf64(alignment: int) -> bytes:
    data = bytearray(64 + 56)
    data[:4] = b"\x7fELF"
    data[4] = 2
    data[5] = 1
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<H", data, 54, 56)
    struct.pack_into("<H", data, 56, 1)
    struct.pack_into("<I", data, 64, PT_LOAD)
    struct.pack_into("<Q", data, 64 + 48, alignment)
    return bytes(data)


def run_self_test() -> int:
    aligned = load_segment_alignments(_synthetic_elf64(0x4000))
    unaligned = load_segment_alignments(_synthetic_elf64(0x1000))
    if aligned != [0x4000] or unaligned != [0x1000]:
        print("[FAIL] ELF parser self-test failed", file=sys.stderr)
        return 1
    print("[OK] ELF parser self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", type=Path)
    parser.add_argument(
        "--minimum-alignment",
        type=int,
        default=DEFAULT_MINIMUM_ALIGNMENT,
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test and run_self_test() != 0:
        return 1
    if not args.paths:
        return 0 if args.self_test else parser.error("at least one path is required")
    return verify_paths(args.paths, args.minimum_alignment)


if __name__ == "__main__":
    raise SystemExit(main())
