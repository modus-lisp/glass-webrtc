"""t/dial-e2e.py -- a real card, dialled from Lisp the way the phone dials it.  Nothing leaves the
machine: a local relay (store and forward, as t/linkcond.py's), a local TURN (t/turn.py), and a
hosted card (hosted-card/card.sh, one process: gateway + glass window manager) with a known box
key and a known OWNER, who is DM'd a login link when the card is ready.

    python3 t/dial-e2e.py LISP-TEST [LISP-TEST ...]

Each LISP-TEST is run with `sbcl --script' and this environment, and must exit 0:

    E2E_RELAY       ws://127.0.0.1:PORT
    E2E_BOX         the box's hex pubkey
    E2E_OWNER_SEC   the owner's secret (hex) -- a test key, local relay only
    E2E_TURN        host:port user pass  (the local TURN)
    E2E_OUT         a directory for screenshots and the dial credential store
    E2E_CARD_LOG    the card's log
    E2E_SETUP       (passed through) a Lisp file that sets up ASDF, loaded first if set

The card runs from MODUS_ROOT (default: this checkout's parent) -- the box as deployed, unchanged.
E2E_OUT defaults to /tmp/glass-dial-e2e.  E2E_HOLD=1 (development) starts everything, writes the
environment to E2E_OUT/env.sh and waits to be killed instead of running the tests.
"""
import json, os, pathlib, signal, socket, subprocess, sys, threading, time
import websockets.sync.server as wss

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent
OUT = pathlib.Path(os.environ.get("E2E_OUT", "/tmp/glass-dial-e2e")).resolve()
OUT.mkdir(parents=True, exist_ok=True)

BOX_SEC   = "11" * 32                       # test keys: never on a public relay
OWNER_SEC = "33" * 32
OWNER_PUB = "3c72addb4fdf09af94f0c94d7fe92a386a7e70cf8a1d85916386bb2535c7b1b1"   # of OWNER_SEC
BOX_PUB   = "4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa"   # of BOX_SEC

def freeport():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def freeport_pair():
    while True:
        p = freeport()
        try:
            s = socket.socket(); s.bind(("127.0.0.1", p + 1)); s.close(); return p
        except OSError:
            continue

# ---- the relay: store and forward (t/linkcond.py's) ----------------------------------------------
EVENTS, LIVE, RLOCK = [], [], threading.Lock()

def matches(ev, f):
    if "kinds" in f and ev["kind"] not in f["kinds"]: return False
    if "authors" in f and ev["pubkey"] not in f["authors"]: return False
    for k, v in f.items():
        if k.startswith("#"):
            vals = {t[1] for t in ev.get("tags", []) if len(t) > 1 and t[0] == k[1:]}
            if not (set(v) & vals): return False
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
                for e in hist: conn.send(json.dumps(["EVENT", sid, e]))
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

WS_PORT, TURN_PORT, DESK_PORT = freeport(), freeport(), freeport_pair()
RELAY = f"ws://127.0.0.1:{WS_PORT}"
TURN_USER, TURN_PASS = "dial-e2e", "dial-e2e-pass"
wsd = wss.serve(relay_conn, "127.0.0.1", WS_PORT)
threading.Thread(target=wsd.serve_forever, daemon=True).start()
turn = subprocess.Popen([sys.executable, str(HERE / "turn.py"), str(TURN_PORT), TURN_USER, TURN_PASS],
                        stdout=open(OUT / "turn.log", "w"), stderr=subprocess.STDOUT)

card_dir = OUT / "card"; card_dir.mkdir(exist_ok=True)
(card_dir / "turn.config").write_text(f'TURN_ICE="turn:127.0.0.1:{TURN_PORT} {TURN_USER} {TURN_PASS}"\n')
nsec = card_dir / "box.nsec"; nsec.write_text(BOX_SEC); nsec.chmod(0o600)
card_pids = []

def start_card():
    ql = os.path.expanduser("~/quicklisp/dists/quicklisp/software")
    env = dict(os.environ, OWNER=OWNER_PUB, CARD_ONE_PROCESS="1", CARD_DIR=str(card_dir),
               CARD_CONFIG=str(card_dir / "turn.config"), CARD_NSEC_FILE=str(nsec),
               CARD_LOGIN_TTL="3600", NOSTR_RELAYS=RELAY, LOGIN_URL_BASE="http://127.0.0.1:1/",
               MODUS_ROOT=os.environ.get("MODUS_ROOT", str(SRC.parent)),
               QUICKLISP_SOFTWARE=os.environ.get("QUICKLISP_SOFTWARE", ql))
    t0 = time.time()
    r = subprocess.run([str(SRC / "hosted-card" / "card.sh"), "e2e", "sbcl", str(DESK_PORT)], env=env,
                       cwd=str(card_dir), capture_output=True, text=True, timeout=900)
    pids = card_dir / "e2e.pids"
    if pids.exists(): card_pids.extend(int(x) for x in set(pids.read_text().split()))
    print(f"card on 127.0.0.1:{DESK_PORT}: {(r.stdout.strip() or r.stderr.strip())[-300:]}  [{time.time() - t0:.0f} s]",
          flush=True)
    return r.returncode == 0

rc = 1
try:
    print(f"== dial-e2e: relay {RELAY} · turn 127.0.0.1:{TURN_PORT} · box {BOX_PUB[:8]}… ==", flush=True)
    if start_card():
        env = dict(os.environ, E2E_RELAY=RELAY, E2E_BOX=BOX_PUB, E2E_OWNER_SEC=OWNER_SEC,
                   E2E_TURN=f"127.0.0.1:{TURN_PORT} {TURN_USER} {TURN_PASS}", E2E_OUT=str(OUT),
                   E2E_CARD_LOG=str(card_dir / "gw-e2e.log"))
        rc = 0
        if os.environ.get("E2E_HOLD"):        # development: keep everything up, say how to reach it
            (OUT / "env.sh").write_text("".join(f"export {k}='{v}'\n" for k, v in env.items()
                                                if k.startswith("E2E_")))
            print(f"holding: source {OUT / 'env.sh'}; kill {os.getpid()} to stop", flush=True)
            signal.signal(signal.SIGTERM, lambda *a: (_ for _ in ()).throw(KeyboardInterrupt()))
            try:
                while True: time.sleep(3600)
            except KeyboardInterrupt:
                pass
        for test in sys.argv[1:]:
            print(f"\n== {test} ==", flush=True)
            r = subprocess.run(["sbcl", "--dynamic-space-size", "4096", "--script", test], env=env, timeout=1200)
            if r.returncode != 0: rc = 1
finally:
    for pid in card_pids:
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    turn.terminate()
print(f"\nDIAL-E2E: {'PASS' if rc == 0 else 'FAIL'}", flush=True)
sys.exit(rc)
