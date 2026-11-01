#!/bin/sh
set -eu

[ "$(id -u)" = 0 ] || { echo '请以 root 运行'; exit 1; }
[ -f /etc/openwrt_release ] || { echo '此安装器仅适用于 OpenWrt'; exit 1; }
cd "$(dirname "$0")"
case "$(uname -m)" in
    x86_64) expected=x86_64 ;;
    *) echo '本发行包仅支持 x86_64，请勿安装到其他架构'; exit 1 ;;
esac
[ "$(cat ARCH)" = "$expected" ] || { echo '安装包架构不匹配'; exit 1; }
sha256sum -c SHA256SUMS
if [ ! -c /dev/net/tun ]; then
    if command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install kmod-tun
    else
        echo '缺少 TUN，请通过系统包管理器安装匹配当前内核的 kmod-tun'; exit 1
    fi
fi
./vntc-openwrt --help >/dev/null
[ ! -x /etc/init.d/vntc ] || /etc/init.d/vntc stop
install_dir=/usr/bin
mkdir -p "$install_dir" /usr/libexec /etc/init.d
cp vntc-openwrt "$install_dir/vntc-openwrt.new"
chmod 755 "$install_dir/vntc-openwrt.new"
mv "$install_dir/vntc-openwrt.new" "$install_dir/vntc-openwrt"
cp files/vntc.init /etc/init.d/vntc
cp files/vntc-setup /usr/libexec/vntc-setup
cp files/vntc-firewall /usr/libexec/vntc-firewall
chmod 755 /etc/init.d/vntc /usr/libexec/vntc-setup /usr/libexec/vntc-firewall
/usr/libexec/vntc-setup
/usr/libexec/vntc-firewall install
# OpenWrt sysupgrade 识别 /lib/upgrade/keep.d。
mkdir -p /lib/upgrade/keep.d
echo '/etc/vntc/' > /lib/upgrade/keep.d/vntc
/etc/init.d/vntc enable
/etc/init.d/vntc start
echo '安装完成；logread -e vntc 可查看运行日志。'
