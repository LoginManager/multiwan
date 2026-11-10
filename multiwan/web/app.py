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

# ---------- توزيع الأحمال ----------
LBSYSCTL = "/etc/sysctl.d/91-multiwan-lb.conf"
LBMODES = {  # الوضع → (الوصف، sysctl)
    "conn":   ("كل اتصال على حدة — أفضل توزيع (الافتراضي)", {"net.ipv4.fib_multipath_hash_policy": "1"}),
    "client": ("كل عميل على خط واحد — أفضل توافق مع البنوك/الألعاب/الكابتشا", {"net.ipv4.fib_multipath_hash_policy": "3", "net.ipv4.fib_multipath_hash_fields": "0x0001"}),
    "pair":   ("كل عميل+موقع على خط واحد — وسط بين الاثنين", {"net.ipv4.fib_multipath_hash_policy": "0"}),
}
def rd(p):
    try: return open(p).read().strip()
    except Exception: return ""
def lb_mode():
    pol = rd("/proc/sys/net/ipv4/fib_multipath_hash_policy")
    if pol == "3" and int(rd("/proc/sys/net/ipv4/fib_multipath_hash_fields") or "0", 0) == 1: return "client"
    return {"0": "pair", "1": "conn"}.get(pol, "conn")
def set_lb_mode(m):
    kv_ = LBMODES[m][1]
    for k, v in kv_.items(): sh(f"sysctl -qw {k}={v}")
    with open(LBSYSCTL, "w") as f: f.write("# طريقة توزيع الأحمال — من اللوحة\n" + "".join(f"{k}={v}\n" for k, v in kv_.items()))
