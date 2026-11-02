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
n/PP+ef8c/45/5x/zj/nn7/lz/8BXqhM2gCQAQA=
