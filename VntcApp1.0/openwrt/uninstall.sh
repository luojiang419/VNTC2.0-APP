#!/bin/sh
set -eu
[ "$(id -u)" = 0 ] || { echo '请以 root 运行'; exit 1; }
[ "${1:-}" = '' ] || [ "${1:-}" = '--purge' ] || { echo '用法：uninstall.sh [--purge]'; exit 1; }
if command -v opkg >/dev/null 2>&1 && opkg status vntc-openwrt 2>/dev/null | grep -q '^Status:.* installed'; then
    opkg remove vntc-openwrt
else
    if [ -x /etc/init.d/vntc ]; then
        /etc/init.d/vntc stop
        /etc/init.d/vntc disable
    fi
    [ ! -x /usr/libexec/vntc-firewall ] || /usr/libexec/vntc-firewall remove
    rm -f /usr/bin/vntc-openwrt /etc/init.d/vntc /usr/libexec/vntc-setup /usr/libexec/vntc-firewall /lib/upgrade/keep.d/vntc
fi
if [ "${1:-}" = '--purge' ]; then
    rm -f /etc/vntc/config.json /etc/vntc/profiles.json /etc/vntc/settings.json
    rmdir /etc/vntc 2>/dev/null || true
fi
echo '卸载完成（默认保留 /etc/vntc 中的配置）。'
