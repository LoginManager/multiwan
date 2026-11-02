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
