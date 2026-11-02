# MultiWAN — دمج خطوط PPPoE على Debian/Proxmox

تجميع حتى 100 خط PPPoE في VM واحدة (Debian 12 على Proxmox) بـ `pppd + macvlan + ECMP`، مع لوحة ويب عربية RTL للإدارة.

## المميزات
- macvlan بـMAC مستقل لكل خط (قابل للتخصيص)
- **مداخل متعددة**: كل مدخل = كرت شبكة في الـVM؛ الـVLAN tag يُضبط على الكرت في Proxmox، ومن اللوحة تختار لكل خط مدخله
- توزيع الحمل ECMP لكل اتصال مع أوزان (16M / 8M) + مُصلّح دوري للجدول
- إعادة اتصال مجدولة: عشوائية مستقلة لكل خط، أو دورة لكل الخطوط
- استبدال تلقائي للخط الواقع من قائمة احتياط (رفع Excel/CSV)
- ترافيك لحظي بنمط Winbox للإجمالي والـLAN ولكل خط
- إيقاف/تشغيل/إعادة/تعديل/حذف، إضافة دفعة أو بالعدد

## الإعداد على Proxmox
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
git clone https://github.com/LoginManager/multiwan.git && cd multiwan
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
/opt/multiwan/app.py          اللوحة
```

## أوامر
```bash
wanstat                          # حالة الخطوط
multiwan-apply.sh                # تطبيق lines.csv بعد تعديل يدوي
journalctl -t multiwan -f        # سجل up/down/failover/reconnect
journalctl -u pppoe@3 -n 30      # سجل خط
```

## التحديث
```bash
cd multiwan && git pull && bash install.sh
```
