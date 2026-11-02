#!/bin/bash
# multiwan-route.sh — يُستدعى من ip-up.d / ip-down.d وكذلك من المُصلّح الدوري (بدون معاملات)
# يبني ECMP default route من كل خطوط ppp الحيّة + جدول توجيه لكل خط (للرد من نفس الخط)
IF=$1; LOCAL=$4; REMOTE=$5
DOWN=0; [[ "$0" == *ip-down* ]] && DOWN=1
exec 9>/run/multiwan.lock; flock 9

if [ -n "$IF" ]; then
  UNIT=${IF#ppp}; TBL=$((100+UNIT))
  if [ $DOWN -eq 0 ]; then
    ip route replace default via $REMOTE dev $IF table $TBL
    ip rule del pref $((1000+UNIT)) 2>/dev/null
    ip rule add from $LOCAL table $TBL pref $((1000+UNIT))
  else
    ip rule del pref $((1000+UNIT)) 2>/dev/null
    ip route flush table $TBL 2>/dev/null
  fi
fi

NH=""; cnt=0
for d in /sys/class/net/ppp*; do
  [ -e "$d" ] || continue
  n=$(basename $d); [ $DOWN -eq 1 ] && [ "$n" = "$IF" ] && continue
  gw=$(ip -4 -o addr show dev $n 2>/dev/null | awk '{for(k=1;k<=NF;k++) if($k=="peer") print $(k+1)}' | cut -d/ -f1)
  [ -z "$gw" ] && continue
  w=$(awk -v u=${n#ppp} '$1==u{print $2}' /etc/multiwan/weights 2>/dev/null); w=${w:-1}
  NH="$NH nexthop via $gw dev $n weight $w"; cnt=$((cnt+1))
done
if [ -n "$NH" ]; then
  want=$(echo $NH | tr -s ' ')
  have=$(ip route show default | sed 's/^default//' | tr '\n' ' ' | sed 's/onlink//g' | tr -s ' ' | sed 's/^ //;s/ $//')
  if [ "$want" != "$have" ]; then ip route replace default $NH; [ -n "$IF" ] || logger -t multiwan "reconciled: $cnt active"; fi
else
  ip route del default 2>/dev/null
fi
[ -n "$IF" ] && logger -t multiwan "$IF $( [ $DOWN -eq 1 ] && echo DOWN || echo UP ) — active: $cnt"
exit 0
