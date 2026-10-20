"""Stand-in cast devices on this PC, for `lovec . --casttest` (nothing reaches a real TV).

  Chromecast  TLS Cast v2 on 127.0.0.1:18009. Answers CONNECT/PING/GET_STATUS, LAUNCH of an
              app id (then lists it with a transport), and on that transport the media
              namespace: LOAD (checked and logged), PLAY, PAUSE, SEEK, GET_STATUS. Receiver STOP
              closes the app.
  mDNS        UDP 127.0.0.1:15353: any query gets a _googlecast._tcp answer for that device.
  DIAL        SSDP on UDP 127.0.0.1:11900 answers with two devices' descriptions over HTTP:
              "Fake FireTVStick" (127.0.0.1:18080) and "Blocked FireTVStick" (127.0.0.1:18081,
              which Reel must never launch anything on). Both have com.plexapp.android.
  ADB         TCP 127.0.0.1:15555, the first stick's remote control. Signs Reel in the way adbd does:
              a token, then (unknown key) the public key, which it checks and "allows" after 0.5 s;
              a key it knows must sign the token correctly. Shell: `dumpsys media_session` (Plex's
              session, which starts 1.5 s after Plex is opened over DIAL: "Pilot" from 0:00),
              `cat /proc/uptime`, and `input keyevent` (play, pause, skip 30 s / back 10 s, stop).

Every request is appended to fakecast.log (JSON lines) next to this script, which the test reads.
Run: python tools/fakecast.py   (needs openssl on PATH the first time, for the certificate)
"""
import base64, hashlib, json, os, socket, ssl, struct, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "fakecast.log")
CERT = os.path.join(HERE, "fakecast-cert.pem")
KEY = os.path.join(HERE, "fakecast-key.pem")
CAST_PORT, MDNS_PORT, SSDP_PORT, ADB_PORT = 18009, 15353, 11900, 15555
DIAL_DEVICES = [("Fake FireTVStick", 18080, "uuid:fake-stick-1"), ("Blocked FireTVStick", 18081, "uuid:fake-stick-2")]

log_lock = threading.Lock()


def log(kind, **data):
    data["kind"] = kind
    data["t"] = round(time.time(), 3)
    with log_lock, open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(data) + "\n")
    print(kind, json.dumps(data)[:300], flush=True)


# --- Cast v2 framing -------------------------------------------------------

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(num, s):
    s = s.encode() if isinstance(s, str) else s
    return varint(num << 3 | 2) + varint(len(s)) + s


def encode(src, dst, ns, payload):
    body = b"\x08\x00" + field(2, src) + field(3, dst) + field(4, ns) + b"\x28\x00" + field(6, json.dumps(payload))
    return struct.pack(">I", len(body)) + body


def read_varint(b, i):
    n = shift = 0
    while True:
        c = b[i]
        i += 1
        n |= (c & 0x7F) << shift
        if c < 0x80:
            return n, i
        shift += 7


