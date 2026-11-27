#!/usr/bin/env python3
"""SmartTube yt-dlp companion server.

A small, dependency-free HTTP service that runs yt-dlp for SmartTube. The app asks for a video by
ID, polls until it is ready, then downloads the finished MP4 (with Range support). Several people
can share one server: each has a personal token, their own list, keep flags and unkept cap, and each
video is stored once on disk. See README.md for the API and the limits.

Configuration (environment):
  YTDLP_TOKEN            the admin token. Only read when the admin profile is first created (startup
                         migration); after that, manage tokens from /admin or the CLI.
  YTDLP_BIN              yt-dlp executable (default: yt-dlp).
  YTDLP_DATA_DIR         where files live (default: ./data).
  YTDLP_HOST / YTDLP_PORT  bind address (default 127.0.0.1:8787). Put it behind Tailscale/LAN only.
  YTDLP_MAX_CONCURRENT   simultaneous yt-dlp jobs (default 2).
  YTDLP_UNKEPT_CAP_GB    default unkept cap for new profiles, in GB of 1024^3 bytes (default 20).
  YTDLP_MAX_HEIGHT       default quality cap when the app sends none (default 1080).
  YTDLP_COOKIES          optional cookies.txt passed to yt-dlp (never leaves this machine).
  YTDLP_PUBLIC_URL       optional address users reach the server at; used to print invite links.

Command line (run in the container with docker exec):
  python3 server.py add-user NAME [--admin]    create a profile and print its token once
  python3 server.py revoke-user USER           revoke a profile's token (its list is kept)
  python3 server.py reissue-user USER          give a profile a new token (the old one stops working)
"""
import base64
import fnmatch
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote

API_VERSION = 5  # 2 = sidecar metadata, library, keep, delete; 3 = unused; 4 = profiles and ownership; 5 = status
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}\Z")  # \Z, not $: "$" also matches before a newline
PROFILE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}\Z")
DOWNLOADED_AT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")
LIBRARY_DEFAULT_LIMIT = 50
LIBRARY_MAX_LIMIT = 200
PROGRESS_RE = re.compile(r"\[download\]\s+(\d+(?:\.\d+)?)%")
ADMIN_ID = "admin"
ROLES = ("admin", "user")
NAME_MAX = 60
CAP_MAX = 1 << 50  # bytes; a sanity bound, not a policy
MAX_BODY = 1 << 20
LAST_SEEN_WRITE_INTERVAL = 60  # seconds between persisted lastSeen updates
STATUS_CACHE_SECONDS = 10  # disk and yt-dlp version in /v1/status are reused for this long
FAILURE_RING_SIZE = 20  # recent job failures kept in memory per profile; reset on restart
FAILURE_MESSAGE_MAX = 200  # characters of a yt-dlp error kept in the failure ring
ADMIN_USER_RE = re.compile(r"^/v1/admin/users/([a-z0-9][a-z0-9-]{0,47})\Z")
ADMIN_TOKEN_RE = re.compile(r"^/v1/admin/users/([a-z0-9][a-z0-9-]{0,47})/token\Z")
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
        self.public_url = env.get("YTDLP_PUBLIC_URL", "").rstrip("/")


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def now_iso(ts=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() if ts is None else ts))


