#!/bin/bash
# multiwan-apply.sh — يعيد توليد peers/secrets/weights من lines.csv ويعيد تشغيل الخطوط المتغيّرة فقط
set -e
D=/etc/multiwan; CSV=$D/lines.csv
exec 8>/run/multiwan-apply.lock; flock 8
PLUGIN=rp-pppoe.so; ls /usr/lib/pppd/*/pppoe.so >/dev/null 2>&1 && PLUGIN=pppoe.so

declare -A OLD OLDMAC OLDLINK
for f in /etc/ppp/peers/line*; do [ -e "$f" ] && OLD[$(basename $f)]=$(md5sum "$f" | cut -d' ' -f1); done
for d in /sys/class/net/mv*; do
  [ -e "$d" ] || continue; n=$(basename $d)
  OLDMAC[$n]=$(cat $d/address); OLDLINK[$n]=$(ip -o link show $n | sed -n 's/^[0-9]*: mv[0-9]*@\([^:]*\):.*/\1/p')
done
OLDN=$(ls /etc/ppp/peers/ 2>/dev/null | grep -c '^line[0-9]*$' || true)

mkdir -p /etc/ppp/peers
: > $D/weights; : > /etc/ppp/chap-secrets; : > /etc/ppp/pap-secrets
rm -f /etc/ppp/peers/line*
i=0
while IFS=, read -r u p w m up; do
  u=$(echo "$u"|tr -d '\r '); p=$(echo "$p"|tr -d '\r '); w=$(echo "$w"|tr -d '\r '); w=${w:-1}
  [ -z "$u" ] && continue
  echo "$i $w" >> $D/weights
  printf '"%s" * "%s" *\n' "$u" "$p" | tee -a /etc/ppp/chap-secrets >> /etc/ppp/pap-secrets
  cat > /etc/ppp/peers/line$i <<P
plugin $PLUGIN mv$i
user "$u"
unit $i
noipdefault
noauth
nodefaultroute
nodetach
lcp-echo-interval 10
lcp-echo-failure 3
mtu 1492
mru 1492
P
  i=$((i+1))
done < "$CSV"
N=$i
chmod 600 /etc/ppp/chap-secrets /etc/ppp/pap-secrets

j=$N; while [ $j -lt $OLDN ]; do systemctl disable --now pppoe@$j >/dev/null 2>&1 || true; ip link del mv$j 2>/dev/null || true; j=$((j+1)); done

/usr/local/sbin/macvlan-up.sh

for j in $(seq 0 $((N-1))); do
  [ -e /sys/class/net/mv$j ] || continue
  new=$(md5sum /etc/ppp/peers/line$j | cut -d' ' -f1)
  newmac=$(cat /sys/class/net/mv$j/address)
  newlink=$(ip -o link show mv$j | sed -n 's/^[0-9]*: mv[0-9]*@\([^:]*\):.*/\1/p')
  if [ -z "${OLD[line$j]}" ]; then
    systemctl enable --now pppoe@$j >/dev/null 2>&1
  elif [ "${OLD[line$j]}" != "$new" ] || [ "${OLDMAC[mv$j]}" != "$newmac" ] || [ "${OLDLINK[mv$j]}" != "$newlink" ]; then
    systemctl is-enabled pppoe@$j >/dev/null 2>&1 && systemctl restart pppoe@$j || true
  fi
done
echo "applied $N lines"