def decode(body):
    msg, i = {}, 0
    while i < len(body):
        key, i = read_varint(body, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            _, i = read_varint(body, i)
        elif wire == 2:
            ln, i = read_varint(body, i)
            v = body[i:i + ln]
            i += ln
            msg[{2: "source", 3: "dest", 4: "ns", 6: "payload"}.get(num, num)] = v.decode("utf-8", "replace")
    return msg


class CastClient(threading.Thread):
    APP_TRANSPORT = "web-7"

    def __init__(self, conn):
        super().__init__(daemon=True)
        self.c = conn
        self.app = None              # (appId, sessionId) when launched
        self.media = None            # dict once loaded
        self.lock = threading.Lock()

    def send(self, src, dst, ns, payload):
        with self.lock:
            self.c.sendall(encode(src, dst, ns, payload))

    def receiver_status(self, dst, rid=0):
        apps = []
        if self.app:
            apps = [{"appId": self.app[0], "sessionId": self.app[1], "transportId": self.APP_TRANSPORT,
                     "displayName": "Plex", "namespaces": [{"name": "urn:x-cast:com.google.cast.media"},
                                                           {"name": "urn:x-cast:plex"}]}]
        self.send("receiver-0", dst, "urn:x-cast:com.google.cast.receiver",
                  {"type": "RECEIVER_STATUS", "requestId": rid,
                   "status": {"applications": apps, "volume": {"level": 0.5, "muted": False}}})

    def media_status(self, dst, rid=0):
        m = self.media
        st = []
        if m:
            t = m["time"] + (time.time() - m["at"] if m["state"] == "PLAYING" else 0)
            st = [{"mediaSessionId": 1, "playerState": m["state"], "currentTime": round(t, 2),
                   "media": {"contentId": m["contentId"], "duration": 1800.0, "customData": {}}}]
        self.send(self.APP_TRANSPORT, dst, "urn:x-cast:com.google.cast.media",
                  {"type": "MEDIA_STATUS", "requestId": rid, "status": st})

    def handle(self, msg):
        ns, src, dst = msg.get("ns"), msg.get("source"), msg.get("dest")
        p = json.loads(msg.get("payload") or "{}")
        t, rid = p.get("type"), p.get("requestId", 0)
        if t not in ("PING", "PONG"):
            log("cast", ns=ns, src=src, dst=dst, payload=p)
        if ns.endswith("tp.heartbeat"):
            if t == "PING":
                self.send(dst, src, ns, {"type": "PONG"})
        elif ns.endswith("cast.receiver"):
            if t == "GET_STATUS":
                self.receiver_status(src, rid)
            elif t == "LAUNCH":
                self.app = (p["appId"], "session-1")
                self.receiver_status(src, rid)
            elif t == "STOP":
                self.app, self.media = None, None
                self.receiver_status(src, rid)
            elif t == "SET_VOLUME":
                self.receiver_status(src, rid)
        elif ns.endswith("cast.media") and dst == self.APP_TRANSPORT:
            if t == "LOAD":
                m = p.get("media", {})
                self.media = {"contentId": m.get("contentId"), "state": "PLAYING",
                              "time": float(p.get("currentTime") or 0), "at": time.time()}
                self.media_status(src, rid)
            elif t in ("PLAY", "PAUSE") and self.media:
                m = self.media
                m["time"] += (time.time() - m["at"]) if m["state"] == "PLAYING" else 0
                m["at"], m["state"] = time.time(), "PLAYING" if t == "PLAY" else "PAUSED"
                self.media_status(src, rid)
            elif t == "SEEK" and self.media:
                self.media["time"], self.media["at"] = float(p.get("currentTime", 0)), time.time()
                self.media_status(src, rid)
            elif t == "GET_STATUS":
                self.media_status(src, rid)

    def run(self):
        buf = b""
        try:
            while True:
                d = self.c.recv(65536)
                if not d:
                    break
                buf += d
                while len(buf) >= 4:
                    n = struct.unpack(">I", buf[:4])[0]
                    if len(buf) < 4 + n:
                        break
                    self.handle(decode(buf[4:4 + n]))
                    buf = buf[4 + n:]
        except (ConnectionError, ssl.SSLError, OSError) as e:
            log("cast-disconnect", err=str(e))
        log("cast-closed")


def cast_server():
    if not os.path.exists(CERT):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", KEY, "-out", CERT,
                        "-days", "365", "-subj", "/CN=Fake Chromecast"], check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", CAST_PORT))
    srv.listen(4)
    while True:
        raw, _ = srv.accept()
        try:
            CastClient(ctx.wrap_socket(raw, server_side=True)).start()
            log("cast-connected")
        except ssl.SSLError as e:
            log("cast-tls-error", err=str(e))


# --- mDNS ------------------------------------------------------------------

def name(n):
    return b"".join(bytes([len(p)]) + p.encode() for p in n.split(".")) + b"\x00"


def rr(nm, rtype, rdata, ttl=120):
    return name(nm) + struct.pack(">HHIH", rtype, 0x8001, ttl, len(rdata)) + rdata


def mdns_server():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", MDNS_PORT))
    inst = "Chromecast-fake123._googlecast._tcp.local"
    txt = b"".join(bytes([len(x)]) + x for x in [b"id=fake123", b"md=Chromecast", b"fn=Fake Living Room TV"])
    pkt = (struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 3)
           + rr("_googlecast._tcp.local", 12, name(inst))
           + rr(inst, 33, struct.pack(">HHH", 0, 0, CAST_PORT) + name("fake123.local"))
           + rr(inst, 16, txt)
           + rr("fake123.local", 1, socket.inet_aton("127.0.0.1")))
    while True:
        q, addr = s.recvfrom(9000)
        log("mdns-query", src=addr[0])
        s.sendto(pkt, addr)


# --- DIAL ------------------------------------------------------------------

def ssdp_server():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", SSDP_PORT))
    while True:
        q, addr = s.recvfrom(9000)
        log("ssdp-search", src=addr[0], st=("dial" if b"dial" in q else "other"))
        for nm, port, uuid in DIAL_DEVICES:
            s.sendto(("HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:%d/dd.xml\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n"
                      "USN: %s::urn:dial-multiscreen-org:service:dial:1\r\n\r\n" % (port, uuid)).encode(), addr)


