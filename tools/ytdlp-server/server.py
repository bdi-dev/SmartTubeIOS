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
  YTDLP_UNKEPT_CAP_GB    cap on unkept downloads, in GB of 1024^3 bytes (default 20). Kept files
                         have no cap. Unkept files are evicted oldest-first when over the cap.
  YTDLP_MAX_HEIGHT       default quality cap when the app sends none (default 1080).
  YTDLP_COOKIES          optional cookies.txt passed to yt-dlp (never leaves this machine).
"""
import base64
import fnmatch
import hmac
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

API_VERSION = 2  # 2 = sidecar metadata, library listing, keep and delete
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}\Z")  # \Z, not $: "$" also matches before a newline
DOWNLOADED_AT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")
LIBRARY_DEFAULT_LIMIT = 50
LIBRARY_MAX_LIMIT = 200
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
        self.unkept_cap_bytes = int(round(float(env.get("YTDLP_UNKEPT_CAP_GB", "20")) * 1024**3))
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
        self.meta = {}  # video_id -> posted metadata, kept apart from job state

    def file_path(self, video_id):
        return os.path.join(self.config.data_dir, video_id + ".mp4")

    def sidecar_path(self, video_id):
        return os.path.join(self.config.data_dir, video_id + ".json")

    def _store_sidecar(self, video_id, record):
        """Atomically replaces <id>.json: write a uniquely named temp file, then os.replace.
        The caller must hold self.lock."""
        fd, tmp = tempfile.mkstemp(dir=self.config.data_dir, prefix=video_id + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(record, f)
            os.replace(tmp, self.sidecar_path(video_id))
        except OSError:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise

    def _write_sidecar(self, video_id, meta, downloaded_at=None):
        """Writes the sidecar for a finished download. The caller must hold self.lock."""
        record = {
            "videoId": video_id,
            "title": meta.get("title", ""),
            "channelTitle": meta.get("channelTitle", ""),
            "duration": meta.get("duration"),
            "thumbnailURL": meta.get("thumbnailURL"),
            "keep": meta.get("keep", True),
            "downloadedAt": time.strftime(
                "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() if downloaded_at is None else downloaded_at)
            ),
            "fileSize": os.path.getsize(self.file_path(video_id)),
        }
        self._store_sidecar(video_id, record)

    def set_keep(self, video_id, keep):
        """Sets the keep flag on a download's sidecar. Returns False if it has no valid sidecar."""
        with self.lock:
            side = self._read_sidecar(video_id)
            if side is None:
                return False
            side["keep"] = keep
            self._store_sidecar(video_id, side)
            return True

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

    def submit(self, video_id, max_height=None, meta=None):
        meta = meta or {}
        with self.lock:
            job = self.jobs.get(video_id)
            if job and job["status"] in ("queued", "running", "ready"):
                return dict(job)  # first writer wins: the new metadata is ignored
            if not job and os.path.exists(self.file_path(video_id)):
                if not os.path.exists(self.sidecar_path(video_id)):  # legacy file: backfill
                    mtime = os.path.getmtime(self.file_path(video_id))
                    self._write_sidecar(video_id, meta, downloaded_at=mtime)
                return {"status": "ready", "progress": 1.0}
            self.jobs[video_id] = {"status": "queued", "progress": 0.0}
            self.meta[video_id] = meta
        self.pool.submit(self._run, video_id, max_height or self.config.max_height)
        return {"status": "queued", "progress": 0.0}

    def _set(self, video_id, **fields):
        with self.lock:
            self.jobs.setdefault(video_id, {}).update(fields)

    def _read_sidecar(self, video_id):
        """Returns a valid sidecar dict, or None (logging the id) if it is unreadable or wrong.
        The caller must hold self.lock."""
        try:
            with open(self.sidecar_path(video_id)) as f:
                side = json.load(f)
        except (OSError, ValueError):
            side = None
        ok = (
            isinstance(side, dict)
            and side.get("videoId") == video_id
            and isinstance(side.get("downloadedAt"), str)
            and DOWNLOADED_AT_RE.match(side["downloadedAt"]) is not None
            and isinstance(side.get("keep"), bool)
        )
        if not ok:
            sys.stderr.write("skipping bad sidecar for %s\n" % video_id)
            return None
        return side

    def library(self, limit, after=None):
        """One keyset page of finished downloads, newest first. `after` is a (downloadedAt, videoId)
        key; only items strictly older than it are returned. Returns (items, nextCursor)."""
        found = []
        with self.lock:
            for name in os.listdir(self.config.data_dir):
                if not name.endswith(".json"):
                    continue
                vid = name[:-5]
                if not VIDEO_ID_RE.match(vid) or not os.path.exists(self.file_path(vid)):
                    continue
                side = self._read_sidecar(vid)
                if side is None:
                    continue
                key = (side["downloadedAt"], vid)
                if after is not None and key >= after:
                    continue
                try:
                    side["fileSize"] = os.path.getsize(self.file_path(vid))
                except OSError:
                    continue
                found.append((key, side))
        found.sort(key=lambda pair: pair[0], reverse=True)
        page = found[:limit]
        next_cursor = encode_cursor(page[-1][0]) if len(found) > limit else None
        return [side for _, side in page], next_cursor

    def _run(self, video_id, height):
        with self.lock:
            meta = self.meta.pop(video_id, {})
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
            try:
                with self.lock:  # sidecar first, so "ready" is never seen without one
                    self._write_sidecar(video_id, meta)
                    self.jobs.setdefault(video_id, {}).update(status="ready", progress=1.0)
            except OSError as e:
                self._set(video_id, status="failed", error="Could not save the file: %s" % e)
            else:
                self.evict(skip=video_id)  # never evict the file that just finished
        else:
            if os.path.exists(out_path):
                os.remove(out_path)
            message = " ".join(stderr_tail)[:300] or "yt-dlp exited with code %s" % code
            self._set(video_id, status="failed", error=message)

    def delete(self, video_id):
        """Removes the .mp4 and its sidecar. Returns "deleted", "missing", or "busy" (a job is
        queued or running, so nothing is removed and _set cannot recreate the file)."""
        with self.lock:
            job = self.jobs.get(video_id)
            if job and job["status"] in ("queued", "running"):
                return "busy"
            self.jobs.pop(video_id, None)
            removed = False
            for path in (self.file_path(video_id), self.sidecar_path(video_id)):
                try:
                    os.remove(path)
                    removed = True
                except FileNotFoundError:
                    pass
            return "deleted" if removed else "missing"

    def _active(self, video_id):
        """True if a job is queued or running. The caller must hold self.lock."""
        job = self.jobs.get(video_id)
        return bool(job) and job["status"] in ("queued", "running")

    def _video_ids_with_mp4(self):
        names = os.listdir(self.config.data_dir)
        return [n[:-4] for n in names if n.endswith(".mp4") and VIDEO_ID_RE.match(n[:-4])]

    def evict(self, skip=None):
        """Evicts unkept downloads, oldest first, until their total is within the cap. Never
        evicts kept files, a queued or running job, or `skip` (the file that just finished).
        Returns the evicted ids."""
        cap = self.config.unkept_cap_bytes
        evicted = []
        with self.lock:
            total = 0
            unkept = []  # (downloadedAt, videoId, size)
            for vid in self._video_ids_with_mp4():
                if not os.path.exists(self.sidecar_path(vid)):
                    continue  # not in the library; startup migrates these
                side = self._read_sidecar(vid)
                if side is None:
                    continue
                try:
                    size = os.path.getsize(self.file_path(vid))
                except OSError:
                    continue
                if side["keep"]:
                    continue
                total += size  # active files count towards the cap but are never evicted
                if not self._active(vid):
                    unkept.append((side["downloadedAt"], vid, size))
            unkept.sort()
            for _, vid, size in unkept:
                if total <= cap:
                    break
                if vid == skip:
                    continue
                for path in (self.file_path(vid), self.sidecar_path(vid)):
                    try:
                        os.remove(path)
                    except FileNotFoundError:
                        pass
                self.jobs.pop(vid, None)
                total -= size
                evicted.append(vid)
        return evicted

    def _fetch_metadata(self, video_id):
        """Asks yt-dlp (no download) for a video's metadata. Returns a dict, or None on any failure."""
        cmd = [self.config.ytdlp_bin, "--no-playlist", "--skip-download", "--dump-single-json"]
        if self.config.cookies:
            cmd += ["--cookies", self.config.cookies]
        cmd.append("https://www.youtube.com/watch?v=" + video_id)  # argv list: never a shell
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            if out.returncode != 0:
                return None
            info = json.loads(out.stdout)
        except (OSError, subprocess.SubprocessError, ValueError):
            return None
        if not isinstance(info, dict) or not info.get("title"):
            return None
        duration = info.get("duration")
        return {
            "title": str(info["title"]),
            "channelTitle": str(info.get("channel") or info.get("uploader") or ""),
            "duration": int(duration) if isinstance(duration, (int, float)) else None,
            "thumbnailURL": info.get("thumbnail") or "https://i.ytimg.com/vi/%s/hqdefault.jpg" % video_id,
        }

    def backfill_metadata(self):
        """Fills in title, channel, duration and thumbnail for downloads whose sidecar has none
        (files made before metadata was recorded). Runs once per start, one video at a time; a video
        yt-dlp cannot describe is skipped and tried again at the next start. Returns how many were
        filled. Never touches the keep flag, download time or size."""
        with self.lock:
            missing = [
                vid
                for vid in sorted(self._sidecar_ids())
                if (side := self._read_sidecar(vid)) is not None and not side.get("title")
            ]
        filled = 0
        for vid in missing:
            meta = self._fetch_metadata(vid)
            if meta is None:
                sys.stderr.write("metadata backfill: could not describe %s\n" % vid)
                continue
            with self.lock:  # re-read: keep may have changed, or the file may have been deleted
                side = self._read_sidecar(vid)
                if side is None or side.get("title") or not os.path.exists(self.file_path(vid)):
                    continue
                side.update(meta)
                try:
                    self._store_sidecar(vid, side)
                except OSError:
                    continue
            filled += 1
        return filled

    def _sidecar_ids(self):
        return [
            name[:-5]
            for name in os.listdir(self.config.data_dir)
            if name.endswith(".json") and VIDEO_ID_RE.match(name[:-5])
        ]

    def startup_cleanup(self):
        """Migrates legacy .mp4 files to unkept sidecars, removes orphan sidecars and stale partial
        downloads (older than an hour), then enforces the cap."""
        now = time.time()
        with self.lock:
            for name in os.listdir(self.config.data_dir):
                path = os.path.join(self.config.data_dir, name)
                if name.endswith(".mp4") and VIDEO_ID_RE.match(name[:-4]):
                    vid = name[:-4]
                    if not os.path.exists(self.sidecar_path(vid)):  # legacy: treat as unkept
                        self._write_sidecar(vid, {"keep": False}, downloaded_at=os.path.getmtime(path))
                elif name.endswith(".json") and VIDEO_ID_RE.match(name[:-5]):
                    if not os.path.exists(self.file_path(name[:-5])):  # orphan sidecar
                        os.remove(path)
                elif name.endswith((".part", ".tmp")) or fnmatch.fnmatch(name, "*.f*.mp4"):
                    if now - os.path.getmtime(path) > 3600:  # stale partial download
                        os.remove(path)
        self.evict()


