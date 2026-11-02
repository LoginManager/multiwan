# MultiWAN — دمج خطوط PPPoE على Proxmox

تجميع حتى 100 خط PPPoE في VM واحدة (Debian 12) مع توزيع حمل ECMP ولوحة ويب عربية.
التفاصيل الكاملة: [multiwan/README.md](multiwan/README.md)

## التنصيب السريع (أمر واحد على Proxmox)
على عقدة Proxmox كـ root:
```bash
curl -fsSL https://github.com/LoginManager/multiwan/archive/refs/heads/main.tar.gz | tar xz
cd multiwan-main && bash proxmox-deploy.sh
```
السكربت يسألك عن الإعدادات (Enter يقبل القيمة الافتراضية) ثم ينشئ الـVM ويثبّت كل شيء ويطبع رابط اللوحة وكلمة السر.

### أو ملف واحد بدون إنترنت للمستودع
`multiwan-proxmox.sh` = نفس السكربت والمشروع كاملاً مضمّن بداخله. انسخه إلى Proxmox وشغّله:
```bash
scp multiwan-proxmox.sh root@<proxmox>:/root/
ssh root@<proxmox> bash /root/multiwan-proxmox.sh
```
الافتراضي 6 مداخل WAN على VLAN 1104–1109 (غيّرها عند السؤال). بعد أي تعديل في الكود أعد بناءه: `bash tools/build-allinone.sh`
