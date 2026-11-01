#!/usr/bin/env python3
"""生成用于 RTSP 网关验收的 20 秒 H.264 测试图，不包含用户媒体。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parents[2] / "tmp/gateway-video.h264")
    args = parser.parse_args()
    assert args.ffmpeg, "请通过 --ffmpeg 指定本机 FFmpeg"
    assert not args.output.exists(), "保留已验收的视频；需要重建时请指定新的 --output"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "testsrc2=size=160x90:rate=10", "-t", "20", "-an", "-c:v", "libx264", "-threads", "1",
        "-preset", "ultrafast", "-tune", "zerolatency", "-x264-params",
        "keyint=10:scenecut=0:bframes=0", "-pix_fmt", "yuv420p", "-f", "h264", str(args.output)], check=True)
    parts = re.split(b"\x00\x00\x00?\x01", args.output.read_bytes())
    assert not parts[0] and len(parts) > 200
    args.output.write_bytes(b"".join(b"\x00\x00\x00\x01" + nal for nal in parts[1:]))
    print("已生成测试视频：" + str(args.output))


if __name__ == "__main__":
    main()
