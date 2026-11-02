#!/bin/bash
# multiwan-reconnect.sh — إعادة الاتصال المجدولة (يُستدعى كل دقيقة من cron)
# reconnect.conf: MODE=random_each|cycle|off  MIN_HOURS MAX_HOURS  EVERY_HOURS SPREAD_SEC RANDOM_ORDER  ONLY_UP
#   random_each : كل خط موعد عشوائي مستقل بين MIN و MAX ساعة
#   cycle       : دورة لكل الخطوط كل EVERY_HOURS ساعة بفاصل SPREAD_SEC
D=/etc/multiwan; S=/var/lib/multiwan; mkdir -p $S
. $D/reconnect.conf 2>/dev/null
MODE=${MODE:-off}; [ "$MODE" = off ] && exit 0
N=$(grep -c . $D/lines.csv); now=$(date +%s)
exec 6>/run/multiwan-reconnect.lock; flock -n 6 || exit 0
isup() { ip -4 -o addr show dev ppp$1 2>/dev/null | grep -q inet; }
ok()   { systemctl is-enabled -q pppoe@$1 2>/dev/null && { [ "${ONLY_UP:-1}" != 1 ] || isup $1; }; }

if [ "$MODE" = random_each ]; then
  MIN=$(awk -v h="${MIN_HOURS:-1}" 'BEGIN{printf "%d",h*3600}'); MAX=$(awk -v h="${MAX_HOURS:-6}" 'BEGIN{printf "%d",h*3600}'); [ $MAX -lt $MIN ] && MAX=$MIN
  newdue() { echo $(( now + MIN + RANDOM * ((MAX-MIN)+1) / 32768 )); }
  for i in $(seq 0 $((N-1))); do
    f=$S/next-$i
    systemctl is-enabled -q pppoe@$i 2>/dev/null || { rm -f $f; continue; }
    [ -f $f ] || { newdue > $f; continue; }
    [ $now -lt $(cat $f) ] && continue
    if ok $i; then systemctl restart pppoe@$i; logger -t multiwan "random reconnect ppp$i"; fi
    newdue > $f
  done
  for f in $S/next-*; do [ -e "$f" ] || continue; k=${f##*-}; [ "$k" -ge "$N" ] && rm -f "$f"; done
elif [ "$MODE" = cycle ]; then
  H=${EVERY_HOURS:-6}; [ "$H" -le 0 ] && exit 0
  last=$(cat $S/cycle-last 2>/dev/null || echo 0)
  [ $((now-last)) -lt $((H*3600)) ] && [ -z "$FORCE" ] && exit 0
  echo $now > $S/cycle-last
  logger -t multiwan "cycle reconnect started"
  if [ "${RANDOM_ORDER:-1}" = 1 ]; then order=$(shuf -i 0-$((N-1))); else order=$(seq 0 $((N-1))); fi
  for j in $order; do
    ok $j || continue
    systemctl restart pppoe@$j
    [ "${SPREAD_SEC:-0}" -gt 0 ] && sleep $(( SPREAD_SEC + RANDOM % (SPREAD_SEC/2+1) ))
  done
  logger -t multiwan "cycle reconnect finished"
fi
exit 0