def encode_cursor(key):
    """Opaque library cursor: urlsafe base64 (no padding) of "<downloadedAt>|<videoId>"."""
    return base64.urlsafe_b64encode(("%s|%s" % key).encode()).decode().rstrip("=")


def decode_cursor(cursor):
    """Returns the (downloadedAt, videoId) key of a cursor. Raises ValueError if malformed."""
    try:
        raw = base64.urlsafe_b64decode((cursor + "=" * (-len(cursor) % 4)).encode()).decode()
    except ValueError:  # binascii.Error and UnicodeDecodeError are both ValueErrors
        raise ValueError("cursor")
    downloaded_at, sep, video_id = raw.partition("|")
    if not sep or not DOWNLOADED_AT_RE.match(downloaded_at) or not VIDEO_ID_RE.match(video_id):
        raise ValueError("cursor")
    return (downloaded_at, video_id)


def parse_metadata(body):
    """Validates the optional metadata of POST /v1/jobs. Raises ValueError(field) if one is bad.
    A missing or null field takes its default."""
    meta = {}
    for key, limit in (("title", 300), ("channelTitle", 200)):
        value = body.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or len(value) > limit:
            raise ValueError(key)
        meta[key] = value
    duration = body.get("duration")
    if duration is not None:
        if isinstance(duration, bool) or not isinstance(duration, (int, float)):
            raise ValueError("duration")
        if not math.isfinite(duration) or duration < 0:
            raise ValueError("duration")
        meta["duration"] = duration
    thumb = body.get("thumbnailURL")
    if thumb is not None:
        if not isinstance(thumb, str) or not thumb.startswith("https://") or len(thumb) > 500:
            raise ValueError("thumbnailURL")
        meta["thumbnailURL"] = thumb
    keep = body.get("keep")
    if keep is None:
        keep = True
    if not isinstance(keep, bool):
        raise ValueError("keep")
    meta["keep"] = keep
    return meta


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
            path, _, query = self.path.partition("?")
            if path == "/v1/health":
                return self._json(
                    200, {"ok": True, "apiVersion": API_VERSION, "ytdlpVersion": _ytdlp_version(config)}
                )
            if not self._authorised():
                return self._json(401, {"error": "unauthorised"})
            if path == "/v1/library":
                return self._library(query)
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

        def _library(self, query):
            params = parse_qs(query, keep_blank_values=True)
            raw_limit = params.get("limit", [str(LIBRARY_DEFAULT_LIMIT)])[-1]
            if not re.fullmatch(r"[0-9]{1,6}", raw_limit) or not 1 <= int(raw_limit) <= LIBRARY_MAX_LIMIT:
                return self._json(400, {"error": "bad limit"})
            raw_cursor = params.get("cursor", [""])[-1]
            after = None
            if raw_cursor:
                try:
                    after = decode_cursor(raw_cursor)
                except ValueError:
                    return self._json(400, {"error": "bad cursor"})
            items, next_cursor = manager.library(int(raw_limit), after)
            self._json(200, {"items": items, "nextCursor": next_cursor})

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
            try:
                meta = parse_metadata(body)
            except ValueError as e:
                return self._json(400, {"error": "bad %s" % e})
            self._json(202, manager.submit(vid, height, meta))

        def do_PUT(self):
            if not self._authorised():
                return self._json(401, {"error": "unauthorised"})
            m = re.match(r"^/v1/files/([^/]+)/keep$", self.path.split("?")[0])
            if not m:
                return self._json(404, {"error": "not found"})
            vid = self._video_id(m.group(1))
            if not vid:
                return self._json(400, {"error": "bad video id"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length) or b"{}")
            except (ValueError, json.JSONDecodeError):
                return self._json(400, {"error": "bad json"})
            keep = body.get("keep") if isinstance(body, dict) else None
            if not isinstance(keep, bool):
                return self._json(400, {"error": "bad keep"})
            if not manager.set_keep(vid, keep):
                return self._json(404, {"error": "unknown file"})
            self._json(200, {"ok": True, "keep": keep})

        def do_DELETE(self):
            if not self._authorised():
                return self._json(401, {"error": "unauthorised"})
            m = re.match(r"^/v1/files/([^/]+)$", self.path.split("?")[0])
            vid = self._video_id(m.group(1)) if m else None
            if not vid:
                return self._json(400, {"error": "bad video id"})
            result = manager.delete(vid)
            if result == "busy":
                return self._json(409, {"deleted": False, "error": "still downloading"})
            self._json(200 if result == "deleted" else 404, {"deleted": result == "deleted"})

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
    manager.startup_cleanup()
    server = ThreadingHTTPServer((config.host, config.port), make_handler(config, manager))
    server.manager = manager
    return server


def main():
    config = Config()
    if not config.token:
        sys.exit("YTDLP_TOKEN is required (a long random string the app will send as a bearer token).")
    server = build_server(config)
    threading.Thread(target=server.manager.backfill_metadata, daemon=True).start()
    sys.stderr.write("SmartTube yt-dlp server on %s:%d, data in %s\n" % (config.host, config.port, config.data_dir))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
