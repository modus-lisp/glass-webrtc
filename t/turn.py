# t/turn.py -- a small local TURN server (RFC 5766: Allocate, Refresh, CreatePermission,
# ChannelBind, Send/Data indications, ChannelData) that SHAPES what it relays: delay, jitter,
# loss and a bandwidth cap, so a card and a headless browser can be measured over a
# phone-like relayed path on one machine (t/linkcond.py).
#
#   python3 t/turn.py PORT USER PASS [SHAPE-FILE]
#
# SHAPE-FILE is JSON, {"delay_ms": 50, "jitter_ms": 5, "loss": 0.02, "kbps": 0}, re-read whenever
# it changes, so one run can step a live session through several link conditions.  Delay is
# EACH WAY and per relayed hop; kbps is a per-direction serialisation rate (0 = none), so a
# backlog shows up as queueing delay, as it does on a real narrow link.  Credentials are the
# long-term kind, realm "e2e"; permissions are not enforced.  127.0.0.1 only.
import hashlib, heapq, json, os, random, socket, struct, sys, threading, time
from aioice import stun
stun.ATTRIBUTES.append((0x0013, "DATA", stun.pack_bytes, stun.unpack_bytes))
for a in stun.ATTRIBUTES:
    stun.ATTRIBUTES_BY_TYPE[a[0]] = a; stun.ATTRIBUTES_BY_NAME[a[1]] = a

PORT, USER, PASS = int(sys.argv[1]), sys.argv[2], sys.argv[3]
SHAPE_FILE = sys.argv[4] if len(sys.argv) > 4 else None
REALM, NONCE = "e2e", b"e2e-nonce"
KEY = hashlib.md5(f"{USER}:{REALM}:{PASS}".encode()).digest()
DELAY, JITTER, LOSS, KBPS = 0.0, 0.0, 0.0, 0.0
def load_shape():
    global DELAY, JITTER, LOSS, KBPS
    try: sh = json.load(open(SHAPE_FILE)) if SHAPE_FILE else {}
    except (OSError, ValueError): return
    DELAY = float(sh.get("delay_ms", 0)) / 1000
    JITTER = float(sh.get("jitter_ms", 0)) / 1000
    LOSS = float(sh.get("loss", 0))
    KBPS = float(sh.get("kbps", 0))
    print(f"turn: shape delay {DELAY*1000:.0f}+{JITTER*1000:.0f} ms each way, loss {LOSS:.1%}, "
          f"cap {KBPS or 'none'} kbit/s", flush=True)
def watch_shape():
    mt = None
    while SHAPE_FILE:
        try: m = os.stat(SHAPE_FILE).st_mtime_ns
        except OSError: m = None
        if m != mt: mt = m; load_shape()
        time.sleep(0.2)
load_shape()
threading.Thread(target=watch_shape, daemon=True).start()
STATS = {"relayed": 0, "dropped": 0, "bytes": 0, "allocs": 0}

class Shaper:
    """Delay, jitter, loss, and a per-direction serialisation rate, then sendto."""
    def __init__(self):
        self.q, self.cv = [], threading.Condition()
        self.free_at = {"up": 0.0, "down": 0.0}
        threading.Thread(target=self.run, daemon=True).start()
    def push(self, sock, data, addr, way):
        if random.random() < LOSS:
            STATS["dropped"] += 1; return
        now = time.time(); t = now
        if KBPS > 0:      # a link that drains KBPS: queueing delay grows with the backlog
            start = max(now, self.free_at[way])
            self.free_at[way] = start + len(data) * 8 / (KBPS * 1000)
            t = self.free_at[way]
        t += DELAY + random.uniform(0, JITTER)
        with self.cv:
            heapq.heappush(self.q, (t, random.random(), sock, data, addr)); self.cv.notify()
    def run(self):
        while True:
            with self.cv:
                while not self.q: self.cv.wait()
                t, _, sock, data, addr = self.q[0]; now = time.time()
                if t > now: self.cv.wait(t - now); continue
                heapq.heappop(self.q)
            try:
                sock.sendto(data, addr); STATS["relayed"] += 1; STATS["bytes"] += len(data)
            except OSError: pass
