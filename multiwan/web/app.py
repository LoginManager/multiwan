#!/usr/bin/env python3
# MultiWAN web panel — لوحة إدارة خطوط PPPoE (عربي RTL)
import os, csv, subprocess, time, functools, re, hmac, fcntl
from flask import Flask, request, redirect, Response, render_template_string, jsonify, flash

D = "/etc/multiwan"
CSV, RES, FAILED, UPL = f"{D}/lines.csv", f"{D}/reserve.csv", f"{D}/failed.csv", f"{D}/uplinks.csv"
FOCONF, RCCONF = f"{D}/failover.conf", f"{D}/reconnect.conf"
APPLY = "/usr/local/sbin/multiwan-apply.sh"
STATE = "/var/lib/multiwan"; UPLOADS = f"{STATE}/uploads"
USER = os.environ.get("ADMIN_USER", "admin"); PASS = os.environ.get("ADMIN_PASS", "admin")
MACRE = re.compile(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$')
CONF, IFNAMES, LANSH = f"{D}/multiwan.conf", f"{D}/ifnames", "/usr/local/sbin/multiwan-lan.sh"
IFRE = re.compile(r'^[A-Za-z0-9_.-]+$')

app = Flask(__name__); app.secret_key = os.urandom(24)
app.jinja_env.filters["human"] = lambda n: human(n or 0)

# ---------------- helpers ----------------
def auth(f):
    @functools.wraps(f)
    def w(*a, **k):
        au = request.authorization; u, pw = creds()
        if not au or not hmac.compare_digest(au.username or "", u) or not hmac.compare_digest(au.password or "", pw):
            return Response("Login required", 401, {"WWW-Authenticate": 'Basic realm="MultiWAN"'})
        return f(*a, **k)
    return w

def sh(cmd): return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()

def norm_mac(m):
    m = (m or "").strip().lower().replace("-", ":")
    if m and len(m) == 12 and ":" not in m: m = ":".join(m[i:i+2] for i in range(0, 12, 2))
    return m if MACRE.match(m) else ""

def read_csv5(path):
    out = []
    if os.path.exists(path):
        with open(path) as f:
            for row in csv.reader(f):
                if not row or not row[0].strip(): continue
                row += [""] * (5 - len(row))
                out.append({"user": row[0].strip(), "pass": row[1].strip(), "weight": row[2].strip() or "1",
                            "mac": norm_mac(row[3]), "uplink": row[4].strip()})
    return out
def write_csv5(path, lines):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for l in lines: f.write(f'{l["user"]},{l["pass"]},{l["weight"]},{l["mac"]},{l.get("uplink","")}\n')
    os.chmod(tmp, 0o600); os.replace(tmp, path)
read_lines = lambda: read_csv5(CSV); write_lines = lambda l: write_csv5(CSV, l)

def apply():
    r = subprocess.run([APPLY], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def uplinks():
    out = []
    if os.path.exists(UPL):
        for row in csv.reader(open(UPL)):
            if row and row[0].strip() and len(row) > 1 and row[1].strip():
                out.append({"name": row[0].strip(), "iface": row[1].strip(), "comment": row[2].strip() if len(row) > 2 else ""})
    return out
def write_uplinks(ups):
    with open(UPL + ".tmp", "w") as f:
        for u in ups: f.write(f'{u["name"]},{u["iface"]},{u["comment"]}\n')
    os.replace(UPL + ".tmp", UPL)
def sysconf():  # multiwan.conf يُقرأ في كل طلب (تغيير الـLAN يظهر فوراً)
    d = {}
    try:
        for l in open(CONF):
            l = l.strip()
            if l and not l.startswith("#") and "=" in l:
                k, v = l.split("=", 1); d[k.strip()] = v.split("#")[0].strip().strip("\"'")
    except Exception: pass
    return d
def creds():  # المستخدم وكلمة السر من multiwan.conf (التغيير من اللوحة يسري فوراً)
    c = sysconf(); return c.get("ADMIN_USER") or USER, c.get("ADMIN_PASS") or PASS
PASSRE = re.compile(r'^[A-Za-z0-9._@%+=-]{6,64}$')
def set_conf(key, val):  # يستبدل سطر KEY= في multiwan.conf (أو يضيفه) بكتابة آمنة
    lines = open(CONF).read().splitlines() if os.path.exists(CONF) else []
    out, done = [], False
    for l in lines:
        if l.strip().startswith(key + "="): out.append(f"{key}={val}"); done = True
        else: out.append(l)
    if not done: out.append(f"{key}={val}")
    with open(CONF + ".tmp", "w") as f: f.write("\n".join(out) + "\n")
    os.chmod(CONF + ".tmp", 0o600); os.replace(CONF + ".tmp", CONF)
def lan_if(): return sysconf().get("LAN_IF", os.environ.get("LAN_IF", ""))
def phys_ifaces(): return sorted((i for i in os.listdir("/sys/class/net") if os.path.exists(f"/sys/class/net/{i}/device")), key=lambda x: (len(x), x))
def proxmox_notes():  # netN → "Fiber02 VLAN121" من /etc/multiwan/ifnames
    out = {}
    try:
        for l in open(IFNAMES):
            p = l.split(None, 2)
            if len(p) >= 2: out[p[1]] = p[2].strip() if len(p) > 2 else ""
    except Exception: pass
    return out
def iface_info(dev, conf_ip=""):
    info = {"dev": dev or "-", "conf_ip": conf_ip, "ips": [], "mac": "-", "state": "غير موجود", "rx": "-", "tx": "-", "note": proxmox_notes().get(dev, "")}
    p = f"/sys/class/net/{dev}"
    if not dev or not IFRE.match(dev) or not os.path.exists(p): return info
    info["ips"] = sh(f"ip -4 -o addr show dev {dev} | awk '{{print $4}}'").split()
    try:
        info["mac"] = open(p + "/address").read().strip(); st = open(p + "/operstate").read().strip()
        info["state"] = "UP" if st == "up" else ("DOWN" if st == "down" else st.upper())
        info["rx"] = human(int(open(p + "/statistics/rx_bytes").read())); info["tx"] = human(int(open(p + "/statistics/tx_bytes").read()))
    except Exception: pass
    return info
def net_info():
    c = sysconf(); used = {u["iface"] for u in uplinks()}; lan = c.get("LAN_IF", "")
    choices = [i for i in phys_ifaces() if i != c.get("MGMT_IF") and (i not in used or i == lan)]
    if lan and lan not in choices: choices.insert(0, lan)
    return {"lan": iface_info(lan, c.get("LAN_IP", "")), "mgmt": iface_info(c.get("MGMT_IF", ""), c.get("MGMT_IP", "")), "choices": choices}

def free_ifaces():
    c = sysconf(); skip = {"lo", c.get("LAN_IF", ""), c.get("MGMT_IF", "")}
    return [i for i in sh("ls /sys/class/net").split() if not i.startswith(("ppp", "mv")) and i not in skip]

def read_failed():
    out = []
    if os.path.exists(FAILED):
        for row in csv.reader(open(FAILED)):
            if len(row) >= 3:
                row += [""] * (7 - len(row))
                out.append({"when": row[0], "idx": row[1], "user": row[2], "pass": row[3], "weight": row[4] or "1", "mac": row[5], "uplink": row[6]})
    return out
def write_failed(rows):
    with open(FAILED, "w") as f:
        for x in rows: f.write(f'{x["when"]},{x["idx"]},{x["user"]},{x["pass"]},{x["weight"]},{x["mac"]},{x["uplink"]}\n')

def kv(path, defaults):
    d = dict(defaults)
    try:
        for l in open(path):
            if "=" in l and not l.startswith("#"): k, v = l.strip().split("=", 1); d[k] = v
    except Exception: pass
    return d
def fo_conf(): return kv(FOCONF, {"FAILOVER_HOURS": "24"})
def rc_conf(): return kv(RCCONF, {"MODE": "off", "MIN_HOURS": "1", "MAX_HOURS": "6", "EVERY_HOURS": "6", "SPREAD_SEC": "60", "RANDOM_ORDER": "1", "ONLY_UP": "1"})

def human(n):
    for u in ["B","KB","MB","GB","TB"]:
        if n < 1024: return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"
def fmt_dur(s): s = int(s); return f"{s//3600}س {s%3600//60}د"

# ---------- إجمالي الاستهلاك لكل مستخدم (يبقى عبر إعادة الاتصال) ----------
USAGE, RUN = f"{STATE}/usage.csv", "/run/multiwan"; UBASE, ULOCK = f"{RUN}/usage-base", "/run/multiwan-usage.lock"
def read_usage():  # user → [rx, tx, since] للجلسات المنتهية (يكتبه multiwan-usage.sh عند ip-down)
    out = {}
    try:
        for r in csv.reader(open(USAGE)):
            if len(r) >= 3 and r[0]:
                out[r[0]] = [int(float(r[1] or 0)), int(float(r[2] or 0)), r[3] if len(r) > 3 else ""]
    except Exception: pass
    return out
def read_ubase():  # unit → (ifindex, rx, tx) عدّاد الجلسة لحظة التصفير
    out = {}
    try:
        for l in open(UBASE):
            p = l.split()
            if len(p) == 4: out[int(p[0])] = (p[1], int(p[2]), int(p[3]))
    except Exception: pass
    return out
def ppp_counters(i):  # (ifindex, rx, tx) للجلسة الحالية أو None
    d = f"/sys/class/net/ppp{i}"
    try: return (open(d + "/ifindex").read().strip(), int(open(d + "/statistics/rx_bytes").read()), int(open(d + "/statistics/tx_bytes").read()))
    except Exception: return None
def session_usage(i, base):  # استهلاك الجلسة الحالية منذ آخر تصفير
    c = ppp_counters(i)
    if not c: return 0, 0
    b = base.get(i)
    if b and b[0] == c[0]: return max(0, c[1] - b[1]), max(0, c[2] - b[2])
    return c[1], c[2]
def usage_reset(users=None):  # None = تصفير الكل
    os.makedirs(RUN, exist_ok=True); now = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(ULOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        U, base, lines = read_usage(), read_ubase(), read_lines()
        if users is None: U = {}; users = {l["user"] for l in lines}
        for u in users: U[u] = [0, 0, now]
        for i, l in enumerate(lines):
            if l["user"] in users:
                c = ppp_counters(i)
                if c: base[i] = c
                else: base.pop(i, None)
        with open(USAGE + ".tmp", "w") as f:
            for u, (rx, tx, since) in U.items(): f.write(f"{u},{rx},{tx},{since}\n")
        os.replace(USAGE + ".tmp", USAGE)
        with open(UBASE + ".tmp", "w") as f:
            for i, (idx, rx, tx) in base.items(): f.write(f"{i} {idx} {rx} {tx}\n")
        os.replace(UBASE + ".tmp", UBASE)

def status():
    res = []; U, base = read_usage(), read_ubase()
    for i, l in enumerate(read_lines()):
        dev = f"ppp{i}"
        ip = sh(f"ip -4 -o addr show dev {dev} 2>/dev/null | awk '{{print $4}}'")
        active = sh(f"systemctl is-active pppoe@{i}") == "active"
        enabled = sh(f"systemctl is-enabled pppoe@{i} 2>/dev/null") == "enabled"
        mac = sh(f"cat /sys/class/net/mv{i}/address 2>/dev/null") or l["mac"] or "-"
        link = sh(f"ip -o link show mv{i} 2>/dev/null | sed -n 's/^[0-9]*: mv[0-9]*@\\([^:]*\\):.*/\\1/p'") or "-"
        rx = tx = 0; up = ""
        if ip:
            try:
                rx = int(open(f"/sys/class/net/{dev}/statistics/rx_bytes").read()); tx = int(open(f"/sys/class/net/{dev}/statistics/tx_bytes").read())
                up = fmt_dur(time.time() - os.stat(f"/sys/class/net/{dev}").st_ctime)
            except Exception: pass
        downfor = ""
        try:
            ds = int(open(f"{STATE}/down-{i}").read()); downfor = fmt_dur(time.time() - ds) if not ip else ""
        except Exception: pass
        state = "UP" if ip else ("CONNECTING" if active else ("STOPPED" if not enabled else "DOWN"))
        u = U.get(l["user"], [0, 0, ""]); srx, stx = session_usage(i, base) if ip else (0, 0)
        trx, ttx = u[0] + srx, u[1] + stx
        res.append({"i": i, "user": l["user"], "weight": l["weight"], "mac": mac, "uplink": l["uplink"], "iface": link, "ip": ip or "-",
                    "state": state, "enabled": enabled, "rx": human(rx), "tx": human(tx), "uptime": up, "downfor": downfor,
                    "trx": human(trx), "ttx": human(ttx), "since": u[2], "rx_b": rx, "tx_b": tx, "trx_b": trx, "ttx_b": ttx})
    return res

_last = {}
def traffic():
    now = time.time(); out = {"lines": [], "lan": None, "total": {"down": 0.0, "up": 0.0}}
    def rate(dev):
        try: rx = int(open(f"/sys/class/net/{dev}/statistics/rx_bytes").read()); tx = int(open(f"/sys/class/net/{dev}/statistics/tx_bytes").read())
        except Exception: _last.pop(dev, None); return None
        prev = _last.get(dev); _last[dev] = (now, rx, tx)
        if not prev or now - prev[0] <= 0: return (0.0, 0.0, rx, tx)
        dt = now - prev[0]; return (max(0, rx-prev[1])*8/dt/1e6, max(0, tx-prev[2])*8/dt/1e6, rx, tx)
    for i, l in enumerate(read_lines()):
        r = rate(f"ppp{i}")
        if r is None: out["lines"].append({"i": i, "user": l["user"], "up": False}); continue
        out["lines"].append({"i": i, "user": l["user"], "up": True, "down": round(r[0],2), "upl": round(r[1],2), "rx": human(r[2]), "tx": human(r[3])})
        out["total"]["down"] += r[0]; out["total"]["up"] += r[1]
    out["total"] = {k: round(v, 2) for k, v in out["total"].items()}
    lif = lan_if(); r = rate(lif) if lif else None
    if r: out["lan"] = {"dev": lif, "to_clients": round(r[1],2), "from_clients": round(r[0],2)}
    out["active"] = sum(1 for x in out["lines"] if x["up"]); out["ts"] = time.strftime("%H:%M:%S")
    return out

def parse_upload(fs):
    name = (fs.filename or "upload").lower(); os.makedirs(UPLOADS, exist_ok=True)
    path = os.path.join(UPLOADS, time.strftime("%Y%m%d-%H%M%S_") + os.path.basename(name)); fs.save(path)
    rows = []
    if name.endswith((".xlsx", ".xlsm")):
        import openpyxl
        for r in openpyxl.load_workbook(path, read_only=True, data_only=True).active.iter_rows(values_only=True):
            rows.append(["" if v is None else str(v).strip() for v in r])
    else:
        txt = open(path, encoding="utf-8-sig", errors="ignore").read(); first = txt.splitlines()[0] if txt else ""
        delim = "\t" if "\t" in first else ("," if "," in first else ";")
        for r in csv.reader(txt.splitlines(), delimiter=delim): rows.append([x.strip() for x in r])
    out = []
    for r in rows:
        r += [""] * (5 - len(r))
        if not r[0] or not r[1] or r[0].lower() in ("user","username","المستخدم","اسم المستخدم","login"): continue
        out.append({"user": r[0], "pass": r[1], "weight": r[2] if r[2].isdigit() else "1", "mac": norm_mac(r[3]), "uplink": r[4]})
    return out, os.path.basename(path)

def form_line(f):
    return {"user": f["user"].strip(), "pass": f["pass"].strip(), "weight": f.get("weight","1").strip() or "1",
            "mac": norm_mac(f.get("mac","")), "uplink": f.get("uplink","").strip()}
def parse_bulk(text):
    out = []
    for row in text.splitlines():
        p = [x.strip() for x in row.split(",")] + [""] * 5
        if p[0] and p[1]: out.append({"user": p[0], "pass": p[1], "weight": p[2] or "1", "mac": norm_mac(p[3]), "uplink": p[4]})
    return out

# ---------------- templates ----------------
CSS = r'''<style>
body{font-family:Tahoma,Arial,sans-serif;background:#0f172a;color:#e2e8f0;margin:0;padding:16px}
h1{font-size:20px;margin:0 0 12px}h3{margin-top:0}.bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px}
.card{background:#1e293b;border-radius:10px;padding:14px;margin-bottom:14px;overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{padding:7px 6px;border-bottom:1px solid #334155;text-align:right;white-space:nowrap}
th{color:#94a3b8;font-weight:normal}.UP{color:#22c55e;font-weight:bold}.DOWN{color:#ef4444;font-weight:bold}.CONNECTING{color:#f59e0b;font-weight:bold}.STOPPED{color:#94a3b8;font-weight:bold}
button,a.btn{background:#2563eb;color:#fff;border:0;border-radius:6px;padding:6px 10px;cursor:pointer;text-decoration:none;font-size:13px}
button.red{background:#dc2626}button.gray{background:#475569}button.green{background:#16a34a}button.orange{background:#d97706}
input,select,textarea{background:#0f172a;color:#e2e8f0;border:1px solid #334155;border-radius:6px;padding:7px;font-size:14px}
textarea{width:100%;direction:ltr}form.inline{display:inline}.flash{background:#14532d;padding:8px 12px;border-radius:6px;margin-bottom:10px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:8px;align-items:end}
.muted{color:#94a3b8;font-size:12px}.mac{font-family:monospace;direction:ltr;display:inline-block}#sum{font-size:14px;color:#94a3b8}
pre{background:#020617;padding:10px;border-radius:6px;overflow:auto;font-size:12px;direction:ltr;text-align:left}a{color:#93c5fd}
.tg{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:12px}.tbox{background:#0f172a;border-radius:8px;padding:8px}
.tbox .h{display:flex;justify-content:space-between;font-size:13px;margin-bottom:4px}.tbox canvas{width:100%;height:110px;display:block;background:#fff;border-radius:4px}
.tbox.tot canvas{height:170px}.rx{color:#ef4444;font-weight:bold}.tx{color:#2563eb;font-weight:bold}.off{color:#64748b}
.tctl{display:flex;gap:8px;align-items:center;margin-bottom:10px;font-size:13px;color:#94a3b8}.chip{display:inline-block;background:#334155;border-radius:6px;padding:4px 8px;margin:3px}
</style>'''

PAGE = r'''<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MultiWAN</title>''' + CSS + r'''</head><body>
<h1>MultiWAN — إدارة خطوط PPPoE</h1>
{% with m = get_flashed_messages() %}{% if m %}<div class="flash">{{ m[0] }}</div>{% endif %}{% endwith %}
<div class="bar"><span id="sum">—</span>
 <form class="inline" method="post" action="/restart-all" onsubmit="return confirm('إعادة تشغيل كل الخطوط؟')"><button class="gray">إعادة تشغيل الكل</button></form>
 <form class="inline" method="post" action="/start-all"><button class="green">تشغيل الكل</button></form>
 <form class="inline" method="post" action="/stop-all" onsubmit="return confirm('إيقاف كل الخطوط؟')"><button class="orange">إيقاف الكل</button></form>
 <form class="inline" method="post" action="/apply"><button>تطبيق الإعدادات</button></form>
 <button type="button" id="tbtn" onclick="toggleTraffic()">الترافيك ▾</button>
 <a class="btn" href="/routes">جدول التوجيه</a></div>

<div class="card" id="tcard" style="display:none">
<div class="tctl"><span id="tts"></span> &nbsp; <span class="rx">■ Rx</span> تنزيل &nbsp; <span class="tx">■ Tx</span> رفع &nbsp; | المقياس:
<select id="tscale" onchange="localStorage.setItem('mw_scale',this.value)"><option value="auto">تلقائي</option><option value="10">10M</option><option value="20">20M</option><option value="50">50M</option><option value="100">100M</option><option value="200">200M</option></select></div>
<div class="tbox tot"><div class="h"><b>الإجمالي (كل الخطوط)</b><span><span class="tx" id="t_tx">0</span> / <span class="rx" id="t_rx">0</span> Mbps</span></div><canvas id="c_tot" width="1000" height="170"></canvas></div>
<div class="tbox tot" style="margin-top:12px"><div class="h"><b>الخروج للعملاء (LAN)</b><span><span class="tx" id="l_tx">0</span> / <span class="rx" id="l_rx">0</span> Mbps</span></div><canvas id="c_lan" width="1000" height="170"></canvas></div>
<div class="tg" id="tg" style="margin-top:12px"></div></div>

<div class="card"><table><thead><tr><th>#</th><th>المستخدم</th><th>المدخل</th><th>الكرت</th><th>MAC</th><th>الوزن</th><th>الحالة</th><th>IP</th><th>مدة الاتصال</th><th>واقع منذ</th><th>تنزيل (الجلسة)</th><th>رفع (الجلسة)</th><th>إجمالي تنزيل</th><th>إجمالي رفع</th><th>إجراءات</th></tr></thead><tbody>
{% for s in st %}<tr id="r{{s.i}}"><td>{{s.i}}</td><td>{{s.user}}</td>
<td><form class="inline" method="post" action="/set-uplink/{{s.i}}"><select name="uplink" onchange="this.form.submit()" style="padding:3px">{% for u in ups %}<option value="{{u.name}}" {% if s.uplink==u.name or (not s.uplink and loop.first) %}selected{% endif %}>{{u.name}}</option>{% endfor %}</select></form></td>
<td class="muted">{{s.iface}}</td><td><span class="mac">{{s.mac}}</span></td><td>{{s.weight}}</td><td class="state {{s.state}}">{{s.state}}</td><td class="ip">{{s.ip}}</td><td class="up">{{s.uptime}}</td><td class="df">{{s.downfor}}</td><td class="rx">{{s.rx}}</td><td class="tx">{{s.tx}}</td>
<td class="trx rx" title="منذ {{s.since or 'البداية'}}">{{s.trx}}</td><td class="ttx tx" title="منذ {{s.since or 'البداية'}}">{{s.ttx}}</td>
<td>{% if s.enabled %}<form class="inline" method="post" action="/stop/{{s.i}}"><button class="orange">إيقاف</button></form>{% else %}<form class="inline" method="post" action="/start/{{s.i}}"><button class="green">تشغيل</button></form>{% endif %}
<form class="inline" method="post" action="/restart/{{s.i}}"><button class="gray">إعادة</button></form> <a class="btn" href="/edit/{{s.i}}">تعديل</a> <a class="btn" href="/log/{{s.i}}">سجل</a>
<form class="inline" method="post" action="/usage-reset/{{s.i}}" onsubmit="return confirm('تصفير إجمالي {{s.user}}؟')"><button class="gray" title="تصفير الإجمالي">تصفير</button></form>
<form class="inline" method="post" action="/delete/{{s.i}}" onsubmit="return confirm('حذف الخط {{s.user}}؟')"><button class="red">حذف</button></form></td></tr>{% endfor %}
</tbody><tfoot><tr style="font-weight:bold;background:#0f172a"><td colspan="10">الإجمالي للكل</td>
<td class="rx" id="sum_rx">{{st|sum(attribute='rx_b')|human}}</td><td class="tx" id="sum_tx">{{st|sum(attribute='tx_b')|human}}</td>
<td class="rx" id="sum_trx">{{st|sum(attribute='trx_b')|human}}</td><td class="tx" id="sum_ttx">{{st|sum(attribute='ttx_b')|human}}</td>
<td><form class="inline" method="post" action="/usage-reset-all" onsubmit="return confirm('تصفير الإجمالي لكل المستخدمين؟')"><button class="orange">تصفير الكل</button></form></td></tr></tfoot></table>
<p class="muted">الإجمالي = كل الجلسات منذ آخر تصفير (يبقى بعد انقطاع الخط وإعادة الاتصال). مرّر الماوس على الرقم لترى تاريخ التصفير.</p></div>

<div class="card" id="net"><h3>الشبكة — كرت الخروج للعملاء والإدارة</h3>
<table><thead><tr><th></th><th>الكرت</th><th>Proxmox</th><th>IP</th><th>MAC</th><th>الحالة</th><th>استقبال</th><th>إرسال</th></tr></thead><tbody>
{% for label, x in [('الخروج للعملاء (LAN)', net.lan), ('الإدارة', net.mgmt)] %}<tr><td><b>{{label}}</b></td><td>{{x.dev}}</td><td class="muted">{{x.note or '—'}}</td>
<td style="direction:ltr;text-align:right">{{x.ips|join(', ') or '—'}}{% if x.conf_ip and x.conf_ip not in x.ips %} <span class="DOWN">(المضبوط {{x.conf_ip}})</span>{% endif %}</td>
<td><span class="mac">{{x.mac}}</span></td><td class="{{x.state}}">{{x.state}}</td><td>{{x.rx}}</td><td>{{x.tx}}</td></tr>{% endfor %}
</tbody></table>
<form method="post" action="/lan" style="margin-top:10px" onsubmit="return confirm('تطبيق إعداد الخروج للعملاء الآن؟ العملاء يجب أن يستخدموا الـgateway الجديد.')"><div class="grid">
<label>كرت الخروج للعملاء<br><select name="iface">{% for i in net.choices %}<option {% if i==net.lan.dev %}selected{% endif %}>{{i}}</option>{% endfor %}</select></label>
<label>IP/الماسك (= gateway العملاء)<br><input name="ip" value="{{net.lan.conf_ip}}" required placeholder="192.168.121.1/24" style="direction:ltr"></label>
<button class="green">حفظ وتطبيق</button></div></form>
<p class="muted">يُطبَّق فوراً بدون إعادة إقلاع. الـVLAN يُضبط على الكرت في Proxmox. الكروت المستخدمة كمداخل لا تظهر في القائمة. الإدارة للعرض فقط حتى لا ينقطع الوصول للوحة.</p></div>

<div class="card" id="sec"><h3>الأمان — بيانات دخول اللوحة</h3>
<form method="post" action="/password" autocomplete="off"><div class="grid">
<label>اسم المستخدم<br><input name="user" value="{{admin_user}}" required style="direction:ltr"></label>
<label>كلمة السر الحالية<br><input name="old" type="password" required style="direction:ltr"></label>
<label>كلمة السر الجديدة<br><input name="new" type="password" required minlength="6" maxlength="64" style="direction:ltr"></label>
<label>تأكيد الجديدة<br><input name="new2" type="password" required minlength="6" maxlength="64" style="direction:ltr"></label>
<label><input type="checkbox" name="root" value="1"> نفس الكلمة لـroot (SSH/Console)</label>
<button class="green">تغيير</button></div></form>
<p class="muted">6 أحرف على الأقل: حروف إنجليزية وأرقام و . _ @ % + = - . بعد التغيير يطلب المتصفح الدخول بالبيانات الجديدة.</p></div>

<div class="card"><h3>المداخل (كروت الشبكة للدخول PPPoE)</h3>
<p class="muted">كل مدخل = كرت شبكة في الـVM؛ الـVLAN tag يُضبط على الكرت في Proxmox. الأول هو الافتراضي. الكروت المتاحة الآن: {{free|join(', ') or 'لا يوجد'}}</p>
{% for u in ups %}<span class="chip"><b>{{u.name}}</b> → {{u.iface}} {% if u.comment %}<span class="muted">({{u.comment}})</span>{% endif %}
{% if ups|length > 1 %}<form class="inline" method="post" action="/uplink-del/{{u.name}}" onsubmit="return confirm('حذف المدخل {{u.name}}؟ خطوطه تنتقل للافتراضي')"><button class="red" style="padding:2px 6px">×</button></form>{% endif %}</span>{% endfor %}
<form method="post" action="/uplink-add" style="margin-top:8px"><div class="grid">
<label>الاسم<br><input name="name" placeholder="wan2" required style="direction:ltr"></label>
<label>الكرت<br><select name="iface">{% for i in free %}<option>{{i}}</option>{% endfor %}</select></label>
<label>ملاحظة<br><input name="comment" placeholder="Fiber02 VLAN1105"></label>
<button class="green">إضافة مدخل</button></div></form></div>

<div class="card"><h3>إضافة خط جديد</h3>
<form method="post" action="/add"><div class="grid">
<label>المستخدم<br><input name="user" required style="direction:ltr"></label><label>كلمة السر<br><input name="pass" required style="direction:ltr"></label>
<label>الوزن<br><select name="weight"><option value="1">1 (8M)</option><option value="2" selected>2 (16M)</option><option value="3">3</option><option value="4">4</option></select></label>
<label>MAC (اختياري)<br><input name="mac" placeholder="تلقائي" style="direction:ltr"></label>
<label>المدخل<br><select name="uplink">{% for u in ups %}<option value="{{u.name}}">{{u.name}}</option>{% endfor %}</select></label>
<button class="green">إضافة وتطبيق</button></div></form>
<p class="muted">دفعة: سطر لكل خط بصيغة user,pass,weight,mac,uplink (الوزن والـMAC والمدخل اختيارية)</p>
<form method="post" action="/bulk"><textarea name="bulk" rows="4"></textarea><br><button>إضافة الدفعة وتطبيق</button></form>
<h3 style="margin-top:14px">إضافة عدة خطوط بالعدد</h3>
<form method="post" action="/add-many"><div class="grid">
<label>العدد<br><input name="count" type="number" min="1" max="200" value="10" required></label>
<label>قالب المستخدم <span class="muted">({n}=الرقم)</span><br><input name="utpl" value="line{n}@isp" style="direction:ltr" required></label>
<label>يبدأ من<br><input name="start" type="number" value="11"></label><label>خانات<br><input name="pad" type="number" min="1" max="4" value="2"></label>
<label>قالب كلمة السر<br><input name="ptpl" value="pass{n}" style="direction:ltr" required></label>
<label>الوزن<br><select name="weight"><option value="1">1</option><option value="2" selected>2</option></select></label>
<label>المدخل<br><select name="uplink">{% for u in ups %}<option value="{{u.name}}">{{u.name}}</option>{% endfor %}</select></label>
<label>بعد الإضافة<br><select name="state"><option value="stopped">موقوف</option><option value="running">شغّال</option></select></label>
<button class="green">إضافة</button></div></form></div>

<div class="card"><h3>جدولة إعادة الاتصال</h3>
<form method="post" action="/reconnect-conf"><div class="grid">
<label>الوضع<br><select name="mode"><option value="random_each" {% if rc.MODE=='random_each' %}selected{% endif %}>عشوائي مستقل لكل خط</option><option value="cycle" {% if rc.MODE=='cycle' %}selected{% endif %}>دورة لكل الخطوط كل N ساعة</option><option value="off" {% if rc.MODE=='off' %}selected{% endif %}>معطّل</option></select></label>
<label>أقل مدة (ساعة) — عشوائي<br><input name="minh" type="number" min="0" step="0.5" value="{{rc.MIN_HOURS}}"></label>
<label>أكبر مدة (ساعة) — عشوائي<br><input name="maxh" type="number" min="0" step="0.5" value="{{rc.MAX_HOURS}}"></label>
<label>كل كم ساعة — دورة<br><input name="every" type="number" min="1" value="{{rc.EVERY_HOURS}}"></label>
<label>فاصل بين الخطوط (ث) — دورة<br><input name="spread" type="number" min="0" value="{{rc.SPREAD_SEC}}"></label>
<label>الخطوط<br><select name="onlyup"><option value="1" {% if rc.ONLY_UP=='1' %}selected{% endif %}>الشغّالة فقط</option><option value="0" {% if rc.ONLY_UP=='0' %}selected{% endif %}>كل المفعّلة</option></select></label>
<button>حفظ</button></div></form>
<p class="muted">الحالة: {{rc_state}} <form class="inline" method="post" action="/reconnect-now"><button class="gray">إعادة الكل الآن</button></form> <form class="inline" method="post" action="/reconnect-reshuffle"><button class="gray">سحب مواعيد جديدة</button></form></p>
{% if nexts %}<table><thead><tr><th>#</th><th>المستخدم</th><th>الإعادة القادمة بعد</th></tr></thead><tbody>{% for n in nexts %}<tr><td>{{n.i}}</td><td>{{n.user}}</td><td>{{n.left}}</td></tr>{% endfor %}</tbody></table>{% endif %}</div>

<div class="card"><h3>الاستبدال التلقائي — قائمة الاحتياط ({{res|length}})</h3>
<form method="post" action="/failover-conf" class="inline">المدة قبل الاستبدال: <input name="hours" type="number" min="1" value="{{fo.FAILOVER_HOURS}}" style="width:70px"> ساعة <button>حفظ</button></form>
<p class="muted">أي خط مفعّل يبقى بدون IP هذه المدة يُستبدل بأول خط احتياط؛ بياناته القديمة تنتقل للمستبدَلة.</p>
<table><thead><tr><th>#</th><th>المستخدم</th><th>الوزن</th><th>MAC</th><th>المدخل</th><th></th></tr></thead><tbody>
{% for r in res %}<tr><td>{{loop.index0}}</td><td>{{r.user}}</td><td>{{r.weight}}</td><td><span class="mac">{{r.mac or '-'}}</span></td><td>{{r.uplink or '—'}}</td>
<td><form class="inline" method="post" action="/reserve-use/{{loop.index0}}"><button class="green">تفعيل كخط الآن</button></form> <form class="inline" method="post" action="/reserve-del/{{loop.index0}}"><button class="red">حذف</button></form></td></tr>{% endfor %}</tbody></table>
<form method="post" action="/reserve-upload" enctype="multipart/form-data" style="margin:8px 0;padding:10px;border:1px dashed #334155;border-radius:8px">
<b>رفع Excel / CSV:</b> <input type="file" name="file" accept=".xlsx,.xlsm,.csv,.txt,.tsv" required>
<label><input type="radio" name="mode" value="append" checked> إضافة</label> <label><input type="radio" name="mode" value="replace"> استبدال الكل</label> <button class="green">رفع</button>
<div class="muted">الأعمدة: المستخدم | كلمة السر | الوزن | MAC | المدخل — صف العناوين اختياري. <a href="/uploads">الملفات المرفوعة</a></div></form>
<p class="muted">أو سطر لكل خط: user,pass,weight,mac,uplink</p>
<form method="post" action="/reserve-add"><textarea name="bulk" rows="3"></textarea><br><button>إضافة للاحتياط</button></form></div>

<div class="card"><h3>الخطوط المستبدَلة ({{failed|length}})</h3>
<table><thead><tr><th>التاريخ</th><th>كان ppp</th><th>المستخدم</th><th></th></tr></thead><tbody>
{% for f in failed %}<tr><td>{{f.when}}</td><td>{{f.idx}}</td><td>{{f.user}}</td><td><form class="inline" method="post" action="/failed-restore/{{loop.index0}}"><button class="gray">إرجاع للاحتياط</button></form> <form class="inline" method="post" action="/failed-del/{{loop.index0}}"><button class="red">مسح</button></form></td></tr>{% endfor %}</tbody></table></div>

<script>
function hb(n){const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++;}return n.toFixed(1)+' '+u[i];}
async function refresh(){try{const r=await fetch('/api/status');const d=await r.json();let up=0;
for(const s of d){const tr=document.getElementById('r'+s.i);if(!tr)continue;const st=tr.querySelector('.state');st.textContent=s.state;st.className='state '+s.state;
for(const k of ['ip','up','df','rx','tx','trx','ttx']){const e=tr.querySelector('td.'+k);if(e)e.textContent=s[{ip:'ip',up:'uptime',df:'downfor',rx:'rx',tx:'tx',trx:'trx',ttx:'ttx'}[k]];}if(s.state=='UP')up++;}
for(const k of ['rx','tx','trx','ttx']){const e=document.getElementById('sum_'+k);if(e)e.textContent=hb(d.reduce((a,s)=>a+(s[k+'_b']||0),0));}
document.getElementById('sum').textContent='الخطوط الشغّالة: '+up+' / '+d.length;}catch(e){}}
refresh();setInterval(refresh,5000);
const N=120,HIST={};let ttimer=null;function hist(k){return HIST[k]||(HIST[k]=[]);}function push(k,rx,tx){const h=hist(k);h.push([rx,tx]);if(h.length>N)h.shift();}
function wdraw(id,h){const c=document.getElementById(id);if(!c)return;const g=c.getContext('2d'),W=c.width,H=c.height;g.fillStyle='#fff';g.fillRect(0,0,W,H);
const sel=document.getElementById('tscale').value;let m=1;for(const v of h)m=Math.max(m,v[0],v[1]);const sc=sel==='auto'?Math.max(1,Math.ceil(m/5)*5):parseFloat(sel);
g.strokeStyle='#e5e7eb';g.lineWidth=1;for(let k=1;k<5;k++){const y=H-H*k/5;g.beginPath();g.moveTo(0,y);g.lineTo(W,y);g.stroke();}for(let k=0;k<W;k+=W/12){g.beginPath();g.moveTo(k,0);g.lineTo(k,H);g.stroke();}
const bw=W/N;h.forEach((v,i)=>{const x=(N-h.length+i)*bw,yr=H-Math.min(1,v[0]/sc)*H,yt=H-Math.min(1,v[1]/sc)*H;g.fillStyle='#ef4444';g.fillRect(x+bw*.15,yr,bw*.35,H-yr);g.fillStyle='#2563eb';g.fillRect(x+bw*.5,yt,bw*.35,H-yt);});
g.fillStyle='#374151';g.font='11px Tahoma';g.textAlign='left';g.fillText(sc+' Mbps',4,12);g.fillText((sc/2).toFixed(1),4,H/2+4);}
function box(l){return `<div class="tbox" id="b${l.i}"><div class="h"><b>ppp${l.i} — ${l.user}</b><span id="v${l.i}"></span></div><canvas id="c${l.i}" width="600" height="110"></canvas></div>`;}
async function ttick(){try{const r=await fetch('/api/traffic');const d=await r.json();document.getElementById('tts').textContent=d.ts;
push('tot',d.total.down,d.total.up);wdraw('c_tot',hist('tot'));document.getElementById('t_rx').textContent=d.total.down;document.getElementById('t_tx').textContent=d.total.up;
if(d.lan){push('lan',d.lan.from_clients,d.lan.to_clients);wdraw('c_lan',hist('lan'));document.getElementById('l_rx').textContent=d.lan.from_clients;document.getElementById('l_tx').textContent=d.lan.to_clients;}
const tg=document.getElementById('tg');for(const l of d.lines){if(!document.getElementById('b'+l.i))tg.insertAdjacentHTML('beforeend',box(l));const v=document.getElementById('v'+l.i);
if(l.up){push('l'+l.i,l.down,l.upl);v.innerHTML=`<span class="tx">${l.upl}</span> / <span class="rx">${l.down}</span> Mbps`;}else{push('l'+l.i,0,0);v.innerHTML='<span class="off">غير متصل</span>';}wdraw('c'+l.i,hist('l'+l.i));}}catch(e){}}
function toggleTraffic(){const c=document.getElementById('tcard'),b=document.getElementById('tbtn');if(c.style.display==='none'){c.style.display='block';b.textContent='الترافيك ▴';ttick();ttimer=setInterval(ttick,1000);localStorage.setItem('mw_traffic','1');}else{c.style.display='none';b.textContent='الترافيك ▾';clearInterval(ttimer);localStorage.removeItem('mw_traffic');}}
document.getElementById('tscale').value=localStorage.getItem('mw_scale')||'auto';if(localStorage.getItem('mw_traffic'))toggleTraffic();
</script></body></html>'''

EDIT = r'''<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>تعديل خط</title>''' + CSS + r'''<style>input,select{width:300px}label{display:block;margin:10px 0}</style></head><body>
<h2>تعديل الخط #{{i}}</h2><form method="post">
<label>المستخدم<br><input name="user" value="{{l.user}}" required style="direction:ltr"></label>
<label>كلمة السر<br><input name="pass" value="{{l.pass}}" required style="direction:ltr"></label>
<label>الوزن<br><input name="weight" value="{{l.weight}}"></label>
<label>MAC <span class="muted">(فارغ = تلقائي {{auto}})</span><br><input name="mac" value="{{l.mac}}" style="direction:ltr" placeholder="{{auto}}"></label>
<label>المدخل<br><select name="uplink">{% for u in ups %}<option value="{{u.name}}" {% if l.uplink==u.name %}selected{% endif %}>{{u.name}} ({{u.iface}})</option>{% endfor %}</select></label>
<button>حفظ وتطبيق</button> <a class="btn" href="/">رجوع</a></form></body></html>'''

LOG = r'''<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>{{title}}</title>''' + CSS + r'''</head><body><h2>{{title}}</h2><a href="/">رجوع</a><pre>{{txt}}</pre></body></html>'''

# ---------------- routes ----------------
@app.route("/")
@auth
def index():
    rc = rc_conf(); nexts = []
    rcs = {"random_each": f'عشوائي مستقل {rc["MIN_HOURS"]}–{rc["MAX_HOURS"]} ساعة لكل خط', "cycle": f'دورة كل {rc["EVERY_HOURS"]} ساعة'}.get(rc["MODE"], "معطّل")
    if rc["MODE"] == "random_each":
        for i, l in enumerate(read_lines()):
            try: d = int(open(f"{STATE}/next-{i}").read()); nexts.append({"i": i, "user": l["user"], "left": fmt_dur(max(0, d - time.time()))})
            except Exception: nexts.append({"i": i, "user": l["user"], "left": "—"})
    return render_template_string(PAGE, st=status(), ups=uplinks(), free=free_ifaces(), res=read_csv5(RES), failed=read_failed(),
                                  fo=fo_conf(), rc=rc, rc_state=rcs, nexts=nexts, net=net_info(), admin_user=creds()[0])

@app.route("/api/status")
@auth
def api_status(): return jsonify(status())
@app.route("/api/traffic")
@auth
def api_traffic(): return jsonify(traffic())

# --- lines ---
@app.route("/add", methods=["POST"])
@auth
def add(): l = read_lines(); l.append(form_line(request.form)); write_lines(l); flash(apply()); return redirect("/")
@app.route("/bulk", methods=["POST"])
@auth
def bulk():
    l = read_lines(); n = parse_bulk(request.form["bulk"]); l += n; write_lines(l); flash(f"أُضيف {len(n)} خط — " + apply()); return redirect("/")
@app.route("/add-many", methods=["POST"])
@auth
def add_many():
    f = request.form; count = max(1, min(200, int(f.get("count","1") or 1))); start = int(f.get("start","1") or 1); pad = max(1, min(4, int(f.get("pad","2") or 2)))
    l = read_lines(); first = len(l)
    for k in range(count):
        n = str(start + k).zfill(pad)
        l.append({"user": f.get("utpl","line{n}").replace("{n}", n), "pass": f.get("ptpl","pass{n}").replace("{n}", n), "weight": f.get("weight","1") or "1", "mac": "", "uplink": f.get("uplink","")})
    write_lines(l); out = apply()
    if f.get("state") == "stopped":
        for i in range(first, first + count): sh(f"systemctl disable --now pppoe@{i}")
    flash(f"أُضيف {count} خط ({first}–{first+count-1}) — " + out); return redirect("/")
@app.route("/edit/<int:i>", methods=["GET","POST"])
@auth
def edit(i):
    l = read_lines()
    if i >= len(l): return redirect("/")
    if request.method == "POST": l[i] = form_line(request.form); write_lines(l); flash(apply()); return redirect("/")
    return render_template_string(EDIT, i=i, l=l[i], ups=uplinks(), auto=f"02:aa:bb:00:{i//256:02x}:{i%256:02x}")
@app.route("/set-uplink/<int:i>", methods=["POST"])
@auth
def set_uplink(i):
    l = read_lines(); u = request.form.get("uplink","").strip()
    if i < len(l) and u in [x["name"] for x in uplinks()]: l[i]["uplink"] = u; write_lines(l); flash(f"الخط {i} → {u} — " + apply())
    return redirect("/")
@app.route("/delete/<int:i>", methods=["POST"])
@auth
def delete(i):
    l = read_lines()
    if i < len(l): del l[i]; write_lines(l); flash(apply())
    return redirect("/")
@app.route("/stop/<int:i>", methods=["POST"])
@auth
def stop(i): sh(f"systemctl disable --now pppoe@{i}"); return redirect("/")
@app.route("/start/<int:i>", methods=["POST"])
@auth
def start(i): sh(f"systemctl enable --now pppoe@{i}"); return redirect("/")
@app.route("/restart/<int:i>", methods=["POST"])
@auth
def restart(i): sh(f"systemctl restart pppoe@{i}"); return redirect("/")
@app.route("/stop-all", methods=["POST"])
@auth
def stop_all():
    for i in range(len(read_lines())): sh(f"systemctl disable --now pppoe@{i}")
    return redirect("/")
@app.route("/start-all", methods=["POST"])
@auth
def start_all():
    for i in range(len(read_lines())): sh(f"systemctl enable --now pppoe@{i}")
    return redirect("/")
@app.route("/restart-all", methods=["POST"])
@auth
def restart_all():
    for i in range(len(read_lines())): sh(f"systemctl is-enabled -q pppoe@{i} && systemctl restart pppoe@{i}")
    return redirect("/")
@app.route("/apply", methods=["POST"])
@auth
def do_apply(): flash(apply()); return redirect("/")
@app.route("/log/<int:i>")
@auth
def log(i): return render_template_string(LOG, title=f"سجل الخط #{i}", txt=sh(f"journalctl -u pppoe@{i} -n 80 --no-pager"))
@app.route("/routes")
@auth
def routes(): return render_template_string(LOG, title="التوجيه والسجل", txt=sh("ip route show default; echo; ip rule; echo; ip -br link | grep -E '^(mv|ppp)'; echo; journalctl -t multiwan -n 60 --no-pager"))

# --- LAN (الخروج للعملاء) ---
@app.route("/lan", methods=["POST"])
@auth
def lan_set():
    i = request.form.get("iface", "").strip(); ip = request.form.get("ip", "").strip()
    if not IFRE.match(i) or not re.match(r'^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$', ip):
        flash("قيم غير صالحة — مثال: 192.168.121.1/24"); return redirect("/#net")
    r = subprocess.run([LANSH, i, ip], capture_output=True, text=True); flash((r.stdout + r.stderr).strip() or "تم")
    return redirect("/#net")

# --- تصفير الإجمالي ---
@app.route("/usage-reset/<int:i>", methods=["POST"])
@auth
def usage_reset_one(i):
    l = read_lines()
    if i < len(l): usage_reset({l[i]["user"]}); flash(f"صُفّر إجمالي {l[i]['user']}")
    return redirect("/")
@app.route("/usage-reset-all", methods=["POST"])
@auth
def usage_reset_all(): usage_reset(); flash("صُفّر الإجمالي لكل المستخدمين"); return redirect("/")

# --- كلمة السر ---
@app.route("/password", methods=["POST"])
@auth
def password():
    f = request.form; cu, cp = creds()
    nu = (f.get("user") or cu).strip(); old = f.get("old", ""); new = f.get("new", ""); new2 = f.get("new2", "")
    if not hmac.compare_digest(old, cp): flash("❌ كلمة السر الحالية غير صحيحة")
    elif new != new2: flash("❌ كلمتا السر الجديدتان غير متطابقتين")
    elif not PASSRE.match(new): flash("❌ كلمة السر: 6–64 حرفاً، حروف إنجليزية/أرقام و . _ @ % + = - فقط")
    elif not re.match(r'^[A-Za-z0-9._-]{1,32}$', nu): flash("❌ اسم المستخدم: حروف إنجليزية/أرقام و . _ - فقط")
    else:
        set_conf("ADMIN_USER", nu); set_conf("ADMIN_PASS", new); msg = f"✓ تم تغيير بيانات الدخول ({nu}) — سيطلب المتصفح الدخول من جديد"
        if f.get("root"):
            r = subprocess.run(["chpasswd"], input=f"root:{new}\n", capture_output=True, text=True)
            msg += " — وكلمة سر root تغيّرت" if r.returncode == 0 else f" — ⚠ root لم تتغيّر: {r.stderr.strip()}"
        sh(f"logger -t multiwan 'panel password changed (user {nu})'"); flash(msg)
    return redirect("/#sec")

# --- uplinks ---
@app.route("/uplink-add", methods=["POST"])
@auth
def uplink_add():
    n = re.sub(r'[^A-Za-z0-9_-]', '', request.form.get("name","")); i = request.form.get("iface","").strip(); c = request.form.get("comment","").replace(",", " ")
    ups = uplinks()
    if n and i and n not in [u["name"] for u in ups]: ups.append({"name": n, "iface": i, "comment": c}); write_uplinks(ups); sh("/usr/local/sbin/macvlan-up.sh"); flash(f"أُضيف المدخل {n} → {i}")
    return redirect("/")
@app.route("/uplink-del/<n>", methods=["POST"])
@auth
def uplink_del(n):
    ups = uplinks()
    if len(ups) > 1 and n in [u["name"] for u in ups]:
        write_uplinks([u for u in ups if u["name"] != n])
        l = read_lines(); ch = False
        for x in l:
            if x["uplink"] == n: x["uplink"] = ""; ch = True
        if ch: write_lines(l)
        flash(apply())
    return redirect("/")

# --- reconnect ---
@app.route("/reconnect-conf", methods=["POST"])
@auth
def reconnect_conf():
    f = request.form; mn = float(f.get("minh","1") or 1); mx = max(mn, float(f.get("maxh","6") or 6))
    open(RCCONF, "w").write(f"MODE={f.get('mode','off')}\nMIN_HOURS={mn:g}\nMAX_HOURS={mx:g}\nEVERY_HOURS={int(float(f.get('every','6') or 6))}\nSPREAD_SEC={int(float(f.get('spread','0') or 0))}\nRANDOM_ORDER=1\nONLY_UP={f.get('onlyup','1')}\n")
    sh(f"rm -f {STATE}/next-*; /usr/local/sbin/multiwan-reconnect.sh"); flash("حُفظت الجدولة"); return redirect("/")
@app.route("/reconnect-now", methods=["POST"])
@auth
def reconnect_now():
    subprocess.Popen("for i in $(shuf -i 0-$(( $(grep -c . /etc/multiwan/lines.csv) - 1 ))); do systemctl is-enabled -q pppoe@$i && systemctl restart pppoe@$i; sleep 20; done", shell=True)
    flash("بدأت إعادة اتصال كل الخطوط بالخلفية (فاصل 20ث)"); return redirect("/")
@app.route("/reconnect-reshuffle", methods=["POST"])
@auth
def reconnect_reshuffle(): sh(f"rm -f {STATE}/next-*; /usr/local/sbin/multiwan-reconnect.sh"); flash("سُحبت مواعيد جديدة"); return redirect("/")

# --- failover / reserve ---
@app.route("/failover-conf", methods=["POST"])
@auth
def failover_conf(): open(FOCONF, "w").write(f"FAILOVER_HOURS={max(1, int(request.form.get('hours','24') or 24))}\n"); return redirect("/")
@app.route("/reserve-add", methods=["POST"])
@auth
def reserve_add(): r = read_csv5(RES); n = parse_bulk(request.form["bulk"]); r += n; write_csv5(RES, r); flash(f"أُضيف {len(n)} خط للاحتياط"); return redirect("/")
@app.route("/reserve-upload", methods=["POST"])
@auth
def reserve_upload():
    fs = request.files.get("file")
    if not fs or not fs.filename: flash("لم يُختر ملف"); return redirect("/")
    try: new, saved = parse_upload(fs)
    except Exception as e: flash(f"فشل قراءة الملف: {e}"); return redirect("/")
    r = [] if request.form.get("mode") == "replace" else read_csv5(RES); have = {x["user"] for x in r}; added = 0
    for l in new:
        if l["user"] not in have: r.append(l); have.add(l["user"]); added += 1
    write_csv5(RES, r); flash(f"رُفع {saved}: أُضيف {added} (الإجمالي {len(r)})"); return redirect("/")
@app.route("/reserve-del/<int:i>", methods=["POST"])
@auth
def reserve_del(i):
    r = read_csv5(RES)
    if i < len(r): del r[i]; write_csv5(RES, r)
    return redirect("/")
@app.route("/reserve-use/<int:i>", methods=["POST"])
@auth
def reserve_use(i):
    r = read_csv5(RES)
    if i < len(r): l = read_lines(); l.append(r.pop(i)); write_lines(l); write_csv5(RES, r); flash(apply())
    return redirect("/")
@app.route("/failed-restore/<int:i>", methods=["POST"])
@auth
def failed_restore(i):
    rows = read_failed()
    if i < len(rows):
        x = rows.pop(i); r = read_csv5(RES); r.append({"user": x["user"], "pass": x["pass"], "weight": x["weight"], "mac": norm_mac(x["mac"]), "uplink": x["uplink"]}); write_csv5(RES, r); write_failed(rows)
    return redirect("/")
@app.route("/failed-del/<int:i>", methods=["POST"])
@auth
def failed_del(i):
    rows = read_failed()
    if i < len(rows): rows.pop(i); write_failed(rows)
    return redirect("/")
@app.route("/uploads")
@auth
def uploads_page(): return render_template_string(LOG, title="الملفات المرفوعة", txt="\n".join(sorted(os.listdir(UPLOADS), reverse=True)) if os.path.isdir(UPLOADS) else "لا يوجد")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("WEB_PORT", "8080")), threaded=True)
