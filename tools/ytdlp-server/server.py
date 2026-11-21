#!/usr/bin/env python3
"""SmartTube yt-dlp companion server (Phase 0).

A small, dependency-free HTTP service that runs yt-dlp for SmartTube. The app asks for a video by
ID, polls until it is ready, then downloads the finished MP4 (with Range support).
See docs/features/ytdlp-companion-server.md for the design.

Configuration (environment):
  YTDLP_TOKEN            required. Bearer token the app must send.
  YTDLP_BIN              yt-dlp executable (default: yt-dlp).
  YTDLP_DATA_DIR         where files live (default: ./data).
  YTDLP_HOST / YTDLP_PORT  bind address (default 127.0.0.1:8787). Put it behind Tailscale/LAN only.
  YTDLP_MAX_CONCURRENT   simultaneous yt-dlp jobs (default 2).
  YTDLP_RETENTION_HOURS  delete files older than this (default 24).
  YTDLP_MAX_HEIGHT       default quality cap when the app sends none (default 1080).
  YTDLP_COOKIES          optional cookies.txt passed to yt-dlp (never leaves this machine).
"""
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
PROGRESS_RE = re.compile(r"\[download\]\s+(\d+(?:\.\d+)?)%")
# AVPlayer-friendly: H.264 + AAC in MP4, falling back to whatever yt-dlp can merge into MP4.
FORMAT_TEMPLATE = (
    "bv*[vcodec^=avc1][height<=?{h}]+ba[ext=m4a]/b[ext=mp4][height<=?{h}]/bv*[height<=?{h}]+ba/b"
)


class Config:
    def __init__(self, env=None):
        env = os.environ if env is None else env
        self.token = env.get("YTDLP_TOKEN", "")
        self.ytdlp_bin = env.get("YTDLP_BIN", "yt-dlp")
        self.data_dir = os.path.abspath(env.get("YTDLP_DATA_DIR", "data"))
        self.host = env.get("YTDLP_HOST", "127.0.0.1")
        self.port = int(env.get("YTDLP_PORT", "8787"))
        self.max_concurrent = int(env.get("YTDLP_MAX_CONCURRENT", "2"))
        self.retention_hours = float(env.get("YTDLP_RETENTION_HOURS", "24"))
        self.max_height = int(env.get("YTDLP_MAX_HEIGHT", "1080"))
        self.cookies = env.get("YTDLP_COOKIES", "")


class JobManager:
    """Tracks yt-dlp jobs. One job per video id; posting the same id again is idempotent."""

    def __init__(self, config):
        self.config = config
        os.makedirs(config.data_dir, exist_ok=True)
        self.pool = ThreadPoolExecutor(max_workers=max(1, config.max_concurrent))
        self.lock = threading.Lock()
        self.jobs = {}  # video_id -> dict(status, progress, error)

    def file_path(self, video_id):
        return os.path.join(self.config.data_dir, video_id + ".mp4")

    def status(self, video_id):
        with self.lock:
            job = self.jobs.get(video_id)
            if job:
                out = dict(job)
            elif os.path.exists(self.file_path(video_id)):
                out = {"status": "ready", "progress": 1.0}  # survived a restart
            else:
                return None
        if out["status"] == "ready":
            try:
                out["fileSize"] = os.path.getsize(self.file_path(video_id))
            except OSError:
                return None
        return out

    def submit(self, video_id, max_height=None):
        with self.lock:
            job = self.jobs.get(video_id)
            if job and job["status"] in ("queued", "running", "ready"):
                return dict(job)
            if not job and os.path.exists(self.file_path(video_id)):
                return {"status": "ready", "progress": 1.0}
            self.jobs[video_id] = {"status": "queued", "progress": 0.0}
        self.pool.submit(self._run, video_id, max_height or self.config.max_height)
        return {"status": "queued", "progress": 0.0}

    def _set(self, video_id, **fields):
        with self.lock:
            self.jobs.setdefault(video_id, {}).update(fields)

    def _run(self, video_id, height):
        self._set(video_id, status="running")
        out_path = self.file_path(video_id)
        cmd = [
            self.config.ytdlp_bin,
            "--no-playlist",
            "--newline",
            "-f", FORMAT_TEMPLATE.format(h=height),
            "--merge-output-format", "mp4",
            "--postprocessor-args", "ffmpeg:-movflags +faststart",
            "-o", out_path,
        ]
        if self.config.cookies:
            cmd += ["--cookies", self.config.cookies]
        cmd.append("https://www.youtube.com/watch?v=" + video_id)  # argv list: never a shell
        stderr_tail = []
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
            )
            for line in proc.stdout:
                m = PROGRESS_RE.search(line)
                if m:
                    self._set(video_id, progress=min(float(m.group(1)) / 100.0, 0.99))
            stderr_tail = proc.stderr.read().strip().splitlines()[-3:]
            code = proc.wait()
        except OSError as e:
            self._set(video_id, status="failed", error="Could not run yt-dlp: %s" % e)
            return
        if code == 0 and os.path.exists(out_path):
            self._set(video_id, status="ready", progress=1.0)
        else:
            if os.path.exists(out_path):
                os.remove(out_path)
            message = " ".join(stderr_tail)[:300] or "yt-dlp exited with code %s" % code
            self._set(video_id, status="failed", error=message)

    def delete(self, video_id):
        with self.lock:
            self.jobs.pop(video_id, None)
        try:
            os.remove(self.file_path(video_id))
            return True
        except FileNotFoundError:
            return False

    def sweep(self, now=None):
        """Removes files older than the retention window. Returns how many were removed."""
        now = time.time() if now is None else now
        limit = self.config.retention_hours * 3600
        removed = 0
        for name in os.listdir(self.config.data_dir):
            path = os.path.join(self.config.data_dir, name)
            if name.endswith(".mp4") and now - os.path.getmtime(path) > limit:
                os.remove(path)
                with self.lock:
                    self.jobs.pop(name[:-4], None)
                removed += 1
        return removed


