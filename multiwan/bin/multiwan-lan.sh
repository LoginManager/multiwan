#!/bin/bash
# multiwan-lan.sh <كرت> <IP/ماسك> — يغيّر كرت/عنوان الخروج للعملاء (LAN) ويطبّقه فوراً بدون إعادة إقلاع
#   مثال:  multiwan-lan.sh net1 192.168.121.1/24
# يحدّث: multiwan.conf (LAN_IF, LAN_IP) و 30-lan.network و nftables.conf
set -e
D=/etc/multiwan; C=$D/multiwan.conf; NET=/etc/systemd/network; NFT=/etc/nftables.conf
die() { echo "❌ $*"; exit 1; }
NEW_IF=${1:-}; NEW_IP=${2:-}
[ -n "$NEW_IF" ] && [ -n "$NEW_IP" ] || die "الاستخدام: $0 <كرت> <IP/ماسك>"
[[ $NEW_IF =~ ^[A-Za-z0-9_.-]+$ ]] || die "اسم كرت غير صالح: $NEW_IF"
. $C
OLD_IF=${LAN_IF:-}; OLD_IP=${LAN_IP:-}

# التحقق
[ -e /sys/class/net/$NEW_IF/device ] || die "الكرت $NEW_IF غير موجود (أو ليس كرتاً فعلياً)"
[ "$NEW_IF" != "${MGMT_IF:-}" ] || die "$NEW_IF هو كرت الإدارة"
cut -d, -f2 $D/uplinks.csv 2>/dev/null | tr -d '\r ' | grep -qx "$NEW_IF" && die "$NEW_IF مستخدم كمدخل PPPoE — احذف المدخل أولاً"
python3 - "$NEW_IP" "${MGMT_IP:-}" <<'P' || die "عنوان غير صالح: $NEW_IP — مثال 192.168.121.1/24 (ولا يتداخل مع شبكة الإدارة)"
import ipaddress, sys
i = ipaddress.ip_interface(sys.argv[1])
assert i.version == 4 and 8 <= i.network.prefixlen <= 30
assert i.ip not in (i.network.network_address, i.network.broadcast_address)
if sys.argv[2]: assert not i.network.overlaps(ipaddress.ip_interface(sys.argv[2]).network)
P
[ "$NEW_IF" = "$OLD_IF" ] && [ "$NEW_IP" = "$OLD_IP" ] && { echo "لا تغيير"; exit 0; }

# multiwan.conf (مع الحفاظ على باقي الملف)
setv() { if grep -q "^$1=" $C; then sed -i -E "s|^$1=[^[:space:]#]*|$1=$2|" $C; else echo "$1=$2" >> $C; fi; }
cp $C $C.bak
setv LAN_IF "$NEW_IF"; setv LAN_IP "$NEW_IP"

# systemd-networkd
rm -f $NET/20-up-$NEW_IF.network
cat > $NET/30-lan.network <<EOF
[Match]
Name=$NEW_IF
[Network]
Address=$NEW_IP
IPv6AcceptRA=no
EOF

# nftables: السماح والتمرير من الكرت الجديد
[ -n "$OLD_IF" ] && [ "$OLD_IF" != "$NEW_IF" ] && sed -i "s/\"$OLD_IF\"/\"$NEW_IF\"/g" $NFT

# تطبيق فوري
[ -n "$OLD_IF" ] && ip -4 addr flush dev "$OLD_IF" 2>/dev/null || true
networkctl reload
ip link set "$NEW_IF" up
networkctl reconfigure "$NEW_IF"
nft -f $NFT
sleep 1
now=$(ip -4 -o addr show dev "$NEW_IF" | awk '{print $4}' | head -1)
logger -t multiwan "LAN: ${OLD_IF:-?} ${OLD_IP:-?} → $NEW_IF $NEW_IP"
echo "✓ الخروج للعملاء: $NEW_IF ${now:-$NEW_IP} — gateway العملاء = ${NEW_IP%/*}"
