#!/bin/bash
# =====================================================================
#  proxmox-deploy.sh — تنصيب MultiWAN كامل على Proxmox بأمر واحد
#
#  يُشغَّل على عقدة Proxmox نفسها (كـ root) وينفّذ كل شيء:
#    1) ينزّل صورة Debian 12 (generic — كيرنل عادي يدعم PPPoE)
#    2) ينشئ VM جديدة: كرت إدارة + كرت LAN للعملاء + كرت لكل مدخل PPPoE (VLAN)
#    3) يضبط cloud-init (IP الإدارة، مفتاح SSH، كلمة السر) ويشغّل الـVM
#    4) يتعرّف على أسماء الكروت داخل الـVM حسب الـMAC ويكتب multiwan.conf و uplinks.csv
#    5) ينسخ المشروع ويشغّل install.sh داخل الـVM ويتأكد أن اللوحة تعمل
#
#  الاستخدام:
#    bash proxmox-deploy.sh            # يسألك عن كل إعداد (Enter = القيمة بين [])
#    bash proxmox-deploy.sh -y         # بدون أسئلة، القيم الافتراضية أو من المتغيرات:
#    VMID=105 MGMT_IP=10.10.60.150/24 MGMT_GW=10.10.60.1 WAN_TAGS="1104 1105 1106" \
#      ADMIN_PASS=MyPass123 bash proxmox-deploy.sh -y
#
#  WAN_TAGS: قائمة المداخل بمسافات. كل عنصر: tag  أو  bridge:tag  أو  bridge:-  (بدون tag)
#     الافتراضي 6 مداخل: "1104 1105 1106 1107 1108 1109"  — أو مثلاً "Fiber02:1104 Fiber03:200"
#  LINES_FILE: (اختياري) ملف CSV على Proxmox بالخطوط  user,pass,weight,mac,uplink
#
#  أسماء الكروت داخل الـVM تُضبط تلقائياً لتطابق Proxmox: net0 إدارة، net1 LAN، net2.. = wan1..
#  لـVM موجودة (أو بعد إضافة/تعديل كروت في Proxmox):
#    bash proxmox-deploy.sh --ifnames 115
# =====================================================================
set -euo pipefail

AUTO=0; MODE=deploy
case "${1:-}" in
  -y|--yes) AUTO=1 ;;
  --ifnames) MODE=ifnames; VMID=${2:-} ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  "") ;;
  *) echo "خيار غير معروف: $1 (استخدم -h)"; exit 1 ;;
esac

