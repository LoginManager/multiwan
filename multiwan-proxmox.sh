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
uSU8SACQAQA=
