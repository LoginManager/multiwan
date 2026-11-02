# MultiWAN — دمج خطوط PPPoE على Debian/Proxmox

تجميع حتى 100 خط PPPoE في VM واحدة (Debian 12 على Proxmox) بـ `pppd + macvlan + ECMP`، مع لوحة ويب عربية RTL للإدارة.

## المميزات
- macvlan بـMAC مستقل لكل خط (قابل للتخصيص)
- **مداخل متعددة**: كل مدخل = كرت شبكة في الـVM؛ الـVLAN tag يُضبط على الكرت في Proxmox، ومن اللوحة تختار لكل خط مدخله
- توزيع الحمل ECMP لكل اتصال مع أوزان (16M / 8M) + مُصلّح دوري للجدول
- إعادة اتصال مجدولة: عشوائية مستقلة لكل خط، أو دورة لكل الخطوط
- استبدال تلقائي للخط الواقع من قائمة احتياط (رفع Excel/CSV)
- ترافيك لحظي بنمط Winbox للإجمالي والـLAN ولكل خط
- قسم "الشبكة": كرت الخروج للعملاء والإدارة (الكرت، IP، MAC، الحالة، VLAN من Proxmox) — وتعديل كرت/IP الخروج للعملاء من اللوحة فوراً
- إيقاف/تشغيل/إعادة/تعديل/حذف، إضافة دفعة أو بالعدد

## التنصيب التلقائي على Proxmox (موصى به)
سكربت `proxmox-deploy.sh` في جذر المستودع يُشغَّل على عقدة Proxmox نفسها ويقوم بكل شيء:
تنزيل Debian 12 ← إنشاء الـVM والكروت ← cloud-init ← نسخ المشروع ← `install.sh` ← التحقق من اللوحة.
```bash
curl -fsSL https://github.com/LoginManager/multiwan/archive/refs/heads/main.tar.gz | tar xz
cd multiwan-main && bash proxmox-deploy.sh
```
ترتيب الكروت الذي ينشئه: `net0` إدارة، `net1` LAN العملاء، `net2…` مداخل PPPoE (واحد لكل VLAN).
أسماء الكروت داخل الـVM **تطابق أسماء Proxmox**: `net0`، `net1`، `net2`… والمداخل `wan1=net2`، `wan2=net3`… مع تعليق الـVLAN الفعلي.

بعد إضافة كرت أو تغيير VLAN في Proxmox (أو لـVM قديمة بأسماء `ens20`/`enp2s1`)، شغّل على Proxmox:
```bash
bash multiwan-proxmox.sh --ifnames 115
```
يقرأ الكروت من `qm config`، يسمّيها داخل الـVM عبر guest agent، يحدّث الإعداد ويعيد الإقلاع.

بدون أسئلة (كل إعداد يمكن تمريره كمتغير):
```bash
VMID=105 MGMT_BRIDGE=vmbr0 MGMT_IP=10.10.60.150/24 MGMT_GW=10.10.60.1 \
LAN_BRIDGE=Fiber02 LAN_TAG=121 LAN_IP=192.168.121.1/24 \
WAN_BRIDGE=Fiber02 WAN_TAGS="1104 1105" ADMIN_PASS=MyPass123 \
LINES_FILE=/root/lines.csv bash proxmox-deploy.sh -y
```
- `WAN_TAGS`: مدخل لكل عنصر (الافتراضي 6: `1104 1105 1106 1107 1108 1109`) — `1104` أو `Fiber03:200` (bridge آخر) أو `Fiber03:-` (بدون tag)
- `LINES_FILE` اختياري: CSV بالخطوط `user,pass,weight,mac,uplink` (أو أضفها لاحقاً من اللوحة)
- نسخة الملف الواحد `multiwan-proxmox.sh` (المشروع مضمّن) تُبنى بـ `bash tools/build-allinone.sh`
- إضافة WAN لاحقاً لـVM قائمة: `qm set 105 --net8 virtio,bridge=Fiber02,tag=1110,firewall=0` ثم من اللوحة ← المداخل ← إضافة (الكرت الجديد يظهر في القائمة)
- تحديث الكود داخل VM موجودة (الخطوط والإعدادات تبقى): `bash multiwan-proxmox.sh --update 115`
- المعلومات النهائية (الرابط وكلمات السر) تُحفظ في `/root/multiwan-vm<ID>.txt` على Proxmox

## الإعداد اليدوي على Proxmox
```bash
# net0 إدارة، net1.. مداخل PPPoE (tag على كل كرت)، آخر كرت خروج للعملاء
qm set 105 --net0 virtio,bridge=vmbr0,firewall=0
qm set 105 --net1 virtio,bridge=Fiber02,tag=1104,firewall=0     # wan1
qm set 105 --net2 virtio,bridge=Fiber02,tag=121,firewall=0      # LAN العملاء
qm set 105 --net3 virtio,bridge=Fiber02,tag=1105,firewall=0     # wan2 (اختياري)
```
داخل الـVM الكروت تظهر `enp6s18, enp6s19, enp6s20, enp6s21 …` بنفس ترتيب net0, net1, …

## التثبيت
```bash
git clone https://github.com/LoginManager/multiwan.git && cd multiwan/multiwan
nano etc/multiwan.conf     # الكروت، عناوين الإدارة والـLAN، كلمة سر اللوحة
nano etc/uplinks.csv       # name,iface,comment  — المداخل
nano etc/lines.csv         # user,pass,weight,mac,uplink — الخطوط الأولية (اختياري)
bash install.sh            # يعيد الإقلاع عند الحاجة لتبديل الكيرنل
```
اللوحة: `http://<MGMT_IP>:8080`

## الملفات
```
/etc/multiwan/multiwan.conf   الإعداد الأساسي
/etc/multiwan/uplinks.csv     المداخل (الأول = الافتراضي)
/etc/multiwan/lines.csv       الخطوط
/etc/multiwan/reserve.csv     الاحتياط
/etc/multiwan/failed.csv      المستبدَلة
/etc/multiwan/reconnect.conf  جدولة إعادة الاتصال
/etc/multiwan/failover.conf   مدة الاستبدال
/usr/local/sbin/*             السكربتات
/etc/multiwan/ifnames         MAC → اسم الكرت (net0..) من Proxmox
/opt/multiwan/app.py          اللوحة
```

## أوامر
```bash
wanstat                          # حالة الخطوط
multiwan-apply.sh                # تطبيق lines.csv بعد تعديل يدوي
multiwan-lan.sh net1 192.168.121.1/24   # تغيير كرت/IP الخروج للعملاء
journalctl -t multiwan -f        # سجل up/down/failover/reconnect
journalctl -u pppoe@3 -n 30      # سجل خط
```

## التحديث
```bash
cd multiwan/multiwan && git pull && bash install.sh
```
