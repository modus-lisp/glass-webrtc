"""t/linkcond.py -- the card over conditioned links: a real card (gateway + glass, one process,
SBCL or hosted modus), the real nsite client in headless Chromium, and between them a local TURN
server (t/turn.py) that adds delay, jitter, loss and a bandwidth cap.  Nothing leaves the machine.

For each link condition, in a fresh browser profile (so the client payload is fetched again):

  * TIME TO DESKTOP: page load to the client running AND the desktop painted -- read off a
    screenshot (a title bar is found), not assumed from the protocol having started.
  * LATENCY: 16 single 12 px drag steps of the topmost window, each once the link is quiet, timed
    from the input event to the window's edge -- or its wireframe outline, which the window
    manager drags instead once it measures lag -- moving on the client's canvas.
  * RATE: a 5 s drag at 60 Hz; inbound messages grouped into updates by 6 ms gaps.

Thresholds are deliberately loose -- the point is to catch the failures that are not a matter of
degree, on a loaded box: the resize answer that starved every frame past a 100 ms round trip (a
blank page), the collector rendezvous that hung a one-process modus card when its desktop thread
waited on a slow link (no payload at all).

    python3 t/linkcond.py <build-dir> <impl>        (t/linkcond.sh builds it and calls this)

<impl> is `sbcl' or a hosted modus binary.  Environment: MODUS_ROOT (default: this checkout's
parent) and QUICKLISP_SOFTWARE (default: ~/quicklisp/dists/quicklisp/software) are the card's;
LINKCOND_ONLY=name,name runs a subset (a stem names its repeats: slow); LINKCOND_OUT (default
/tmp/glass-linkcond-out) gets the screenshots, the card's logs and results.json; LINKCOND_DEBUG=1
prints every drag step.
"""
import json, os, pathlib, signal, socket, statistics, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright
import websockets.sync.server as wss

BUILD = pathlib.Path(sys.argv[1]).resolve()
IMPL = sys.argv[2]
HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent
OUT = pathlib.Path(os.environ.get("LINKCOND_OUT", "/tmp/glass-linkcond-out")).resolve()
OUT.mkdir(parents=True, exist_ok=True)
assert str(OUT).startswith("/tmp/"), "this test writes only to /tmp"

#            name      link (each way, through the TURN)                  thresholds
SCENARIOS = [
    ("lan",    None,                                              dict(ttd=25, ups=12, lat=150)),
    ("rtt100", dict(delay_ms=50, jitter_ms=5),                    dict(ttd=35, ups=6,  lat=450)),
    ("lossy",  dict(delay_ms=50, jitter_ms=5, loss=0.03),         dict(ttd=45, ups=2,  lat=900)),
    ("narrow", dict(delay_ms=50, jitter_ms=5, kbps=1500),         dict(ttd=45, ups=3,  lat=900)),
    ("far",    dict(delay_ms=125, jitter_ms=10, loss=0.01),       dict(ttd=60, ups=2,  lat=1200)),
] + [
    # A client that takes seconds to arrive: the desktop's thread waits in its RFB handshake all
    # that time while the gateway sends -- and collects.  Hosted modus deadlocked there (a socket
    # stream's read was not GC-safe); whether a collection lands in the window is luck, about one
    # session in two, so three sessions.  modus's test/stream-read-gc.lisp is the exact check.
    (f"slow{i}", dict(delay_ms=60, jitter_ms=20, loss=0.05),      dict(ttd=90, ups=1,  lat=2500))
    for i in (1, 2, 3)
]
only = [s for s in os.environ.get("LINKCOND_ONLY", "").split(",") if s]
if only:      # a name, or its stem: slow = slow1,slow2,slow3
    SCENARIOS = [s for s in SCENARIOS if s[0] in only or s[0].rstrip("0123456789") in only]

fails = []
def ok(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}{('   ' + str(detail)) if detail else ''}", flush=True)
    if not cond:
        fails.append(name)

def freeport():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def freeport_pair():
    """A port P with P+1 also free: the card's desktop and its admission service."""
    while True:
        p = freeport()
        try:
            s = socket.socket(); s.bind(("127.0.0.1", p + 1)); s.close(); return p
        except OSError:
            continue