SHAPE = Shaper()

srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); srv.bind(("127.0.0.1", PORT))
allocs = {}        # client addr -> Alloc

class Alloc:
    def __init__(self, client):
        self.client = client
        self.relay = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.relay.bind(("127.0.0.1", 0))
        self.chan_of, self.peer_of = {}, {}      # peer addr <-> channel number
        STATS["allocs"] += 1
        threading.Thread(target=self.from_peers, daemon=True).start()
    def from_peers(self):
        while True:
            try: data, peer = self.relay.recvfrom(65536)
            except OSError: return
            ch = self.chan_of.get(peer)
            if ch is not None:
                pkt = struct.pack("!HH", ch, len(data)) + data
                pkt += bytes((4 - len(pkt) % 4) % 4)
            else:
                pkt = bytes(stun.Message(stun.Method.DATA, stun.Class.INDICATION,
                                         attributes={"XOR-PEER-ADDRESS": peer, "DATA": data}))
            SHAPE.push(srv, pkt, self.client, "down")

def reply(req, cls, attrs, addr, sign=True):
    m = stun.Message(req.message_method, cls, req.transaction_id, attrs)
    if sign: m.add_message_integrity(KEY)
    srv.sendto(bytes(m), addr)

def handle_stun(data, addr):
    try: req = stun.parse_message(data)
    except ValueError: return
    meth, cls = req.message_method, req.message_class
    if meth == stun.Method.BINDING and cls == stun.Class.REQUEST:
        return reply(req, stun.Class.RESPONSE, {"XOR-MAPPED-ADDRESS": addr}, addr, sign=False)
    if cls == stun.Class.INDICATION and meth == stun.Method.SEND:
        a = allocs.get(addr)
        if a and "XOR-PEER-ADDRESS" in req.attributes and "DATA" in req.attributes:
            SHAPE.push(a.relay, req.attributes["DATA"], req.attributes["XOR-PEER-ADDRESS"], "up")
        return
    if cls != stun.Class.REQUEST: return
    if "MESSAGE-INTEGRITY" not in req.attributes:
        return reply(req, stun.Class.ERROR, {"ERROR-CODE": (401, "Unauthorized"),
                                             "REALM": REALM, "NONCE": NONCE}, addr, sign=False)
    try: stun.parse_message(data, KEY)
    except ValueError:
        return reply(req, stun.Class.ERROR, {"ERROR-CODE": (401, "Unauthorized"),
                                             "REALM": REALM, "NONCE": NONCE}, addr, sign=False)
    if meth == stun.Method.ALLOCATE:
        a = allocs.get(addr) or Alloc(addr); allocs[addr] = a
        return reply(req, stun.Class.RESPONSE, {"XOR-RELAYED-ADDRESS": a.relay.getsockname(),
                                                "XOR-MAPPED-ADDRESS": addr, "LIFETIME": 600}, addr)
    if meth == stun.Method.REFRESH:
        if req.attributes.get("LIFETIME", 600) == 0 and addr in allocs:
            allocs.pop(addr).relay.close()
        return reply(req, stun.Class.RESPONSE, {"LIFETIME": req.attributes.get("LIFETIME", 600)}, addr)
    if meth == stun.Method.CREATE_PERMISSION:
        return reply(req, stun.Class.RESPONSE, {}, addr)
    if meth == stun.Method.CHANNEL_BIND:
        a = allocs.get(addr)
        if a:
            ch, peer = req.attributes["CHANNEL-NUMBER"], req.attributes["XOR-PEER-ADDRESS"]
            a.chan_of[peer] = ch; a.peer_of[ch] = peer
        return reply(req, stun.Class.RESPONSE, {}, addr)

print(f"turn on 127.0.0.1:{PORT}", flush=True)
while True:
    data, addr = srv.recvfrom(65536)
    if data and 0x40 <= data[0] <= 0x7F:             # ChannelData from a client
        a = allocs.get(addr)
        if a and len(data) >= 4:
            ch, n = struct.unpack("!HH", data[:4]); peer = a.peer_of.get(ch)
            if peer: SHAPE.push(a.relay, data[4:4 + n], peer, "up")
    else:
        handle_stun(data, addr)