def lb_info():
    lines, marks = read_lines(), {}
    ct = subprocess.run(["conntrack", "-L", "-f", "ipv4"], capture_output=True, text=True) if sh("command -v conntrack") else None
    if ct is not None:
        for m in re.findall(r"mark=(\d+)", ct.stdout): marks[int(m)] = marks.get(int(m), 0) + 1
    rows = []
    for i, l in enumerate(lines):
        if not os.path.exists(f"/sys/class/net/ppp{i}") or not sh(f"ip -4 -o addr show dev ppp{i}"): continue
        w = int(l["weight"]) if str(l["weight"]).isdigit() else 1
        rows.append({"i": i, "user": l["user"], "uplink": l["uplink"], "w": w, "conns": marks.get(100 + i, 0)})
    tw, tc = sum(r["w"] for r in rows) or 1, sum(r["conns"] for r in rows)
    for r in rows: r["exp"] = round(r["w"] * 100 / tw, 1); r["act"] = round(r["conns"] * 100 / tc, 1) if tc else 0
    nh = sh("ip route show default").count("nexthop") or (1 if sh("ip route show default") else 0)
    sticky = bool(sh("nft list table ip multiwan 2>/dev/null | head -1"))
    return {"rows": rows, "total": tc, "untracked": sum(v for k, v in marks.items() if not 100 <= k < 356),
            "ecmp": nh, "sticky": sticky, "ct": ct is not None, "mode": lb_mode()}

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
CSS = r'''<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Arabic:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root{--bg:#0b1120;--panel:#111a2e;--panel2:#0f172a;--line:#1f2b45;--text:#e6edf7;--muted:#8a9ab5;--brand:#3b82f6;--brand2:#6366f1;
--ok:#22c55e;--bad:#ef4444;--warn:#f59e0b;--idle:#64748b;--rx:#ef4444;--tx:#3b82f6;--grid:#1c2740;--shadow:0 1px 2px rgba(0,0,0,.3),0 8px 24px rgba(0,0,0,.18);--r:14px}
:root[data-theme=light]{--bg:#f3f6fb;--panel:#ffffff;--panel2:#f7f9fc;--line:#e3e9f2;--text:#0f172a;--muted:#5b6b84;--grid:#eef2f8;--shadow:0 1px 2px rgba(15,23,42,.06),0 8px 24px rgba(15,23,42,.06)}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.6 "IBM Plex Sans Arabic","Segoe UI",Tahoma,sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--brand);text-decoration:none}a:hover{text-decoration:underline}
.ltr{direction:ltr;unicode-bidi:isolate}td.ltr{text-align:right}.num{font-variant-numeric:tabular-nums}.muted{color:var(--muted);font-size:12.5px}
svg.i{width:16px;height:16px;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
/* header */
.top{position:sticky;top:0;z-index:20;background:color-mix(in srgb,var(--bg) 82%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.top .in{max-width:1440px;margin:auto;padding:10px 20px;display:flex;align-items:center;gap:14px;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:17px}
.logo{width:34px;height:34px;border-radius:10px;background:linear-gradient(135deg,var(--brand),var(--brand2));display:grid;place-items:center;color:#fff;box-shadow:var(--shadow)}
.logo svg{width:20px;height:20px;stroke:#fff}
.brand small{display:block;font-weight:400;font-size:11.5px;color:var(--muted);margin-top:-3px}
.pill{display:inline-flex;align-items:center;gap:6px;padding:5px 11px;border-radius:999px;background:var(--panel);border:1px solid var(--line);font-size:13px;white-space:nowrap}
.dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 25%,transparent)}
.sp{flex:1}
nav.tabs{max-width:1440px;margin:auto;padding:0 20px;display:flex;gap:4px;overflow-x:auto;scrollbar-width:none}
nav.tabs button{background:none;border:0;border-bottom:2px solid transparent;color:var(--muted);padding:10px 14px;font:inherit;font-weight:500;cursor:pointer;display:flex;align-items:center;gap:7px;white-space:nowrap;border-radius:0}
nav.tabs button:hover{color:var(--text)}nav.tabs button.on{color:var(--text);border-bottom-color:var(--brand)}
main{max-width:1440px;margin:auto;padding:20px}
.tab{display:none;animation:fade .2s ease}.tab.on{display:block}@keyframes fade{from{opacity:0;transform:translateY(4px)}to{opacity:1}}
/* cards */
.card{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--shadow);margin-bottom:18px;overflow:hidden}
.card>.hd{display:flex;align-items:center;gap:10px;padding:14px 18px;border-bottom:1px solid var(--line);flex-wrap:wrap}
.card>.hd h3{margin:0;font-size:15px;font-weight:600;display:flex;align-items:center;gap:8px}.card>.hd .sp{flex:1}
.card>.bd{padding:16px 18px}.card>.bd.p0{padding:0}
.kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:14px;margin-bottom:18px}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:16px;box-shadow:var(--shadow);position:relative;overflow:hidden}
.kpi .l{color:var(--muted);font-size:12.5px;display:flex;align-items:center;gap:6px;padding-inline-end:44px}.kpi .v{font-size:26px;font-weight:700;margin-top:6px;font-variant-numeric:tabular-nums;direction:ltr;text-align:right}
.kpi .v small{font-size:13px;font-weight:500;color:var(--muted)}.kpi .ic{position:absolute;inset-inline-end:14px;top:14px;width:34px;height:34px;border-radius:10px;display:grid;place-items:center;opacity:.9}
.kpi .bar{height:6px;border-radius:9px;background:var(--panel2);margin-top:10px;overflow:hidden}.kpi .bar i{display:block;height:100%;background:var(--ok);border-radius:9px;transition:width .4s}
.c-ok{background:color-mix(in srgb,var(--ok) 15%,transparent);color:var(--ok)}.c-rx{background:color-mix(in srgb,var(--rx) 15%,transparent);color:var(--rx)}
.c-tx{background:color-mix(in srgb,var(--tx) 15%,transparent);color:var(--tx)}.c-br{background:color-mix(in srgb,var(--brand2) 15%,transparent);color:var(--brand2)}
/* tables */
.tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13.5px}
th{position:sticky;top:0;background:var(--panel2);color:var(--muted);font-weight:500;font-size:12px;text-align:right;padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:9px 12px;border-bottom:1px solid var(--line);white-space:nowrap;vertical-align:middle}
tbody tr:hover{background:color-mix(in srgb,var(--brand) 6%,transparent)}tfoot td{background:var(--panel2);font-weight:600;border-bottom:0}
.rx{color:var(--rx)}.tx{color:var(--tx)}.b{font-weight:600}
.badge{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600}
.badge:before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.UP{color:var(--ok)}.DOWN{color:var(--bad)}.CONNECTING{color:var(--warn)}.STOPPED,.UNKNOWN{color:var(--idle)}
.badge.UP{background:color-mix(in srgb,var(--ok) 14%,transparent)}.badge.DOWN{background:color-mix(in srgb,var(--bad) 14%,transparent)}
.badge.CONNECTING{background:color-mix(in srgb,var(--warn) 14%,transparent)}.badge.CONNECTING:before{animation:pulse 1s infinite}
.badge.STOPPED,.badge.UNKNOWN{background:color-mix(in srgb,var(--idle) 16%,transparent)}@keyframes pulse{50%{opacity:.25}}
.tag{display:inline-block;padding:2px 8px;border-radius:6px;background:var(--panel2);border:1px solid var(--line);font-size:12px}
/* controls */
button,.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;background:var(--brand);color:#fff;border:1px solid transparent;border-radius:9px;padding:7px 13px;font:inherit;font-size:13px;font-weight:500;cursor:pointer;text-decoration:none;white-space:nowrap;transition:filter .15s,background .15s}
button:hover,.btn:hover{filter:brightness(1.1);text-decoration:none}
button.ghost,.btn.ghost{background:var(--panel2);color:var(--text);border-color:var(--line)}button.ghost:hover{background:var(--line)}
button.green{background:#16a34a}button.red{background:#dc2626}button.orange{background:#d97706}button.gray{background:#475569}
.ib{width:30px;height:30px;padding:0;border-radius:8px;background:var(--panel2);color:var(--muted);border:1px solid var(--line)}
.ib:hover{color:var(--text);background:var(--line)}.ib.ok:hover{color:var(--ok)}.ib.warn:hover{color:var(--warn)}.ib.bad:hover{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 40%,var(--line))}
.acts{display:flex;gap:5px}form.inline{display:inline}
input,select,textarea{background:var(--panel2);color:var(--text);border:1px solid var(--line);border-radius:9px;padding:8px 10px;font:inherit;font-size:13.5px;outline:none;transition:border .15s,box-shadow .15s}
input:focus,select:focus,textarea:focus{border-color:var(--brand);box-shadow:0 0 0 3px color-mix(in srgb,var(--brand) 22%,transparent)}
select.mini{padding:4px 8px;font-size:12.5px;border-radius:7px}textarea{width:100%;direction:ltr;font-family:ui-monospace,Consolas,monospace;font-size:12.5px}
label.f{display:flex;flex-direction:column;gap:5px;font-size:12.5px;color:var(--muted)}label.f input,label.f select{color:var(--text)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px;align-items:end}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.split{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,520px),1fr));gap:18px}
.search{position:relative}.search input{padding-inline-start:32px;width:240px}.search svg{position:absolute;inset-inline-start:10px;top:50%;transform:translateY(-50%);color:var(--muted)}
details.box{border:1px solid var(--line);border-radius:var(--r);background:var(--panel);box-shadow:var(--shadow);margin-bottom:18px}
details.box>summary{cursor:pointer;list-style:none;padding:14px 18px;font-weight:600;display:flex;align-items:center;gap:8px}details.box>summary::-webkit-details-marker{display:none}
details.box[open]>summary{border-bottom:1px solid var(--line)}details.box>div{padding:16px 18px}
.sub{font-weight:600;margin:18px 0 10px;font-size:13.5px}.sub:first-child{margin-top:0}
.drop{border:1.5px dashed var(--line);border-radius:12px;padding:14px;background:var(--panel2)}
.chip{display:inline-flex;align-items:center;gap:8px;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:6px 6px 6px 12px;margin:0 0 8px 8px}
.chip b{font-weight:600}.note{display:flex;gap:10px;padding:12px 14px;border-radius:10px;background:color-mix(in srgb,var(--brand) 8%,transparent);border:1px solid color-mix(in srgb,var(--brand) 25%,transparent);font-size:13px;margin-bottom:14px}
.note.bad{background:color-mix(in srgb,var(--bad) 8%,transparent);border-color:color-mix(in srgb,var(--bad) 30%,transparent)}
.meter{background:var(--panel2);border-radius:6px;height:10px;position:relative;min-width:160px}.meter i{position:absolute;inset-block:0;inset-inline-start:0;background:var(--ok);border-radius:6px}
.meter b{position:absolute;top:-4px;height:18px;border-inline-start:2px solid var(--warn)}
/* charts */
.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,560px),1fr));gap:18px;margin-bottom:18px}
.chart .hd .val{font-variant-numeric:tabular-nums;direction:ltr}.chart canvas{width:100%;height:190px;display:block}
.mini{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px}.mini .m{background:var(--panel2);border:1px solid var(--line);border-radius:12px;padding:10px 12px}
.mini .m .h{display:flex;justify-content:space-between;font-size:12.5px;margin-bottom:4px}.mini canvas{width:100%;height:70px;display:block}.off{color:var(--idle)}
.legend{display:flex;gap:14px;font-size:12.5px;color:var(--muted)}.legend span:before{content:"";display:inline-block;width:10px;height:10px;border-radius:3px;margin-inline-end:6px;vertical-align:-1px;background:currentColor}
/* toast */
.toast{position:fixed;bottom:20px;inset-inline-start:20px;z-index:50;max-width:min(560px,calc(100% - 40px));background:var(--panel);border:1px solid var(--line);border-inline-start:4px solid var(--brand);box-shadow:0 12px 32px rgba(0,0,0,.35);border-radius:12px;padding:12px 14px;display:flex;gap:10px;align-items:flex-start;animation:fade .25s}
.toast button{background:none;color:var(--muted);padding:0 4px}
pre{background:var(--panel2);border:1px solid var(--line);padding:14px;border-radius:12px;overflow:auto;font:12.5px/1.55 ui-monospace,Consolas,monospace;direction:ltr;text-align:left;margin:0;max-height:75vh}
.mac{font-family:ui-monospace,Consolas,monospace;font-size:12.5px;direction:ltr;display:inline-block}
@media (max-width:1180px){.hm{display:none}}
@media (max-width:700px){main{padding:12px}.top .in{padding:10px 12px}.search input{width:100%}.kpi .v{font-size:22px}}
</style>
<script>try{document.documentElement.dataset.theme=localStorage.getItem('mw_theme')||'dark'}catch(e){}</script>'''