BOX_SEC   = "11" * 32          # the card's Nostr identity
OWNER_SEC = "33" * 32          # its owner: allowlisted, signs in with a NIP-07 signer in the page

# ---- the relay: store and forward ----------------------------------------------------------------
EVENTS, LIVE, RLOCK = [], [], threading.Lock()

def matches(ev, f):
    if "kinds" in f and ev["kind"] not in f["kinds"]:
        return False
    if "authors" in f and ev["pubkey"] not in f["authors"]:
        return False
    for k, v in f.items():
        if k.startswith("#"):
            vals = {t[1] for t in ev.get("tags", []) if len(t) > 1 and t[0] == k[1:]}
            if not (set(v) & vals):
                return False
    return True

def relay_conn(conn):
    try:
        for raw in conn:
            msg = json.loads(raw)
            if msg[0] == "REQ":
                sid, filts = msg[1], msg[2:]
                with RLOCK:
                    LIVE.append((conn, sid, filts))
                    hist = [e for e in EVENTS if any(matches(e, f) for f in filts)]
                for e in hist:
                    conn.send(json.dumps(["EVENT", sid, e]))
                conn.send(json.dumps(["EOSE", sid]))
            elif msg[0] == "EVENT":
                ev = msg[1]
                with RLOCK:
                    EVENTS.append(ev)
                    tgt = [(c, s) for (c, s, f) in LIVE if any(matches(ev, x) for x in f)]
                conn.send(json.dumps(["OK", ev["id"], True, ""]))
                for c, s in tgt:
                    try: c.send(json.dumps(["EVENT", s, ev]))
                    except Exception: pass
            elif msg[0] == "CLOSE":
                with RLOCK:
                    LIVE[:] = [x for x in LIVE if not (x[0] is conn and x[1] == msg[1])]
    except Exception:
        pass
    finally:
        with RLOCK:
            LIVE[:] = [x for x in LIVE if x[0] is not conn]

# ---- the page server: the BUILT shell, with the signer spliced in front of it ---------------------
SHELL = (BUILD / "nsite-shell.html").read_text()
MODTAG = '<script type="module">'
assert MODTAG in SHELL, "the built page has no module tag to splice in front of"
SHELL = SHELL.replace(MODTAG, '<script src="/signer.js"></script>\n'
                              '<script src="/signer-shim.js"></script>\n' + MODTAG, 1)
FILES = {
    "/shell.html":     ("text/html", SHELL),
    "/keys.html":      ("text/html", '<!doctype html><meta charset="utf-8"><title>keys</title>'
                                     '<script src="/signer.js"></script>'),
    "/signer.js":      ("text/javascript", (BUILD / "signer.js").read_text()),
    "/signer-shim.js": ("text/javascript", (HERE / "signer-shim.js").read_text()),
}

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path not in FILES:
            self.send_error(404); return
        ctype, body = FILES[path]
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a): pass

HTTP_PORT, WS_PORT, TURN_PORT, DESK_PORT = freeport(), freeport(), freeport(), freeport_pair()
BASE, RELAY = f"http://127.0.0.1:{HTTP_PORT}", f"ws://127.0.0.1:{WS_PORT}"
TURN_USER, TURN_PASS = "linkcond", "linkcond-pass"
httpd = ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), H)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
wsd = wss.serve(relay_conn, "127.0.0.1", WS_PORT)
threading.Thread(target=wsd.serve_forever, daemon=True).start()

SHAPE = OUT / "shape.json"
def shape(link):
    SHAPE.write_text(json.dumps(link or {}))
    time.sleep(0.5)                                  # t/turn.py re-reads it within 0.2 s
shape(None)
turn = subprocess.Popen([sys.executable, str(HERE / "turn.py"), str(TURN_PORT), TURN_USER, TURN_PASS,
                         str(SHAPE)], stdout=open(OUT / "turn.log", "w"), stderr=subprocess.STDOUT)

