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
#  تحديث كود MultiWAN داخل VM موجودة (الخطوط والإعدادات تبقى كما هي):
#    bash proxmox-deploy.sh --update 115
# =====================================================================
set -euo pipefail

AUTO=0; MODE=deploy
case "${1:-}" in
  -y|--yes) AUTO=1 ;;
  --ifnames) MODE=ifnames; VMID=${2:-} ;;
  --update) MODE=update; VMID=${2:-} ;;
  -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
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

# ---------------- وضع --update: نسخ الكود الجديد وتشغيل install.sh داخل VM موجودة ----------------
if [ "$MODE" = update ]; then
  [[ ${VMID:-} =~ ^[0-9]+$ ]] || die "الاستخدام: bash $0 --update <رقم الـVM>"
  qm config "$VMID" >/dev/null 2>&1 || die "الـVM $VMID غير موجودة على هذه العقدة"
  step "تحديث MultiWAN داخل الـVM $VMID"
  load_src
  agent_wait 12 || die "qemu-guest-agent لا يرد في الـVM $VMID"
  tar -C "$SRC" --exclude=__pycache__ --exclude="*.pyc" -czf - . | base64 | gexec bash -c 'rm -rf /opt/multiwan-src && mkdir -p /opt/multiwan-src && base64 -d | tar -xz -C /opt/multiwan-src' \
    || die "تعذّر نسخ الملفات إلى الـVM"
  echo "  نُسخت الملفات — تشغيل install.sh (الإعدادات في /etc/multiwan لا تُمس)"
  gexec bash -c 'rm -f /var/log/multiwan-install.rc; setsid nohup bash -c "bash /opt/multiwan-src/install.sh > /var/log/multiwan-install.log 2>&1; echo \$? > /var/log/multiwan-install.rc" >/dev/null 2>&1 </dev/null &' </dev/null
  shown=0; rc=""
  for n in $(seq 1 120); do
    sleep 5
    out=$(gexec tail -n +$((shown+1)) /var/log/multiwan-install.log </dev/null 2>/dev/null || true)
    [ -n "$out" ] && { printf '%s\n' "$out" | sed 's/^/  │ /'; shown=$((shown + $(printf '%s\n' "$out" | wc -l))); }
    rc=$(gexec cat /var/log/multiwan-install.rc </dev/null 2>/dev/null || true)
    [ -n "$rc" ] && break
  done
  [ -n "$rc" ] || die "انتهت المهلة — السجل داخل الـVM: /var/log/multiwan-install.log"
  [ "$rc" = 0 ] || die "install.sh فشل (rc=$rc) — السجل داخل الـVM: /var/log/multiwan-install.log"
  echo; echo "✅ تم التحديث. أعد تحميل اللوحة في المتصفح."
  exit 0
fi

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
tar -C "$SRC" --exclude=__pycache__ --exclude="*.pyc" -czf - . | vssh "sudo rm -rf /opt/multiwan-src && sudo mkdir -p /opt/multiwan-src && sudo tar -xzf - -C /opt/multiwan-src"
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
MAIA
