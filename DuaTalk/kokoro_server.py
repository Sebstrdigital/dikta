#!/usr/bin/env python3
"""
Kokoro TTS Server - keeps model loaded in memory for fast responses.
Run with: python3.11 kokoro_server.py
"""

import http.server
import json
import socketserver
import tempfile
import os
import sys
import warnings

warnings.filterwarnings('ignore')

PORT = 59123  # Local-only port for TTS

# Pre-load the model at startup
print("Loading Kokoro model (this takes a few seconds)...")
from kokoro import KPipeline
import soundfile as sf
import numpy as np

pipe = KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')
print("Model loaded! Server ready.")


class TTSHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging

    def do_POST(self):
        if self.path == '/speak':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)

            try:
                data = json.loads(post_data.decode('utf-8'))
                text = data.get('text', '')
                voice = data.get('voice', 'af_heart')
                output_path = data.get('output_path', '')

                if not text or not output_path:
                    self.send_error(400, 'Missing text or output_path')
                    return

                # Generate audio
                all_audio = []
                for result in pipe(text, voice=voice):
                    all_audio.append(result.audio.numpy())

                combined = np.concatenate(all_audio)
                sf.write(output_path, combined, 24000)

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': True}).encode())

            except Exception as e:
                self.send_error(500, str(e))

        elif self.path == '/ping':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'pong')

        else:
            self.send_error(404)

    def do_GET(self):
        if self.path == '/ping':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'pong')
        else:
            self.send_error(404)


if __name__ == '__main__':
    with socketserver.TCPServer(('127.0.0.1', PORT), TTSHandler) as httpd:
        print(f"Kokoro TTS server running on http://127.0.0.1:{PORT}")
        print("Endpoints: POST /speak, GET /ping")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down...")
            sys.exit(0)