def new_token():
    return secrets.token_urlsafe(32)


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def atomic_write_json(path, obj):
    """Writes JSON to a uniquely named temp file in the same directory, then os.replace()s it."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except OSError:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def new_profile(pid, name, role, digest, cap_bytes):
    return {
        "id": pid,
        "name": name,
        "role": role,
        "tokenHash": digest,
        "createdAt": now_iso(),
        "lastSeen": None,
        "capBytes": cap_bytes,
    }


def public_profile(p):
    """Profile fields that may leave the server. Never the token hash."""
    return {
        "id": p["id"],
        "name": p["name"],
        "role": p["role"],
        "createdAt": p.get("createdAt"),
        "lastSeen": p.get("lastSeen"),
        "capBytes": p["capBytes"],
        "hasToken": bool(p.get("tokenHash")),
    }


def me_view(p):
    return {"id": p["id"], "name": p["name"], "role": p["role"], "capBytes": p["capBytes"]}


def parse_fields(body, allowed):
    """Validates the profile fields present in body. Raises ValueError(field) if one is unknown or bad."""
    for key in body:
        if key not in allowed:
            raise ValueError(key)
    out = {}
    if "name" in body:
        name = body["name"]
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= NAME_MAX:
            raise ValueError("name")
        out["name"] = name.strip()
    if "role" in body:
        if body["role"] not in ROLES:
            raise ValueError("role")
        out["role"] = body["role"]
    if "capBytes" in body:
        cap = body["capBytes"]
        if isinstance(cap, bool) or not isinstance(cap, int) or not 0 <= cap <= CAP_MAX:
            raise ValueError("capBytes")
        out["capBytes"] = cap
    return out


class JobManager:
    """Tracks yt-dlp jobs, profiles and per-profile ownership of the downloaded files.

    Files live once in the data dir (<id>.mp4 + <id>.json sidecar). Who may see a file, and whether
    each profile keeps it, lives in owners/<profile>.json. Everything below is guarded by self.lock.
    """

    def __init__(self, config):
        self.config = config
        os.makedirs(config.data_dir, exist_ok=True)
        os.makedirs(self.owners_dir, exist_ok=True)
        self.pool = ThreadPoolExecutor(max_workers=max(1, config.max_concurrent))
        self.lock = threading.RLock()
        self.jobs = {}  # video_id -> dict(status, progress, error?, owners={profile id: keep})
        self.meta = {}  # video_id -> posted metadata, kept apart from job state
        self.profiles = []  # persisted in profiles.json
        self.owners = {}  # profile id -> {video_id: {"keep": bool, "addedAt": str}}
        self.migrated = False  # True once existing sidecars were given to the admin profile
        self._last_saved = {}  # profile id -> time.time() of the last persisted lastSeen
        self.failures = {}  # profile id -> deque of recent job failures (in memory only)
        self.started = time.time()
        self._shared_lock = threading.Lock()
        self._shared = None  # (expires at time.monotonic(), shared status facts) for /v1/status
        self._load_profiles()
        self._ensure_admin()

    # -- paths and persistence --
    @property
    def profiles_path(self):
        return os.path.join(self.config.data_dir, "profiles.json")

    @property
    def owners_dir(self):
        return os.path.join(self.config.data_dir, "owners")

    def file_path(self, video_id):
        return os.path.join(self.config.data_dir, video_id + ".mp4")

    def sidecar_path(self, video_id):
        return os.path.join(self.config.data_dir, video_id + ".json")

    def _owners_path(self, pid):
        return os.path.join(self.owners_dir, pid + ".json")

    def _load_profiles(self):
        try:
            with open(self.profiles_path) as f:
                data = json.load(f)
        except FileNotFoundError:
            data = {}
        except (OSError, ValueError):
            raise RuntimeError("profiles.json is unreadable; restore it from backup before starting")
        if not isinstance(data, dict):
            raise RuntimeError("profiles.json has the wrong shape; restore it from backup before starting")
        self.migrated = data.get("ownershipMigrated") is True
        for p in data.get("profiles", []):
            if (
                isinstance(p, dict)
                and isinstance(p.get("id"), str)
                and PROFILE_ID_RE.match(p["id"])
                and p.get("role") in ROLES
                and isinstance(p.get("capBytes"), int)
            ):
                self.profiles.append(p)
        for p in self.profiles:
            self.owners[p["id"]] = self._load_owner_file(p["id"])

    def _load_owner_file(self, pid):
        try:
            with open(self._owners_path(pid)) as f:
                raw = json.load(f)
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            sys.stderr.write("owner record for profile %s is unreadable; starting it empty\n" % pid)
            return {}
        out = {}
        if isinstance(raw, dict):
            for vid, rec in raw.items():
                if VIDEO_ID_RE.match(vid) and isinstance(rec, dict) and isinstance(rec.get("keep"), bool):
                    out[vid] = {"keep": rec["keep"], "addedAt": str(rec.get("addedAt", ""))}
        return out

    def _save_profiles(self):
        """Persists profiles.json. The caller must hold self.lock."""
        atomic_write_json(
            self.profiles_path,
            {"version": 1, "ownershipMigrated": self.migrated, "profiles": self.profiles},
        )

    def _save_owners(self, pid):
        """Persists one profile's owner record. The caller must hold self.lock."""
        os.makedirs(self.owners_dir, exist_ok=True)
        atomic_write_json(self._owners_path(pid), self.owners.get(pid, {}))

    def _profile(self, pid):
        for p in self.profiles:
            if p["id"] == pid:
                return p
        return None

    def _require(self, pid):
        p = self._profile(pid)
        if p is None:
            raise ApiError(404, "unknown user")
        return p

    def _admin_count(self):
        return sum(1 for p in self.profiles if p["role"] == "admin")

    def _ensure_admin(self):
        """Creates the admin profile from YTDLP_TOKEN the first time only (idempotent)."""
        if not self.config.token:
            return
        with self.lock:
            if self._profile(ADMIN_ID) is None:
                self.profiles.append(
                    new_profile(ADMIN_ID, "Admin", "admin", token_hash(self.config.token), self.config.unkept_cap_bytes)
                )
                self.owners.setdefault(ADMIN_ID, {})
                self._save_profiles()

    # -- auth and profile admin --
    def authenticate(self, token):
        """Returns a copy of the profile that owns this token, or None. Compares hashes in constant time."""
        if not token:
            return None
        digest = token_hash(token)
        with self.lock:
            found = None
            for p in self.profiles:
                stored = p.get("tokenHash")
                if isinstance(stored, str) and hmac.compare_digest(stored, digest):
                    found = p
            if found is None:
                return None
            now = time.time()
            found["lastSeen"] = now_iso(now)
            if now - self._last_saved.get(found["id"], 0) >= LAST_SEEN_WRITE_INTERVAL:
                self._last_saved[found["id"]] = now
                self._save_profiles()
            return dict(found)

    def _usage_detail_locked(self, pid):
        """Per-profile usage. A shared file counts in full toward each owner that lists it."""
        kept_count = kept_bytes = unkept_count = unkept_bytes = 0
        for vid, rec in self.owners.get(pid, {}).items():
            size = self._size(vid)
            if size is None:
                continue
            if rec["keep"]:
                kept_count += 1
                kept_bytes += size
            else:
                unkept_count += 1
                unkept_bytes += size
        return {
            "videoCount": kept_count + unkept_count,
            "totalBytes": kept_bytes + unkept_bytes,
            "unkeptBytes": unkept_bytes,
            "kept": {"count": kept_count, "bytes": kept_bytes},
            "unkept": {"count": unkept_count, "bytes": unkept_bytes},
        }

    def _usage_locked(self, pid):
        detail = self._usage_detail_locked(pid)
        return {k: detail[k] for k in ("videoCount", "totalBytes", "unkeptBytes")}

    def _view_locked(self, p):
        view = public_profile(p)
        view.update(self._usage_locked(p["id"]))
        return view

    def list_users(self):
        with self.lock:
            return [self._view_locked(p) for p in self.profiles]

    def find_user(self, query):
        """Finds a profile by id, or by name (case-insensitive). Raises ApiError if none or ambiguous."""
        with self.lock:
            matches = [p for p in self.profiles if p["id"] == query]
            if not matches:
                matches = [p for p in self.profiles if p["name"].casefold() == query.casefold()]
            if not matches:
                raise ApiError(404, "no such user")
            if len(matches) > 1:
                raise ApiError(409, "several users have that name; use the id")
            return dict(matches[0])

    def create_user(self, name, role):
        """Creates a profile. Returns (public view, token); the token is shown once and never stored."""
        with self.lock:
            base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:24] or "user"
            pid = None
            while pid is None or self._profile(pid) is not None:
                pid = "%s-%s" % (base, secrets.token_hex(3))
            token = new_token()
            p = new_profile(pid, name, role, token_hash(token), self.config.unkept_cap_bytes)
            self.profiles.append(p)
            self.owners[pid] = {}
            self._save_profiles()
            return self._view_locked(p), token

    def update_user(self, pid, changes):
        with self.lock:
            p = self._require(pid)
            if "role" in changes and changes["role"] != p["role"]:
                if p["role"] == "admin" and self._admin_count() <= 1:
                    raise ApiError(409, "the last admin cannot be demoted")
                p["role"] = changes["role"]
            if "name" in changes:
                p["name"] = changes["name"]
            if "capBytes" in changes:
                p["capBytes"] = changes["capBytes"]
            self._save_profiles()
            if "capBytes" in changes:
                self._enforce_caps_locked([pid])
            return self._view_locked(p)

    def reissue_token(self, pid):
        with self.lock:
            p = self._require(pid)
            token = new_token()
            p["tokenHash"] = token_hash(token)
            self._save_profiles()
            return self._view_locked(p), token

    def revoke_token(self, pid):
        with self.lock:
            p = self._require(pid)
            p["tokenHash"] = None
            self._save_profiles()
            return self._view_locked(p)

    def delete_user(self, pid):
        """Removes a profile and its ownership. Files with no owner left are deleted. Returns the
        number of files removed."""
        with self.lock:
            p = self._require(pid)
            if p["role"] == "admin" and self._admin_count() <= 1:
                raise ApiError(409, "the last admin cannot be deleted")
            removed = 0
            for vid in list(self.owners.get(pid, {})):
                if self._drop_owner_locked(pid, vid):
                    removed += 1
            self.owners.pop(pid, None)
            self.failures.pop(pid, None)
            try:
                os.remove(self._owners_path(pid))
            except FileNotFoundError:
                pass
            for job in self.jobs.values():
                job.get("owners", {}).pop(pid, None)
            self.profiles.remove(p)
            self._save_profiles()
            return removed

    # -- ownership --
    def owns(self, pid, video_id):
        with self.lock:
            return video_id in self.owners.get(pid, {})

    def owner_record(self, pid, video_id):
        with self.lock:
            rec = self.owners.get(pid, {}).get(video_id)
            return dict(rec) if rec else None

    def _grant_locked(self, pid, video_id, keep, added_at=None):
        if self._profile(pid) is None:
            return
        rec = self.owners.setdefault(pid, {})
        if video_id in rec:
            return  # first grant wins: its keep flag and addedAt stand
        rec[video_id] = {"keep": bool(keep), "addedAt": added_at or now_iso()}
        self._save_owners(pid)

    def grant(self, pid, video_id, keep, added_at=None):
        with self.lock:
            self._grant_locked(pid, video_id, keep, added_at)

    def set_keep_for(self, pid, video_id, keep):
        """Sets the caller's keep flag. Returns False if the caller does not own the video."""
        with self.lock:
            rec = self.owners.get(pid, {}).get(video_id)
            if rec is None:
                return False
            rec["keep"] = keep
            self._save_owners(pid)
            return True

    def _drop_owner_locked(self, pid, video_id):
        """Removes one profile's ownership. When no owner is left, the files are removed (unless a job
        is still writing them). Returns True if the files were removed. The caller must hold self.lock."""
        rec = self.owners.get(pid)
        if rec is not None and video_id in rec:
            del rec[video_id]
            self._save_owners(pid)
        job = self.jobs.get(video_id)
        if job is not None:
            job.get("owners", {}).pop(pid, None)
        if any(video_id in other for other in self.owners.values()):
            return False
        if self._active(video_id):
            return False  # the running job sees no owners and removes its own file
        self._remove_files(video_id)
        self.jobs.pop(video_id, None)
        return True

    def delete_for(self, pid, video_id):
        """Removes the caller's ownership of a video. Returns "deleted", "missing" or "busy"."""
        with self.lock:
            job = self.jobs.get(video_id)
            owned = video_id in self.owners.get(pid, {})
            joined = job is not None and pid in job.get("owners", {})
            if self._active(video_id) and (owned or joined):
                return "busy"
            if not owned:
                return "missing"
            self._drop_owner_locked(pid, video_id)
            return "deleted"

    # -- metadata sidecars and files --
    def _store_sidecar(self, video_id, record):
        """Atomically replaces <id>.json. The caller must hold self.lock."""
        atomic_write_json(self.sidecar_path(video_id), record)

    def _write_sidecar(self, video_id, meta, downloaded_at=None):
        """Writes the sidecar for a finished download. The caller must hold self.lock."""
        record = {
            "videoId": video_id,
            "title": meta.get("title", ""),
            "channelTitle": meta.get("channelTitle", ""),
            "duration": meta.get("duration"),
            "thumbnailURL": meta.get("thumbnailURL"),
            "keep": meta.get("keep", True),  # the first requester's flag; per-profile keep is in owners
            "downloadedAt": now_iso(downloaded_at),
            "fileSize": os.path.getsize(self.file_path(video_id)),
        }
        self._store_sidecar(video_id, record)

    def _size(self, video_id):
        try:
            return os.path.getsize(self.file_path(video_id))
        except OSError:
            return None

    def _remove_files(self, video_id):
        for path in (self.file_path(video_id), self.sidecar_path(video_id)):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass

    def _active(self, video_id):
        """True if a job is queued or running. The caller must hold self.lock."""
        job = self.jobs.get(video_id)
        return bool(job) and job.get("status") in ("queued", "running")

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

    # -- jobs --
    def _state_locked(self, video_id):
        """The public state of a video: its job while one is pending or failed, else ready from disk."""
        job = self.jobs.get(video_id)
        if job and job.get("status") in ("queued", "running", "failed"):
            return public_job(job)
        size = self._size(video_id)
        if size is None:
            return None
        return {"status": "ready", "progress": 1.0, "fileSize": size}

    def status(self, pid, video_id):
        """Job state for a caller who owns the video or joined its job; None (404) otherwise."""
        with self.lock:
            job = self.jobs.get(video_id)
            visible = video_id in self.owners.get(pid, {}) or (job is not None and pid in job.get("owners", {}))
            if not visible:
                return None
            return self._state_locked(video_id)

    def submit(self, pid, video_id, max_height=None, meta=None):
        """Asks for a video on behalf of profile pid. Never starts a second download: an owned video
        returns its state, a video on disk is granted to pid (dedup), and an in-flight job is joined."""
        meta = meta or {}
        keep = meta.get("keep", True)
        with self.lock:
            if video_id in self.owners.get(pid, {}):
                state = self._state_locked(video_id)
                if state is not None:
                    return state
            job = self.jobs.get(video_id)
            if job and job.get("status") in ("queued", "running"):
                job.setdefault("owners", {}).setdefault(pid, keep)
                return public_job(job)
            if self._size(video_id) is not None:  # already downloaded by someone: dedup
                if not os.path.exists(self.sidecar_path(video_id)):  # legacy file: backfill
                    self._write_sidecar(video_id, meta, downloaded_at=os.path.getmtime(self.file_path(video_id)))
                self._grant_locked(pid, video_id, keep)
                self._enforce_caps_locked([pid], skip=video_id)
                return {"status": "ready", "progress": 1.0}
            self.jobs[video_id] = {"status": "queued", "progress": 0.0, "owners": {pid: keep}}
            self.meta[video_id] = meta
        self.pool.submit(self._run, video_id, max_height or self.config.max_height)
        return {"status": "queued", "progress": 0.0}

    def _set(self, video_id, **fields):
        with self.lock:
            self.jobs.setdefault(video_id, {}).update(fields)

    def _fail(self, video_id, message):
        """Marks a job failed and records the failure in the ring of each profile that asked for it."""
        with self.lock:
            job = self.jobs.setdefault(video_id, {})
            job.update(status="failed", error=message)
            at = now_iso()
            for pid in job.get("owners", {}):
                if self._profile(pid) is None:
                    continue
                ring = self.failures.setdefault(pid, deque(maxlen=FAILURE_RING_SIZE))
                ring.append({"videoId": video_id, "message": message[:FAILURE_MESSAGE_MAX], "at": at})

    def _finish(self, video_id, meta):
        """Writes the sidecar and grants every owner who asked while the job ran."""
        with self.lock:
            job = self.jobs.get(video_id, {})
            owners = {pid: keep for pid, keep in job.get("owners", {}).items() if self._profile(pid)}
            if not owners:  # everyone left while it ran
                self._remove_files(video_id)
                self.jobs.pop(video_id, None)
                return
            self._write_sidecar(video_id, meta)  # sidecar first, so "ready" is never seen without one
            for pid, keep in owners.items():
                self._grant_locked(pid, video_id, keep)
            self.jobs.pop(video_id, None)
            self._enforce_caps_locked(list(owners), skip=video_id)  # never evict the file just finished

    def library(self, pid, limit, after=None):
        """One keyset page of the caller's downloads, newest first. `after` is a (downloadedAt, videoId)
        key; only items strictly older than it are returned. Returns (items, nextCursor)."""
        found = []
        with self.lock:
            for vid, rec in self.owners.get(pid, {}).items():
                size = self._size(vid)
                if size is None:
                    continue
                side = self._read_sidecar(vid)
                if side is None:
                    continue
                key = (side["downloadedAt"], vid)
                if after is not None and key >= after:
                    continue
                item = dict(side)
                item["keep"] = rec["keep"]
                item["fileSize"] = size
                found.append((key, item))
        found.sort(key=lambda pair: pair[0], reverse=True)
        page = found[:limit]
        next_cursor = encode_cursor(page[-1][0]) if len(found) > limit else None
        return [item for _, item in page], next_cursor

    # -- status --
    def _shared_status(self):
        """Facts every caller sees: disk and yt-dlp version, cached for STATUS_CACHE_SECONDS. The yt-dlp
        call runs outside self.lock so a slow binary never blocks the other routes."""
        with self._shared_lock:
            now = time.monotonic()
            if self._shared is None or now >= self._shared[0]:
                usage = shutil.disk_usage(self.config.data_dir)
                facts = {
                    "ytdlpVersion": _ytdlp_version(self.config),
                    "disk": {"freeBytes": usage.free, "totalBytes": usage.total},
                }
                self._shared = (now + STATUS_CACHE_SECONDS, facts)
            return self._shared[1]

    def _server_totals_locked(self):
        """Physical files on disk, each counted once. Admin only."""
        files = total = 0
        for name in os.listdir(self.config.data_dir):
            if not (name.endswith(".mp4") and VIDEO_ID_RE.match(name[:-4])):
                continue
            size = self._size(name[:-4])
            if size is not None:
                files += 1
                total += size
        return {"profiles": len(self.profiles), "totalFiles": files, "totalBytes": total}

    def caller_status(self, pid):
        """The body of GET /v1/status for profile pid. Shared facts plus numbers scoped to the caller;
        the server block is added only for admins. Titles and other users' ids never appear here."""
        shared = self._shared_status()
        with self.lock:
            p = self._profile(pid)
            if p is None:
                raise ApiError(401, "unauthorised")
            usage = self._usage_detail_locked(pid)
            running = queued = 0
            for job in self.jobs.values():
                if pid not in job.get("owners", {}):
                    continue
                if job.get("status") == "running":
                    running += 1
                elif job.get("status") == "queued":
                    queued += 1
            failures = [dict(f) for f in reversed(self.failures.get(pid, ()))]
            out = {
                "apiVersion": API_VERSION,
                "ytdlpVersion": shared["ytdlpVersion"],
                "uptimeSeconds": int(time.time() - self.started),
                "disk": dict(shared["disk"]),
                "you": {
                    "videoCount": usage["videoCount"],
                    "kept": usage["kept"],
                    "unkept": usage["unkept"],
                    "capBytes": p["capBytes"],
                },
                "jobs": {"running": running, "queued": queued},
                "recentFailures": failures,
            }
            if p["role"] == "admin":
                out["server"] = self._server_totals_locked()
            return out

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
            self._fail(video_id, "Could not run yt-dlp: %s" % e)
            return
        if code == 0 and os.path.exists(out_path):
            try:
                self._finish(video_id, meta)
            except OSError as e:
                self._fail(video_id, "Could not save the file: %s" % e)
        else:
            if os.path.exists(out_path):
                os.remove(out_path)
            message = " ".join(stderr_tail)[:300] or "yt-dlp exited with code %s" % code
            self._fail(video_id, message)

    def _enforce_caps_locked(self, pids, skip=None):
        """For each profile, evicts its own oldest unkept entries until its unkept total (every unkept
        video it owns, shared files counted in full) is within its cap. Evicting removes only that
        profile's ownership; the file goes when no owner is left. Returns the evicted ids."""
        evicted = []
        for pid in pids:
            p = self._profile(pid)
            if p is None:
                continue
            rows = []  # (downloadedAt, videoId, size) for unkept, idle entries
            total = 0
            for vid, rec in self.owners.get(pid, {}).items():
                if rec["keep"]:
                    continue
                size = self._size(vid)
                if size is None:
                    continue
                side = self._read_sidecar(vid)
                if side is None:
                    continue
                total += size  # active files count towards the cap but are never evicted
                if not self._active(vid):
                    rows.append((side["downloadedAt"], vid, size))
            rows.sort()
            for _, vid, size in rows:
                if total <= p["capBytes"]:
                    break
                if vid == skip:
                    continue
                self._drop_owner_locked(pid, vid)
                total -= size
                evicted.append(vid)
        return evicted

    def evict(self, skip=None):
        """Enforces every profile's cap. Returns the ids whose ownership was evicted."""
        with self.lock:
            return self._enforce_caps_locked([p["id"] for p in self.profiles], skip)

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
        filled. Never touches owners, download time or size."""
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
            with self.lock:  # re-read: the file may have been deleted meanwhile
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
        """Migrates legacy .mp4 files to sidecars, removes orphan sidecars and stale partial downloads
        (older than an hour), drops ownership of files that are gone, gives existing downloads to the
        admin profile once, then enforces every cap."""
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
            for pid, rec in self.owners.items():
                gone = [vid for vid in rec if self._size(vid) is None]
                for vid in gone:
                    del rec[vid]
                if gone:
                    self._save_owners(pid)
            if not self.migrated and self._profile(ADMIN_ID) is not None:
                for vid in self._sidecar_ids():
                    side = self._read_sidecar(vid)
                    if side is not None and self._size(vid) is not None:
                        self._grant_locked(ADMIN_ID, vid, side["keep"], side["downloadedAt"])
                self.migrated = True
                self._save_profiles()
        self.evict()


def public_job(job):
    out = {"status": job["status"], "progress": job.get("progress", 0.0)}
    if job.get("error"):
        out["error"] = job["error"]
    return out


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


ADMIN_PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>SmartTube NAS admin</title>
<style>
:root { color-scheme: light dark; --bg:#f5f5f7; --fg:#1d1d1f; --muted:#6e6e73; --card:#ffffff; --line:#d2d2d7; --accent:#0a68d6; --bad:#c0392b; --ok:#1e8e3e; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#000000; --fg:#f5f5f7; --muted:#a1a1a6; --card:#1c1c1e; --line:#3a3a3c; --accent:#4da3ff; --bad:#ff6b5e; --ok:#32d74b; } }
:root[data-theme="dark"] { --bg:#000000; --fg:#f5f5f7; --muted:#a1a1a6; --card:#1c1c1e; --line:#3a3a3c; --accent:#4da3ff; --bad:#ff6b5e; --ok:#32d74b; }
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg); font: 15px/1.4 -apple-system, system-ui, sans-serif; }
h1 { font-size: 20px; margin: 0 0 12px; }
h2 { font-size: 16px; margin: 0 0 8px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 14px; margin-bottom: 14px; }
.muted { color: var(--muted); font-size: 13px; }
.err { color: var(--bad); margin: 8px 0; }
input[type=text], input[type=password], input[type=number] { font: inherit; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px; background: var(--bg); color: var(--fg); max-width: 100%; }
button { font: inherit; padding: 6px 11px; border-radius: 7px; border: 1px solid var(--line); background: var(--card); color: var(--fg); cursor: pointer; margin: 2px; }
button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
button.danger { color: var(--bad); }
.wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; min-width: 640px; }
th, td { text-align: left; padding: 7px 6px; border-bottom: 1px solid var(--line); vertical-align: middle; }
th { font-size: 12px; color: var(--muted); font-weight: 600; }
progress { width: 120px; height: 10px; vertical-align: middle; }
code { font-family: ui-monospace, Menlo, monospace; font-size: 13px; word-break: break-all; }
.row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.token-box { border: 1px dashed var(--accent); border-radius: 8px; padding: 10px; margin-top: 10px; }
</style>
</head>
<body>
<h1>SmartTube NAS admin</h1>

<div class="card" id="signin">
  <h2>Admin token</h2>
  <p class="muted">Paste an admin token. It is kept for this browser tab only and sent as a Bearer header.</p>
  <div class="row">
    <input type="password" id="tokenIn" autocomplete="off" aria-label="Admin token" size="40">
    <button class="primary" id="useToken">Use token</button>
    <button id="signOut" hidden>Sign out</button>
  </div>
  <div class="err" id="signErr"></div>
</div>

<div id="app" hidden>
  <div class="card">
    <h2>Add user</h2>
    <div class="row">
      <input type="text" id="newName" maxlength="60" placeholder="Name" aria-label="Name">
      <label><input type="checkbox" id="newAdmin"> admin</label>
      <button class="primary" id="addUser">Add user</button>
    </div>
    <div id="tokenOut"></div>
    <div class="err" id="addErr"></div>
  </div>

  <div class="card">
    <div class="row" style="justify-content: space-between;">
      <h2>Users</h2>
      <button id="refresh">Refresh</button>
    </div>
    <div class="wrap">
      <table>
        <thead><tr><th>Name</th><th>Role</th><th>Last seen</th><th>Videos</th><th>Unkept usage</th><th>Cap (GB)</th><th>Actions</th></tr></thead>
        <tbody id="users"></tbody>
      </table>
    </div>
    <div class="err" id="listErr"></div>
    <p class="muted">Counts and sizes only. Titles of other users' downloads are never shown here.</p>
  </div>
</div>

<script>
(function () {
  "use strict";
  var KEY = "ytdlpAdminToken";
  var GB = 1024 * 1024 * 1024;

  function $(id) { return document.getElementById(id); }
  function getToken() {
    try { return sessionStorage.getItem(KEY) || ""; } catch (e) { return ""; }
  }
  function setToken(t) {
    try { if (t) { sessionStorage.setItem(KEY, t); } else { sessionStorage.removeItem(KEY); } } catch (e) {}
  }
  function el(tag, text, cls) {
    var n = document.createElement(tag);
    if (text !== undefined && text !== null) { n.textContent = text; }
    if (cls) { n.className = cls; }
    return n;
  }
  function button(label, handler, cls) {
    var b = el("button", label, cls || "");
    b.type = "button";
    b.addEventListener("click", handler);
    return b;
  }
  function gb(bytes) { return (bytes / GB).toFixed(bytes < GB ? 2 : 1) + " GB"; }
  function when(iso) { return iso ? new Date(iso).toLocaleString() : "never"; }

  async function api(method, path, body) {
    var headers = { "Authorization": "Bearer " + getToken() };
    var init = { method: method, headers: headers, cache: "no-store", credentials: "omit" };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    var res = await fetch(path, init);
    var data = {};
    try { data = await res.json(); } catch (e) {}
    if (res.status === 401) {
      setToken("");
      showSignIn("Token rejected or revoked. Paste a valid admin token.");
      throw new Error("unauthorised");
    }
    if (!res.ok) { throw new Error(data.error || ("HTTP " + res.status)); }
    return data;
  }

  function showSignIn(message) {
    $("app").hidden = true;
    $("signin").hidden = false;
    $("signOut").hidden = true;
    $("signErr").textContent = message || "";
  }
  function showApp() {
    $("signin").hidden = false;
    $("signOut").hidden = false;
    $("app").hidden = false;
    $("signErr").textContent = "";
    loadUsers();
  }

  function inviteLink(token) {
    return "smarttube://nas?url=" + encodeURIComponent(location.origin) + "&token=" + encodeURIComponent(token);
  }
  function copyText(text, btn) {
    var done = function () { var old = btn.textContent; btn.textContent = "Copied"; setTimeout(function () { btn.textContent = old; }, 1500); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () {});
    }
  }
  function showToken(title, token, user) {
    var box = $("tokenOut");
    box.replaceChildren();
    var wrap = el("div", null, "token-box");
    wrap.appendChild(el("h2", title + " " + (user.name || "")));
    wrap.appendChild(el("p", "Shown once. Give it to the user now; it cannot be shown again.", "muted"));
    var t = el("code", token);
    wrap.appendChild(t);
    wrap.appendChild(el("div"));
    wrap.appendChild(button("Copy token", function (e) { copyText(token, e.target); }));
    var link = inviteLink(token);
    wrap.appendChild(el("p", "Invite link (open it on the user's device):", "muted"));
    wrap.appendChild(el("code", link));
    wrap.appendChild(el("div"));
    wrap.appendChild(button("Copy invite link", function (e) { copyText(link, e.target); }));
    wrap.appendChild(button("Dismiss", function () { box.replaceChildren(); }));
    box.appendChild(wrap);
  }

  function renderUsers(users) {
    var body = $("users");
    body.replaceChildren();
    users.forEach(function (u) {
      var tr = document.createElement("tr");
      tr.appendChild(el("td", u.name));
      tr.appendChild(el("td", u.role));
      tr.appendChild(el("td", when(u.lastSeen)));
      tr.appendChild(el("td", String(u.videoCount)));

      var usageTd = el("td");
      var bar = el("progress");
      bar.max = Math.max(u.capBytes, 1);
      bar.value = Math.min(u.unkeptBytes, bar.max);
      usageTd.appendChild(bar);
      usageTd.appendChild(el("div", gb(u.unkeptBytes) + " of " + gb(u.capBytes) + " unkept", "muted"));
      tr.appendChild(usageTd);

      var capTd = el("td");
      var capIn = document.createElement("input");
      capIn.type = "number"; capIn.step = "0.1"; capIn.min = "0"; capIn.size = 6;
      capIn.value = (u.capBytes / GB).toFixed(1);
      capIn.setAttribute("aria-label", "Cap for " + u.name + " in GB");
      capTd.appendChild(capIn);
      capTd.appendChild(button("Save", function () {
        var gbVal = parseFloat(capIn.value);
        if (!(gbVal >= 0)) { $("listErr").textContent = "Cap must be a number of GB."; return; }
        patchUser(u.id, { capBytes: Math.round(gbVal * GB) });
      }));
      tr.appendChild(capTd);

      var actions = el("td");
      var other = u.role === "admin" ? "user" : "admin";
      actions.appendChild(button(u.role === "admin" ? "Demote" : "Promote", function () {
        patchUser(u.id, { role: other });
      }));
      actions.appendChild(button("New token", function () {
        run(function () { return api("POST", "/v1/admin/users/" + u.id + "/token"); },
          function (data) { showToken("New token for", data.token, data.user); });
      }));
      var revoke = button("Revoke token", function () {
        if (!confirm("Revoke the token of " + u.name + "? Their list is kept.")) { return; }
        run(function () { return api("DELETE", "/v1/admin/users/" + u.id + "/token"); }, loadUsers);
      });
      revoke.disabled = !u.hasToken;
      actions.appendChild(revoke);
      actions.appendChild(button("Delete", function () {
        if (!confirm("Delete " + u.name + "? Their list is removed. Videos nobody else owns are deleted.")) { return; }
        run(function () { return api("DELETE", "/v1/admin/users/" + u.id); }, loadUsers);
      }, "danger"));
      tr.appendChild(actions);
      body.appendChild(tr);
    });
    if (!users.length) {
      var empty = document.createElement("tr");
      empty.appendChild(el("td", "No users yet.", "muted"));
      body.appendChild(empty);
    }
  }

  function run(task, then) {
    $("listErr").textContent = "";
    task().then(then, function (err) {
      if (err && err.message !== "unauthorised") { $("listErr").textContent = err.message; }
    });
  }
  function patchUser(id, changes) {
    run(function () { return api("PATCH", "/v1/admin/users/" + id, changes); }, loadUsers);
  }
  function loadUsers() {
    run(function () { return api("GET", "/v1/admin/users"); }, function (data) { renderUsers(data.users || []); });
  }

  $("useToken").addEventListener("click", function () {
    var t = $("tokenIn").value.trim();
    if (!t) { $("signErr").textContent = "Paste a token first."; return; }
    setToken(t);
    $("tokenIn").value = "";
    showApp();
  });
  $("signOut").addEventListener("click", function () {
    setToken("");
    $("tokenOut").replaceChildren();
    showSignIn("Signed out.");
  });
  $("refresh").addEventListener("click", loadUsers);
  $("addUser").addEventListener("click", function () {
    var name = $("newName").value.trim();
    if (!name) { $("addErr").textContent = "Type a name first."; return; }
    $("addErr").textContent = "";
    var role = $("newAdmin").checked ? "admin" : "user";
    run(function () { return api("POST", "/v1/admin/users", { name: name, role: role }); }, function (data) {
      $("newName").value = "";
      $("newAdmin").checked = false;
      showToken("Token for", data.token, data.user);
      loadUsers();
    });
  });

  if (getToken()) { showApp(); } else { showSignIn(""); }
})();
</script>
</body>
</html>
"""


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

        def _html(self, code, text):
            data = text.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)

        def _auth(self):
            """The calling profile, or None after sending 401."""
            header = self.headers.get("Authorization", "")
            token = header[len("Bearer "):] if header.startswith("Bearer ") else ""
            profile = manager.authenticate(token)
            if profile is None:
                self._json(401, {"error": "unauthorised"})
            return profile

        def _admin(self):
            """The calling admin profile, or None after sending 401 or 403."""
            profile = self._auth()
            if profile is not None and profile["role"] != "admin":
                self._json(403, {"error": "forbidden"})
                return None
            return profile

        def _body(self):
            """The request body as a JSON object, or None if it is not one."""
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return None
            if length < 0 or length > MAX_BODY:
                return None
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return None
            return body if isinstance(body, dict) else None

        def _video_id(self, raw):
            return raw if isinstance(raw, str) and VIDEO_ID_RE.match(raw) else None

        def _api_error(self, err):
            self._json(err.status, {"error": err.message})

        # -- routes --
        def do_GET(self):
            path, _, query = self.path.partition("?")
            if path == "/v1/health":
                return self._json(
                    200, {"ok": True, "apiVersion": API_VERSION, "ytdlpVersion": _ytdlp_version(config)}
                )
            if path in ("/admin", "/admin/"):
                return self._html(200, ADMIN_PAGE)
            me = self._auth()
            if me is None:
                return
            if path == "/v1/me":
                return self._json(200, me_view(me))
            if path == "/v1/status":
                try:
                    return self._json(200, manager.caller_status(me["id"]))
                except ApiError as e:
                    return self._api_error(e)
            if path == "/v1/library":
                return self._library(me["id"], query)
            if path == "/v1/admin/users":
                if me["role"] != "admin":
                    return self._json(403, {"error": "forbidden"})
                return self._json(200, {"users": manager.list_users()})
            m = re.match(r"^/v1/jobs/([^/]+)$", path)
            if m:
                vid = self._video_id(m.group(1))
                if not vid:
                    return self._json(400, {"error": "bad video id"})
                status = manager.status(me["id"], vid)
                return self._json(200, status) if status else self._json(404, {"error": "unknown job"})
            m = re.match(r"^/v1/files/([^/]+)\.mp4$", path)
            if m:
                vid = self._video_id(m.group(1))
                if not vid:
                    return self._json(400, {"error": "bad video id"})
                if not manager.owns(me["id"], vid):
                    return self._json(404, {"error": "no such file"})
                return self._serve_file(manager.file_path(vid))
            self._json(404, {"error": "not found"})

        def _library(self, pid, query):
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
            items, next_cursor = manager.library(pid, int(raw_limit), after)
            self._json(200, {"items": items, "nextCursor": next_cursor})

        def do_POST(self):
            path = self.path.split("?")[0]
            me = self._auth()
            if me is None:
                return
            if path == "/v1/jobs":
                return self._post_job(me)
            if path == "/v1/admin/users":
                if me["role"] != "admin":
                    return self._json(403, {"error": "forbidden"})
                return self._admin_create()
            m = ADMIN_TOKEN_RE.match(path)
            if m:
                if me["role"] != "admin":
                    return self._json(403, {"error": "forbidden"})
                try:
                    user, token = manager.reissue_token(m.group(1))
                except ApiError as e:
                    return self._api_error(e)
                return self._json(200, {"user": user, "token": token})
            self._json(404, {"error": "not found"})

        def _post_job(self, me):
            body = self._body()
            if body is None:
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
            self._json(202, manager.submit(me["id"], vid, height, meta))

        def _admin_create(self):
            body = self._body()
            if body is None:
                return self._json(400, {"error": "bad json"})
            try:
                fields = parse_fields(body, ("name", "role"))
                if "name" not in fields:
                    raise ValueError("name")
            except ValueError as e:
                return self._json(400, {"error": "bad %s" % e})
            user, token = manager.create_user(fields["name"], fields.get("role", "user"))
            self._json(201, {"user": user, "token": token})

        def do_PUT(self):
            path = self.path.split("?")[0]
            me = self._auth()
            if me is None:
                return
            m = re.match(r"^/v1/files/([^/]+)/keep$", path)
            if not m:
                return self._json(404, {"error": "not found"})
            vid = self._video_id(m.group(1))
            if not vid:
                return self._json(400, {"error": "bad video id"})
            body = self._body()
            if body is None:
                return self._json(400, {"error": "bad json"})
            keep = body.get("keep")
            if not isinstance(keep, bool):
                return self._json(400, {"error": "bad keep"})
            if not manager.set_keep_for(me["id"], vid, keep):
                return self._json(404, {"error": "unknown file"})
            self._json(200, {"ok": True, "keep": keep})

        def do_PATCH(self):
            path = self.path.split("?")[0]
            me = self._auth()
            if me is None:
                return
            m = ADMIN_USER_RE.match(path)
            if m:
                if me["role"] != "admin":
                    return self._json(403, {"error": "forbidden"})
                body = self._body()
                if body is None:
                    return self._json(400, {"error": "bad json"})
                try:
                    changes = parse_fields(body, ("name", "role", "capBytes"))
                except ValueError as e:
                    return self._json(400, {"error": "bad %s" % e})
                try:
                    user = manager.update_user(m.group(1), changes)
                except ApiError as e:
                    return self._api_error(e)
                return self._json(200, {"user": user})
            self._json(404, {"error": "not found"})

        def do_DELETE(self):
            path = self.path.split("?")[0]
            me = self._auth()
            if me is None:
                return
            m = re.match(r"^/v1/files/([^/]+)$", path)
            if m:
                vid = self._video_id(m.group(1))
                if not vid:
                    return self._json(400, {"error": "bad video id"})
                result = manager.delete_for(me["id"], vid)
                if result == "busy":
                    return self._json(409, {"deleted": False, "error": "still downloading"})
                if result == "missing":
                    return self._json(404, {"deleted": False})
                return self._json(200, {"deleted": True})
            m = ADMIN_TOKEN_RE.match(path)
            if m:
                if me["role"] != "admin":
                    return self._json(403, {"error": "forbidden"})
                try:
                    user = manager.revoke_token(m.group(1))
                except ApiError as e:
                    return self._api_error(e)
                return self._json(200, {"user": user})
            m = ADMIN_USER_RE.match(path)
            if m:
                if me["role"] != "admin":
                    return self._json(403, {"error": "forbidden"})
                try:
                    manager.delete_user(m.group(1))
                except ApiError as e:
                    return self._api_error(e)
                return self._json(200, {"deleted": True})
            self._json(404, {"error": "not found"})

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


