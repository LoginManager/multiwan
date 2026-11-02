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
  # خدمة تغيّر الأسماء عند كل إقلاع قبل الشبكة (احتياط إن لم تطبّقها udev)
  gexec tee /etc/systemd/system/multiwan-ifnames.service < "$SRC/systemd/multiwan-ifnames.service" >/dev/null
  gexec bash -c 'systemctl daemon-reload && systemctl enable multiwan-ifnames' </dev/null >/dev/null 2>&1 || die "تعذّر تفعيل multiwan-ifnames.service"
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
sITk9z2x099hr/gK2vdlmZNaadv4qiSco4ymwY3H88uT7kC1vs0irURAZcC1LwqWDN07ClYCpvrD
qZzb8k3yuYKJ2X7A5nP7gc1maMXjmTSL3yjLY0ou7DBkK03FX1XDG2kaXpEdBKMqWt6sLfd2reQO
L9UaymGrxC4yV7eRIIRpTrsBuaakQhSITZCSo/MoAFfi3FBDsYW5mH2NlhoG85UobQaWSxdQ09Et
TPveDcGaZnG1CuF7EQZZ1ntZg4n9La4Bv+fhK/9ipK4aHWM1Kj9P0/ZN94Wqhi6VOcnthalDhdML
C+mX5Y+rHuG6pgDLCu5M4qGanVrnyoNiyPw0bzWIXXmfJYRULBYYUoijIa+pgZwqE9uifGC+lqLy
LeG/b2gz+oexoi5POobKkVRQwiLQaNFxVwyyKam8bqYuYZX1I8SbKIkKrVZ+Jmb1WhHXa0WKXktt
d/Vzv/Sl245cyLEluWsuuSLChgyKbrXKh3RLtV3G5aRaa1mmLs+UNphBxmkXn7kmp5jm+KDsSdBi
rKVe4Wob5a5dlspNL79Wkfjl6rXJsgB0VaIvCVxzDYFJRTgv6ec8Rvt2fV19EvB+1uZA5T7W+/WD
iRb+bplTIr7rop5he7XJGqc5rjqpwabOsA3nsygGgmfzRhjMYyBSoB3S3TvIGPMREw4JcFLApCH0
WpqS469pASNR+IEM3S5uWd0uLeld4Ipg2u3yKy7qhMXUuprNY4ykQf8BgQgw4ZOFBMaRvQkiRP/B
3eHs+Ofdly9enaIK4qH70CXEs/iKQPaGXIT9we7ZPbtn9+ye3bN7ds/u2T27Z/fsnt2ze3bP7sk/
/wVUyCeRAGgBAA==
