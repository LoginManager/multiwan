#!/bin/bash
# macvlan-up.sh — ينشئ macvlan لكل خط فوق المدخل (الكرت) المحدد له
# lines.csv   : user,pass,weight,mac,uplink
# uplinks.csv : name,iface,comment
D=/etc/multiwan
CSV=$D/lines.csv; UPL=$D/uplinks.csv
declare -A IF
while IFS=, read -r n i c; do n=$(echo "$n"|tr -d '\r '); i=$(echo "$i"|tr -d '\r '); [ -n "$n" ] && [ -n "$i" ] && IF[$n]=$i; done < "$UPL"
DEF=$(head -1 "$UPL" | cut -d, -f1 | tr -d '\r ')
for i in "${IF[@]}"; do ip link set "$i" up 2>/dev/null; done
k=0
while IFS=, read -r u p w m up; do
  u=$(echo "$u"|tr -d '\r '); m=$(echo "$m"|tr -d '\r '|tr 'A-F' 'a-f'); up=$(echo "$up"|tr -d '\r ')
  [ -z "$u" ] && continue
  [ -z "$up" ] || [ -z "${IF[$up]}" ] && up=$DEF
  link=${IF[$up]}
  [ -z "$m" ] && m=$(printf '02:aa:bb:00:%02x:%02x' $((k/256)) $((k%256)))
  cur=$(cat /sys/class/net/mv$k/address 2>/dev/null || true)
  curlink=$(ip -o link show mv$k 2>/dev/null | sed -n 's/^[0-9]*: mv[0-9]*@\([^:]*\):.*/\1/p')
  if [ -n "$cur" ] && { [ "$cur" != "$m" ] || [ "$curlink" != "$link" ]; }; then ip link del mv$k; cur=""; fi
  if [ -z "$cur" ]; then
    ip link add mv$k link "$link" address "$m" type macvlan mode bridge || { logger -t multiwan "mv$k: cannot create on $link"; k=$((k+1)); continue; }
  fi
  ip link set mv$k up
  k=$((k+1))
done < "$CSV"
