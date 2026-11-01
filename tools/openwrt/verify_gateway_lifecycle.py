#!/usr/bin/env python3
"""在已完成网关数据面验收的 B 节点验证配置保留和卸载/离线重装。"""
import argparse
import hashlib
import json
from pathlib import Path

from verify_gateway import DEPLOY, FOLDERS, Node, wait


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=FOLDERS, required=True)
    args = parser.parse_args()
    folder = DEPLOY / "validation" / args.arch
    assert json.loads((folder / "report.json").read_text(encoding="utf-8"))["success"]
    report = {"architecture": args.arch, "checks": [], "success": False}
    target = folder / "lifecycle.json"
    b = Node(args.arch, 1, folder / "lifecycle-commands.log")
    a = Node(args.arch, 0, folder / "lifecycle-source.log")

    def save():
        target.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    def passed(name, **evidence):
        report["checks"].append({"name": name, "passed": True, **evidence})
        save()
        print("PASS " + args.arch + ": " + name, flush=True)

    def hashes():
        return b.cmd("sha256sum /etc/vntc/config.json /etc/vntc/profiles.json /etc/config/vntc_gateway")

    try:
        remote_hash = a.cmd("sha256sum /opt/vntc-gateway-test/payload.bin").split()[0]
        before = hashes()
        before_firewall = b.cmd("uci show firewall | grep -v -E '^firewall\\.(vntcg_|vntc_openwrt)'")
        b.cmd("uci set firewall.vntcg_map_collision=rule; "
              "uci set firewall.vntcg_map_collision.name='unowned-gateway-test'; "
              "uci set firewall.vntcg_map_collision.src=lan; "
              "uci set firewall.vntcg_map_collision.proto=tcp; "
              "uci set firewall.vntcg_map_collision.dest_port=65533; "
              "uci set firewall.vntcg_map_collision.target=REJECT; uci commit firewall; "
              "uci set vntc_gateway.collision=service; uci set vntc_gateway.collision.proto=tcp; "
              "uci set vntc_gateway.collision.listen_port=19001; "
              "uci set vntc_gateway.collision.dest_ip=192.168.60.100; "
              "uci set vntc_gateway.collision.dest_port=18090; uci commit vntc_gateway")
        previous = b.cmd("sha256sum /etc/config/firewall")
        code, error = b.cmd("/usr/libexec/vntc-gateway apply", ok=False)
        assert code != 0 and "vntcg_map_collision" in error
        assert previous == b.cmd("sha256sum /etc/config/firewall")
        b.cmd("uci delete vntc_gateway.collision; uci commit vntc_gateway")
        assert before == hashes()
        passed("规则名称被其他配置占用时拒绝应用且不改写防火墙")
        portable = next((DEPLOY / args.arch).glob("VNTC_OpenWrt_*.tar.gz"))
        report["portable_sha256"] = hashlib.sha256(portable.read_bytes()).hexdigest()
        b.upload(portable.read_bytes(), "/tmp/vntcg-portable.tar.gz")
        b.cmd("mkdir -p /tmp/vntcg-portable; tar xzf /tmp/vntcg-portable.tar.gz -C /tmp/vntcg-portable")
        installer = "/tmp/vntcg-portable/VNTC_OpenWrt_4.8.40_" + args.arch
        for mode in ("opkg", "portable"):
            if mode == "opkg":
                b.cmd("opkg remove vntc-openwrt", timeout=180)
            else:
                b.cmd(f"cd {installer} && sh uninstall.sh", timeout=180)
            assert before == hashes()
            assert b.cmd("uci get firewall.vntcg_map_collision.name").strip() == "unowned-gateway-test"
            managed = b.cmd("uci show firewall | grep -E '^firewall\\.(vntcg_|vntc_openwrt)' || true")
            assert all("vntcg_map_collision" in line for line in managed.splitlines())
            assert before_firewall == b.cmd("uci show firewall | grep -v -E '^firewall\\.(vntcg_|vntc_openwrt)'")
            b.cmd(f"cd {installer} && sh install.sh", timeout=180)
            wait("offline WebUI", lambda: b.api("/health"))
            wait("offline VNT", b.running, 240)
            assert before == hashes()
            expected = b.cmd("sha256sum /opt/vntc-gateway-test/payload.bin").split()[0]
            local = b.ns("wget -qO /tmp/vntcg-local-after-install -T 15 http://192.168.60.100:18090/payload.bin && sha256sum /tmp/vntcg-local-after-install")
            assert local.split()[0] == expected
            remote = wait("remote after reinstall", lambda: b.ns("wget -qO /tmp/vntcg-after-install -T 20 http://10.26.0.2:18081/payload.bin && sha256sum /tmp/vntcg-after-install"), 180)
            assert remote.split()[0] == remote_hash
            assert "192.168.50.0/24" in b.cmd("ip route show proto 186")
            passed(mode + " 卸载清理受管规则、保留配置和其他规则，离线安装后恢复本地与远端访问")
        b.cmd("test \"$(uci get firewall.vntcg_map_collision.name)\" = unowned-gateway-test; "
              "uci delete firewall.vntcg_map_collision; uci commit firewall; /etc/init.d/firewall reload")
        assert before == hashes()
        report.update(success=True, final_status=b.api("/status"))
        save()
        print("ALL_GATEWAY_LIFECYCLE_TESTS_PASSED " + args.arch, flush=True)
    except Exception as error:
        report["error"] = str(error)
        save()
        raise
    finally:
        b.ssh.close()
        a.ssh.close()


if __name__ == "__main__":
    main()
