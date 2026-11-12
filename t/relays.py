"""t/relays.py -- which public relays actually carry a sign-in, and how fast.

A sign-in is two gift wraps (NIP-59, kind 1059): the offer to the box and its answer back, each
one relay hop.  A relay that drops them, or sits on them, is invisible from the page -- the
client just waits -- so this measures it directly.  Per relay, ROUNDS times: one connection
subscribes to a random #p, a second publishes a throwaway signed kind-1059 to it, and the OK and
the delivery are timed.  Random keys, random content: nothing real is sent.

    python3 t/relays.py [RELAY...]          (default: the relays named below)

Environment: RELAYS_ROUNDS (5), RELAYS_MAX_S (1.0: the median delivery a relay must beat to
count), RELAYS_NEED (2: how many of the GIVEN relays must count, so a list with a backup passes
and one carried by a single relay fails).  Exit 0 = PASS.

Measured 2026-11-11, which is why this exists: nos.lol and nostr.mom never acknowledged a gift
wrap; relay.damus.io answered HTTP 503; relay.primal.net took 3.7-9.8 s; offchain.pub accepts
only keys it knows (the probe passes, a real sign-in is refused: run t/linkcond.py with
LINKCOND_RELAYS to be sure of a list); relay.snort.social and nostr.oxtr.dev took ~0.2 s.
"""
import asyncio, hashlib, json, os, statistics, sys, time
import websockets

DEFAULT = ["wss://relay.snort.social", "wss://nostr.oxtr.dev", "wss://relay.primal.net",
           "wss://nos.lol", "wss://relay.damus.io"]
ROUNDS = int(os.environ.get("RELAYS_ROUNDS", "5"))
MAX_S = float(os.environ.get("RELAYS_MAX_S", "1.0"))
NEED = int(os.environ.get("RELAYS_NEED", "2"))

# ---- BIP-340, enough to sign one event --------------------------------------------------------------
P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)

def add(a, b):
    if a is None: return b
    if b is None: return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0: return None
    l = ((3 * a[0] * a[0]) * pow(2 * a[1], -1, P) if a == b
         else (b[1] - a[1]) * pow(b[0] - a[0], -1, P)) % P
    x = (l * l - a[0] - b[0]) % P
    return (x, (l * (a[0] - x) - a[1]) % P)

def mul(k, p):
    r = None
    while k:
        if k & 1: r = add(r, p)
        p = add(p, p); k >>= 1
    return r

def tagged(tag, m):
    t = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(t + t + m).digest()

def sign(sk, msg):
    pt = mul(sk, G); d = sk if pt[1] % 2 == 0 else N - sk
    b32 = lambda i: i.to_bytes(32, "big")
    aux = tagged("BIP0340/aux", os.urandom(32))
    k0 = int.from_bytes(tagged("BIP0340/nonce", bytes(x ^ y for x, y in zip(b32(d), aux))
                               + b32(pt[0]) + msg), "big") % N
    r = mul(k0, G); k = k0 if r[1] % 2 == 0 else N - k0
    e = int.from_bytes(tagged("BIP0340/challenge", b32(r[0]) + b32(pt[0]) + msg), "big") % N
    return (b32(r[0]) + b32((k + e * d) % N)).hex()

def gift_wrap(p_tag):
    """A kind-1059 shaped like a real one: a throwaway key, backdated, ~1 KB of opaque content."""
    sk = int.from_bytes(os.urandom(32), "big") % N
    ev = {"pubkey": format(mul(sk, G)[0], "064x"),
          "created_at": int(time.time()) - int.from_bytes(os.urandom(2), "big") % 3600,
          "kind": 1059, "tags": [["p", p_tag]], "content": os.urandom(600).hex()}
    ev["id"] = hashlib.sha256(json.dumps([0, ev["pubkey"], ev["created_at"], 1059, ev["tags"],
                                          ev["content"]], separators=(",", ":")).encode()).hexdigest()
    ev["sig"] = sign(sk, bytes.fromhex(ev["id"]))
    return ev

# ---- one round -------------------------------------------------------------------------------------
async def one_round(url):
    """(ok_s or None, delivered_s or None, note)"""
    p_tag = os.urandom(32).hex()
    try:
        async with websockets.connect(url, open_timeout=6) as sub, \
                   websockets.connect(url, open_timeout=6) as pub:
            await sub.send(json.dumps(["REQ", "s", {"kinds": [1059], "#p": [p_tag],
                                                    "since": int(time.time()) - 7200}]))
            while True:
                m = json.loads(await asyncio.wait_for(sub.recv(), 6))
                if m[0] == "CLOSED": return (None, None, "subscription refused: " + str(m[2])[:40])
                if m[0] == "EOSE": break
            ev = gift_wrap(p_tag); t0 = time.time()
            await pub.send(json.dumps(["EVENT", ev]))
            res = {"ok": None, "got": None, "note": ""}
            async def wait_ok():
                async for raw in pub:
                    m = json.loads(raw)
                    if m[0] == "OK" and m[1] == ev["id"]:
                        if m[2]: res["ok"] = time.time() - t0
                        else: res["note"] = "refused: " + str(m[3])[:40]
                        return
            async def wait_ev():
                async for raw in sub:
                    m = json.loads(raw)
                    if m[0] == "EVENT" and m[2].get("id") == ev["id"]:
                        res["got"] = time.time() - t0; return
            tasks = [asyncio.create_task(wait_ok()), asyncio.create_task(wait_ev())]
            await asyncio.wait(tasks, timeout=12)
            for t in tasks: t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            return (res["ok"], res["got"], res["note"] or ("" if res["ok"] else "no OK in 12 s"))
    except Exception as e:
        return (None, None, f"{type(e).__name__}: {str(e)[:40]}")

async def probe(url):
    out = []
    for _ in range(ROUNDS):
        out.append(await one_round(url))
        await asyncio.sleep(0.5)
    return url, out

async def main(relays):
    return await asyncio.gather(*(probe(u) for u in relays))

relays = sys.argv[1:] or DEFAULT
print(f"== relays: {ROUNDS} gift wraps each; a relay counts with median delivery <= {MAX_S:.1f} s ==",
      flush=True)
good = 0
print(f"{'relay':<30} {'OK':>8} {'delivered':>10}  {'rounds':>6}  note")
for url, out in asyncio.run(main(relays)):
    oks = [r[0] for r in out if r[0] is not None]
    gots = [r[1] for r in out if r[1] is not None]
    # a round that never delivered counts as forever: the median is over ALL rounds
    med = statistics.median([r[1] if r[1] is not None else float("inf") for r in out])
    counts = med <= MAX_S
    good += counts
    note = next((r[2] for r in out if r[2]), "")
    f = lambda v: f"{statistics.median(v):6.2f} s" if v else "      -"
    print(f"{url:<30} {f(oks):>8} {f(gots):>10}  {len(gots)}/{len(out):<4}  "
          f"{'ok  ' if counts else 'slow' if gots else 'dead'} {note}", flush=True)
print(f"\nRELAYS: {good} of {len(relays)} carry a gift wrap within {MAX_S:.1f} s (need {NEED}): "
      f"{'PASS' if good >= NEED else 'FAIL'}")
sys.exit(0 if good >= NEED else 1)
