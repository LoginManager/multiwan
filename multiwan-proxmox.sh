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
# =====================================================================
set -euo pipefail

AUTO=0
case "${1:-}" in
  -y|--yes) AUTO=1 ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
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
AA==
