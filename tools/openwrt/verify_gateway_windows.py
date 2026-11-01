#!/usr/bin/env python3
"""原生 Windows 临时客户端访问两套 ARM 网关，并用 FFmpeg 解码 RTSP。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request

from verify_gateway import DEPLOY, FOLDERS, Node, ROOT, wait


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--arch", choices=FOLDERS, action="append", help="只补测指定架构，保留旧报告")
    parser.add_argument("--leave-connected", action="store_true", help="保留本次测试架构的 TCP 连接")
    args = parser.parse_args()
    assert args.ffmpeg, "需要本机 FFmpeg"
    folder = DEPLOY / "validation" / ("windows-" + "-".join(args.arch) if args.arch else "windows")
    folder.mkdir(parents=True, exist_ok=True)
    config = json.loads((ROOT / "dist/windows-arm-interop/state/config.json").read_text(encoding="utf-8"))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    report = {"success": False, "cases": [], "video": []}
    target = folder / "report.json"

    def save():
        target.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    def api(path, method="GET"):
        req = urllib.request.Request("http://127.0.0.1:18083/api" + path, method=method,
            headers={"Authorization": "Bearer " + config["web"]["access_token"]})
        with opener.open(req, timeout=120) as response:
            return json.load(response)

    def decode(source, output, network=False):
        cmd = [args.ffmpeg, "-hide_banner", "-loglevel", "error"]
        if network:
            cmd += ["-rtsp_transport", "tcp"]
        cmd += ["-i", source, "-map", "0:v:0", "-f", "framehash", "-hash", "sha256", "-y", str(output)]
        result = subprocess.run(cmd, capture_output=True, timeout=120)
        output.with_suffix(".log").write_bytes(result.stderr)
        hashes = [line.rsplit(",", 1)[1].strip() for line in output.read_text().splitlines()
                  if line and not line.startswith("#")]
        assert result.returncode == 0 and len(hashes) == 200, (result.returncode, len(hashes), result.stderr)
        return hashes

    try:
        reference = decode(str(ROOT / "tmp/gateway-video.h264"), folder / "reference.framehash")
        assert api("/about")["platform"] == "windows/x86_64"
        for arch in (args.arch or ("aarch64", "armv7")):
            assert json.loads((DEPLOY / "validation" / arch / "report.json").read_text(encoding="utf-8"))["success"]
            expected = {}
            for i in range(2):
                node = Node(arch, i, folder / f"{arch}-{i}-source.log")
                expected[i] = node.cmd("sha256sum /opt/vntc-gateway-test/payload.bin").split()[0]
                node.ssh.close()
            for protocol in ("tcp", "quic"):
                profile = (json.loads((DEPLOY / "live/x86_64-runtime.json").read_text(encoding="utf-8"))["windows_profiles"][protocol]
                           if arch == "x86_64" else f"win-{arch}-{protocol}")
                api(f"/profiles/{profile}/connect", "POST")
                wait("Windows registration", lambda: api("/status")["online_peer_count"] >= 2)
                status = api("/status")
                assert status["connected_server"].startswith(protocol + "://"), status
                ready_started = time.monotonic()
                attempts = {}
                for i in range(2):
                    ip = f"10.26.0.{i + 2}"
                    def fetch():
                        attempts[ip] = attempts.get(ip, 0) + 1
                        with opener.open(f"http://{ip}:18081/payload.bin", timeout=10) as response:
                            return response.read()
                    # 注册完成后仍需等待实际对端通路，和原生互通验收采用相同原则。
                    payload = wait("Windows mapped service " + ip, fetch, 120)
                    assert hashlib.sha256(payload).hexdigest() == expected[i]
                status = api("/status")
                assert status["connected_server"].startswith(protocol + "://"), status
                report["cases"].append({"architecture": arch, "protocol": protocol,
                    "two_gateway_http_sha256": True, "status": status,
                    "ready_and_transfer_seconds": round(time.monotonic() - ready_started, 3),
                    "service_attempts": attempts})
                save()
                print(f"PASS Windows -> {arch} {protocol}: two gateway mappings", flush=True)
                if protocol == "tcp":
                    frames = decode("rtsp://10.26.0.2:18554/live", folder / (arch + ".framehash"), True)
                    assert frames == reference, "远端解码帧与原始视频不一致"
                    report["video"].append({"architecture": arch, "decoded_frames": len(frames),
                        "all_decoded_frame_sha256_match": True})
                    save()
                    print(f"PASS Windows FFmpeg -> {arch}: 200 video frames verified", flush=True)
        final_profile = "win-aarch64-tcp"
        if args.leave_connected:
            final_arch = (args.arch or ["aarch64", "armv7"])[-1]
            final_profile = (json.loads((DEPLOY / "live/x86_64-runtime.json").read_text(encoding="utf-8"))["windows_profiles"]["tcp"]
                             if final_arch == "x86_64" else f"win-{final_arch}-tcp")
        api(f"/profiles/{final_profile}/connect", "POST")
        wait("final Windows connection", lambda: api("/status")["online_peer_count"] >= 2)
        report.update(success=True, final_status=api("/status"))
        save()
        print("ALL_WINDOWS_GATEWAY_TESTS_PASSED", flush=True)
    except Exception as error:
        report["error"] = str(error)
        save()
        raise


if __name__ == "__main__":
    main()