die()  { echo -e "\n❌ $*" >&2; exit 1; }
step() { echo -e "\n==> $*"; }
[ "$(id -u)" = 0 ] || die "شغّله كـ root على عقدة Proxmox"
command -v qm >/dev/null && command -v pvesm >/dev/null || die "هذا السكربت يعمل على Proxmox VE فقط (لا يوجد qm)"

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_TARBALL=${REPO_TARBALL:-https://github.com/LoginManager/multiwan/archive/refs/heads/${REPO_BRANCH:-main}.tar.gz}
IMG_URL=${IMG_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2}
IMG_DIR=/var/lib/vz/template/multiwan
IMG=$IMG_DIR/$(basename "$IMG_URL")
KEY=/root/.ssh/multiwan_ed25519

randpass() { head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-12; }
ask() {  # ask VAR "السؤال" افتراضي
  local var=$1 q=$2 def=${!1:-$3} ans=""
  if [ $AUTO -eq 0 ]; then read -r -p "  $q [$def]: " ans </dev/tty || true; fi
  printf -v "$var" '%s' "${ans:-$def}"
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
load_src() {  # SRC = مجلد multiwan/ (مضمّن في السكربت، أو بجانبه، أو من GitHub)
  if grep -q '^__MULTIWAN_PAYLOAD__$' "$0" 2>/dev/null; then
    # نسخة الملف الواحد: المشروع مضمّن في آخر هذا السكربت
    mkdir -p "$WORK/src"
    sed '1,/^__MULTIWAN_PAYLOAD__$/d' "$0" | base64 -d | tar -xz -C "$WORK/src" || die "الملفات المضمّنة تالفة"
    SRC=$WORK/src; echo "  (المشروع مضمّن في السكربت)"
  elif [ -f "$HERE/multiwan/install.sh" ]; then SRC=$HERE/multiwan
  elif [ -f "$HERE/install.sh" ] && [ -d "$HERE/bin" ]; then SRC=$HERE
  else
    echo "  تنزيل المشروع من $REPO_TARBALL"
    mkdir -p "$WORK/repo"; curl -fsSL "$REPO_TARBALL" | tar -xz -C "$WORK/repo" --strip-components=1 || die "فشل تنزيل المشروع"
    SRC=$WORK/repo/multiwan
  fi
  [ -f "$SRC/install.sh" ] || die "لم أجد install.sh في $SRC"
  echo "  المصدر: $SRC"
}

# تنفيذ أمر داخل الـVM عبر qemu-guest-agent (يعمل حتى لو الشبكة مقطوعة)؛ stdin يُمرَّر للأمر
gexec() {
  qm guest exec "$VMID" --timeout 300 --pass-stdin 1 -- "$@" | perl -MJSON::PP -0777 -ne '
    binmode STDOUT, ":utf8"; binmode STDERR, ":utf8";
    my $j = decode_json($_); print $j->{"out-data"} // ""; print STDERR $j->{"err-data"} // "";
    exit(defined $j->{exitcode} ? $j->{exitcode} : 1)'
}
agent_wait() { local n; for n in $(seq 1 ${1:-60}); do qm agent "$VMID" ping >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
# "MAC netN bridge VLANtag" لكل كرت من إعداد Proxmox
ifmap() {
  qm config "$VMID" | sed -n 's/^\(net[0-9]*\): [a-z0-9]*=\([0-9A-Fa-f:]*\),\(.*\)$/\1 \2 \3/p' | while read -r n mac opts; do
    br=$(sed -n 's/.*bridge=\([^,]*\).*/\1/p' <<<"$opts"); tag=$(sed -n 's/.*tag=\([0-9]*\).*/\1/p' <<<"$opts")
    echo "$(tr 'A-F' 'a-f' <<<"$mac") $n $br${tag:+ VLAN$tag}"
  done | sort -V -k2
}
# يسمّي كروت الـVM net0.. حسب Proxmox ويحدّث الإعداد ثم يعيد الإقلاع
apply_ifnames() {
  agent_wait 12 || die "qemu-guest-agent لا يرد في الـVM $VMID — تأكد أنها شغّالة و Options → QEMU Guest Agent مفعّل"
  echo "  الكروت في Proxmox:"; ifmap | sed 's/^/    /'
  ifmap | gexec tee /etc/multiwan/ifnames >/dev/null || die "تعذّر الكتابة داخل الـVM"
  gexec tee /usr/local/sbin/multiwan-ifnames.sh < "$SRC/bin/multiwan-ifnames.sh" >/dev/null
  gexec chmod 755 /usr/local/sbin/multiwan-ifnames.sh </dev/null
  gexec bash /usr/local/sbin/multiwan-ifnames.sh </dev/null | sed 's/^/  │ /' || die "multiwan-ifnames.sh فشل داخل الـVM"
  echo "  إعادة إقلاع الـVM $VMID ..."
  qm reboot "$VMID" --timeout 180 >/dev/null 2>&1 || { qm stop "$VMID" >/dev/null; qm start "$VMID" >/dev/null; }
  sleep 10; agent_wait 60 || die "الـVM لم تعد بعد الإقلاع — افحص الكونسول"
  echo "  الكروت داخل الـVM الآن:"; gexec ip -br link </dev/null | grep -vE '^(lo|mv|ppp)' | sed 's/^/    /'
  local bad; bad=$(ifmap | while read -r mac n _; do gexec cat /sys/class/net/$n/address </dev/null 2>/dev/null | grep -qi "$mac" || echo "$n"; done)
  [ -z "$bad" ] || die "لم تُطبَّق الأسماء: $bad — داخل الـVM: ls /etc/systemd/network/10-multiwan-*"
  echo "  ✓ الأسماء مطابقة لـProxmox"
}

# ---------------- وضع --ifnames: ضبط أسماء كروت VM موجودة ----------------
if [ "$MODE" = ifnames ]; then
  [[ ${VMID:-} =~ ^[0-9]+$ ]] || die "الاستخدام: bash $0 --ifnames <رقم الـVM>"
  qm config "$VMID" >/dev/null 2>&1 || die "الـVM $VMID غير موجودة على هذه العقدة"
  step "ضبط أسماء كروت الـVM $VMID لتطابق Proxmox"
  load_src >/dev/null
  apply_ifnames
  echo; echo "✅ تم. افتح اللوحة ← المداخل للتأكد (wan1=net2 ... بتعليق الـVLAN)."
  exit 0
fi

# ---------------- الإعدادات ----------------
DEF_STORAGE=$(pvesm status -content images 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}' | grep -xE 'local-lvm|local-zfs' | head -1 || true)
[ -n "$DEF_STORAGE" ] || DEF_STORAGE=$(pvesm status -content images 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}' | head -1 || true)
DEF_PASS=$(randpass)

echo "======== MultiWAN — إعداد VM جديدة على Proxmox ========"
echo "--- الـVM"
ask VMID        "رقم الـVM"                             "$(pvesh get /cluster/nextid 2>/dev/null || echo 105)"
ask VM_NAME     "اسم الـVM"                             multiwan
ask STORAGE     "التخزين (للقرص و cloud-init)"           "${DEF_STORAGE:-local-lvm}"
ask CORES       "عدد الأنوية"                           4
ask MEMORY      "الذاكرة MB"                            2048
ask DISK        "حجم القرص"                             8G
echo "--- كرت الإدارة (net0)"
ask MGMT_BRIDGE "bridge الإدارة"                        vmbr0
ask MGMT_TAG    "VLAN tag للإدارة (فارغ = بدون)"        ""
ask MGMT_IP     "IP الإدارة/الماسك"                     10.10.60.150/24
ask MGMT_GW     "Gateway الإدارة (للتثبيت فقط)"         10.10.60.1
ask DNS         "DNS"                                   8.8.8.8
echo "--- كرت العملاء LAN (net1)"
ask LAN_BRIDGE  "bridge الـLAN"                         Fiber02
ask LAN_TAG     "VLAN tag للـLAN (فارغ = بدون)"         121
ask LAN_IP      "IP الـVM على شبكة العملاء (gateway لهم)" 192.168.121.1/24
echo "--- مداخل PPPoE (net2 ...)"
ask WAN_BRIDGE  "bridge الافتراضي للمداخل"              Fiber02
ask WAN_TAGS    "VLAN tags للمداخل (بمسافات، واحد لكل WAN)" "1104 1105 1106 1107 1108 1109"
echo "--- الدخول"
ask WEB_PORT    "منفذ اللوحة"                           8080
ask ADMIN_USER  "مستخدم اللوحة"                         admin
ask ADMIN_PASS  "كلمة سر اللوحة"                        "$DEF_PASS"
ask ROOT_PASS   "كلمة سر root للـVM (SSH/Console)"      "$ADMIN_PASS"
ask LINES_FILE  "ملف الخطوط CSV (فارغ = تضيفها من اللوحة)" ""

# ---------------- التحقق ----------------
step "التحقق من الإعدادات"
IPRE='^([0-9]{1,3}\.){3}[0-9]{1,3}'
[[ $VMID =~ ^[0-9]+$ ]] && [ "$VMID" -ge 100 ] || die "رقم VM غير صالح: $VMID"
if ls /etc/pve/nodes/*/qemu-server/$VMID.conf >/dev/null 2>&1 || ls /etc/pve/nodes/*/lxc/$VMID.conf >/dev/null 2>&1; then
  die "الرقم $VMID مستخدم مسبقاً — اختر رقماً آخر"
fi
pvesm status -storage "$STORAGE" >/dev/null 2>&1 || die "التخزين $STORAGE غير موجود"
[[ $MGMT_IP =~ $IPRE/[0-9]{1,2}$ ]] || die "IP الإدارة يجب أن يكون بالشكل 10.10.60.150/24"
[[ $LAN_IP  =~ $IPRE/[0-9]{1,2}$ ]] || die "IP الـLAN يجب أن يكون بالشكل 192.168.121.1/24"
[[ $MGMT_GW =~ $IPRE$ ]] || die "Gateway غير صالح: $MGMT_GW"
for p in "$ADMIN_PASS" "$ROOT_PASS"; do [[ $p =~ ^[A-Za-z0-9._@%+=-]{6,}$ ]] || die "كلمة السر: 6 أحرف على الأقل، حروف/أرقام و . _ @ % + = - فقط"; done
[[ $ADMIN_USER =~ ^[A-Za-z0-9._-]+$ ]] || die "اسم المستخدم غير صالح"
for t in $MGMT_TAG $LAN_TAG; do [[ $t =~ ^[0-9]+$ ]] || die "VLAN tag غير صالح: $t"; done
[ -z "$LINES_FILE" ] || [ -f "$LINES_FILE" ] || die "ملف الخطوط غير موجود: $LINES_FILE"
brok() { ip link show "$1" >/dev/null 2>&1 || die "الـbridge '$1' غير موجود على هذه العقدة"; }
brok "$MGMT_BRIDGE"; brok "$LAN_BRIDGE"

# المداخل: bridge + tag لكل واحد
WAN_BR=(); WAN_TG=()
for w in $WAN_TAGS; do
  if [[ $w == *:* ]]; then b=${w%%:*}; t=${w#*:}; else b=$WAN_BRIDGE; t=$w; fi
  [ "$t" = "-" ] && t=""
  [ -z "$t" ] || [[ $t =~ ^[0-9]+$ ]] || die "VLAN tag غير صالح للمدخل: $w"
  brok "$b"; WAN_BR+=("$b"); WAN_TG+=("$t")
done
[ ${#WAN_BR[@]} -ge 1 ] || die "حدد مدخلاً واحداً على الأقل في WAN_TAGS"
MIP=${MGMT_IP%/*}
ping -c1 -W1 "$MIP" >/dev/null 2>&1 && die "العنوان $MIP يرد على ping — مستخدم من جهاز آخر"

echo "  VM $VMID ($VM_NAME) على $STORAGE — ${CORES} أنوية، ${MEMORY}MB، قرص $DISK"
echo "  net0 إدارة : $MGMT_BRIDGE${MGMT_TAG:+ tag=$MGMT_TAG}  $MGMT_IP  gw $MGMT_GW"
echo "  net1 LAN   : $LAN_BRIDGE${LAN_TAG:+ tag=$LAN_TAG}  $LAN_IP"
for k in "${!WAN_BR[@]}"; do echo "  net$((k+2)) wan$((k+1)) : ${WAN_BR[$k]}${WAN_TG[$k]:+ tag=${WAN_TG[$k]}}"; done
if [ $AUTO -eq 0 ]; then
  read -r -p "متابعة؟ [Y/n]: " ok </dev/tty || true
  case "${ok:-y}" in y|Y|yes|نعم|ن) ;; *) echo "أُلغي."; exit 1 ;; esac
fi

# ---------------- مصدر المشروع ----------------
step "تجهيز ملفات المشروع"
load_src

# ---------------- صورة Debian ----------------
step "صورة Debian 12"
mkdir -p "$IMG_DIR"
if [ ! -s "$IMG" ]; then
  echo "  تنزيل $IMG_URL"
  curl -fL --progress-bar -o "$IMG.part" "$IMG_URL" || die "فشل تنزيل الصورة"
  sums=$(curl -fsSL "$(dirname "$IMG_URL")/SHA512SUMS" 2>/dev/null | awk -v f="$(basename "$IMG")" '$2==f{print $1}' || true)
  if [ -n "$sums" ]; then
    [ "$(sha512sum "$IMG.part" | cut -d' ' -f1)" = "$sums" ] || { rm -f "$IMG.part"; die "الصورة تالفة (SHA512 لا يطابق) — أعد التشغيل"; }
    echo "  SHA512 ✓"
  fi
  mv "$IMG.part" "$IMG"
else echo "  موجودة: $IMG"; fi

# ---------------- مفتاح SSH ----------------
[ -f $KEY ] || ssh-keygen -q -t ed25519 -N "" -C "multiwan-deploy" -f $KEY
SSHO=(-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=10)
vssh() { ssh "${SSHO[@]}" debian@"$MIP" "$@"; }      # يمرّر stdin (للنسخ)
vrun() { ssh -n "${SSHO[@]}" debian@"$MIP" "$@"; }   # أوامر فقط — لا يأكل stdin

# ---------------- إنشاء الـVM ----------------
step "إنشاء VM $VMID"
nic() { echo "virtio,bridge=$1,firewall=0${2:+,tag=$2}"; }
NETS=(--net0 "$(nic "$MGMT_BRIDGE" "$MGMT_TAG")" --net1 "$(nic "$LAN_BRIDGE" "$LAN_TAG")")
for k in "${!WAN_BR[@]}"; do NETS+=(--net$((k+2)) "$(nic "${WAN_BR[$k]}" "${WAN_TG[$k]}")"); done

qm create "$VMID" --name "$VM_NAME" --ostype l26 --cpu host --cores "$CORES" --memory "$MEMORY" \
  --scsihw virtio-scsi-single --agent enabled=1 --onboot 1 --serial0 socket --vga serial0 "${NETS[@]}"
CREATED=1
cleanup_vm() { if [ "${CREATED:-0}" = 1 ]; then echo "  (الـVM $VMID بقيت للفحص — لحذفها: qm stop $VMID; qm destroy $VMID --purge)"; fi; }
trap 'cleanup_vm; rm -rf "$WORK"' EXIT

if ! qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on,ssd=1,iothread=1" >/dev/null 2>&1; then
  echo "  import-from غير مدعوم — استخدام importdisk"
  qm importdisk "$VMID" "$IMG" "$STORAGE" >/dev/null
  disk=$(qm config "$VMID" | sed -n 's/^unused0: //p')
  qm set "$VMID" --scsi0 "$disk,discard=on,ssd=1,iothread=1" >/dev/null
fi
qm resize "$VMID" scsi0 "$DISK" >/dev/null
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 \
  --ciuser debian --cipassword "$ROOT_PASS" --sshkeys $KEY.pub \
  --ipconfig0 "ip=$MGMT_IP,gw=$MGMT_GW" --nameserver "$DNS" >/dev/null
echo "  تم الإنشاء"

step "تشغيل الـVM وانتظار SSH (حتى 5 دقائق)"
qm start "$VMID"
for n in $(seq 1 60); do vrun true 2>/dev/null && break; [ "$n" = 60 ] && die "الـVM لم ترد على SSH على $MIP — افحص الكونسول: qm terminal $VMID"; sleep 5; echo -n "."; done
echo " ✓"
vrun "sudo cloud-init status --wait >/dev/null 2>&1 || true"

# ---------------- أسماء الكروت داخل الـVM حسب الـMAC ----------------
step "التعرّف على الكروت"
VM_IFS=$(vrun 'for d in /sys/class/net/*; do echo "$(basename $d) $(cat $d/address)"; done')
ifname() {
  local mac; mac=$(qm config "$VMID" | sed -n "s/^net$1: [a-z0-9]*=\([0-9A-Fa-f:]*\),.*/\1/p" | tr 'A-F' 'a-f')
  awk -v m="$mac" '$2==m{print $1}' <<<"$VM_IFS"
}
MGMT_IF=$(ifname 0); LAN_IF=$(ifname 1)
[ -n "$MGMT_IF" ] && [ -n "$LAN_IF" ] || die "تعذّر تحديد أسماء الكروت داخل الـVM"
UPLINKS=""
for k in "${!WAN_BR[@]}"; do
  i=$(ifname $((k+2))); [ -n "$i" ] || die "تعذّر تحديد كرت net$((k+2))"
  UPLINKS+="wan$((k+1)),$i,${WAN_BR[$k]} VLAN${WAN_TG[$k]:-none}"$'\n'
done
echo "  إدارة=$MGMT_IF  LAN=$LAN_IF"; printf '%s' "$UPLINKS" | sed 's/^/  مدخل: /'

# ---------------- ملفات الإعداد ----------------
step "كتابة الإعدادات ونسخ المشروع"
vrun "sudo mkdir -p /etc/multiwan && sudo chmod 700 /etc/multiwan"
vssh "sudo tee /etc/multiwan/multiwan.conf >/dev/null" <<EOF
# /etc/multiwan/multiwan.conf — مولّد بواسطة proxmox-deploy.sh ($(date '+%F %T'))
# كرت الإدارة (net0 / $MGMT_BRIDGE)
MGMT_IF=$MGMT_IF
MGMT_IP=$MGMT_IP
# gateway مؤقت على الإدارة لتثبيت الحزم فقط
TMP_GW=$MGMT_GW
# كرت الخروج للعملاء (net1 / $LAN_BRIDGE${LAN_TAG:+ tag $LAN_TAG})
LAN_IF=$LAN_IF
LAN_IP=$LAN_IP
DNS=$DNS
WEB_PORT=$WEB_PORT
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS
EOF
printf '%s' "$UPLINKS" | vssh "sudo tee /etc/multiwan/uplinks.csv >/dev/null"
if [ -n "$LINES_FILE" ]; then tr -d '\r' < "$LINES_FILE" | { grep . || true; } | vssh "sudo tee /etc/multiwan/lines.csv >/dev/null"
else vrun "sudo truncate -s0 /etc/multiwan/lines.csv"; fi
echo "root:$ROOT_PASS" | vssh "sudo chpasswd"
tar -C "$SRC" -czf - . | vssh "sudo rm -rf /opt/multiwan-src && sudo mkdir -p /opt/multiwan-src && sudo tar -xzf - -C /opt/multiwan-src"
echo "  ✓"

# ---------------- التثبيت داخل الـVM ----------------
# يعمل في الخلفية داخل الـVM حتى لا ينقطع إذا أُعيد ضبط الشبكة أثناء التثبيت
step "تشغيل install.sh داخل الـVM (عدة دقائق)"
vrun "sudo rm -f /var/log/multiwan-install.rc; sudo setsid nohup bash -c 'bash /opt/multiwan-src/install.sh > /var/log/multiwan-install.log 2>&1; echo \$? > /var/log/multiwan-install.rc' >/dev/null 2>&1 < /dev/null &"
shown=0; rc=""
for n in $(seq 1 240); do
  sleep 5
  out=$(vrun "sudo tail -n +$((shown+1)) /var/log/multiwan-install.log 2>/dev/null" 2>/dev/null || true)
  [ -n "$out" ] && { printf '%s\n' "$out" | sed 's/^/  │ /'; shown=$((shown + $(printf '%s\n' "$out" | wc -l))); }
  rc=$(vrun "sudo cat /var/log/multiwan-install.rc 2>/dev/null" 2>/dev/null || true)
  [ -n "$rc" ] && break
done
[ -n "$rc" ] || die "انتهت المهلة — السجل داخل الـVM: /var/log/multiwan-install.log"
[ "$rc" = 0 ] || die "install.sh فشل (rc=$rc) — السجل: ssh -i $KEY debian@$MIP sudo cat /var/log/multiwan-install.log"

if vrun "uname -r" | grep -q cloud; then
  step "إعادة إقلاع لتفعيل الكيرنل الجديد"
  vrun "sudo systemctl reboot" || true; sleep 15
  for n in $(seq 1 60); do vrun true 2>/dev/null && break; sleep 5; done
fi

# ---------------- أسماء الكروت = أسماء Proxmox ----------------
step "تسمية الكروت net0, net1, ... لتطابق Proxmox"
apply_ifnames
MGMT_IF=net0; LAN_IF=net1
UPLINKS=$(gexec cat /etc/multiwan/uplinks.csv </dev/null)$'\n'

# ---------------- التحقق ----------------
step "التحقق من اللوحة"
code=000
for n in $(seq 1 12); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$ADMIN_USER:$ADMIN_PASS" "http://$MIP:$WEB_PORT/" || true)
  [ "$code" = 200 ] && break; sleep 5
done
[ "$code" = 200 ] && echo "  اللوحة تعمل ✓" || echo "  ⚠ اللوحة لم ترد (HTTP $code) — افحص: ssh root@$MIP journalctl -u multiwan-web -n 30"
CREATED=0

INFO=/root/multiwan-vm$VMID.txt
cat > "$INFO" <<EOF
MultiWAN VM $VMID ($VM_NAME) — $(date '+%F %T')
اللوحة : http://$MIP:$WEB_PORT   المستخدم: $ADMIN_USER   كلمة السر: $ADMIN_PASS
SSH    : ssh root@$MIP   (كلمة السر: $ROOT_PASS)   أو: ssh -i $KEY debian@$MIP
الكروت : إدارة=$MGMT_IF  LAN=$LAN_IF ($LAN_IP)
$(printf '%s' "$UPLINKS" | sed 's/^/مدخل  : /')
EOF
chmod 600 "$INFO"
echo
echo "================ ✅ تم ================"
cat "$INFO"
echo
echo "الخطوة التالية: افتح اللوحة وأضف خطوط PPPoE (أو ارفع ملف Excel/CSV)."
echo "العملاء: gateway = ${LAN_IP%/*} على VLAN ${LAN_TAG:-بدون tag}."
echo "حُفظت هذه المعلومات في $INFO"
exit 0
__MULTIWAN_PAYLOAD__
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
