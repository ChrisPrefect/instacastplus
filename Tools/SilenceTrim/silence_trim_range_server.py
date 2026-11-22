#!/usr/bin/env python3
"""Local HTTP server with Range support and an adjustable throttle, for stream tests of the
silence trim engine (silence_trim_glitch_probe with SILENCE_TRIM_HTTP).

    python3 Tools/SilenceTrim/silence_trim_range_server.py --port 8765 --root <dir> [--root <dir>]

GET /<file name> serves the first root that has that file; GET /control?rate=<bytes per second>
sets the throttle for all transfers at once (0 = unthrottled).
"""
import argparse
import http.server
import os
import re
import socketserver
import sys
import time
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--root', action='append', required=True)
args = parser.parse_args()
state = {'rate': 0.0}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve(head=True)

    def do_GET(self):
        self.serve()

    def serve(self, head=False):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/control':
            rate = urllib.parse.parse_qs(parsed.query).get('rate', ['0'])[0]
            state['rate'] = float(rate)
            self.send_response(204)
            self.end_headers()
            return
        name = os.path.basename(parsed.path)
        path = next((os.path.join(root, name) for root in args.root if os.path.isfile(os.path.join(root, name))), None)
        if not path:
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start, end = 0, size - 1
        match = re.match(r'bytes=(\d*)-(\d*)', self.headers.get('Range', ''))
        if match:
            if match.group(1):
                start = int(match.group(1))
            if match.group(2):
                end = min(int(match.group(2)), size - 1)
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        else:
            self.send_response(200)
        self.send_header('Content-Type', 'audio/mpeg')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        if head:
            return
        with open(path, 'rb') as source:
            source.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    piece = source.read(min(16384, left))
                    if not piece:
                        break
                    self.wfile.write(piece)
                    left -= len(piece)
                    if state['rate'] > 0:
                        time.sleep(len(piece) / state['rate'])
            except (BrokenPipeError, ConnectionResetError):
                pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


print(f'serving on {args.port}', flush=True)
Server(('127.0.0.1', args.port), Handler).serve_forever()