# ---- the page-side instruments --------------------------------------------------------------------
# Every inbound data-channel message, timestamped; every pointer input, timestamped.
TAP = """(() => {
  window.__rx = []; window.__inputs = [];
  const tap = (ch) => ch.addEventListener('message', (e) => {
    const n = e.data.byteLength ?? e.data.size ?? e.data.length ?? 0;
    window.__rx.push([performance.now(), n, ch.label]); });
  const P = RTCPeerConnection.prototype, cdc = P.createDataChannel;
  P.createDataChannel = function (...a) { const ch = cdc.apply(this, a); tap(ch); return ch; };
  const ael = P.addEventListener;
  P.addEventListener = function (t, f, ...r) {
    if (t === 'datachannel') ael.call(this, t, (e) => tap(e.channel));
    return ael.call(this, t, f, ...r); };
  const od = Object.getOwnPropertyDescriptor(P, 'ondatachannel');
  Object.defineProperty(P, 'ondatachannel', { set(f) {
    od.set.call(this, (e) => { tap(e.channel); return f && f(e); }); },
    get() { return od.get.call(this); } });
  for (const t of ['pointermove', 'mousemove'])
    document.addEventListener(t, () => window.__inputs.push(performance.now()), true);
})();"""

def ice(servers, relay_only):
    """Replace the shell's ICE servers: none at all on the LAN (gathering against unreachable
    public STUN costs its full ten-second cap here), or the local TURN, relay-only."""
    pol = ", iceTransportPolicy: 'relay'" if relay_only else ""
    return ("(() => { const P = window.RTCPeerConnection;"
            " window.RTCPeerConnection = function (cfg) {"
            f"   return new P(Object.assign({{}}, cfg, {{ iceServers: {json.dumps(servers)}{pol} }})); }};"
            " window.RTCPeerConnection.prototype = P.prototype; })();")

