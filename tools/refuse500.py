import http.server
class H(http.server.BaseHTTPRequestHandler):
    def _r(self):
        self.send_response(500); self.send_header('Content-Length', '0'); self.end_headers()
        print('500 for', self.command, self.headers.get('Range'), flush=True)
    do_GET = do_HEAD = _r
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 18765), H).serve_forever()