# أيقونات SVG مضمّنة (بدون إنترنت)
_I = {
 "logo": '<path d="M4 12h4l3-8 4 16 3-8h2"/>',
 "home": '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/>',
 "lines": '<path d="M5 12a7 7 0 0 1 14 0"/><path d="M8.5 12a3.5 3.5 0 0 1 7 0"/><circle cx="12" cy="16" r="1.5"/>',
 "lb": '<path d="M16 3h5v5"/><path d="M8 3H3v5"/><path d="M12 22v-8.3a4 4 0 0 0-1.17-2.83L3 3"/><path d="M15 9l6-6"/>',
 "net": '<rect x="9" y="2" width="6" height="6" rx="1"/><rect x="2" y="16" width="6" height="6" rx="1"/><rect x="16" y="16" width="6" height="6" rx="1"/><path d="M12 8v4M5 16v-4h14v4"/>',
 "box": '<path d="M21 8l-9-5-9 5 9 5 9-5z"/><path d="M3 8v8l9 5 9-5V8"/><path d="M12 13v8"/>',
 "cog": '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
 "down": '<path d="M12 5v14M5 12l7 7 7-7"/>', "up": '<path d="M12 19V5M5 12l7-7 7 7"/>',
 "power": '<path d="M18.4 6.6a9 9 0 1 1-12.8 0"/><path d="M12 2v10"/>', "play": '<path d="M6 4l14 8-14 8z"/>',
 "restart": '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>', "edit": '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
 "log": '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M16 13H8M16 17H8"/>',
 "zero": '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 8v4l2 2"/>',
 "trash": '<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>', "search": '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/>',
 "moon": '<path d="M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8z"/>', "route": '<circle cx="6" cy="19" r="3"/><circle cx="18" cy="5" r="3"/><path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15"/>',
 "plus": '<path d="M12 5v14M5 12h14"/>', "shield": '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>', "link": '<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>',
 "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>', "x": '<path d="M18 6L6 18M6 6l12 12"/>', "check": '<path d="M20 6L9 17l-5-5"/>',
 "upload": '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M17 8l-5-5-5 5M12 3v12"/>', "back": '<path d="M5 12h14M13 5l7 7-7 7"/>',
}
def icon(n, cls="i"): return f'<svg class="{cls}" viewBox="0 0 24 24">{_I[n]}</svg>'

def _hdr(sub="", extra="", nav=""):
    return ('''<header class="top"><div class="in"><div class="brand"><div class="logo">''' + icon("logo") + '''</div><div>MultiWAN<small>''' + sub +
            '''</small></div></div>''' + extra + '''<span class="sp"></span>
<button class="ib" type="button" title="الوضع الفاتح/الداكن" onclick="let t=document.documentElement.dataset.theme==='light'?'dark':'light';document.documentElement.dataset.theme=t;try{localStorage.setItem('mw_theme',t)}catch(e){};if(window.redraw)redraw()">''' + icon("moon") + '''</button>
</div>''' + nav + '''</header>''')

TOAST = r'''{% with m = get_flashed_messages() %}{% if m %}<div class="toast" id="toast"><div style="flex:1">{{ m[0] }}</div><button type="button" onclick="this.parentNode.remove()">''' + icon("x") + r'''</button></div>
<script>setTimeout(()=>{const t=document.getElementById('toast');if(t)t.remove()},7000)</script>{% endif %}{% endwith %}'''

NAV = r'''<nav class="tabs" id="tabs">
<button data-t="ov">''' + icon("home") + r'''نظرة عامة</button><button data-t="ln">''' + icon("lines") + r'''الخطوط <span class="tag num">{{st|length}}</span></button>
<button data-t="lbt">''' + icon("lb") + r'''توزيع الأحمال</button><button data-t="nw">''' + icon("net") + r'''الشبكة والمداخل</button>
<button data-t="rs">''' + icon("box") + r'''الاحتياط <span class="tag num">{{res|length}}</span></button><button data-t="cf">''' + icon("cog") + r'''الإعدادات</button>
</nav>'''

