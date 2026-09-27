import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        try:
            payload = json.loads(body)
            print("\n=== ALERTMANAGER EVENT ===", flush=True)
            print(json.dumps(payload, indent=2), flush=True)
        except json.JSONDecodeError:
            print("\n=== INVALID PAYLOAD ===", flush=True)
            print(body.decode(errors="replace"), flush=True)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def log_message(self, format, *args):
        pass


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