def dial_handler(dev_name, port, uuid):
    state = {"plex": "stopped"}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, code, body=b"", headers=()):
            self.send_response(code)
            for k, v in headers:
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            log("dial-get", device=dev_name, path=self.path)
            if self.path == "/dd.xml":
                body = ("<?xml version=\"1.0\"?><root><device><friendlyName>%s</friendlyName><manufacturer>Amazon</manufacturer>"
                        "<modelName>AFTSS</modelName><UDN>%s</UDN></device></root>" % (dev_name.replace("'", "&apos;"), uuid))
                self.reply(200, body.encode(), [("Application-URL", "http://127.0.0.1:%d/apps/" % port)])
            elif self.path == "/apps/com.plexapp.android":
                body = ("<?xml version=\"1.0\"?><service xmlns=\"urn:dial-multiscreen-org:schemas:dial\"><name>com.plexapp.android</name>"
                        "<state>%s</state></service>" % state["plex"])
                self.reply(200, body.encode())
            else:
                self.reply(404)

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
            log("dial-launch", device=dev_name, path=self.path, body=body)
            if self.path == "/apps/com.plexapp.android":
                state["plex"] = "running"
                if port == DIAL_DEVICES[0][1]:
                    tv.opened()
                self.reply(201, headers=[("Location", "http://127.0.0.1:%d/apps/com.plexapp.android/run" % port)])
            else:
                self.reply(404)
    return H


# --- ADB (Fire TV remote) ---------------------------------------------------

A_CNXN, A_AUTH, A_OPEN, A_OKAY, A_CLSE, A_WRTE = 0x4e584e43, 0x48545541, 0x4e45504f, 0x59414b4f, 0x45534c43, 0x45545257
SHA1_PREFIX = bytes.fromhex("3021300906052b0e03021a05000414")


def uptime_ms():
    return int(time.monotonic() * 1000)


class FakeTV:
    """Plex's media session on the stick."""

    def __init__(self):
        self.lock = threading.Lock()
        self.session = None          # {state, pos, updated} (pos in ms at `updated`)

    def opened(self):
        with self.lock:
            self.session = None
        def start():
            time.sleep(1.5)
            with self.lock:
                self.session = {"state": 3, "pos": 0, "updated": uptime_ms()}
            log("tv-playing", title="Pilot")
        threading.Thread(target=start, daemon=True).start()

    def now(self):
        st = self.session
        return st["pos"] + (uptime_ms() - st["updated"] if st["state"] == 3 else 0)

    def key(self, code):
        with self.lock:
            st = self.session
            if not st:
                return
            pos = self.now()
            if code == 126: st["state"] = 3
            elif code == 127: st["state"] = 2
            elif code == 90: pos += 30000
            elif code == 89: pos = max(0, pos - 10000)
            elif code == 86: self.session = None; return
            st["pos"], st["updated"] = pos, uptime_ms()

    def dumpsys(self):
        out = ["MEDIA SESSION SERVICE (dumpsys media_session)", "", "  Sessions Stack - have 2 sessions:",
               "    LauncherSession com.amazon.tv.launcher/LauncherSession (userId=0)",
               "      ownerPid=900, ownerUid=1000, userId=0",
               "      package=com.amazon.tv.launcher",
               "      active=false",
               "      state=PlaybackState {state=3, position=999000, buffered position=0, speed=1.0, updated=1, actions=0, custom actions=[], active item id=-1, error=null}",
               "      metadata:size=0, description=null"]
        with self.lock:
            st = self.session
            if st:
                out += ["    PlexMediaSession com.plexapp.android/PlexMediaSession (userId=0)",
                        "      ownerPid=4242, ownerUid=10071, userId=0",
                        "      package=com.plexapp.android",
                        "      launchIntent=null",
                        "      active=true",
                        "      state=PlaybackState {state=%d, position=%d, buffered position=0, speed=1.0, updated=%d, "
                        "actions=823, custom actions=[], active item id=-1, error=null}" % (st["state"], st["pos"], st["updated"]),
                        "      volumeType=1, controlType=2, max=0, current=0",
                        "      metadata:size=7, description=Pilot, Fake Show, null",
                        "      queueTitle=null, size=0"]
        return "\n".join(out) + "\n"


tv = FakeTV()
adb_keys = set()


def adb_packet(cmd, a0, a1, data=b""):
    return struct.pack("<6I", cmd, a0, a1, len(data), sum(data) & 0xFFFFFFFF, cmd ^ 0xFFFFFFFF) + data


