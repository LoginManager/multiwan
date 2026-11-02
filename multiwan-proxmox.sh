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
