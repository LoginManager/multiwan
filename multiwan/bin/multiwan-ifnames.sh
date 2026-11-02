#!/bin/bash
# multiwan-ifnames.sh — يسمّي كروت الـVM بنفس أسماء Proxmox (net0, net1, ...) ويحدّث كل الإعدادات
# يقرأ /etc/multiwan/ifnames — سطر لكل كرت:  MAC الاسم [تعليق]
#     مثال:  bc:24:11:49:a3:2b net2 Fiber02 VLAN1104
# (يكتبه proxmox-deploy.sh --ifnames من qm config)
#  - الإدارة والـLAN يُعرفان من multiwan.conf، وكل كرت آخر يصبح مدخلاً: netN → wan(N-1) بتعليق الـVLAN
#  - يحدّث multiwan.conf و uplinks.csv و lines.csv و nftables و systemd-networkd
#  - الأسماء الجديدة تُطبَّق بعد إعادة الإقلاع
set -e
R=${MULTIWAN_ROOT:-}   # للاختبار فقط
D=$R/etc/multiwan; NET=$R/etc/systemd/network; MAP=$D/ifnames; NFT=$R/etc/nftables.conf
[ -s $MAP ] || { echo "لا يوجد $MAP"; exit 1; }
. $D/multiwan.conf

cur_name() { local d; for d in $R/sys/class/net/*; do [ -e "$d/device" ] && [ "$(cat "$d/address")" = "$1" ] && { basename "$d"; return; }; done; }

declare -A REN CMT ISWAN
WANS=()
rm -f $NET/10-multiwan-*.link
while read -r mac name cmt; do
  mac=$(echo "$mac" | tr 'A-F' 'a-f')
  [ -z "$mac" ] || [ -z "$name" ] && continue
  printf '[Match]\nMACAddress=%s\n[Link]\nName=%s\n' "$mac" "$name" > $NET/10-multiwan-$name.link
  old=$(cur_name "$mac"); [ -n "$old" ] && REN[$old]=$name
  CMT[$name]=$cmt
  if [ "$old" = "$MGMT_IF" ] || [ "$name" = "$MGMT_IF" ] || [ "$old" = "$LAN_IF" ] || [ "$name" = "$LAN_IF" ]; then continue; fi
  WANS+=("$name"); ISWAN[$name]=1
done < $MAP

# 1) الإدارة/LAN في multiwan.conf و networkd و nftables
for o in "${!REN[@]}"; do
  n=${REN[$o]}; [ "$o" = "$n" ] && continue
  sed -i -E "s/^(MGMT_IF|LAN_IF)=$o([[:space:]]|\$)/\1=$n\2/" $D/multiwan.conf
  sed -i "s/^Name=$o\$/Name=$n/" $NET/*.network 2>/dev/null || true
  sed -i "s/\"$o\"/\"$n\"/g" $NFT 2>/dev/null || true
done

# 2) المداخل: netN → wan(N-1)، بالترتيب، مع تعليق الـVLAN من Proxmox
declare -A UMAP
tmp=$(mktemp); rest=$(mktemp)
while IFS=, read -r n i c; do
  n=$(echo "$n" | tr -d '\r '); i=$(echo "$i" | tr -d '\r '); c=$(echo "$c" | tr -d '\r')
  [ -z "$n" ] && continue
  [ -n "${REN[$i]:-}" ] && i=${REN[$i]}
  if [ -n "${ISWAN[$i]:-}" ]; then UMAP[$n]=$i   # الاسم القديم → الكرت (يُسمّى لاحقاً)
  else echo "$n,$i,$c" >> "$rest"; fi
done < $D/uplinks.csv
wname() { local k=${1//[^0-9]/}; echo "wan$(( ${k:-1} - 1 ))"; }
for w in $(printf '%s\n' "${WANS[@]}" | sort -V); do
  echo "$(wname "$w"),$w,${CMT[$w]}" >> "$tmp"
done
cat "$rest" >> "$tmp"; rm -f "$rest"
cp $D/uplinks.csv $D/uplinks.csv.bak; mv "$tmp" $D/uplinks.csv; chmod 600 $D/uplinks.csv

# 3) الخطوط التي تشير لاسم مدخل قديم → الاسم الجديد
if [ -s $D/lines.csv ]; then
  cp $D/lines.csv $D/lines.csv.bak; tmp=$(mktemp)
  while IFS= read -r line || [ -n "$line" ]; do
    IFS=, read -r u p w m up <<< "$line"; key=$(echo "$up" | tr -d '\r ')
    if [ -n "$key" ] && [ -n "${UMAP[$key]:-}" ]; then echo "$u,$p,$w,$m,$(wname "${UMAP[$key]}")"; else echo "$line"; fi
  done < $D/lines.csv > "$tmp"
  mv "$tmp" $D/lines.csv; chmod 600 $D/lines.csv
fi

# 4) ملفات networkd للمداخل (مثل install.sh)
rm -f $NET/20-up-*.network
while IFS=, read -r n i c; do i=$(echo "$i" | tr -d '\r '); [ -z "$i" ] && continue
  printf '[Match]\nName=%s\n[Network]\nLinkLocalAddressing=no\nIPv6AcceptRA=no\n' "$i" > $NET/20-up-$i.network
done < $D/uplinks.csv

# 5) الأسماء تُطبَّق من initramfs عند الإقلاع
[ -n "$R" ] || update-initramfs -u >/dev/null 2>&1 || true

echo "الأسماء:"; for o in "${!REN[@]}"; do echo "  $o → ${REN[$o]}"; done | sort -V -k3
echo "المداخل:"; sed 's/^/  /' $D/uplinks.csv
echo "أعد الإقلاع لتطبيق الأسماء"
