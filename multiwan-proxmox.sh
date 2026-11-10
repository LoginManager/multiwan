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
