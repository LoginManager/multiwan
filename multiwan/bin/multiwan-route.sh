#!/bin/bash
# multiwan-route.sh — يُستدعى من ip-up.d / ip-down.d وكذلك من المُصلّح الدوري (بدون معاملات)
# يبني ECMP default route من كل خطوط ppp الحيّة + لكل خط N جدول 100+N وقاعدتان:
#   from <IP الخط>  → جدوله (الرد من نفس الخط)            pref 1000+N
#   fwmark 100+N    → جدوله (ثبات اتصالات العملاء على خطها) pref 2000+N   (العلامة من nftables)
IF=$1; LOCAL=$4; REMOTE=$5
DOWN=0; [[ "$0" == *ip-down* ]] && DOWN=1
exec 9>/run/multiwan.lock; flock 9

line_up() {  # line_up pppN local remote — جدول الخط وقاعدتاه (idempotent)
  local u=${1#ppp}; local t=$((100+u))
  ip route replace default via $3 dev $1 table $t
  if ! ip rule show pref $((1000+u)) | grep -q "from $2 "; then
    ip rule del pref $((1000+u)) 2>/dev/null; ip rule add from $2 table $t pref $((1000+u))
  fi
  ip rule show pref $((2000+u)) | grep -q fwmark || ip rule add fwmark $t table $t pref $((2000+u))
}
line_down() {
  local u=${1#ppp}
  ip rule del pref $((1000+u)) 2>/dev/null; ip rule del pref $((2000+u)) 2>/dev/null
  ip route flush table $((100+u)) 2>/dev/null
}

if [ -n "$IF" ]; then
  if [ $DOWN -eq 0 ]; then line_up $IF $LOCAL $REMOTE; else line_down $IF; fi
fi

NH=""; cnt=0
for d in /sys/class/net/ppp*; do
  [ -e "$d" ] || continue
  n=$(basename $d); [ $DOWN -eq 1 ] && [ "$n" = "$IF" ] && continue
  read -r loc gw < <(ip -4 -o addr show dev $n 2>/dev/null | awk '{for(k=1;k<=NF;k++) if($k=="peer") {print $4, $(k+1)}}' | cut -d/ -f1)
  [ -z "$gw" ] && continue
  [ -n "$IF" ] || line_up $n $loc $gw   # المُصلّح: تأكد من جدول/قواعد كل خط حي
  w=$(awk -v u=${n#ppp} '$1==u{print $2}' /etc/multiwan/weights 2>/dev/null); w=${w:-1}
  NH="$NH nexthop via $gw dev $n weight $w"; cnt=$((cnt+1)); one="via $gw dev $n"
done
if [ -n "$NH" ]; then
  want=$(echo $NH | tr -s ' ')
  [ $cnt -eq 1 ] && want=$one   # خط واحد: النواة تعرضه "default via X dev pppN" بدون nexthop
  have=$(ip route show default | sed 's/^default//' | tr '\n' ' ' | sed 's/onlink//g;s/linkdown//g' | tr -s ' ' | sed 's/^ //;s/ $//')
  if [ "$want" != "$have" ]; then ip route replace default $NH; [ -n "$IF" ] || logger -t multiwan "reconciled: $cnt active"; fi
else
  ip route del default 2>/dev/null
fi
[ -n "$IF" ] && logger -t multiwan "$IF $( [ $DOWN -eq 1 ] && echo DOWN || echo UP ) — active: $cnt"
exit 0
