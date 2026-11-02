#!/bin/bash
# multiwan-failover.sh — كل 5 دقائق: خط مفعّل بدون IP لمدة ≥ FAILOVER_HOURS يُستبدل بأول خط احتياط
D=/etc/multiwan
. $D/failover.conf 2>/dev/null
HOURS=${FAILOVER_HOURS:-24}
CSV=$D/lines.csv; RES=$D/reserve.csv; FAILED=$D/failed.csv
mkdir -p /var/lib/multiwan
exec 7>/run/multiwan-failover.lock; flock -n 7 || exit 0
now=$(date +%s); N=$(grep -c . $CSV); changed=0
for i in $(seq 0 $((N-1))); do
  f=/var/lib/multiwan/down-$i
  systemctl is-enabled -q pppoe@$i 2>/dev/null || { rm -f $f; continue; }
  if ip -4 -o addr show dev ppp$i 2>/dev/null | grep -q inet; then rm -f $f; continue; fi
  [ -f $f ] || { echo $now > $f; continue; }
  dur=$(( (now-$(cat $f))/3600 )); [ $dur -lt $HOURS ] && continue
  spare=$(grep -m1 . $RES || true)
  [ -z "$spare" ] && { logger -t multiwan "failover: ppp$i down ${dur}h but reserve empty"; continue; }
  old=$(sed -n "$((i+1))p" $CSV); olduser=${old%%,*}
  sed -i '0,/^.*[^[:space:]].*$/{/^.*[^[:space:]].*$/d}' $RES
  # الاحتياط يرث المدخل القديم إن لم يحدد مدخلاً
  IFS=, read -r su sp sw sm sup <<< "$spare"; oup=$(echo "$old" | cut -d, -f5); [ -z "$sup" ] && sup=$oup
  esc=$(printf '%s' "$su,$sp,${sw:-1},$sm,$sup" | sed 's/[&/\]/\\&/g')
  sed -i "$((i+1))s/.*/$esc/" $CSV
  echo "$(date '+%F %T'),$i,$old" >> $FAILED
  rm -f $f; changed=1
  logger -t multiwan "failover: ppp$i ($olduser) down ${dur}h → replaced by $su"
done
[ $changed -eq 1 ] && /usr/local/sbin/multiwan-apply.sh >/dev/null
exit 0