def run_cli(config, argv):
    """add-user, revoke-user and reissue-user. Prints tokens once, to the operator's terminal."""
    import argparse

    parser = argparse.ArgumentParser(prog="server.py", description="Manage SmartTube NAS profiles.")
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add-user", help="create a profile and print its token once")
    add.add_argument("name")
    add.add_argument("--admin", action="store_true", help="make the profile an admin")
    for name, help_text in (
        ("revoke-user", "revoke a profile's token; its list is kept"),
        ("reissue-user", "give a profile a new token; the old one stops working"),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("user", help="profile id or name")
    args = parser.parse_args(argv)
    manager = JobManager(config)
    try:
        if args.command == "add-user":
            try:
                fields = parse_fields({"name": args.name}, ("name",))
            except ValueError:
                sys.exit("the name must be 1 to %d characters" % NAME_MAX)
            user, token = manager.create_user(fields["name"], "admin" if args.admin else "user")
            print("Created %s (id %s, role %s)." % (user["name"], user["id"], user["role"]))
            print("Token (shown once): %s" % token)
            if config.public_url:
                print(
                    "Invite link: smarttube://nas?url=%s&token=%s"
                    % (quote(config.public_url, safe=""), quote(token, safe=""))
                )
        elif args.command == "revoke-user":
            pid = manager.find_user(args.user)["id"]
            user = manager.revoke_token(pid)
            print("Revoked the token of %s (id %s). Their list is kept." % (user["name"], user["id"]))
        else:
            pid = manager.find_user(args.user)["id"]
            user, token = manager.reissue_token(pid)
            print("New token for %s (id %s), shown once: %s" % (user["name"], user["id"], token))
    except ApiError as e:
        sys.exit(e.message)
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    config = Config()
    if argv:
        return run_cli(config, argv)
    if not config.token:
        sys.exit("YTDLP_TOKEN is required (a long random string; it becomes the admin token on first start).")
    server = build_server(config)
    threading.Thread(target=server.manager.backfill_metadata, daemon=True).start()
    sys.stderr.write("SmartTube yt-dlp server on %s:%d, data in %s\n" % (config.host, config.port, config.data_dir))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
