#!/bin/bash
# build-allinone.sh — يبني multiwan-proxmox.sh: ملف واحد = proxmox-deploy.sh + المشروع كاملاً مضمّناً
# الاستخدام: bash tools/build-allinone.sh   (أعد تشغيله بعد أي تعديل في multiwan/ أو proxmox-deploy.sh)
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); OUT=$R/multiwan-proxmox.sh
{
  cat "$R/proxmox-deploy.sh"
  echo "__MULTIWAN_PAYLOAD__"
  tar -C "$R/multiwan" --exclude=__pycache__ --exclude="*.pyc" --exclude="*.bak" --owner=0 --group=0 --sort=name -czf - . | base64 -w 76
} > "$OUT"
chmod +x "$OUT"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