PAGE = r'''<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MultiWAN</title>''' + CSS + r'''</head><body>
''' + _hdr("إدارة خطوط PPPoE", '''<span class="pill"><span class="dot" id="hdot"></span><span id="sum">—</span></span>
<span class="pill num"><span class="rx">''' + icon("down") + '''</span><span class="ltr" id="h_rx">0</span><span class="tx">''' + icon("up") + '''</span><span class="ltr" id="h_tx">0</span><span class="muted">Mbps</span></span>''', NAV) + r'''

<main>

<!-- ============ نظرة عامة ============ -->
<section class="tab" data-tab="ov">
<div class="kpis">
 <div class="kpi"><div class="ic c-ok">''' + icon("lines") + r'''</div><div class="l">الخطوط المتصلة</div><div class="v"><span id="k_up">{{st|selectattr('state','equalto','UP')|list|length}}</span> <small>/ {{st|length}}</small></div><div class="bar"><i id="k_upbar" style="width:{{ ((st|selectattr('state','equalto','UP')|list|length) * 100 / (st|length or 1))|round }}%"></i></div></div>
 <div class="kpi"><div class="ic c-rx">''' + icon("down") + r'''</div><div class="l">التنزيل الآن</div><div class="v"><span id="k_rx">0</span> <small>Mbps</small></div></div>
 <div class="kpi"><div class="ic c-tx">''' + icon("up") + r'''</div><div class="l">الرفع الآن</div><div class="v"><span id="k_tx">0</span> <small>Mbps</small></div></div>
 <div class="kpi"><div class="ic c-rx">''' + icon("down") + r'''</div><div class="l">إجمالي التنزيل</div><div class="v" id="k_trx">{{st|sum(attribute='trx_b')|human}}</div></div>
 <div class="kpi"><div class="ic c-tx">''' + icon("up") + r'''</div><div class="l">إجمالي الرفع</div><div class="v" id="k_ttx">{{st|sum(attribute='ttx_b')|human}}</div></div>
 <div class="kpi"><div class="ic c-br">''' + icon("lb") + r'''</div><div class="l">الاتصالات النشطة</div><div class="v" id="k_conn">{{lb.total}}</div></div>
</div>
<div class="charts">
 <div class="card chart"><div class="hd"><h3>''' + icon("lines") + r'''الإجمالي — كل الخطوط</h3><span class="sp"></span><span class="val"><span class="tx" id="t_tx">0</span> / <span class="rx" id="t_rx">0</span> Mbps</span></div><div class="bd"><canvas id="c_tot" width="1000" height="190"></canvas></div></div>
 <div class="card chart"><div class="hd"><h3>''' + icon("net") + r'''الخروج للعملاء (LAN)</h3><span class="sp"></span><span class="val"><span class="tx" id="l_tx">0</span> / <span class="rx" id="l_rx">0</span> Mbps</span></div><div class="bd"><canvas id="c_lan" width="1000" height="190"></canvas></div></div>
</div>
<div class="card"><div class="hd"><h3>''' + icon("lb") + r'''الترافيك لكل خط</h3><span class="sp"></span><span class="legend"><span class="rx">تنزيل</span><span class="tx">رفع</span></span>
<span class="muted" id="tts"></span><select id="tscale" class="mini" onchange="try{localStorage.setItem('mw_scale',this.value)}catch(e){};redraw()"><option value="auto">مقياس تلقائي</option><option value="10">10M</option><option value="20">20M</option><option value="50">50M</option><option value="100">100M</option><option value="200">200M</option></select></div>
<div class="bd"><div class="mini" id="tg"></div></div></div>
</section>

<!-- ============ الخطوط ============ -->
<section class="tab" data-tab="ln">
<div class="card"><div class="hd"><h3>''' + icon("lines") + r'''خطوط PPPoE</h3>
<div class="search">''' + icon("search") + r'''<input id="q" placeholder="بحث: مستخدم، IP، مدخل…" oninput="filt()"></div><span class="sp"></span>
<form class="inline" method="post" action="/start-all"><button class="ghost">''' + icon("play") + r'''تشغيل الكل</button></form>
<form class="inline" method="post" action="/restart-all" onsubmit="return confirm('إعادة تشغيل كل الخطوط؟')"><button class="ghost">''' + icon("restart") + r'''إعادة الكل</button></form>
<form class="inline" method="post" action="/stop-all" onsubmit="return confirm('إيقاف كل الخطوط؟')"><button class="ghost">''' + icon("power") + r'''إيقاف الكل</button></form>
<form class="inline" method="post" action="/apply"><button>''' + icon("check") + r'''تطبيق الإعدادات</button></form></div>
<div class="bd p0 tw"><table><thead><tr><th>#</th><th>المستخدم</th><th>المدخل / الكرت</th><th class="hm">MAC</th><th class="hm">الوزن</th><th>الحالة</th><th>IP</th><th>المدة</th><th>الجلسة <span class="ltr"><span class="rx">↓</span> / <span class="tx">↑</span></span></th><th>الإجمالي <span class="ltr"><span class="rx">↓</span> / <span class="tx">↑</span></span></th><th>إجراءات</th></tr></thead><tbody id="lt">
{% for s in st %}<tr id="r{{s.i}}"><td class="muted num">{{s.i}}</td><td class="b ltr">{{s.user}}</td>
<td><div class="row" style="gap:6px;flex-wrap:nowrap"><form class="inline" method="post" action="/set-uplink/{{s.i}}"><select name="uplink" class="mini" onchange="this.form.submit()">{% for u in ups %}<option value="{{u.name}}" {% if s.uplink==u.name or (not s.uplink and loop.first) %}selected{% endif %}>{{u.name}}</option>{% endfor %}</select></form><span class="muted">{{s.iface}}</span></div></td>
<td class="hm"><span class="mac">{{s.mac}}</span></td><td class="hm num">{{s.weight}}</td><td><span class="state badge {{s.state}}">{{s.state}}</span></td>
<td class="ltr num"><span class="f-ip">{{s.ip}}</span></td><td class="num"><span class="f-up">{{s.uptime}}</span><span class="f-df DOWN">{{s.downfor}}</span></td>
<td class="num ltr"><span class="rx f-rx">{{s.rx}}</span> <span class="muted">/</span> <span class="tx f-tx">{{s.tx}}</span></td>
<td class="num b ltr" title="منذ {{s.since or 'البداية'}}"><span class="rx f-trx">{{s.trx}}</span> <span class="muted">/</span> <span class="tx f-ttx">{{s.ttx}}</span></td>
<td><div class="acts">{% if s.enabled %}<form class="inline" method="post" action="/stop/{{s.i}}"><button class="ib warn" title="إيقاف">''' + icon("power") + r'''</button></form>{% else %}<form class="inline" method="post" action="/start/{{s.i}}"><button class="ib ok" title="تشغيل">''' + icon("play") + r'''</button></form>{% endif %}
<form class="inline" method="post" action="/restart/{{s.i}}"><button class="ib" title="إعادة الاتصال">''' + icon("restart") + r'''</button></form>
<a class="btn ib" href="/edit/{{s.i}}" title="تعديل">''' + icon("edit") + r'''</a><a class="btn ib" href="/log/{{s.i}}" title="السجل">''' + icon("log") + r'''</a>
<form class="inline" method="post" action="/usage-reset/{{s.i}}" onsubmit="return confirm('تصفير إجمالي {{s.user}}؟')"><button class="ib" title="تصفير الإجمالي">''' + icon("zero") + r'''</button></form>
<form class="inline" method="post" action="/delete/{{s.i}}" onsubmit="return confirm('حذف الخط {{s.user}}؟')"><button class="ib bad" title="حذف">''' + icon("trash") + r'''</button></form></div></td></tr>{% endfor %}
{% if not st %}<tr><td colspan="11" style="text-align:center;padding:30px" class="muted">لا توجد خطوط بعد — أضف من «إضافة خطوط» بالأسفل</td></tr>{% endif %}
</tbody><tfoot><tr><td colspan="6">الإجمالي للكل</td><td class="hm"></td><td class="hm"></td>
<td class="num ltr"><span class="rx" id="sum_rx">{{st|sum(attribute='rx_b')|human}}</span> <span class="muted">/</span> <span class="tx" id="sum_tx">{{st|sum(attribute='tx_b')|human}}</span></td>
<td class="num ltr"><span class="rx" id="sum_trx">{{st|sum(attribute='trx_b')|human}}</span> <span class="muted">/</span> <span class="tx" id="sum_ttx">{{st|sum(attribute='ttx_b')|human}}</span></td>
<td><form class="inline" method="post" action="/usage-reset-all" onsubmit="return confirm('تصفير الإجمالي لكل المستخدمين؟')"><button class="ghost">''' + icon("zero") + r'''تصفير الكل</button></form></td></tr></tfoot></table></div>
<div class="bd muted">الإجمالي = كل الجلسات منذ آخر تصفير، ويبقى بعد انقطاع الخط وإعادة الاتصال. مرّر الماوس على الرقم لترى تاريخ التصفير.</div></div>

<details class="box"><summary>''' + icon("plus") + r'''إضافة خطوط</summary><div>
<div class="sub">خط واحد</div>
<form method="post" action="/add"><div class="grid">
<label class="f">المستخدم<input name="user" required class="ltr"></label><label class="f">كلمة السر<input name="pass" required class="ltr"></label>
<label class="f">الوزن<select name="weight"><option value="1">1 (8M)</option><option value="2" selected>2 (16M)</option><option value="3">3</option><option value="4">4</option></select></label>
<label class="f">MAC (اختياري)<input name="mac" placeholder="تلقائي" class="ltr"></label>
<label class="f">المدخل<select name="uplink">{% for u in ups %}<option value="{{u.name}}">{{u.name}}</option>{% endfor %}</select></label>
<button class="green">''' + icon("plus") + r'''إضافة وتطبيق</button></div></form>
<div class="sub">دفعة — سطر لكل خط: <span class="ltr">user,pass,weight,mac,uplink</span> <span class="muted">(الوزن والـMAC والمدخل اختيارية)</span></div>
<form method="post" action="/bulk"><textarea name="bulk" rows="4"></textarea><div class="row" style="margin-top:8px"><button>إضافة الدفعة وتطبيق</button></div></form>
<div class="sub">عدة خطوط بالعدد</div>
<form method="post" action="/add-many"><div class="grid">
<label class="f">العدد<input name="count" type="number" min="1" max="200" value="10" required></label>
<label class="f">قالب المستخدم ({n}=الرقم)<input name="utpl" value="line{n}@isp" class="ltr" required></label>
<label class="f">يبدأ من<input name="start" type="number" value="11"></label><label class="f">خانات<input name="pad" type="number" min="1" max="4" value="2"></label>
<label class="f">قالب كلمة السر<input name="ptpl" value="pass{n}" class="ltr" required></label>
<label class="f">الوزن<select name="weight"><option value="1">1</option><option value="2" selected>2</option></select></label>
<label class="f">المدخل<select name="uplink">{% for u in ups %}<option value="{{u.name}}">{{u.name}}</option>{% endfor %}</select></label>
<label class="f">بعد الإضافة<select name="state"><option value="stopped">موقوف</option><option value="running">شغّال</option></select></label>
<button class="green">إضافة</button></div></form>
</div></details>
</section>

<!-- ============ توزيع الأحمال ============ -->
<section class="tab" data-tab="lbt">
<div class="kpis">
 <div class="kpi"><div class="ic c-br">''' + icon("route") + r'''</div><div class="l">خطوط في المسار الموزّع (ECMP)</div><div class="v" id="lb_ecmp">{{lb.ecmp}}</div></div>
 <div class="kpi"><div class="ic c-ok">''' + icon("shield") + r'''</div><div class="l">ثبات الاتصالات على خطها</div><div class="v" style="font-size:20px">{% if lb.sticky %}<span class="UP">مفعّل</span>{% else %}<span class="DOWN">غير مفعّل</span>{% endif %}</div></div>
 <div class="kpi"><div class="ic c-tx">''' + icon("link") + r'''</div><div class="l">الاتصالات النشطة</div><div class="v" id="lb_total">{{lb.total}}</div></div>
</div>
{% if not lb.sticky %}<div class="note bad">ثبات الاتصالات غير مفعّل — نفّذ داخل الـVM: <b class="ltr">multiwan-update</b></div>{% endif %}
{% if not lb.ct %}<div class="note bad">أداة conntrack غير مثبتة — نفّذ: <b class="ltr">apt install conntrack</b> (أو multiwan-update)</div>{% endif %}
<div class="card" id="lb"><div class="hd"><h3>''' + icon("lb") + r'''التوزيع الفعلي مقابل المتوقع</h3><span class="sp"></span><span class="legend"><span class="UP">الفعلي</span><span style="color:var(--warn)">المتوقع حسب الوزن</span></span></div>
<div class="bd p0 tw"><table><thead><tr><th>الخط</th><th>المستخدم</th><th>المدخل</th><th>الوزن</th><th>المتوقع</th><th>الاتصالات</th><th>الفعلي</th><th style="width:32%"></th></tr></thead><tbody id="lb_rows">
{% for r in lb.rows %}<tr><td class="num">ppp{{r.i}}</td><td class="ltr">{{r.user}}</td><td>{{r.uplink or '—'}}</td><td class="num">{{r.w}}</td><td class="num">{{r.exp}}%</td><td class="num">{{r.conns}}</td><td class="num b">{{r.act}}%</td>
<td><div class="meter"><i style="width:{{[r.act*2,100]|min}}%"></i><b style="inset-inline-start:{{[r.exp*2,100]|min}}%"></b></div></td></tr>{% endfor %}
{% if not lb.rows %}<tr><td colspan="8" class="muted" style="text-align:center;padding:24px">لا توجد خطوط متصلة الآن</td></tr>{% endif %}
</tbody></table></div>
<div class="bd muted">المقياس ×2. التوزيع بعدد الاتصالات وليس بالسرعة، ويقترب من المتوقع كلما زاد عدد العملاء والاتصالات.</div></div>
<div class="card"><div class="hd"><h3>''' + icon("cog") + r'''طريقة التوزيع</h3></div><div class="bd">
<form method="post" action="/lb-mode" class="row"><select name="mode">{% for k, v in lbmodes.items() %}<option value="{{k}}" {% if lb.mode==k %}selected{% endif %}>{{v[0]}}</option>{% endfor %}</select><button>حفظ</button></form>
<p class="muted" style="margin-bottom:0">«كل عميل على خط واحد» يمنع مشاكل المواقع التي ترفض تغيّر الـIP (بنوك، ألعاب، كابتشا)، لكن العميل الواحد لا يستفيد من أكثر من خط. التغيير يُطبَّق على الاتصالات الجديدة.</p></div></div>
</section>

<!-- ============ الشبكة والمداخل ============ -->
<section class="tab" data-tab="nw">
<div class="card" id="net"><div class="hd"><h3>''' + icon("net") + r'''كروت الشبكة — الخروج للعملاء والإدارة</h3></div>
<div class="bd p0 tw"><table><thead><tr><th></th><th>الكرت</th><th>Proxmox</th><th>IP</th><th>MAC</th><th>الحالة</th><th>استقبال</th><th>إرسال</th></tr></thead><tbody>
{% for label, x in [('الخروج للعملاء (LAN)', net.lan), ('الإدارة', net.mgmt)] %}<tr><td class="b">{{label}}</td><td><span class="tag">{{x.dev}}</span></td><td class="muted">{{x.note or '—'}}</td>
<td class="ltr num">{{x.ips|join(', ') or '—'}}{% if x.conf_ip and x.conf_ip not in x.ips %} <span class="DOWN">(المضبوط {{x.conf_ip}})</span>{% endif %}</td>
<td><span class="mac">{{x.mac}}</span></td><td><span class="badge {{x.state}}">{{x.state}}</span></td><td class="num">{{x.rx}}</td><td class="num">{{x.tx}}</td></tr>{% endfor %}
</tbody></table></div>
<div class="bd"><form method="post" action="/lan" onsubmit="return confirm('تطبيق إعداد الخروج للعملاء الآن؟ العملاء يجب أن يستخدموا الـgateway الجديد.')"><div class="grid">
<label class="f">كرت الخروج للعملاء<select name="iface">{% for i in net.choices %}<option {% if i==net.lan.dev %}selected{% endif %}>{{i}}</option>{% endfor %}</select></label>
<label class="f">IP/الماسك (= gateway العملاء)<input name="ip" value="{{net.lan.conf_ip}}" required placeholder="192.168.121.1/24" class="ltr"></label>
<button class="green">حفظ وتطبيق</button></div></form>
<p class="muted" style="margin-bottom:0">يُطبَّق فوراً بدون إعادة إقلاع. الـVLAN يُضبط على الكرت في Proxmox. الكروت المستخدمة كمداخل لا تظهر في القائمة. الإدارة للعرض فقط حتى لا ينقطع الوصول للوحة.</p></div></div>

<div class="card"><div class="hd"><h3>''' + icon("route") + r'''المداخل — كروت الدخول PPPoE</h3><span class="sp"></span><span class="muted">الأول هو الافتراضي</span></div><div class="bd">
{% for u in ups %}<span class="chip"><b>{{u.name}}</b><span class="tag">{{u.iface}}</span>{% if u.comment %}<span class="muted">{{u.comment}}</span>{% endif %}
{% if ups|length > 1 %}<form class="inline" method="post" action="/uplink-del/{{u.name}}" onsubmit="return confirm('حذف المدخل {{u.name}}؟ خطوطه تنتقل للافتراضي')"><button class="ib bad" title="حذف" style="width:24px;height:24px">''' + icon("x") + r'''</button></form>{% endif %}</span>{% endfor %}
<form method="post" action="/uplink-add" style="margin-top:10px"><div class="grid">
<label class="f">الاسم<input name="name" placeholder="wan7" required class="ltr"></label>
<label class="f">الكرت<select name="iface">{% for i in free %}<option>{{i}}</option>{% endfor %}</select></label>
<label class="f">ملاحظة<input name="comment" placeholder="Fiber02 VLAN1105"></label>
<button class="green">''' + icon("plus") + r'''إضافة مدخل</button></div></form>
<p class="muted" style="margin-bottom:0">كل مدخل = كرت شبكة في الـVM، والـVLAN يُضبط على الكرت في Proxmox. الكروت المتاحة الآن: {{free|join(', ') or 'لا يوجد'}}</p></div></div>
</section>

<!-- ============ الاحتياط ============ -->
<section class="tab" data-tab="rs">
<div class="card"><div class="hd"><h3>''' + icon("box") + r'''قائمة الاحتياط <span class="tag num">{{res|length}}</span></h3><span class="sp"></span>
<form method="post" action="/failover-conf" class="row"><span class="muted">الاستبدال بعد</span><input name="hours" type="number" min="1" value="{{fo.FAILOVER_HOURS}}" style="width:76px"><span class="muted">ساعة بدون IP</span><button class="ghost">حفظ</button></form></div>
<div class="bd p0 tw"><table><thead><tr><th>#</th><th>المستخدم</th><th>الوزن</th><th>MAC</th><th>المدخل</th><th></th></tr></thead><tbody>
{% for r in res %}<tr><td class="muted num">{{loop.index0}}</td><td class="ltr b">{{r.user}}</td><td class="num">{{r.weight}}</td><td><span class="mac">{{r.mac or '-'}}</span></td><td>{{r.uplink or '—'}}</td>
<td><div class="acts"><form class="inline" method="post" action="/reserve-use/{{loop.index0}}"><button class="green">تفعيل كخط الآن</button></form><form class="inline" method="post" action="/reserve-del/{{loop.index0}}"><button class="ib bad" title="حذف">''' + icon("trash") + r'''</button></form></div></td></tr>{% endfor %}
{% if not res %}<tr><td colspan="6" class="muted" style="text-align:center;padding:24px">القائمة فارغة</td></tr>{% endif %}
</tbody></table></div>
<div class="bd"><p class="muted" style="margin-top:0">أي خط مفعّل يبقى بدون IP المدة المحددة يُستبدل بأول خط احتياط، وبياناته القديمة تنتقل للمستبدَلة.</p>
<div class="split"><form method="post" action="/reserve-upload" enctype="multipart/form-data" class="drop"><div class="sub">''' + icon("upload") + r''' رفع Excel / CSV</div>
<div class="row"><input type="file" name="file" accept=".xlsx,.xlsm,.csv,.txt,.tsv" required><label><input type="radio" name="mode" value="append" checked> إضافة</label><label><input type="radio" name="mode" value="replace"> استبدال الكل</label><button class="green">رفع</button></div>
<div class="muted" style="margin-top:6px">الأعمدة: المستخدم | كلمة السر | الوزن | MAC | المدخل — صف العناوين اختياري. <a href="/uploads">الملفات المرفوعة</a></div></form>
<form method="post" action="/reserve-add"><div class="sub">أو سطر لكل خط: <span class="ltr">user,pass,weight,mac,uplink</span></div><textarea name="bulk" rows="3"></textarea><div class="row" style="margin-top:8px"><button>إضافة للاحتياط</button></div></form></div></div></div>

<div class="card"><div class="hd"><h3>''' + icon("clock") + r'''الخطوط المستبدَلة <span class="tag num">{{failed|length}}</span></h3></div>
<div class="bd p0 tw"><table><thead><tr><th>التاريخ</th><th>كان ppp</th><th>المستخدم</th><th></th></tr></thead><tbody>
{% for f in failed %}<tr><td class="num">{{f.when}}</td><td class="num">{{f.idx}}</td><td class="ltr">{{f.user}}</td><td><div class="acts"><form class="inline" method="post" action="/failed-restore/{{loop.index0}}"><button class="ghost">إرجاع للاحتياط</button></form><form class="inline" method="post" action="/failed-del/{{loop.index0}}"><button class="ib bad" title="مسح">''' + icon("trash") + r'''</button></form></div></td></tr>{% endfor %}
{% if not failed %}<tr><td colspan="4" class="muted" style="text-align:center;padding:24px">لا يوجد</td></tr>{% endif %}
</tbody></table></div></div>
</section>

<!-- ============ الإعدادات ============ -->
<section class="tab" data-tab="cf">
<div class="card"><div class="hd"><h3>''' + icon("restart") + r'''جدولة إعادة الاتصال</h3><span class="sp"></span><span class="tag">{{rc_state}}</span></div><div class="bd">
<form method="post" action="/reconnect-conf"><div class="grid">
<label class="f">الوضع<select name="mode"><option value="random_each" {% if rc.MODE=='random_each' %}selected{% endif %}>عشوائي مستقل لكل خط</option><option value="cycle" {% if rc.MODE=='cycle' %}selected{% endif %}>دورة لكل الخطوط كل N ساعة</option><option value="off" {% if rc.MODE=='off' %}selected{% endif %}>معطّل</option></select></label>
<label class="f">أقل مدة (ساعة) — عشوائي<input name="minh" type="number" min="0" step="0.5" value="{{rc.MIN_HOURS}}"></label>
<label class="f">أكبر مدة (ساعة) — عشوائي<input name="maxh" type="number" min="0" step="0.5" value="{{rc.MAX_HOURS}}"></label>
<label class="f">كل كم ساعة — دورة<input name="every" type="number" min="1" value="{{rc.EVERY_HOURS}}"></label>
<label class="f">فاصل بين الخطوط (ث) — دورة<input name="spread" type="number" min="0" value="{{rc.SPREAD_SEC}}"></label>
<label class="f">الخطوط<select name="onlyup"><option value="1" {% if rc.ONLY_UP=='1' %}selected{% endif %}>الشغّالة فقط</option><option value="0" {% if rc.ONLY_UP=='0' %}selected{% endif %}>كل المفعّلة</option></select></label>
<button>حفظ</button></div></form>
<div class="row" style="margin-top:12px"><form class="inline" method="post" action="/reconnect-now"><button class="ghost">''' + icon("restart") + r'''إعادة الكل الآن</button></form><form class="inline" method="post" action="/reconnect-reshuffle"><button class="ghost">سحب مواعيد جديدة</button></form></div></div>
{% if nexts %}<div class="bd p0 tw" style="border-top:1px solid var(--line)"><table><thead><tr><th>#</th><th>المستخدم</th><th>الإعادة القادمة بعد</th></tr></thead><tbody>{% for n in nexts %}<tr><td class="num muted">{{n.i}}</td><td class="ltr">{{n.user}}</td><td class="num">{{n.left}}</td></tr>{% endfor %}</tbody></table></div>{% endif %}</div>

<div class="card" id="sec"><div class="hd"><h3>''' + icon("shield") + r'''الأمان — بيانات دخول اللوحة</h3></div><div class="bd">
<form method="post" action="/password" autocomplete="off"><div class="grid">
<label class="f">اسم المستخدم<input name="user" value="{{admin_user}}" required class="ltr"></label>
<label class="f">كلمة السر الحالية<input name="old" type="password" required class="ltr"></label>
<label class="f">كلمة السر الجديدة<input name="new" type="password" required minlength="6" maxlength="64" class="ltr"></label>
<label class="f">تأكيد الجديدة<input name="new2" type="password" required minlength="6" maxlength="64" class="ltr"></label>
<label class="row muted"><input type="checkbox" name="root" value="1"> نفس الكلمة لـroot (SSH/Console)</label>
<button class="green">تغيير</button></div></form>
<p class="muted" style="margin-bottom:0">6 أحرف على الأقل: حروف إنجليزية وأرقام و . _ @ % + = - . بعد التغيير يطلب المتصفح الدخول بالبيانات الجديدة.</p></div></div>

<div class="card"><div class="hd"><h3>''' + icon("log") + r'''أدوات</h3></div><div class="bd row">
<a class="btn ghost" href="/routes">''' + icon("route") + r'''جدول التوجيه والسجل</a><a class="btn ghost" href="/uploads">''' + icon("upload") + r'''الملفات المرفوعة</a></div></div>
</section>
</main>
''' + TOAST + r'''
<script>
// ---------- التبويبات ----------
const TABS=[...document.querySelectorAll('.tab')];
function show(t){TABS.forEach(s=>s.classList.toggle('on',s.dataset.tab===t));document.querySelectorAll('#tabs button').forEach(b=>b.classList.toggle('on',b.dataset.t===t));
 try{localStorage.setItem('mw_tab',t)}catch(e){};if(t==='lbt')lbtick();setTimeout(redraw,30);}
document.querySelectorAll('#tabs button').forEach(b=>b.onclick=()=>{show(b.dataset.t);history.replaceState(null,'','#'+b.dataset.t)});
(function(){const h=location.hash.slice(1);let t=null;if(h){const e=document.getElementById(h);if(e&&e.closest('.tab'))t=e.closest('.tab').dataset.tab;else if(TABS.some(s=>s.dataset.tab===h))t=h;}
 if(!t){try{t=localStorage.getItem('mw_tab')}catch(e){}}show(TABS.some(s=>s.dataset.tab===t)?t:'ov');})();
function filt(){const q=document.getElementById('q').value.toLowerCase();document.querySelectorAll('#lt tr[id]').forEach(r=>r.style.display=r.textContent.toLowerCase().includes(q)?'':'none');}
// ---------- الحالة ----------
function hb(n){const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++;}return n.toFixed(1)+' '+u[i];}
const $=id=>document.getElementById(id);
async function refresh(){try{const d=await (await fetch('/api/status')).json();let up=0;
for(const s of d){const tr=$('r'+s.i);if(s.state=='UP')up++;if(!tr)continue;const st=tr.querySelector('.state');st.textContent=s.state;st.className='state badge '+s.state;
for(const k of ['ip','up','df','rx','tx','trx','ttx']){const e=tr.querySelector('.f-'+k);if(e)e.textContent=s[{ip:'ip',up:'uptime',df:'downfor',rx:'rx',tx:'tx',trx:'trx',ttx:'ttx'}[k]];}}
for(const k of ['rx','tx','trx','ttx']){const v=hb(d.reduce((a,s)=>a+(s[k+'_b']||0),0));const e=$('sum_'+k);if(e)e.textContent=v;if(k[0]=='t'&&$('k_'+k))$('k_'+k).textContent=v;}
$('sum').textContent=up+' / '+d.length+' متصل';$('k_up').textContent=up;$('k_upbar').style.width=(d.length?up*100/d.length:0)+'%';
$('hdot').style.background=up==d.length?'var(--ok)':(up?'var(--warn)':'var(--bad)');}catch(e){}}
refresh();setInterval(refresh,5000);
// ---------- توزيع الأحمال ----------
async function lbtick(){try{const d=await (await fetch('/api/lb')).json();$('lb_ecmp').textContent=d.ecmp;$('lb_total').textContent=d.total;$('k_conn').textContent=d.total;
if(!d.rows.length){$('lb_rows').innerHTML='<tr><td colspan="8" class="muted" style="text-align:center;padding:24px">لا توجد خطوط متصلة الآن</td></tr>';return;}
$('lb_rows').innerHTML=d.rows.map(r=>`<tr><td class="num">ppp${r.i}</td><td class="ltr">${r.user}</td><td>${r.uplink||'—'}</td><td class="num">${r.w}</td><td class="num">${r.exp}%</td><td class="num">${r.conns}</td><td class="num b">${r.act}%</td><td><div class="meter"><i style="width:${Math.min(r.act*2,100)}%"></i><b style="inset-inline-start:${Math.min(r.exp*2,100)}%"></b></div></td></tr>`).join('');}catch(e){}}
setInterval(()=>{const t=document.querySelector('.tab.on');if(t&&(t.dataset.tab==='lbt'||t.dataset.tab==='ov'))lbtick()},10000);
// ---------- الرسوم ----------
const N=150,HIST={};function hist(k){return HIST[k]||(HIST[k]=[]);}function push(k,rx,tx){const h=hist(k);h.push([rx,tx]);if(h.length>N)h.shift();}
const css=v=>getComputedStyle(document.documentElement).getPropertyValue(v).trim();
function wdraw(id,h){const c=$(id);if(!c||!c.offsetParent)return;const dpr=window.devicePixelRatio||1,W=c.clientWidth*dpr,H=c.clientHeight*dpr;if(c.width!==W||c.height!==H){c.width=W;c.height=H;}
const g=c.getContext('2d');g.clearRect(0,0,W,H);const sel=$('tscale').value;let m=1;for(const v of h)m=Math.max(m,v[0],v[1]);const sc=sel==='auto'?Math.max(1,Math.ceil(m*1.15/5)*5):parseFloat(sel);
g.strokeStyle=css('--grid');g.lineWidth=dpr;for(let k=1;k<4;k++){const y=Math.round(H*k/4)+.5;g.beginPath();g.moveTo(0,y);g.lineTo(W,y);g.stroke();}
const xs=i=>W-(h.length-1-i)*(W/(N-1));
for(const [ix,col] of [[0,css('--rx')],[1,css('--tx')]]){if(h.length<2)break;g.beginPath();h.forEach((v,i)=>{const x=xs(i),y=H-Math.min(1,v[ix]/sc)*(H-4*dpr);i?g.lineTo(x,y):g.moveTo(x,y)});
 const gr=g.createLinearGradient(0,0,0,H);gr.addColorStop(0,col+'55');gr.addColorStop(1,col+'05');g.lineWidth=1.8*dpr;g.strokeStyle=col;g.stroke();g.lineTo(xs(h.length-1),H);g.lineTo(xs(0),H);g.closePath();g.fillStyle=gr;g.fill();}
g.fillStyle=css('--muted');g.font=(11*dpr)+'px sans-serif';g.textAlign='left';g.fillText(sc+' Mbps',6*dpr,13*dpr);g.fillText((sc/2)+'',6*dpr,H/2+4*dpr);}
function box(l){return `<div class="m" id="b${l.i}"><div class="h"><b class="ltr">ppp${l.i} · ${l.user}</b><span id="v${l.i}" class="num"></span></div><canvas id="c${l.i}"></canvas></div>`;}
function redraw(){wdraw('c_tot',hist('tot'));wdraw('c_lan',hist('lan'));document.querySelectorAll('#tg canvas').forEach(c=>wdraw(c.id,hist('l'+c.id.slice(1))));}
async function ttick(){try{const d=await (await fetch('/api/traffic')).json();$('tts').textContent=d.ts;
push('tot',d.total.down,d.total.up);$('t_rx').textContent=$('k_rx').textContent=$('h_rx').textContent=d.total.down;$('t_tx').textContent=$('k_tx').textContent=$('h_tx').textContent=d.total.up;
if(d.lan){push('lan',d.lan.from_clients,d.lan.to_clients);$('l_rx').textContent=d.lan.from_clients;$('l_tx').textContent=d.lan.to_clients;}
const tg=$('tg');for(const l of d.lines){if(!$('b'+l.i))tg.insertAdjacentHTML('beforeend',box(l));const v=$('v'+l.i);
if(l.up){push('l'+l.i,l.down,l.upl);v.innerHTML=`<span class="tx">${l.upl}</span> / <span class="rx">${l.down}</span> Mbps`;}else{push('l'+l.i,0,0);v.innerHTML='<span class="off">غير متصل</span>';}}
redraw();}catch(e){}}
try{$('tscale').value=localStorage.getItem('mw_scale')||'auto'}catch(e){}
ttick();setInterval(ttick,2000);window.addEventListener('resize',redraw);
</script></body></html>'''

