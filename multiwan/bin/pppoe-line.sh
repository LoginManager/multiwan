#!/bin/bash
# pppoe-line.sh N — يشغّل pppd للخط N: 3 محاولات بفاصل 15ث ثم محاولة كل ساعة
i=$1; fails=0
while true; do
  t0=$(date +%s)
  /usr/sbin/pppd call line$i
  dur=$(( $(date +%s) - t0 ))
  if [ $dur -gt 60 ]; then fails=0; else fails=$((fails+1)); fi
  if [ $fails -le 3 ]; then sleep 15; else sleep 3600; fi
done
