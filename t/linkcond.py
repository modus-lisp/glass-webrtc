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

LINKCOND_RELAYS=wss://a,wss://b signals over those PUBLIC relays instead of the local one -- the
one thing here that leaves the machine, and only when asked.  The `answer' column is then the
sign-in's real cost: the offer's gift wrap going out to the box's answer being applied, which is
two relay hops and the card's unwrap.  Measured 2026-11: nos.lol never acknowledged a gift wrap and
relay.primal.net took 4-10 s, so a sign-in on those took up to 18 s; t/relays.py picks better ones.
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
# THIN LINKS, run only when named (LINKCOND_ONLY=thin,dial): where the sharp RFB desktop cannot keep
# up and the fuzzy video one should take over -- what the automatic choice between them is tested
# on.  Their thresholds are what the AUTO card should manage, not what RFB alone can.
EXTRA = [
    ("thin",   dict(delay_ms=60, jitter_ms=10, kbps=300),         dict(ttd=60, ups=1,  lat=2500)),
    # dial's STEPS: the drag probe sees a step as an edge crossing a 13 px strip, and at 48 kbps
    # (where auto puts this link) the picture is too soft for most small steps to register --
    # 4 of 16 measured, with a median of 1.0 s (the sharp desktop alone: 1.7 s).
    ("dial",   dict(delay_ms=100, jitter_ms=20, kbps=96),         dict(ttd=90, ups=0.5, lat=4000, steps=4)),
]
only = [s for s in os.environ.get("LINKCOND_ONLY", "").split(",") if s]
if only:      # a name, or its stem: slow = slow1,slow2,slow3
    SCENARIOS = [s for s in SCENARIOS + EXTRA if s[0] in only or s[0].rstrip("0123456789") in only]

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
if os.environ.get("LINKCOND_RELAYS"):   # keys printed in this file do not go on a public relay
    BOX_SEC, OWNER_SEC = os.urandom(32).hex(), os.urandom(32).hex()

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
            if os.environ.get("LINKCOND_DEBUG"):
                print(f"     relay <- {raw[:160]}", flush=True)
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
    except Exception as e:
        if os.environ.get("LINKCOND_DEBUG"):
            print(f"     relay connection ended: {e!r}", flush=True)
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
RELAY = os.environ.get("LINKCOND_RELAYS") or RELAY       # the public ones, when asked
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
                         str(SHAPE)], stdout=open(OUT / "turn.log", "w"), stderr=subprocess.STDOUT,
                        env=dict(os.environ, TURN_DROPLOG=str(OUT / "drops.log")))

# ---- the page-side instruments --------------------------------------------------------------------
# Every inbound data-channel message, timestamped; every pointer input, timestamped.
TAP = """(() => {
  window.__rx = []; window.__inputs = []; window.__sig = {};
  // SIGNALLING: the offer's gift wrap leaving (first kind-1059 EVENT on any relay socket) and the
  // answer being applied -- their difference is what the relays cost a sign-in.
  const W = window.WebSocket;
  window.WebSocket = function (...a) { const s = new W(...a); const send = s.send.bind(s);
    const host = String(a[0]).replace(/^wss?:\/\//, '').split('/')[0];
    s.addEventListener('message', (e) => { if (typeof e.data !== 'string') return;
      if (e.data.startsWith('["EOSE"')) (window.__sig.log ||= []).push([performance.now(), host, 'EOSE']);
      else if (e.data.startsWith('["EVENT"') && e.data.includes('"kind":1059'))
        (window.__sig.log ||= []).push([performance.now(), host, 'gift wrap in']); });
    s.send = (d) => { if (window.__sig.out == null && typeof d === 'string' && d.startsWith('["EVENT"')
                          && d.includes('"kind":1059')) window.__sig.out = performance.now();
                      return send(d); };
    return s; };
  window.WebSocket.prototype = W.prototype; Object.assign(window.WebSocket, W);
  const tap = (ch) => ch.addEventListener('message', (e) => {
    const n = e.data.byteLength ?? e.data.size ?? e.data.length ?? 0;
    window.__rx.push([performance.now(), n, ch.label]); });
  const P = RTCPeerConnection.prototype, cdc = P.createDataChannel, srd = P.setRemoteDescription;
  P.setRemoteDescription = function (d, ...r) {
    if (d && d.type === 'answer' && window.__sig.answer == null) window.__sig.answer = performance.now();
    return srd.call(this, d, ...r); };
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

AUDIO_STATS = """async () => {
  const pc = (window.__pcs || []).filter(p => p.connectionState === 'connected').pop();
  if (!pc) return null;
  const s = await pc.getStats(); let a = null;
  s.forEach(r => { if (r.type === 'inbound-rtp' && r.kind === 'audio') a = r; });
  if (!a) return null;
  const k = ['packetsReceived','packetsLost','jitter','totalSamplesReceived','concealedSamples',
             'silentConcealedSamples','insertedSamplesForDeceleration','removedSamplesForAcceleration',
             'jitterBufferDelay','jitterBufferEmittedCount','jitterBufferTargetDelay'];
  const o = {}; for (const x of k) o[x] = a[x]; return o;
}"""

def audio_check(p, name):
    """LINKCOND_AUDIO=1 (with a card playing CARD_TEST_TONE): how much of the audio the browser had to
    time-stretch.  NetEQ plays the jitter buffer faster (acceleration: samples removed) or slower
    (deceleration: samples inserted) to keep its target delay when packets arrive unevenly -- on a
    steady tone, and on music, that is heard as the pitch wavering."""
    # the speaker: play the remote audio (headless Chrome has a fake output that pulls it)
    p.evaluate("""() => { for (const a of document.querySelectorAll('audio')) { a.muted = false; a.play().catch(()=>{}); } }""")
    a0 = p.evaluate(AUDIO_STATS); time.sleep(15); a1 = p.evaluate(AUDIO_STATS)
    if not (a0 and a1):
        dbg = p.evaluate("""async () => { const out = [];
          for (const pc of (window.__pcs || [])) { const types = new Set();
            try { (await pc.getStats()).forEach(r => types.add(r.type + (r.kind ? ':' + r.kind : ''))); } catch (e) {}
            out.push(pc.connectionState + ' ' + pc.getTransceivers().map(t => t.receiver.track.kind + '/' + t.direction).join(',') + ' [' + [...types].join(' ') + ']'); }
          return out; }""")
        print(f"  audio: no inbound audio stream ({a0!r}) pcs {dbg}", flush=True); return
    d = {k: (a1[k] or 0) - (a0[k] or 0) for k in a1 if isinstance(a1[k], (int, float))}
    got = max(1, d.get("totalSamplesReceived", 0))
    stretched = d.get("insertedSamplesForDeceleration", 0) + d.get("removedSamplesForAcceleration", 0)
    delay = (d.get("jitterBufferDelay", 0) / max(1, d.get("jitterBufferEmittedCount", 0))) * 1000
    print(f"  audio: {d.get('packetsReceived',0)} pkts, lost {d.get('packetsLost',0)}, jitter {1000*(a1.get('jitter') or 0):.0f} ms, "
          f"stretched {100*stretched/got:.1f}% (decel {d.get('insertedSamplesForDeceleration',0)}, accel {d.get('removedSamplesForAcceleration',0)}), "
          f"concealed {100*d.get('concealedSamples',0)/got:.1f}%, buffer {delay:.0f} ms (target {1000*(a1.get('jitterBufferTargetDelay') or 0)/max(1,a1.get('jitterBufferEmittedCount') or 1):.0f})", flush=True)

WARP_APPS = [("devices", "terminals", "#warpPanel"), ("files", "files", "#filesPanel"),
             ("media", "media", "#mediaPanel")]

def warp_check(p, name):
    """LINKCOND_WARP=1 (a card with WARP_CHANNEL, WARP_FILES and WARP_MEDIA): the phone's other apps,
    over the warp channel.  Each is opened from the apps button and must fill from the box."""
    for app, label, panel in WARP_APPS:
        opened = p.evaluate("""([app, label]) => {
            const chip = document.querySelector('#appSwitch.on button[data-app="' + app + '"]');
            if (chip) { if (chip.disabled) return 'disabled'; chip.click(); return 'ok'; }   // a full panel's strip
            const apps = document.querySelector('button[aria-label=apps]'); if (!apps) return 'no apps button';
            apps.click();
            const b = [...document.querySelectorAll('#appsMenu button')].find(b => b.textContent.includes(label));
            if (!b) return 'not in the menu';
            if (b.disabled) return 'disabled';
            b.click(); return 'ok'; }""", [app, label])
        rows, t0 = 0, time.time()
        while opened == "ok" and time.time() - t0 < 30:
            rows = p.evaluate("(sel) => { const e = document.querySelector(sel); return e && "
                              "getComputedStyle(e).display !== 'none' ? e.querySelectorAll('li').length : -1 }", panel)
            if rows > 0: break
            time.sleep(0.5)
        p.screenshot(path=str(OUT / f"{name}-warp-{app}.png"))
        ok(f"{name}: the {app} app opens over the warp channel and fills from the box",
           opened == "ok" and rows > 0, f"{opened}, {rows} rows")
    p.evaluate("() => { const b = [...document.querySelectorAll('#appSwitch button.close, #appsMenu button')]"
               ".find(b => b.classList.contains('close') || b.textContent.includes('desktop')); if (b) b.click(); }")

def title_bar(png):
    """(x, y, left) inside the topmost window title bar on the screenshot, or None: the first run
    of light-grey rows at least 150 px wide, LEFT where that run begins.  Also the share of the
    screen's middle that is the WM's teal workspace (61,122,138; ~57,123,140 once through a codec).

    It used to count colours (>= 1000 = painted, against grey RFB tiles' few hundred), which only
    held while a 640x480 desktop was SCALED to the window: the scaling's blend made the colours.
    Once the desktop is resized to the window it is shown 1:1, a painted one has ~150 colours, and
    a desktop with only its old corner painted had as many as a whole one.  Teal coverage tells
    them apart: whole ~85%, a 640x480 corner of 1280x720 ~34%, grey tiles ~0."""
    from PIL import Image
    im = Image.open(png).convert("RGB"); w, h = im.size; px = im.load()
    mid = list(im.crop((w // 8, h // 8, w * 7 // 8, h * 7 // 8)).getdata())
    colours = round(100 * sum(1 for r, g, b in mid
                              if abs(r - 59) <= 14 and abs(g - 122) <= 14 and abs(b - 139) <= 14) / len(mid))
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
# What the user is LOOKING AT: the desktop as video (a VIDEO_PRIMARY card) when a <video> is showing
# frames, else noVNC's canvas.  Video is copied to a scratch canvas to be read.
PIXEL = """async ([X, Y, since, limit]) => {
  const v = [...document.querySelectorAll('video')].find(v => v.videoWidth > 64 &&
              v.getBoundingClientRect().width > 200 && getComputedStyle(v).visibility !== 'hidden' &&
              getComputedStyle(v).display !== 'none' && +getComputedStyle(v).opacity > 0.5);
  let c, g, w, h;
  if (v) { w = v.videoWidth; h = v.videoHeight;
           c = window.__vc || (window.__vc = document.createElement('canvas'));
           c.width = w; c.height = h; g = c.getContext('2d', { willReadFrequently: true }); }
  else { c = [...document.querySelectorAll('canvas')].sort((a, b) =>
               b.width * b.height - a.width * a.height)[0];
         w = c.width; h = c.height; g = c.getContext('2d', { willReadFrequently: true }); }
  const r = (v || c).getBoundingClientRect(), sx = w / r.width;
  const at = () => { if (v) g.drawImage(v, 0, 0);
                     return g.getImageData(Math.floor((X - 6 - r.left) * sx), Math.floor((Y - r.top) * h / r.height),
                                           Math.max(1, Math.round(13 * sx)), 1).data.join(','); };
  if (since === null) return at();
  const t0 = performance.now();
  return await new Promise(res => { const step = () => {
    if (at() !== since) res(performance.now());
    else if (performance.now() - t0 > limit) res(null);
    else requestAnimationFrame(step); }; step(); });
}"""

# Decoded frames of the largest showing <video>, or null: how a VIDEO_PRIMARY card's updates arrive.
VFRAMES = """() => { const v = [...document.querySelectorAll('video')].find(v => v.videoWidth > 64);
  return v && v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality().totalVideoFrames : null; }"""

# Complete RFB FramebufferUpdates noVNC has applied: its _framebufferUpdate returns true when the
# last rect of one is in.  "upd/s" counts data-channel arrivals instead, and one big update split
# across several of them counts several times -- this is the count of updates as such.
FBU = """() => { const r = window.__rfb; if (!r) return null;
  if (!r.__fbuHooked) { const f = r._framebufferUpdate.bind(r); window.__fbu = 0;
    r._framebufferUpdate = () => { const done = f(); if (done) window.__fbu++; return done; };
    const q = r._requestRemoteResize; window.__rsz = 0;
    if (typeof q === 'function') r._requestRemoteResize = (...a) => { window.__rsz++; return q.apply(r, a); };
    r.__fbuHooked = true; }
  return window.__fbu; }"""

# THE DESKTOP'S SIZE AND THE WINDOW'S: [desktop w, h, #screen w, h], or None.  The desktop follows
# the window (SetDesktopSize); until it has, a title bar found on the screen is where it WAS.
SIZE = ("() => { const r = window.__rfb, s = document.getElementById('screen');"
        " const b = s && s.getBoundingClientRect();"
        " return r && b ? [r._fbWidth, r._fbHeight, Math.round(b.width), Math.round(b.height)] : null; }")

def follows(p, wait):
    """Wait up to WAIT s for the desktop to be the window's size: (settled, [dw, dh, ww, wh])."""
    t1 = time.time(); v = None
    while time.time() - t1 < wait:
        v = p.evaluate(SIZE)
        if v and abs(v[0] - v[2]) <= 8 and abs(v[1] - v[3]) <= 8: return True, v
        time.sleep(0.25)
    return False, v

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
            rxs = p.evaluate("([a, b]) => window.__rx.filter(r => r[0] >= a && r[0] <= b)"
                             ".map(r => [Math.round(r[0] - a), r[1], r[2]])",
                             [t_in, (t_seen or t_in + 3000) + 5]) if t_in else []
            wall = (p.evaluate("performance.timeOrigin") + t_in) / 1000 if t_in else 0
            print(f"     step {i}: at {wall:.3f} seen {t_seen and round(t_seen - (t_in or 0))}  rx {rxs}", flush=True)
        quiet()
    p.evaluate(FBU)                                  # hook before counting from zero
    k0 = rx(); t0 = p.evaluate("performance.now()"); f0 = p.evaluate(VFRAMES); u0 = p.evaluate(FBU)
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
    f1 = p.evaluate(VFRAMES); u1 = p.evaluate(FBU); rsz = p.evaluate("window.__rsz")
    p.mouse.up()
    ups, last = 0, -1e9
    for t, n, lab in msgs:
        if n > 64:
            if t - last > 6: ups += 1
            last = t
    secs = (t1 - t0) / 1000
    video = f0 is not None and f1 is not None and f1 > f0 and ups < (f1 - f0)
    if video: ups = f1 - f0          # the desktop arrived as video frames, not on the data channel
    return dict(video=video,lat_n=len(lat),
                lat_med=statistics.median(lat) if lat else None,
                lat_p90=sorted(lat)[max(0, int(len(lat) * 0.9) - 1)] if lat else None,
                ups=ups / secs, kbs=sum(m[1] for m in msgs) / secs / 1024,
                resize_asks=rsz,
                fbu=(u1 - u0) / secs if u0 is not None and u1 is not None else None,
                kb_per_fbu=(sum(m[1] for m in msgs) / 1024 / (u1 - u0)
                            if u0 is not None and u1 is not None and u1 > u0 else None))

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
    card = os.environ.get("LINKCOND_CARD") or str(SRC / "hosted-card" / "card.sh")   # another launcher, same contract
    r = subprocess.run([card, "lc", IMPL, str(DESK_PORT)], env=env,
                       cwd=str(card_dir), capture_output=True, text=True,
                       timeout=int(os.environ.get("LINKCOND_CARD_TIMEOUT", "900")))   # a cold compile is longer
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
            # every peer connection the page makes, for AUDIO_STATS (the client's is module-scoped)
            ctx.add_init_script("""(() => { const P = window.RTCPeerConnection; window.__pcs = [];
              window.RTCPeerConnection = function (...a) { const pc = new P(...a); window.__pcs.push(pc); return pc; };
              window.RTCPeerConnection.prototype = P.prototype; })();""")
            p = ctx.new_page()
            # the browser's console, for the reasons noVNC gives only there (an UNCLEAN disconnect)
            conlog = open(OUT / f"{name}-console.txt", "w")
            p.on("console", lambda m, f=conlog: (f.write(f"{m.type}: {m.text}\n"), f.flush()))
            p.on("pageerror", lambda e, f=conlog: (f.write(f"pageerror: {e}\n"), f.flush()))
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
                    # A title bar on a screen that is not mostly workspace is grey RFB tiles, or
                    # a desktop only partly painted -- see TITLE_BAR.
                    if grab and colours >= 50:
                        painted = True; break
                time.sleep(0.5)
            r["ttd"] = time.time() - t0 if painted else None
            sig = p.evaluate("() => window.__sig")
            if os.environ.get("LINKCOND_DEBUG") and sig.get("out") is not None:
                for ms, h, what in sig.get("log", []):
                    print(f"     relay {(ms - sig['out']) / 1000:+6.2f} s  {h:24} {what}", flush=True)
                if sig.get("answer") is not None:
                    print(f"     relay {(sig['answer'] - sig['out']) / 1000:+6.2f} s  answer applied", flush=True)
            r["answer"] = ((sig["answer"] - sig["out"]) / 1000
                           if sig.get("answer") is not None and sig.get("out") is not None else None)
            if not painted:      # the client's own account of how far it got
                fbsz = p.evaluate("() => { const r = window.__rfb, s = document.getElementById('screen'),"
                                  " c = s && s.querySelector('canvas'); return JSON.stringify({fb: r && [r._fbWidth, r._fbHeight],"
                                  " screen: s && [s.clientWidth, s.clientHeight], canvas: c && [c.width, c.height, c.style.width, c.style.height],"
                                  " scale: r && r.scaleViewport, resize: r && r.resizeSession}); }")
                (OUT / f"{name}-diag.txt").write_text(d + "\nsizes " + fbsz + "\n")
                p.screenshot(path=str(OUT / f"{name}-failed.png"))
            r["colours"] = colours
            ok(f"{name}: the client runs", running)
            ok(f"{name}: the desktop is painted (a window's title bar is on the screen)", painted,
               f"{colours}% workspace")
            if painted:
                ok(f"{name}: time to desktop <= {th['ttd']} s", r["ttd"] <= th["ttd"], f"{r['ttd']:.1f} s")
                # A VIDEO desktop is painted before the resize lands (its first frames are the old
                # size, scaled): drag where the title bar is once the desktop has its size.
                if follows(p, 8)[0]:
                    time.sleep(0.5)
                    p.screenshot(path=str(OUT / f"{name}.png"))
                    grab = title_bar(OUT / f"{name}.png")[0] or grab
                if os.environ.get("LINKCOND_AUDIO"):
                    audio_check(p, name)
                m = measure(p, grab); r.update(m)
                r["mode"] = p.evaluate("window.__deskMode && (window.__deskMode + (window.__deskAuto ? ' (auto)' : ''))")
                p.screenshot(path=str(OUT / f"{name}-after.png"))
                ok(f"{name}: drag steps answered", m["lat_n"] >= th.get("steps", 12), f"{m['lat_n']}/16")
                ok(f"{name}: input -> update median <= {th['lat']} ms", m["lat_med"] is not None
                   and m["lat_med"] <= th["lat"],
                   f"{m['lat_med']:.0f} ms (p90 {m['lat_p90']:.0f})" if m["lat_med"] is not None else "none")
                ok(f"{name}: >= {th['ups']} updates/s while dragging", m["ups"] >= th["ups"],
                   f"{m['ups']:.1f}/s, {m['kbs']:.0f} KB/s")
                if name == SCENARIOS[0][0]:
                    # THE DESKTOP IS THE SHAPE OF THE WINDOW LOOKING AT IT: the card starts at
                    # 640x480, noVNC asks (SetDesktopSize) for the size of #screen, and glass's WM
                    # resizes.  Then a phone-shaped window, and the desktop follows that too.
                    good, v = follows(p, 8)
                    ok(f"{name}: the desktop became the window's size (SetDesktopSize)", good,
                       v and f"desktop {v[0]}x{v[1]}, window {v[2]}x{v[3]}")
                    p.set_viewport_size({"width": 390, "height": 700})
                    good, v = follows(p, 10)
                    ok(f"{name}: ...and followed a phone-shaped window", good,
                       v and f"desktop {v[0]}x{v[1]}, window {v[2]}x{v[3]}")
                    p.screenshot(path=str(OUT / f"{name}-phone.png"))
                    if os.environ.get("LINKCOND_WARP"):
                        warp_check(p, name)
                    # SHARP OR FUZZY, switched live -- only on a box that offers both (a video card).
                    if p.evaluate("window.__deskMode"):
                        click = ("(label) => { const b = [...document.querySelectorAll('button')]"
                                 ".find(b => b.textContent === label); if (b) b.click(); return !!b; }")
                        def settle(mode, wait=8):
                            t1 = time.time()
                            while time.time() - t1 < wait:
                                if p.evaluate("window.__deskMode") == mode: return True
                                time.sleep(0.25)
                            return False
                        p.evaluate(FBU)
                        u0 = p.evaluate(FBU)
                        p.evaluate(click, "sharp · rfb")
                        good = settle("rfb"); time.sleep(2.5)            # the Clock ticks: RFB frames
                        u1 = p.evaluate(FBU)
                        hidden = p.evaluate("getComputedStyle(window.__vidEl).visibility") == "hidden"
                        ok(f"{name}: switched live to RFB -- video hidden, glass's frames arriving",
                           good and hidden and u1 > u0, f"mode {p.evaluate('window.__deskMode')}, "
                           f"video {'hidden' if hidden else 'SHOWN'}, {u1 - u0} RFB updates")
                        p.screenshot(path=str(OUT / f"{name}-rfb.png"))
                        f0 = p.evaluate(VFRAMES)
                        p.evaluate(click, "fuzzy · video")
                        good = settle("video"); time.sleep(2.5)
                        f1 = p.evaluate(VFRAMES)
                        ok(f"{name}: ...and back to video, frames presented again",
                           good and f1 is not None and f1 > (f0 or 0),
                           f"mode {p.evaluate('window.__deskMode')}, {(f1 or 0) - (f0 or 0)} video frames")
                        p.evaluate(click, "auto")                       # hand the choice back
            results[name] = r
            ctx.close()
        browser.close()
finally:
    stop_card()
    turn.terminate()
    (OUT / "results.json").write_text(json.dumps(dict(impl=IMPL, results=results), indent=1))

print(f"\n{'scenario':<8} {'desktop':>8} {'answer':>8} {'median':>8} {'p90':>8} {'upd/s':>7} {'KB/s':>6} {'fbu/s':>6} {'KB/fbu':>7}")
for name, r in results.items():
    f = lambda v, fmt: (fmt % v) if v is not None else "-"
    print(f"{name:<8} {f(r.get('ttd'), '%6.1f s'):>8} {f(r.get('answer'), '%6.1f s'):>8} {f(r.get('lat_med'), '%5.0f ms'):>8} "
          f"{f(r.get('lat_p90'), '%5.0f ms'):>8} {f(r.get('ups'), '%5.1f'):>7} {f(r.get('kbs'), '%4.0f'):>6}"
          f" {f(r.get('fbu'), '%5.1f'):>6} {f(r.get('kb_per_fbu'), '%6.1f'):>7}  resize asks {r.get('resize_asks')}"
          f"{'  mode ' + r['mode'] if r.get('mode') else ''}"
          f"{'  video' if r.get('video') else ''}")
print(f"\nLINKCOND {IMPL}: {'PASS' if not fails else 'FAIL (' + str(len(fails)) + ')'}", flush=True)
sys.exit(1 if fails else 0)