_PAGE_SIMPLE = lambda title_expr, body: (r'''<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>''' + title_expr + ''' — MultiWAN</title>''' + CSS + r'''</head><body>
''' + _hdr("إدارة خطوط PPPoE", '<a class="btn ghost" href="/">' + icon("back") + 'رجوع للوحة</a>') + r'''<main style="max-width:1100px">''' + body + r'''</main>''' + TOAST + r'''</body></html>''')

EDIT = _PAGE_SIMPLE("تعديل خط", r'''<div class="card" style="max-width:640px;margin:auto"><div class="hd"><h3>''' + icon("edit") + r'''تعديل الخط #{{i}}</h3></div><div class="bd">
<form method="post"><div class="grid" style="grid-template-columns:1fr 1fr">
<label class="f">المستخدم<input name="user" value="{{l.user}}" required class="ltr"></label>
<label class="f">كلمة السر<input name="pass" value="{{l.pass}}" required class="ltr"></label>
<label class="f">الوزن<input name="weight" value="{{l.weight}}" class="num"></label>
<label class="f">المدخل<select name="uplink">{% for u in ups %}<option value="{{u.name}}" {% if l.uplink==u.name %}selected{% endif %}>{{u.name}} ({{u.iface}})</option>{% endfor %}</select></label>
<label class="f" style="grid-column:1/-1"><span>MAC — فارغ = تلقائي <span class="ltr">{{auto}}</span></span><input name="mac" value="{{l.mac}}" class="ltr" placeholder="{{auto}}"></label>
</div><div class="row" style="margin-top:16px"><button class="green">''' + icon("check") + r'''حفظ وتطبيق</button><a class="btn ghost" href="/#ln">إلغاء</a></div></form></div></div>''')

LOG = _PAGE_SIMPLE("{{title}}", r'''<div class="card"><div class="hd"><h3>''' + icon("log") + r'''{{title}}</h3><span class="sp"></span><a class="btn ghost" href="javascript:location.reload()">''' + icon("restart") + r'''تحديث</a></div><div class="bd"><pre>{{txt}}</pre></div></div>''')

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
                                  fo=fo_conf(), rc=rc, rc_state=rcs, nexts=nexts, net=net_info(), admin_user=creds()[0], lb=lb_info(), lbmodes=LBMODES)

@app.route("/api/status")
@auth
def api_status(): return jsonify(status())
@app.route("/api/lb")
@auth
def api_lb(): return jsonify(lb_info())
@app.route("/lb-mode", methods=["POST"])
@auth
def lb_mode_set():
    m = request.form.get("mode", "")
    if m in LBMODES: set_lb_mode(m); flash("طريقة التوزيع: " + LBMODES[m][0] + " — تُطبَّق على الاتصالات الجديدة")
    return redirect("/#lb")
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
