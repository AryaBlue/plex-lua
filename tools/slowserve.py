# A deliberately bad local file server for `lovec . --shots stall`: serves
# %TEMP%/plexsub/mf/long.mp4 at http://127.0.0.1:18766/long.mp4 (with Range
# support), sending a little at a time and stopping for 1.5 s after every
# 400 KB, like a congested network.
import http.server, os, re, socketserver, time

PATH = os.path.join(os.environ["TEMP"], "plexsub", "mf", "long.mp4")
CHUNK = 64 * 1024
PAUSE_EVERY = 400 * 1024


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        size = os.path.getsize(PATH)
        start, end = 0, size - 1
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
        if m:
            if m.group(1): start = int(m.group(1))
            if m.group(2): end = min(int(m.group(2)), size - 1)
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        else:
            self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        sent = 0
        with open(PATH, "rb") as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    data = f.read(min(CHUNK, left))
                    self.wfile.write(data)
                    left -= len(data)
                    sent += len(data)
                    if sent >= PAUSE_EVERY:
                        sent = 0
                        time.sleep(1.5)
            except (ConnectionError, OSError):
                pass

    def log_message(self, *a):
        pass


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


S(("127.0.0.1", 18766), H).serve_forever()