def title_bar(png):
    """(x, y, left) inside the topmost window title bar on the screenshot, or None: the first run
    of light-grey rows at least 150 px wide, LEFT where that run begins.  Also how many colours
    the desktop area shows."""
    from PIL import Image
    im = Image.open(png).convert("RGB"); w, h = im.size; px = im.load()
    colours = len(set(im.crop((w // 8, h // 8, w * 7 // 8, h * 7 // 8)).getdata()))
    for y in range(20, h // 2):
        run, best, start = 0, (0, 0), 0
        for x in range(w):
            r, g, b = px[x, y]
            if 190 <= r <= 220 and abs(r - g) < 6 and abs(g - b) < 6:
                if run == 0: start = x
                run += 1
                if run > best[0]: best = (run, start)
            else:
                run = 0
        if best[0] >= 150:
            return (best[1] + best[0] // 3, y + 8, best[1]), colours
    return None, colours

# What the user sees: a 13 px strip of the title bar's row around where its left edge lands after
# a 12 px step.  The step right moves an edge into it, the step back moves it out -- whether the
# window manager moves the window or, once it measures lag, a wireframe outline of it.  Polled
# every animation frame, so the latency is input event to the change on the client's canvas.
PIXEL = """async ([X, Y, since, limit]) => {
  const c = [...document.querySelectorAll('canvas')].sort((a, b) =>
              b.width * b.height - a.width * a.height)[0];
  const r = c.getBoundingClientRect(), g = c.getContext('2d', { willReadFrequently: true });
  const sx = c.width / r.width;
  const at = () => g.getImageData(Math.floor((X - 6 - r.left) * sx),
                                  Math.floor((Y - r.top) * c.height / r.height),
                                  Math.max(1, Math.round(13 * sx)), 1).data.join(',');
  if (since === null) return at();
  const t0 = performance.now();
  return await new Promise(res => { const step = () => {
    if (at() !== since) res(performance.now());
    else if (performance.now() - t0 > limit) res(null);
    else requestAnimationFrame(step); }; step(); });
}"""

def measure(p, grab):
    x, y, left = grab
    rx = lambda: p.evaluate("window.__rx.length")
    def quiet(ms=250, limit=3.0):                    # nothing sizeable arriving for MS
        end = time.time() + limit
        while time.time() < end:
            n = p.evaluate(f"window.__rx.filter(r => r[1] > 64 && performance.now() - r[0] < {ms}).length")
            if n == 0: return
            time.sleep(0.05)
    p.mouse.move(x, y); p.mouse.down(); time.sleep(0.5); quiet()
    lat = []
    probe = left + 12
    for i in range(16):
        before = p.evaluate(PIXEL, [probe, y, None, 0])
        n_in = p.evaluate("window.__inputs.length")
        x += 12 if i % 2 == 0 else -12
        p.mouse.move(x, y)
        t_seen = p.evaluate(PIXEL, [probe, y, before, 3000])
        t_in = p.evaluate(f"window.__inputs[{n_in}]")
        if t_in and t_seen:
            lat.append(t_seen - t_in)
        if os.environ.get("LINKCOND_DEBUG"):
            print(f"     step {i}: probe ({probe},{y}) seen {t_seen and t_seen - (t_in or 0)}", flush=True)
        quiet()
    k0 = rx(); t0 = p.evaluate("performance.now()")
    end = time.time() + 5; step = 0
    while time.time() < end:            # out 150 px and back, over and over: ends where it began
        step += 1
        ph, k = (step // 30) % 2, step % 30
        p.mouse.move(x + (k * 5 if ph == 0 else 150 - k * 5), y)
        time.sleep(1 / 60)
    p.mouse.move(x, y)
    time.sleep(0.6)
    t1 = p.evaluate("performance.now()")
    msgs = p.evaluate(f"window.__rx.slice({k0})")
    p.mouse.up()
    ups, last = 0, -1e9
    for t, n, lab in msgs:
        if n > 64:
            if t - last > 6: ups += 1
            last = t
    secs = (t1 - t0) / 1000
    return dict(lat_n=len(lat),
                lat_med=statistics.median(lat) if lat else None,
                lat_p90=sorted(lat)[max(0, int(len(lat) * 0.9) - 1)] if lat else None,
                ups=ups / secs, kbs=sum(m[1] for m in msgs) / secs / 1024)

# ---- the card -------------------------------------------------------------------------------------
card_dir = OUT / "card"; card_dir.mkdir(exist_ok=True)
(card_dir / "turn.config").write_text(f'TURN_ICE="turn:127.0.0.1:{TURN_PORT} {TURN_USER} {TURN_PASS}"\n')
nsec = card_dir / "box.nsec"; nsec.write_text(BOX_SEC); nsec.chmod(0o600)
card_pids = []

# The client as a deployed card serves it: RAW (kiln ships no .gz beside it; a phone's log reads
# "816706 B raw").  A copy with no .gz next to it, so the gateway cannot pick the 8x smaller one --
# whose quick arrival hides what a slow client start does to the card.
payload = card_dir / "payload.js"
payload.write_bytes(pathlib.Path(os.environ.get("LINKCOND_PAYLOAD", str(BUILD / "payload.js"))).read_bytes())

def start_card(owner_pub):
    ql = os.path.expanduser("~/quicklisp/dists/quicklisp/software")
    env = dict(os.environ,
               OWNER=owner_pub, CARD_ONE_PROCESS="1", CARD_DIR=str(card_dir),
               CARD_CONFIG=str(card_dir / "turn.config"), CARD_NSEC_FILE=str(nsec),
               CARD_LOGIN_TTL="3600", PAYLOAD_FILE=payload,
               NOSTR_RELAYS=RELAY, LOGIN_URL_BASE=BASE + "/",
               MODUS_ROOT=os.environ.get("MODUS_ROOT", str(SRC.parent)),
               QUICKLISP_SOFTWARE=os.environ.get("QUICKLISP_SOFTWARE", ql))
    t0 = time.time()
    r = subprocess.run([str(SRC / "hosted-card" / "card.sh"), "lc", IMPL, str(DESK_PORT)], env=env,
                       cwd=str(card_dir), capture_output=True, text=True, timeout=900)
    pids = card_dir / "lc.pids"
    if pids.exists():
        card_pids.extend(int(x) for x in set(pids.read_text().split()))
    print(f"   card ({IMPL}) on 127.0.0.1:{DESK_PORT}: {r.stdout.strip().splitlines()[0] if r.stdout.strip() else r.stderr.strip()[-200:]}"
          f"  [{time.time() - t0:.0f} s]", flush=True)
    return r.returncode == 0

def stop_card():
    for pid in card_pids:
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass

# ---- run ------------------------------------------------------------------------------------------
results = {}
try:
    with sync_playwright() as pw:
        browser = pw.chromium.launch(args=["--no-sandbox", "--disable-features=WebRtcHideLocalIpsWithMdns"])
        keys = browser.new_page(); keys.goto(f"{BASE}/keys.html")
        pubof = lambda sec: keys.evaluate(
            "(s) => window.NSIGNER.getPublicKey(new Uint8Array(s.match(/../g).map(x => parseInt(x, 16))))", sec)
        BOX_PUB, OWNER_PUB = pubof(BOX_SEC), pubof(OWNER_SEC)
        keys.close()
        print(f"== linkcond: {IMPL} · page {BASE} · relay {RELAY} · turn 127.0.0.1:{TURN_PORT} ==", flush=True)
        if not start_card(OWNER_PUB):
            ok("the card started", False, f"see {card_dir}/gw-lc.log"); raise SystemExit
        turn_ice = [{"urls": f"turn:127.0.0.1:{TURN_PORT}", "username": TURN_USER, "credential": TURN_PASS}]

        for name, link, th in SCENARIOS:
            print(f"\n== {name}: {json.dumps(link) if link else 'direct, loopback'} ==", flush=True)
            shape(link)
            ctx = browser.new_context(viewport={"width": 1280, "height": 720})
            ctx.add_init_script(ice(turn_ice, True) if link else ice([], False))
            ctx.add_init_script(TAP)
            p = ctx.new_page()
            t0 = time.time()
            p.goto(f"{BASE}/shell.html?box={BOX_PUB}&relays={RELAY}&signer={OWNER_SEC}")
            r = dict(link=link)
            running = painted = False; grab = None; colours = 0
            while time.time() - t0 < th["ttd"] + 15:
                d = p.evaluate("() => (document.getElementById('diag')||{}).textContent || ''")
                if "payload running" in d:
                    running = True
                if p.locator("#signin").count():
                    p.click("#signin")
                if running:
                    p.screenshot(path=str(OUT / f"{name}.png"))
                    grab, colours = title_bar(OUT / f"{name}.png")
                    if grab:
                        painted = True; break
                time.sleep(0.5)
            r["ttd"] = time.time() - t0 if painted else None
            r["colours"] = colours
            ok(f"{name}: the client runs", running)
            ok(f"{name}: the desktop is painted (a window's title bar is on the screen)", painted,
               f"{colours} colours")
            if painted:
                ok(f"{name}: time to desktop <= {th['ttd']} s", r["ttd"] <= th["ttd"], f"{r['ttd']:.1f} s")
                m = measure(p, grab); r.update(m)
                p.screenshot(path=str(OUT / f"{name}-after.png"))
                ok(f"{name}: drag steps answered", m["lat_n"] >= 12, f"{m['lat_n']}/16")
                ok(f"{name}: input -> update median <= {th['lat']} ms", m["lat_med"] is not None
                   and m["lat_med"] <= th["lat"],
                   f"{m['lat_med']:.0f} ms (p90 {m['lat_p90']:.0f})" if m["lat_med"] is not None else "none")
                ok(f"{name}: >= {th['ups']} updates/s while dragging", m["ups"] >= th["ups"],
                   f"{m['ups']:.1f}/s, {m['kbs']:.0f} KB/s")
            results[name] = r
            ctx.close()
        browser.close()
finally:
    stop_card()
    turn.terminate()
    (OUT / "results.json").write_text(json.dumps(dict(impl=IMPL, results=results), indent=1))

print(f"\n{'scenario':<8} {'desktop':>8} {'median':>8} {'p90':>8} {'upd/s':>7} {'KB/s':>6}")
for name, r in results.items():
    f = lambda v, fmt: (fmt % v) if v is not None else "-"
    print(f"{name:<8} {f(r.get('ttd'), '%6.1f s'):>8} {f(r.get('lat_med'), '%5.0f ms'):>8} "
          f"{f(r.get('lat_p90'), '%5.0f ms'):>8} {f(r.get('ups'), '%5.1f'):>7} {f(r.get('kbs'), '%4.0f'):>6}")
print(f"\nLINKCOND {IMPL}: {'PASS' if not fails else 'FAIL (' + str(len(fails)) + ')'}", flush=True)
sys.exit(1 if fails else 0)
