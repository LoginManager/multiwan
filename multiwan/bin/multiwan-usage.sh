#!/bin/bash
# multiwan-usage.sh — إجمالي التنزيل/الرفع لكل مستخدم عبر إعادة الاتصال (يُستدعى من ip-up.d و ip-down.d)
#   /var/lib/multiwan/usage.csv : user,rx,tx,since   مجموع الجلسات المنتهية (بايت) + وقت آخر تصفير
#   /run/multiwan/session-N     : user ifindex       الجلسة الحالية لـpppN
#   /run/multiwan/usage-base    : N ifindex rx tx    عند التصفير أثناء جلسة: ما قبل التصفير لا يُحسب
# اللوحة تعرض: usage.csv + عدّاد الجلسة الحالية (ناقص base إن وُجد)
IF=$1; [[ $IF == ppp* ]] || exit 0
UNIT=${IF#ppp}; R=/run/multiwan; DB=/var/lib/multiwan/usage.csv; BASE=$R/usage-base
mkdir -p $R /var/lib/multiwan
exec 8>/run/multiwan-usage.lock; flock 8
idx=$(cat /sys/class/net/$IF/ifindex 2>/dev/null || echo 0)
peer_user() { sed -n 's/^user "\(.*\)"$/\1/p' /etc/ppp/peers/line$UNIT 2>/dev/null; }

if [[ $0 == *ip-up* ]]; then
  echo "$(peer_user) $idx" > $R/session-$UNIT
  # base لجلسة سابقة على نفس الخط لم يعد له معنى
  [ -f $BASE ] && awk -v u="$UNIT" -v i="$idx" '!($1==u && $2!=i)' $BASE > $BASE.tmp && mv $BASE.tmp $BASE
  exit 0
fi

# ip-down: أضف بايتات الجلسة المنتهية (من pppd) لمستخدمها
user=""; sidx=$idx
[ -f $R/session-$UNIT ] && read -r user sidx < $R/session-$UNIT
[ -n "$user" ] || user=$(peer_user)
rx=${BYTES_RCVD:-0}; tx=${BYTES_SENT:-0}
if [ -f $BASE ]; then
  b=$(awk -v u="$UNIT" -v i="$sidx" '$1==u && $2==i {print $3, $4}' $BASE)
  if [ -n "$b" ]; then read -r brx btx <<< "$b"; rx=$(( rx > brx ? rx - brx : 0 )); tx=$(( tx > btx ? tx - btx : 0 )); fi
  awk -v u="$UNIT" '$1!=u' $BASE > $BASE.tmp && mv $BASE.tmp $BASE
fi
rm -f $R/session-$UNIT
[ -n "$user" ] || exit 0
touch $DB
awk -F, -v u="$user" -v r="$rx" -v t="$tx" -v now="$(date '+%F %T')" '
  $1==u { printf "%s,%.0f,%.0f,%s\n", $1, $2+r, $3+t, $4; f=1; next }
  NF { print }
  END { if (!f) printf "%s,%.0f,%.0f,%s\n", u, r, t, now }' $DB > $DB.tmp && mv $DB.tmp $DB
exit 0