def parse_adb_key(data):
    """Android's RSAPublicKey (base64) -> (n, e, problems)."""
    b64 = data.rstrip(b"\0").split(b" ")[0]
    raw = base64.b64decode(b64)
    words, n0inv = struct.unpack_from("<II", raw)
    n = int.from_bytes(raw[8:8 + 256], "little")
    rr = int.from_bytes(raw[264:264 + 256], "little")
    (e,) = struct.unpack_from("<I", raw, 520)
    problems = []
    if len(raw) != 524 or words != 64: problems.append("size")
    if (n0inv * n) % (1 << 32) != (1 << 32) - 1: problems.append("n0inv")
    if rr != pow(2, 4096, n): problems.append("rr")
    if e != 65537: problems.append("exponent %d" % e)
    return n, e, problems


def adb_verify(n, e, token, sig):
    m = pow(int.from_bytes(sig, "big"), e, n).to_bytes(256, "big")
    digest = SHA1_PREFIX + token
    return m == b"\x00\x01" + b"\xff" * (256 - 3 - len(digest)) + b"\x00" + digest


def adb_client(c):
    buf = b""
    def read():
        nonlocal buf
        while len(buf) < 24:
            d = c.recv(65536)
            if not d: raise ConnectionError("closed")
            buf += d
        cmd, a0, a1, ln, _, _ = struct.unpack_from("<6I", buf)
        while len(buf) < 24 + ln:
            d = c.recv(65536)
            if not d: raise ConnectionError("closed")
            buf += d
        data = buf[24:24 + ln]
        buf = buf[24 + ln:]
        return cmd, a0, a1, data
    send_lock = threading.Lock()
    def send(*a):
        with send_lock:
            c.sendall(adb_packet(*a))
    banner = b"device::ro.product.name=sheldon;ro.product.model=AFTSS;ro.product.device=sheldon;\0"
    token = os.urandom(20)
    next_id = [100]
    try:
        cmd, a0, a1, data = read()
        assert cmd == A_CNXN, "first message must be CNXN"
        log("adb-connect", version=a0, maxdata=a1, banner=data.decode("latin1"))
        send(A_AUTH, 1, 0, token)
        while True:
            cmd, a0, a1, data = read()
            if cmd == A_AUTH and a0 == 2:
                ok = any(adb_verify(n, e, token, data) for n, e in adb_keys)
                log("adb-auth-signature", ok=ok)
                if ok:
                    send(A_CNXN, 0x01000000, 4096, banner)
                    break
                token = os.urandom(20)
                send(A_AUTH, 1, 0, token)
            elif cmd == A_AUTH and a0 == 3:
                n, e, problems = parse_adb_key(data)
                log("adb-key", ok=not problems, problems=problems, name=data.rstrip(b"\0").split(b" ", 1)[-1].decode())
                if problems:
                    return
                time.sleep(0.5)            # the viewer presses Allow
                adb_keys.add((n, e))
                send(A_CNXN, 0x01000000, 4096, banner)
                break
        streams = {}
        while True:
            cmd, a0, a1, data = read()
            if cmd == A_OPEN:
                local = next_id[0]; next_id[0] += 1
                shell = data.rstrip(b"\0").decode()
                assert shell.startswith("shell:")
                shell = shell[6:]
                send(A_OKAY, local, a0)
                out = ""
                if shell.startswith("dumpsys media_session"):
                    out = tv.dumpsys() + "@@UPTIME\n%.2f 1234.00\n" % (uptime_ms() / 1000)
                elif shell.startswith("input keyevent"):
                    codes = [int(x) for x in shell.split()[2:]]
                    log("adb-key-event", codes=codes)
                    for k in codes:
                        tv.key(k)
                else:
                    log("adb-shell", cmd=shell)
                if out:
                    send(A_WRTE, local, a0, out.encode())
                    streams[local] = a0
                else:
                    send(A_CLSE, local, a0)
            elif cmd == A_OKAY and a1 in streams:
                send(A_CLSE, a1, streams.pop(a1))
    except (ConnectionError, OSError, AssertionError) as e:
        log("adb-closed", err=str(e))
    finally:
        c.close()


def adb_server():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", ADB_PORT))
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=adb_client, args=(conn,), daemon=True).start()


def main():
    if os.path.exists(LOG):
        os.remove(LOG)
    for fn in (cast_server, mdns_server, ssdp_server, adb_server):
        threading.Thread(target=fn, daemon=True).start()
    for nm, port, uuid in DIAL_DEVICES:
        srv = ThreadingHTTPServer(("127.0.0.1", port), dial_handler(nm, port, uuid))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    print("fake cast devices ready", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
