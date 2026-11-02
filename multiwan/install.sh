#!/bin/bash
# =====================================================================
#  MultiWAN — install.sh — تثبيت/تحديث كامل بأمر واحد (Debian 12 على Proxmox)
#  الاستخدام:  cd multiwan && bash install.sh
#  آمن لإعادة التشغيل: لا يلمس /etc/multiwan/*.csv أو *.conf الموجودة
# =====================================================================
set -e
[ "$(id -u)" = 0 ] || { echo "شغّله كـ root"; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
D=/etc/multiwan
mkdir -p $D /var/lib/multiwan/uploads /opt/multiwan /etc/ppp/peers /etc/ppp/ip-up.d /etc/ppp/ip-down.d

# ---------- 1) الإعدادات (أول مرة فقط) ----------
for f in multiwan.conf uplinks.csv lines.csv; do [ -e $D/$f ] || cp $SRC/etc/$f $D/$f; done
touch $D/reserve.csv $D/failed.csv $D/weights
[ -e $D/failover.conf ]  || echo "FAILOVER_HOURS=24" > $D/failover.conf
[ -e $D/reconnect.conf ] || printf 'MODE=off\nMIN_HOURS=1\nMAX_HOURS=6\nEVERY_HOURS=6\nSPREAD_SEC=60\nRANDOM_ORDER=1\nONLY_UP=1\n' > $D/reconnect.conf
chmod 600 $D/*.csv $D/multiwan.conf
. $D/multiwan.conf
echo "==> MGMT=$MGMT_IF ($MGMT_IP)  LAN=$LAN_IF ($LAN_IP)  uplinks: $(cut -d, -f1,2 $D/uplinks.csv | tr '\n' ' ')"

# ---------- 2) الشبكة (systemd-networkd) ----------
mkdir -p /etc/systemd/network /etc/cloud/cloud.cfg.d; rm -f /etc/network/interfaces
cat > /etc/systemd/network/10-mgmt.network <<EOF
[Match]
Name=$MGMT_IF
[Network]
Address=$MGMT_IP
DNS=$DNS
EOF
# ردود الإدارة (اللوحة/SSH) ترجع عبر gateway الإدارة من أي شبكة — دون أن يمر ترافيك العملاء منه
MGMT_NET=$(python3 -c 'import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)' "$MGMT_IP")
if [ -n "${TMP_GW:-}" ]; then cat >> /etc/systemd/network/10-mgmt.network <<EOF
[Route]
Destination=$MGMT_NET
Scope=link
Table=200
[Route]
Gateway=$TMP_GW
Table=200
[RoutingPolicyRule]
From=${MGMT_IP%/*}
Table=200
Priority=900
EOF
fi
cat > /etc/systemd/network/30-lan.network <<EOF
[Match]
Name=$LAN_IF
[Network]
Address=$LAN_IP
IPv6AcceptRA=no
EOF
rm -f /etc/systemd/network/20-up-*.network
while IFS=, read -r n i c; do i=$(echo "$i"|tr -d '\r '); [ -z "$i" ] && continue
cat > /etc/systemd/network/20-up-$i.network <<EOF
[Match]
Name=$i
[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
done < $D/uplinks.csv
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network.cfg
systemctl enable --now systemd-networkd >/dev/null 2>&1 || true
networkctl reload; sleep 2

# ---------- 3) الحزم + الكيرنل العادي (صورة cloud ما فيها PPPoE) ----------
export DEBIAN_FRONTEND=noninteractive
TMPROUTE=0; ip route show default | grep -q . || { ip route add default via $TMP_GW && TMPROUTE=1; }
# DNS مؤقت إن لم يكن الحل يعمل (الحزم تحتاجه فقط)
getent hosts deb.debian.org >/dev/null 2>&1 || { rm -f /etc/resolv.conf; echo "nameserver ${DNS:-8.8.8.8}" > /etc/resolv.conf; }
apt-get update -qq
apt-get install -y -qq ppp nftables qemu-guest-agent python3-flask python3-openpyxl >/dev/null
NEEDREBOOT=0
if uname -r | grep -q cloud; then
  echo "==> الكيرنل cloud لا يدعم PPPoE — تثبيت linux-image-amd64"
  apt-get install -y -qq linux-image-amd64 >/dev/null
  apt-get purge -y -qq 'linux-image-*cloud*' >/dev/null 2>&1 || true; update-grub >/dev/null 2>&1 || true
  NEEDREBOOT=1
fi
[ $TMPROUTE -eq 1 ] && ip route del default via $TMP_GW || true
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
# SSH للإدارة
ssh-keygen -A >/dev/null 2>&1 || true; mkdir -p /run/sshd
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-root.conf
systemctl enable --now ssh >/dev/null 2>&1 || true; systemctl restart ssh || true

# ---------- 4) السكربتات ----------
install -m 755 $SRC/bin/macvlan-up.sh $SRC/bin/multiwan-apply.sh $SRC/bin/pppoe-line.sh $SRC/bin/multiwan-route.sh $SRC/bin/multiwan-ifnames.sh \
               $SRC/bin/multiwan-failover.sh $SRC/bin/multiwan-reconnect.sh /usr/local/sbin/
install -m 755 $SRC/bin/wanstat /usr/local/bin/wanstat
ln -sf /usr/local/sbin/multiwan-route.sh /etc/ppp/ip-up.d/50-multiwan
ln -sf /usr/local/sbin/multiwan-route.sh /etc/ppp/ip-down.d/50-multiwan
install -m 644 $SRC/web/app.py /opt/multiwan/app.py
install -m 644 $SRC/systemd/* /etc/systemd/system/

# ---------- 5) NAT + sysctl ----------
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    oifname "ppp*" masquerade
  }
}
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    iifname { "$MGMT_IF", "$LAN_IF" } accept
    icmp type echo-request accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "$LAN_IF" oifname "ppp*" accept
    tcp flags syn tcp option maxseg size set rt mtu
  }
}
EOF
cat > /etc/sysctl.d/90-multiwan.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.fib_multipath_hash_policy=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.netfilter.nf_conntrack_max=1048576
EOF
sysctl --system >/dev/null
nft -f /etc/nftables.conf

# ---------- 6) تشغيل ----------
rm -f /etc/cron.d/pppoe-reconnect /etc/cron.d/pppoe-random-each
systemctl daemon-reload
systemctl enable multiwan-ifnames >/dev/null 2>&1 || true
systemctl enable --now nftables macvlan multiwan-web multiwan-reconcile.timer multiwan-failover.timer multiwan-reconnect.timer >/dev/null 2>&1
systemctl restart nftables macvlan multiwan-web
/usr/local/sbin/multiwan-apply.sh

echo
echo "==> تم. اللوحة: http://${MGMT_IP%/*}:${WEB_PORT:-8080}  ($ADMIN_USER / $ADMIN_PASS)"
echo "    wanstat | journalctl -t multiwan -f"
[ $NEEDREBOOT -eq 1 ] && echo "⚠  تم تبديل الكيرنل — نفّذ: reboot"
exit 0
