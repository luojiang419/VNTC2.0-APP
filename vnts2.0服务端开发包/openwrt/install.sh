#!/bin/sh
set -eu
[ "$(id -u)" = 0 ] || { echo '请以 root 运行'; exit 1; }
[ -f /etc/openwrt_release ] || { echo '仅适用于 OpenWrt'; exit 1; }
cd "$(dirname "$0")"
case "$(uname -m)" in
    x86_64) expected=x86_64 ;;
    aarch64) expected=aarch64 ;;
    armv7l|armv8l)
        expected=armv7
        grep -Eq 'Features[[:space:]]*:.*[[:space:]]vfpv(3|3d16|4)([[:space:]]|$)' /proc/cpuinfo || {
            echo 'ARMv7 包要求 VFPv3/VFPv4，不适用于无浮点单元的芯片'; exit 1;
        } ;;
    *) echo '不支持此 CPU 架构'; exit 1 ;;
esac
[ "$(cat ARCH)" = "$expected" ] || { echo '安装包架构不匹配'; exit 1; }
sha256sum -c SHA256SUMS
./vnts2-openwrt --help >/dev/null
[ ! -x /etc/init.d/vnts2 ] || /etc/init.d/vnts2 stop
cp vnts2-openwrt /usr/bin/vnts2-openwrt.new
chmod 755 /usr/bin/vnts2-openwrt.new
mv /usr/bin/vnts2-openwrt.new /usr/bin/vnts2-openwrt
mkdir -p /usr/libexec /lib/upgrade/keep.d
cp files/vnts2.init /etc/init.d/vnts2
cp files/vnts2-setup /usr/libexec/vnts2-setup
chmod 755 /etc/init.d/vnts2 /usr/libexec/vnts2-setup
/usr/libexec/vnts2-setup
echo '/etc/vnts2/' > /lib/upgrade/keep.d/vnts2
/etc/init.d/vnts2 enable
/etc/init.d/vnts2 start
echo '安装完成，logread -e vnts2 查看日志。'
