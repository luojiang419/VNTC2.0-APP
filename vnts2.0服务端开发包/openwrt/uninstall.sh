#!/bin/sh
set -eu
[ "$(id -u)" = 0 ] || { echo '请以 root 运行'; exit 1; }
if command -v opkg >/dev/null 2>&1 && opkg status vnts2-openwrt 2>/dev/null | grep -q '^Status:.* installed'; then
    opkg remove vnts2-openwrt
else
    if [ -x /etc/init.d/vnts2 ]; then
        /etc/init.d/vnts2 stop
        /etc/init.d/vnts2 disable
    fi
    rm -f /usr/bin/vnts2-openwrt /etc/init.d/vnts2 /usr/libexec/vnts2-setup /lib/upgrade/keep.d/vnts2
fi
echo '已卸载程序，保留 /etc/vnts2 中的配置、数据库和密钥。'