def make_handler(config, manager):
    class Handler(BaseHTTPRequestHandler):
        server_version = "SmartTubeYtDlp/0"

        def log_message(self, fmt, *args):  # log ids and status only, never headers/tokens
            sys.stderr.write("%s %s\n" % (self.command, self.path.split("?")[0]))

        # -- helpers --
        def _json(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _authorised(self):
            header = self.headers.get("Authorization", "")
            return hmac.compare_digest(header, "Bearer " + config.token)

        def _video_id(self, raw):
            return raw if VIDEO_ID_RE.match(raw or "") else None

        # -- routes --
        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/v1/health":
                return self._json(200, {"ok": True, "ytdlpVersion": _ytdlp_version(config)})
            if not self._authorised():
                return self._json(401, {"error": "unauthorised"})
            m = re.match(r"^/v1/jobs/([^/]+)$", path)
            if m:
                vid = self._video_id(m.group(1))
                if not vid:
                    return self._json(400, {"error": "bad video id"})
                status = manager.status(vid)
                return self._json(200, status) if status else self._json(404, {"error": "unknown job"})
            m = re.match(r"^/v1/files/([^/]+)\.mp4$", path)
            if m:
                vid = self._video_id(m.group(1))
                if not vid:
                    return self._json(400, {"error": "bad video id"})
                return self._serve_file(manager.file_path(vid))
            self._json(404, {"error": "not found"})

        def do_POST(self):
            if not self._authorised():
                return self._json(401, {"error": "unauthorised"})
            if self.path.split("?")[0] != "/v1/jobs":
                return self._json(404, {"error": "not found"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length) or b"{}")
            except (ValueError, json.JSONDecodeError):
                return self._json(400, {"error": "bad json"})
            vid = self._video_id(body.get("videoId"))
            if not vid:
                return self._json(400, {"error": "bad video id"})
            height = body.get("maxHeight")
            if height is not None and not (isinstance(height, int) and 144 <= height <= 4320):
                return self._json(400, {"error": "bad maxHeight"})
            self._json(202, manager.submit(vid, height))

        def do_DELETE(self):
            if not self._authorised():
                return self._json(401, {"error": "unauthorised"})
            m = re.match(r"^/v1/files/([^/]+)$", self.path.split("?")[0])
            vid = self._video_id(m.group(1)) if m else None
            if not vid:
                return self._json(400, {"error": "bad video id"})
            self._json(200 if manager.delete(vid) else 404, {"deleted": True})

        def _serve_file(self, path):
            try:
                size = os.path.getsize(path)
            except OSError:
                return self._json(404, {"error": "no such file"})
            start, end = 0, size - 1
            rng = self.headers.get("Range")
            status = 200
            if rng:
                m = re.match(r"^bytes=(\d*)-(\d*)$", rng.strip())
                if not m or (m.group(1) == "" and m.group(2) == ""):
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.end_headers()
                    return
                if m.group(1) == "":  # suffix range: last N bytes
                    start = max(size - int(m.group(2)), 0)
                else:
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                if start >= size or start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.end_headers()
                    return
                status = 206
            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if status == 206:
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            self.end_headers()
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(1 << 20, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)

    return Handler


def _ytdlp_version(config):
    try:
        out = subprocess.run(
            [config.ytdlp_bin, "--version"], capture_output=True, text=True, timeout=10
        )
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def build_server(config):
    manager = JobManager(config)
    manager.sweep()
    server = ThreadingHTTPServer((config.host, config.port), make_handler(config, manager))
    server.manager = manager
    return server


def main():
    config = Config()
    if not config.token:
        sys.exit("YTDLP_TOKEN is required (a long random string the app will send as a bearer token).")
    server = build_server(config)
    sys.stderr.write("SmartTube yt-dlp server on %s:%d, data in %s\n" % (config.host, config.port, config.data_dir))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
