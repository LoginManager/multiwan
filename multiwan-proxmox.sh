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
H4sIAAAAAAAAA+xcbXMTx5bm8/yKjhGxZCyNRn4DGVFhg8m61nZcmJAPtkGyNLYH9BbNyIYAVQGM
cZxbyWZrv+2nu6kE8x4uIcT3l0hf80v2Oae7502yQ+2SpO5dphJ5Zrr79OlzTp/z9JluMuaR3/3K
4poYG+O/uOJ/+d4ay03krPHR8ZFxvJ+YyI0dEWO/P2tHjrRdr9QS4kir0fAOq/db5f+gV8Y8P3Xm
7OxUplb53fogBY+Pjh6gf2t0dGyC9T86PjYyNpI7krWsnDVxRGR/N45C1/9z/R8Vs+2q53x6Zk78
+sV/is7z7r3OE9F51nnd3em8FvPz840p0dnvbnW/FGftFadUN+dbjWu1xjXD6DzqPOne6+529kXn
aecRaljZLLdV7bq3u7vi4qwAqQeo8bzzUCQlEWHlNFVFLiU6e90vRLHZbFbEcVErlTeqqHdcTH04
O1/s/EWAsX2BFjug9BAk0e8eaHReoN0u3py/MEPFW53v0dEDvH6YMYyjR0XnAd7eYz7/hvePjLRP
nHqcPfMhkX4J/u90t4jCXfzhQSS7d9BgT77dwmifdV6ByqsUSAwNoRH184yK76FwH48Y4dBQXjAJ
LqfSAp7BziPR+QnE7hLzJBfm64uLs53/0rczUIJXWhPd3e43nZ87e2BByYgrSCLcVsmMpLKDkW3L
Clo2zOkjkkFkOJqh7n3wj+HudP4mdYe2nacgs8Wy9ttAVp1XVChF3/mOWuB5WySt8VlhihOzKegH
Db+BXLa633aekv3sdF6AQ5bYE3rsblF330M+D9gConRVlc7DPOnyJ7aUH1ifgVLoIRgHBk2sqK5C
ZTQMZbfU4wNqDiE+565AaYvV+YNmjkTCYkOXKNkXLEhV555klKx6F39hCxjVbVSaula2q+aHCxdT
LEQw8IA00r0rSIidX0ixe91tEHgtPnXqK41r2igxVbi7XZ4OpHDSNw3eH5oUVFCRh/Sou02K6m6Z
/CjZUI2kjNAU01bQhIC4YC17ZIzUehvDeQ3+933pUOdhXeCtrw9/kt3jeb0j+1E97VAtGqq0qnDH
rA5dU4rl72CYapIWqMaDWBMM+y6/Ag8vuV7IfnstOklmjrlwv/NAkCMmus+Ubl7Qb/cr0gdGS70N
8GDUZBvI+9NPiuAFaD6RStknoweJvyqVBK4D+vanHMQyPY8feAqyPZ4t/PsQjzxpmWHfj5EfZXFB
CaQ31b85PX84Cz2jhrR32MC+YsMArTtkbSZI/8QShkn4ujSDDk20/hFm8heypp+pCYn5ORkO3fDk
2WNW2Gf5XpJN7ZX0q/IxmDJRZw2FkH28YmPr3k8ZkDsNcg9iLjZlnXTFblYb1zPuelE5vCedH7Wq
5dzeQff70t3RgL7ufksTQbm8ffRNNqq7hDHfRjdkAuT8Yek7ZFl7cvb8BLb/mjeC2SKCQPPr9r+T
+LbRCQlaO149D++yPh5xtXK10a6knbrj8SPavOw80yz/xBX3uaTo1AEcqlUeHnfAEoMfvdO906vL
jFEsFldK7rpRbreqIr3qLsyIdc9runnTXHO89fZKptyomTONNac+W6qX1uyWWaPIvImIW2qV150N
22zZq665bpcqrlkrOfUMkEtm7XNxUxCEufa5Ua4I3SZNFcT77wvqVPSohNgx2H098vXtC4KH8iM5
ql0W2g/d+3lRrNtetiiCKQLzondWUdAUkOakjVmV5X794oeiCAVKCQuSGg9oN0aTKJUxOt/R9A10
5POjm/uaGxoC7685ON8RoWbKVigGS359JjVHRbCkFR/wVYTErAKXU0U85ehpRNbm6PeI7XKX+gui
Nd/eliVAG9rxBrNOux6ec4FblF4jFMnhb5QTZcO8wxOZveNeaHhFu+7mskUTf5s51yqmaIrTzAnN
G0Uw7xscG4BvFsoSYAIinXZW66Wa7QrLGmODYA/zovNdVPxszMXPaqLcqK86a4zFdokndLvL87FX
QZDDHsa51rZdT8CY655sBaUDJzwWytvuc8vnEs3t4//nqoTDPuKWFCpBhG3WM2xxi+MBT/oQAUgL
77Ypzt/jkPCie59w2D0p9c6LVCCRi7PTZwtWdkzMfjR74fK/nJ8++9FUYaO20srKN9PzKM3gv3H8
jmXN3Kh8/9GnofdiyYASdetzzordyuZoKly+cOajAhYwfE+kTuYy1viJDF5lLKK1ZHza2/BT2XCh
MGBZ2VFoJDs2ILAwm567PH9mYaEwe32+5LpWboT6nZ6bWrh8bnpmqmBSNDSrTt12M2V344DZLtLX
Wb9pUdT9FPMBQNUIZJ/cP7SWlLAABsz4pvMz7HQcM8rnjH7G6WeCfk7Qz8miDHxcqSgNvigHN5LP
ZeE5kistp7Jmi85/UwRMxaqkUcHXNEAwhfNiMNBiLOLnBSCYjmJ6sVJsu3ZruAk5DW/aztq6Nwyg
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
