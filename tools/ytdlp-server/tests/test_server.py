import base64
import json
import os
import re
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import server  # noqa: E402

FAKE = os.path.join(os.path.dirname(__file__), "fake_ytdlp.py")
TOKEN = "test-token"
GOOD = "dQw4w9WgXcQ"  # 11 chars
BAD_RUN = "FAILxxxxxxx"  # 11 chars, fake yt-dlp fails


def http(base, method, path, body=None, token=TOKEN, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cfg = server.Config(
            {
                "YTDLP_TOKEN": TOKEN,
                "YTDLP_BIN": FAKE,
                "YTDLP_DATA_DIR": cls.tmp.name,
                "YTDLP_PORT": "0",
            }
        )
        cls.cfg = cfg
        cls.srv = server.build_server(cfg)
        cls.base = "http://127.0.0.1:%d" % cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.tmp.cleanup()

    # -- helpers --
    def call(self, method, path, body=None, token=TOKEN, headers=None):
        return http(self.base, method, path, body, token, headers)

    def wait_for(self, vid, want):
        for _ in range(100):
            _, body, _ = self.call("GET", "/v1/jobs/" + vid)
            state = json.loads(body)
            if state["status"] == want:
                return state
            time.sleep(0.05)
        self.fail("job %s never reached %s (last %s)" % (vid, want, state))

    # -- tests --
    def test_health_needs_no_token(self):
        code, body, _ = self.call("GET", "/v1/health", token=None)
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["ytdlpVersion"], "2099.01.01")
        self.assertEqual(json.loads(body)["apiVersion"], 4)
        self.assertIs(json.loads(body)["ok"], True)

    def test_requires_token(self):
        self.assertEqual(self.call("POST", "/v1/jobs", {"videoId": GOOD}, token=None)[0], 401)
        self.assertEqual(self.call("POST", "/v1/jobs", {"videoId": GOOD}, token="wrong")[0], 401)
        self.assertEqual(self.call("GET", "/v1/jobs/" + GOOD, token="wrong")[0], 401)

    def test_rejects_bad_video_ids(self):
        for bad in ["short", "../../etc/passwd", "a" * 12, "bad id!!!!!!", ""]:
            code, _, _ = self.call("POST", "/v1/jobs", {"videoId": bad})
            self.assertEqual(code, 400, bad)
        self.assertEqual(self.call("GET", "/v1/files/..%2Fsecret.mp4")[0], 400)

    def test_rejects_bad_max_height(self):
        self.assertEqual(self.call("POST", "/v1/jobs", {"videoId": GOOD, "maxHeight": 5})[0], 400)
        self.assertEqual(self.call("POST", "/v1/jobs", {"videoId": GOOD, "maxHeight": "hd"})[0], 400)

    def test_job_lifecycle_file_range_and_delete(self):
        code, body, _ = self.call("POST", "/v1/jobs", {"videoId": GOOD, "maxHeight": 720})
        self.assertEqual(code, 202)
        again = self.call("POST", "/v1/jobs", {"videoId": GOOD})
        self.assertEqual(again[0], 202)  # idempotent
        state = self.wait_for(GOOD, "ready")
        self.assertEqual(state["fileSize"], 1024)

        code, body, headers = self.call("GET", "/v1/files/%s.mp4" % GOOD)
        self.assertEqual((code, len(body)), (200, 1024))
        self.assertEqual(headers["Accept-Ranges"], "bytes")

        code, body, headers = self.call("GET", "/v1/files/%s.mp4" % GOOD, headers={"Range": "bytes=10-19"})
        self.assertEqual(code, 206)
        self.assertEqual(body, bytes(range(10, 20)))
        self.assertEqual(headers["Content-Range"], "bytes 10-19/1024")

        code, body, _ = self.call("GET", "/v1/files/%s.mp4" % GOOD, headers={"Range": "bytes=-4"})
        self.assertEqual((code, body), (206, bytes([252, 253, 254, 255])))
        code, _, _ = self.call("GET", "/v1/files/%s.mp4" % GOOD, headers={"Range": "bytes=5000-"})
        self.assertEqual(code, 416)

        self.assertEqual(self.call("DELETE", "/v1/files/" + GOOD)[0], 200)
        self.assertEqual(self.call("GET", "/v1/jobs/" + GOOD)[0], 404)
        self.assertEqual(self.call("DELETE", "/v1/files/" + GOOD)[0], 404)

    def test_failed_job_reports_error(self):
        self.assertEqual(self.call("POST", "/v1/jobs", {"videoId": BAD_RUN})[0], 202)
        state = self.wait_for(BAD_RUN, "failed")
        self.assertIn("Video unavailable", state["error"])

    def test_unknown_job_is_404(self):
        self.assertEqual(self.call("GET", "/v1/jobs/AAAAAAAAAAA")[0], 404)

    # -- metadata sidecar (Task 1.1) --
    def sidecar(self, vid):
        with open(os.path.join(self.cfg.data_dir, vid + ".json")) as f:
            return json.load(f)

    def test_finished_job_writes_sidecar_with_metadata_and_keep(self):
        vid = "METAvideo01"
        meta = {
            "videoId": vid,
            "title": "A title",
            "channelTitle": "A channel",
            "duration": 61.5,
            "thumbnailURL": "https://example.com/t.jpg",
            "keep": True,
        }
        self.assertEqual(self.call("POST", "/v1/jobs", meta)[0], 202)
        self.wait_for(vid, "ready")
        side = self.sidecar(vid)  # written before "ready" was seen
        self.assertEqual(side["videoId"], vid)
        self.assertEqual(side["title"], "A title")
        self.assertEqual(side["channelTitle"], "A channel")
        self.assertEqual(side["duration"], 61.5)
        self.assertEqual(side["thumbnailURL"], "https://example.com/t.jpg")
        self.assertIs(side["keep"], True)
        self.assertEqual(side["fileSize"], 1024)
        self.assertRegex(side["downloadedAt"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_job_state_does_not_leak_metadata(self):
        vid = "METAleak001"
        self.call("POST", "/v1/jobs", {"videoId": vid, "title": "Secret title", "keep": False})
        self.wait_for(vid, "ready")
        _, body, _ = self.call("GET", "/v1/jobs/" + vid)
        state = json.loads(body)
        self.assertEqual(set(state), {"status", "progress", "fileSize"})
        self.assertNotIn(b"Secret title", body)

    def test_omitted_metadata_still_gives_valid_sidecar(self):
        vid = "PLAINvideo1"
        self.call("POST", "/v1/jobs", {"videoId": vid})
        self.wait_for(vid, "ready")
        side = self.sidecar(vid)
        self.assertEqual(side["title"], "")
        self.assertEqual(side["channelTitle"], "")
        self.assertIsNone(side["duration"])
        self.assertIsNone(side["thumbnailURL"])
        self.assertIs(side["keep"], True)
        self.assertEqual(side["fileSize"], 1024)

    def test_bad_metadata_is_400(self):
        bad_bodies = [
            {"title": "x" * 301},
            {"title": 5},
            {"channelTitle": "x" * 201},
            {"duration": "5"},
            {"duration": True},
            {"duration": -1},
            {"thumbnailURL": "http://example.com/t.jpg"},
            {"thumbnailURL": "https://example.com/" + "x" * 490},
            {"keep": "yes"},
            {"keep": 1},
        ]
        for extra in bad_bodies:
            body = dict(extra, videoId=GOOD)
            self.assertEqual(self.call("POST", "/v1/jobs", body)[0], 400, extra)

    def test_first_writer_wins(self):
        vid = "FIRSTwrite1"
        self.call("POST", "/v1/jobs", {"videoId": vid, "title": "first"})
        self.call("POST", "/v1/jobs", {"videoId": vid, "title": "second"})
        self.wait_for(vid, "ready")
        self.call("POST", "/v1/jobs", {"videoId": vid, "title": "third"})
        self.assertEqual(self.sidecar(vid)["title"], "first")

    def test_legacy_file_gets_backfilled_sidecar(self):
        vid = "LEGACYxxxxx"
        path = os.path.join(self.cfg.data_dir, vid + ".mp4")
        with open(path, "wb") as f:
            f.write(b"x" * 10)
        os.utime(path, (1700000000, 1700000000))
        self.addCleanup(lambda: [os.remove(p) for p in (path, path[:-4] + ".json") if os.path.exists(p)])
        self.assertEqual(self.call("POST", "/v1/jobs", {"videoId": vid, "title": "Legacy", "keep": False})[0], 202)
        side = self.sidecar(vid)
        self.assertEqual(side["title"], "Legacy")
        self.assertIs(side["keep"], False)
        self.assertEqual(side["downloadedAt"], "2023-11-14T22:13:20Z")
        self.assertEqual(side["fileSize"], 10)


class LibraryTests(unittest.TestCase):
    """Each test gets its own server and data dir, so no other test's files show up here."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        cfg = server.Config(
            {"YTDLP_TOKEN": TOKEN, "YTDLP_BIN": FAKE, "YTDLP_DATA_DIR": self.tmp.name, "YTDLP_PORT": "0"}
        )
        self.srv = server.build_server(cfg)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.shutdown)
        self.addCleanup(self.srv.server_close)

    def add(self, vid, downloaded_at, keep=True, title=""):
        """Writes a finished download (an .mp4, its sidecar, and admin's ownership) into the data dir."""
        base = os.path.join(self.tmp.name, vid)
        with open(base + ".mp4", "wb") as f:
            f.write(b"x" * 10)
        self.write_json(vid, {
            "videoId": vid, "title": title, "channelTitle": "", "duration": None,
            "thumbnailURL": None, "keep": keep, "downloadedAt": downloaded_at, "fileSize": 10,
        })
        self.srv.manager.grant("admin", vid, keep, downloaded_at)

    def write_json(self, vid, obj):
        with open(os.path.join(self.tmp.name, vid + ".json"), "w") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))

    def library(self, query="", token=TOKEN):
        code, body, _ = http(self.base, "GET", "/v1/library" + query, token=token)
        return code, json.loads(body)

    def ids(self, page):
        return [item["videoId"] for item in page["items"]]

    def test_two_pages_no_overlap(self):
        for i in range(1, 6):
            self.add("LIBVIDEO00%d" % i, "2026-01-0%dT00:00:00Z" % i)
        code, p1 = self.library("?limit=2")
        self.assertEqual((code, self.ids(p1)), (200, ["LIBVIDEO005", "LIBVIDEO004"]))
        self.assertIsNotNone(p1["nextCursor"])
        code, p2 = self.library("?limit=2&cursor=" + p1["nextCursor"])
        self.assertEqual(self.ids(p2), ["LIBVIDEO003", "LIBVIDEO002"])
        code, p3 = self.library("?limit=2&cursor=" + p2["nextCursor"])
        self.assertEqual(self.ids(p3), ["LIBVIDEO001"])
        self.assertIsNone(p3["nextCursor"])

    def test_download_between_pages_causes_no_duplicate_or_skip(self):
        for i in range(1, 6):
            self.add("LIBVIDEO00%d" % i, "2026-01-0%dT00:00:00Z" % i)
        _, p1 = self.library("?limit=2")
        self.add("LIBVIDEO006", "2026-01-06T00:00:00Z")  # newer than everything, lands on top
        _, p2 = self.library("?limit=2&cursor=" + p1["nextCursor"])
        self.assertEqual(self.ids(p2), ["LIBVIDEO003", "LIBVIDEO002"])
        self.assertFalse(set(self.ids(p1)) & set(self.ids(p2)))

    def test_same_timestamp_is_ordered_by_video_id(self):
        self.add("TIEVIDEO0AA", "2026-02-01T00:00:00Z")
        self.add("TIEVIDEO0BB", "2026-02-01T00:00:00Z")
        _, p1 = self.library("?limit=1")
        _, p2 = self.library("?limit=1&cursor=" + p1["nextCursor"])
        self.assertEqual(self.ids(p1) + self.ids(p2), ["TIEVIDEO0BB", "TIEVIDEO0AA"])
        self.assertIsNone(p2["nextCursor"])

    def test_empty_library(self):
        self.assertEqual(self.library(), (200, {"items": [], "nextCursor": None}))

    def test_items_carry_sidecar_fields_and_keep(self):
        self.add("LIBVIDEO001", "2026-01-01T00:00:00Z", keep=False, title="Kept?")
        _, page = self.library()
        item = page["items"][0]
        self.assertEqual((item["title"], item["keep"], item["fileSize"]), ("Kept?", False, 10))

    def test_sidecar_without_mp4_is_left_out(self):
        self.write_json("ORPHANjson1", {"videoId": "ORPHANjson1", "downloadedAt": "2026-01-01T00:00:00Z", "keep": True})
        self.assertEqual(self.library()[1]["items"], [])

    def test_corrupt_and_mismatched_sidecars_are_skipped(self):
        self.add("LIBVIDEO001", "2026-01-01T00:00:00Z")
        self.add("BROKENjson1", "2026-01-02T00:00:00Z")
        self.write_json("BROKENjson1", "{not json")
        self.add("MISMATCH001", "2026-01-03T00:00:00Z")
        self.write_json("MISMATCH001", {"videoId": "LIBVIDEO001", "downloadedAt": "2026-01-03T00:00:00Z", "keep": True})
        code, page = self.library()
        self.assertEqual((code, self.ids(page)), (200, ["LIBVIDEO001"]))

    def test_bad_limit_is_400(self):
        for query in ["?limit=0", "?limit=201", "?limit=abc", "?limit=-1", "?limit=1.5"]:
            self.assertEqual(self.library(query)[0], 400, query)

    def test_bad_cursor_is_400(self):
        def enc(text):
            return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")

        for cursor in ["!!!", enc("garbage"), enc("2026-01-01T00:00:00Z|bad id"), enc("2026-01-01|LIBVIDEO001")]:
            self.assertEqual(self.library("?cursor=" + cursor)[0], 400, cursor)

    def test_library_needs_token(self):
        self.assertEqual(self.library(token=None)[0], 401)

    # -- keep toggle (Task 1.4) --
    def set_keep(self, vid, body=None, token=TOKEN, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(self.base + "/v1/files/%s/keep" % vid, data=data, method="PUT")
        if token:
            req.add_header("Authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def sidecar_keep(self, vid):
        """The admin's keep flag for a video (ownership is the source of truth)."""
        return self.srv.manager.owner_record("admin", vid)["keep"]

    def test_keep_toggle_sets_true_and_false(self):
        self.add("KEEPvideo01", "2026-01-01T00:00:00Z", keep=True)
        self.assertEqual(self.set_keep("KEEPvideo01", {"keep": False}), (200, {"ok": True, "keep": False}))
        self.assertIs(self.sidecar_keep("KEEPvideo01"), False)
        self.assertEqual(self.set_keep("KEEPvideo01", {"keep": True}), (200, {"ok": True, "keep": True}))
        self.assertIs(self.sidecar_keep("KEEPvideo01"), True)
        self.assertEqual(self.library()[1]["items"][0]["keep"], True)

    def test_keep_unknown_id_is_404(self):
        self.assertEqual(self.set_keep("NOSUCHvid00", {"keep": True})[0], 404)

    def test_keep_bad_body_is_400(self):
        self.add("KEEPbadbod1", "2026-01-01T00:00:00Z")
        self.assertEqual(self.set_keep("KEEPbadbod1", raw=b"{not json")[0], 400)
        for body in [{"keep": "yes"}, {"keep": 1}, {"keep": None}, {}, ["keep"]]:
            self.assertEqual(self.set_keep("KEEPbadbod1", body)[0], 400, body)
        self.assertIs(self.sidecar_keep("KEEPbadbod1"), True)

    def test_keep_needs_token(self):
        self.add("KEEPnoauth01", "2026-01-01T00:00:00Z")
        self.assertEqual(self.set_keep("KEEPnoauth01", {"keep": False}, token=None)[0], 401)
        self.assertIs(self.sidecar_keep("KEEPnoauth01"), True)

    # -- delete (Task 1.5) --
    def delete(self, vid):
        code, body, _ = http(self.base, "DELETE", "/v1/files/" + vid)
        return code, json.loads(body)

    def exists(self, name):
        return os.path.exists(os.path.join(self.tmp.name, name))

    def test_delete_removes_mp4_and_sidecar(self):
        self.add("DELvideo001", "2026-01-01T00:00:00Z")
        self.assertEqual(self.delete("DELvideo001"), (200, {"deleted": True}))
        self.assertFalse(self.exists("DELvideo001.mp4"))
        self.assertFalse(self.exists("DELvideo001.json"))

    def test_delete_removes_orphan_sidecar(self):
        self.write_json("DELorphan01", {"videoId": "DELorphan01", "downloadedAt": "2026-01-01T00:00:00Z", "keep": True})
        self.srv.manager.grant("admin", "DELorphan01", True)  # an owner with no file: last owner leaves
        self.assertEqual(self.delete("DELorphan01"), (200, {"deleted": True}))
        self.assertFalse(self.exists("DELorphan01.json"))

    def test_delete_running_or_queued_job_is_409_and_removes_nothing(self):
        for status in ("running", "queued"):
            vid = "DELbusy%s1" % status[:3]
            self.add(vid, "2026-01-01T00:00:00Z")
            self.srv.manager.jobs[vid] = {"status": status, "progress": 0.5}
            code, body = self.delete(vid)
            self.assertEqual((code, body["deleted"]), (409, False), status)
            self.assertTrue(self.exists(vid + ".mp4"))
            self.assertTrue(self.exists(vid + ".json"))
            self.srv.manager.jobs.pop(vid)

    def test_delete_unknown_id_is_404_with_deleted_false(self):
        self.assertEqual(self.delete("DELnothing1"), (404, {"deleted": False}))


class StorageTests(unittest.TestCase):
    """Unkept cap, eviction, legacy migration and startup cleanup (Task 1.6)."""

    CAP = 25  # bytes: three 10-byte unkept files are over it, two are under it

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cfg = server.Config(
            {
                "YTDLP_TOKEN": TOKEN,
                "YTDLP_BIN": FAKE,
                "YTDLP_DATA_DIR": self.tmp.name,
                "YTDLP_PORT": "0",
                "YTDLP_UNKEPT_CAP_GB": repr(self.CAP / 1024**3),
            }
        )
        self.manager = server.JobManager(self.cfg)

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    def add(self, vid, downloaded_at, keep=False, size=10):
        with open(self.path(vid + ".mp4"), "wb") as f:
            f.write(b"x" * size)
        with open(self.path(vid + ".json"), "w") as f:
            json.dump(
                {"videoId": vid, "title": "", "channelTitle": "", "duration": None, "thumbnailURL": None,
                 "keep": keep, "downloadedAt": downloaded_at, "fileSize": size},
                f,
            )
        self.manager.grant("admin", vid, keep, downloaded_at)

    def has_mp4(self, vid):
        return os.path.exists(self.path(vid + ".mp4"))

    def test_three_unkept_over_cap_evict_oldest_first(self):
        self.add("EVICTvid001", "2026-01-01T00:00:00Z")
        self.add("EVICTvid002", "2026-01-02T00:00:00Z")
        self.add("EVICTvid003", "2026-01-03T00:00:00Z")
        self.assertEqual(self.manager.evict(), ["EVICTvid001"])
        self.assertFalse(self.has_mp4("EVICTvid001"))
        self.assertFalse(os.path.exists(self.path("EVICTvid001.json")))
        self.assertTrue(self.has_mp4("EVICTvid002"))
        self.assertTrue(self.has_mp4("EVICTvid003"))
        self.assertEqual(self.manager.evict(), [])

    def test_kept_files_are_never_evicted(self):
        self.add("KEEPvid0001", "2026-01-00T00:00:00Z", keep=True, size=500)  # oldest, huge, kept
        self.add("EVICTvid001", "2026-01-01T00:00:00Z")
        self.add("EVICTvid002", "2026-01-02T00:00:00Z")
        self.add("EVICTvid003", "2026-01-03T00:00:00Z")
        self.manager.evict()
        self.assertTrue(self.has_mp4("KEEPvid0001"))
        self.assertTrue(os.path.exists(self.path("KEEPvid0001.json")))

    def test_under_cap_evicts_nothing(self):
        self.add("EVICTvid001", "2026-01-01T00:00:00Z")
        self.add("EVICTvid002", "2026-01-02T00:00:00Z")
        self.assertEqual(self.manager.evict(), [])

    def test_running_job_file_is_skipped(self):
        self.add("RUNvid00001", "2026-01-01T00:00:00Z")  # oldest, but its job is running
        self.manager.jobs["RUNvid00001"] = {"status": "running", "progress": 0.5}
        self.add("EVICTvid002", "2026-01-02T00:00:00Z")
        self.add("EVICTvid003", "2026-01-03T00:00:00Z")
        self.assertEqual(self.manager.evict(), ["EVICTvid002"])
        self.assertTrue(self.has_mp4("RUNvid00001"))

    def test_skip_protects_the_file_that_just_finished(self):
        self.add("EVICTvid001", "2026-01-01T00:00:00Z")
        self.add("EVICTvid002", "2026-01-02T00:00:00Z")
        self.add("EVICTvid003", "2026-01-03T00:00:00Z")
        self.assertEqual(self.manager.evict(skip="EVICTvid001"), ["EVICTvid002"])
        self.assertTrue(self.has_mp4("EVICTvid001"))

    def test_legacy_mp4_is_migrated_as_unkept_and_counted(self):
        path = self.path("LEGACYxxxxx.mp4")
        with open(path, "wb") as f:
            f.write(b"x" * 10)
        os.utime(path, (1700000000, 1700000000))
        self.manager.startup_cleanup()
        with open(self.path("LEGACYxxxxx.json")) as f:
            side = json.load(f)
        self.assertIs(side["keep"], False)
        self.assertEqual(side["downloadedAt"], "2023-11-14T22:13:20Z")
        self.assertEqual((side["title"], side["channelTitle"]), ("", ""))

    def test_startup_removes_orphans_and_stale_partials_only(self):
        with open(self.path("ORPHANvid01.json"), "w") as f:
            f.write("{}")
        old = time.time() - 7200
        for name in ["STALEvid001.part", "STALEvid001.f137.mp4", "STALEvid001.tmp"]:
            with open(self.path(name), "wb") as f:
                f.write(b"x")
            os.utime(self.path(name), (old, old))
        with open(self.path("FRESHvid001.part"), "wb") as f:
            f.write(b"x")
        self.manager.startup_cleanup()
        self.assertFalse(os.path.exists(self.path("ORPHANvid01.json")))
        for name in ["STALEvid001.part", "STALEvid001.f137.mp4", "STALEvid001.tmp"]:
            self.assertFalse(os.path.exists(self.path(name)), name)
        self.assertTrue(os.path.exists(self.path("FRESHvid001.part")))

    def test_backfill_fills_empty_metadata_and_keeps_everything_else(self):
        self.add("BACKFILLvid", "2026-01-02T00:00:00Z", keep=True, size=7)
        self.assertEqual(self.manager.backfill_metadata(), 1)
        with open(self.path("BACKFILLvid.json")) as f:
            side = json.load(f)
        self.assertEqual((side["title"], side["channelTitle"]), ("Title BACKFILLvid", "Channel"))
        self.assertEqual((side["duration"], side["thumbnailURL"]), (42, "https://t.test/BACKFILLvid"))
        self.assertEqual((side["keep"], side["downloadedAt"], side["fileSize"]), (True, "2026-01-02T00:00:00Z", 7))
        self.assertEqual(self.manager.backfill_metadata(), 0)  # nothing left to fill

    def test_backfill_skips_a_video_yt_dlp_cannot_describe(self):
        self.add("FAILvid0001", "2026-01-02T00:00:00Z")
        self.add("GOODvid0001", "2026-01-03T00:00:00Z")
        self.assertEqual(self.manager.backfill_metadata(), 1)
        with open(self.path("FAILvid0001.json")) as f:
            self.assertEqual(json.load(f)["title"], "")  # left for the next start
        with open(self.path("GOODvid0001.json")) as f:
            self.assertEqual(json.load(f)["title"], "Title GOODvid0001")

    def test_startup_evict_keeps_kept_file(self):
        self.add("KEEPvid0001", "2026-01-00T00:00:00Z", keep=True, size=500)
        server.build_server(self.cfg).server_close()  # runs startup_cleanup
        self.assertTrue(self.has_mp4("KEEPvid0001"))


class MultiUserTests(unittest.TestCase):
    """Profiles, ownership, dedup, per-profile keep, delete, cap, admin API and CLI (plan item 7).
    Each test gets its own server and data dir. Fake runs are counted in a log file."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        logdir = tempfile.TemporaryDirectory()
        self.addCleanup(logdir.cleanup)
        self.log = os.path.join(logdir.name, "runs.log")
        patcher = unittest.mock.patch.dict(os.environ, {"FAKE_YTDLP_LOG": self.log})
        patcher.start()
        self.addCleanup(patcher.stop)
        cfg = server.Config(
            {"YTDLP_TOKEN": TOKEN, "YTDLP_BIN": FAKE, "YTDLP_DATA_DIR": self.tmp.name, "YTDLP_PORT": "0"}
        )
        self.srv = server.build_server(cfg)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.shutdown)
        self.addCleanup(self.srv.server_close)

    # -- helpers --
    def call(self, method, path, body=None, token=TOKEN):
        return http(self.base, method, path, body, token)

    def jcall(self, method, path, body=None, token=TOKEN):
        code, raw, _ = http(self.base, method, path, body, token)
        return code, json.loads(raw) if raw else None

    def make_user(self, name, admin=False):
        code, data = self.jcall("POST", "/v1/admin/users", {"name": name, "role": "admin" if admin else "user"})
        self.assertEqual(code, 201)
        return data["user"]["id"], data["token"]

    def download_count(self, vid):
        if not os.path.exists(self.log):
            return 0
        with open(self.log) as f:
            return sum(1 for line in f if line.split() == ["download", vid])

    def wait_ready(self, token, vid):
        state = None
        for _ in range(200):
            code, state = self.jcall("GET", "/v1/jobs/" + vid, token=token)
            self.assertEqual(code, 200)
            if state["status"] == "ready":
                return state
            self.assertNotEqual(state["status"], "failed", state)
            time.sleep(0.05)
        self.fail("job %s never became ready (last %s)" % (vid, state))

    def fetch(self, token, vid, keep=True):
        code, _ = self.jcall("POST", "/v1/jobs", {"videoId": vid, "keep": keep}, token=token)
        self.assertEqual(code, 202)
        return self.wait_ready(token, vid)

    def library(self, token):
        code, page = self.jcall("GET", "/v1/library?limit=200", token=token)
        self.assertEqual(code, 200)
        return page["items"]

    def ids(self, token):
        return [item["videoId"] for item in self.library(token)]

    def item(self, token, vid):
        return next(i for i in self.library(token) if i["videoId"] == vid)

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    # -- auth and identity --
    def test_missing_or_wrong_token_is_401(self):
        cases = [
            ("GET", "/v1/me", None),
            ("GET", "/v1/library", None),
            ("POST", "/v1/jobs", {"videoId": GOOD}),
            ("GET", "/v1/admin/users", None),
            ("PATCH", "/v1/me", {"capBytes": 1}),
            ("DELETE", "/v1/files/" + GOOD, None),
        ]
        for method, path, body in cases:
            for token in (None, "wrong"):
                code, raw, _ = self.call(method, path, body, token=token)
                self.assertEqual((code, json.loads(raw)), (401, {"error": "unauthorised"}), path)

    def test_me_reports_identity_without_the_token_hash(self):
        code, me = self.jcall("GET", "/v1/me")
        self.assertEqual((code, me["id"], me["name"], me["role"]), (200, "admin", "Admin", "admin"))
        self.assertEqual(set(me), {"id", "name", "role", "capBytes"})
        uid, token = self.make_user("Sam")
        code, me = self.jcall("GET", "/v1/me", token=token)
        self.assertEqual((code, me["id"], me["role"]), (200, uid, "user"))
        self.assertNotIn("tokenHash", json.dumps(me))

    def test_health_stays_public(self):
        self.assertEqual(self.call("GET", "/v1/health", token=None)[0], 200)

    # -- dedup, lists, keep --
    def test_second_user_gets_the_existing_file_without_a_ytdlp_run(self):
        _, a = self.make_user("Ann")
        _, b = self.make_user("Ben")
        self.fetch(a, GOOD)
        self.assertEqual(self.download_count(GOOD), 1)
        code, body = self.jcall("POST", "/v1/jobs", {"videoId": GOOD, "keep": False}, token=b)
        self.assertEqual((code, body["status"]), (202, "ready"))
        self.assertEqual(self.download_count(GOOD), 1)
        self.assertEqual(self.ids(b), [GOOD])
        self.assertIs(self.item(b, GOOD)["keep"], False)

    def test_lists_are_disjoint_and_keep_is_per_profile(self):
        _, a = self.make_user("Ann")
        _, b = self.make_user("Ben")
        v1, v2 = "LISTone0001", "LISTtwo0002"
        self.fetch(a, v1)
        self.fetch(b, v2)
        self.assertEqual((self.ids(a), self.ids(b)), ([v1], [v2]))
        self.jcall("POST", "/v1/jobs", {"videoId": v1, "keep": False}, token=b)  # shared, Ben unkept
        self.assertIs(self.item(a, v1)["keep"], True)
        self.assertIs(self.item(b, v1)["keep"], False)
        self.assertEqual(self.call("PUT", "/v1/files/%s/keep" % v1, {"keep": True}, token=b)[0], 200)
        self.assertIs(self.item(b, v1)["keep"], True)
        self.assertIs(self.item(a, v1)["keep"], True)

    def test_non_owner_gets_404_on_file_and_job_routes(self):
        _, a = self.make_user("Ann")
        _, c = self.make_user("Cal")
        self.fetch(a, GOOD)
        self.assertEqual(self.call("GET", "/v1/files/%s.mp4" % GOOD, token=c)[0], 404)
        self.assertEqual(self.call("GET", "/v1/jobs/" + GOOD, token=c)[0], 404)
        self.assertEqual(self.call("GET", "/v1/files/%s.mp4" % GOOD, token=a)[0], 200)

    def test_request_for_an_in_flight_video_joins_the_job(self):
        slow = "SLOWvideo01"
        _, a = self.make_user("Ann")
        _, b = self.make_user("Ben")
        self.assertEqual(self.jcall("POST", "/v1/jobs", {"videoId": slow}, token=a)[0], 202)
        code, body = self.jcall("POST", "/v1/jobs", {"videoId": slow}, token=b)
        self.assertEqual(code, 202)
        self.assertIn(body["status"], ("queued", "running"))
        self.wait_ready(a, slow)
        self.wait_ready(b, slow)
        self.assertEqual(self.download_count(slow), 1)
        self.assertEqual((self.ids(a), self.ids(b)), ([slow], [slow]))

    # -- delete and cap --
    def test_delete_removes_only_the_callers_ownership(self):
        _, a = self.make_user("Ann")
        _, b = self.make_user("Ben")
        self.fetch(a, GOOD)
        self.jcall("POST", "/v1/jobs", {"videoId": GOOD}, token=b)
        self.assertEqual(self.jcall("DELETE", "/v1/files/" + GOOD, token=a), (200, {"deleted": True}))
        self.assertTrue(os.path.exists(self.path(GOOD + ".mp4")))  # Ben still owns it
        self.assertEqual((self.ids(a), self.ids(b)), ([], [GOOD]))
        self.assertEqual(self.call("GET", "/v1/files/%s.mp4" % GOOD, token=a)[0], 404)
        self.assertEqual(self.call("DELETE", "/v1/files/" + GOOD, token=a)[0], 404)
        self.assertEqual(self.jcall("DELETE", "/v1/files/" + GOOD, token=b)[0], 200)
        self.assertFalse(os.path.exists(self.path(GOOD + ".mp4")))
        self.assertFalse(os.path.exists(self.path(GOOD + ".json")))

    def test_deleting_a_user_keeps_shared_files_until_the_last_owner_leaves(self):
        uid_a, a = self.make_user("Ann")
        uid_b, b = self.make_user("Ben")
        self.fetch(a, GOOD)
        self.jcall("POST", "/v1/jobs", {"videoId": GOOD}, token=b)
        self.assertEqual(self.jcall("DELETE", "/v1/admin/users/" + uid_b)[0], 200)
        self.assertTrue(os.path.exists(self.path(GOOD + ".mp4")))
        self.assertEqual(self.ids(a), [GOOD])
        self.assertEqual(self.jcall("DELETE", "/v1/admin/users/" + uid_a)[0], 200)
        self.assertFalse(os.path.exists(self.path(GOOD + ".mp4")))

    def test_cap_evicts_only_that_profiles_entries_and_counts_shared_files_in_full(self):
        _, a = self.make_user("Ann")
        uid_b, b = self.make_user("Ben")
        v1, v2 = "CAPvideo001", "CAPvideo002"  # 1024 bytes each; the cap is 2000 bytes
        self.fetch(a, v1, keep=False)
        self.fetch(a, v2, keep=False)
        self.assertEqual(self.jcall("PATCH", "/v1/admin/users/" + uid_b, {"capBytes": 2000})[0], 200)
        self.jcall("POST", "/v1/jobs", {"videoId": v1, "keep": False}, token=b)  # shared: 1024 for Ben
        self.assertEqual(self.ids(b), [v1])
        self.jcall("POST", "/v1/jobs", {"videoId": v2, "keep": False}, token=b)  # Ben: 2048, over the cap
        self.assertEqual(self.ids(b), [v2])  # Ben's own oldest entry went, not Ann's
        self.assertEqual(sorted(self.ids(a)), [v1, v2])
        self.assertTrue(os.path.exists(self.path(v1 + ".mp4")))  # Ann still owns it

    def test_user_cannot_edit_own_cap(self):
        _, b = self.make_user("Ben")
        before = self.jcall("GET", "/v1/me", token=b)[1]["capBytes"]
        self.assertEqual(self.jcall("PATCH", "/v1/me", {"capBytes": 5}, token=b)[0], 404)
        self.assertEqual(self.jcall("PATCH", "/v1/admin/users/ben", {"capBytes": 5}, token=b)[0], 403)
        self.assertEqual(self.jcall("GET", "/v1/me", token=b)[1]["capBytes"], before)

    # -- admin API --
    def test_users_cannot_call_admin_routes(self):
        _, b = self.make_user("Ben")
        self.assertEqual(self.jcall("GET", "/v1/admin/users", token=b)[0], 403)
        self.assertEqual(self.jcall("POST", "/v1/admin/users", {"name": "X"}, token=b)[0], 403)
        self.assertEqual(self.jcall("PATCH", "/v1/admin/users/admin", {"capBytes": 1}, token=b)[0], 403)
        self.assertEqual(self.call("DELETE", "/v1/admin/users/admin", token=b)[0], 403)
        self.assertEqual(self.call("POST", "/v1/admin/users/admin/token", token=b)[0], 403)
        self.assertEqual(self.call("DELETE", "/v1/admin/users/admin/token", token=b)[0], 403)
        self.assertEqual(len(self.jcall("GET", "/v1/admin/users")[1]["users"]), 2)  # nothing changed

    def test_admin_list_shows_counts_and_sizes_but_no_titles(self):
        _, b = self.make_user("Ben")
        self.jcall("POST", "/v1/jobs", {"videoId": GOOD, "title": "Secret title", "keep": False}, token=b)
        self.wait_ready(b, GOOD)
        code, raw, _ = self.call("GET", "/v1/admin/users")
        self.assertEqual(code, 200)
        self.assertNotIn(b"Secret title", raw)
        ben = next(u for u in json.loads(raw)["users"] if u["name"] == "Ben")
        self.assertEqual((ben["videoCount"], ben["totalBytes"], ben["unkeptBytes"]), (1, 1024, 1024))
        self.assertNotIn("tokenHash", raw.decode())

    def test_last_admin_cannot_be_deleted_or_demoted(self):
        self.assertEqual(self.jcall("PATCH", "/v1/admin/users/admin", {"role": "user"})[0], 409)
        self.assertEqual(self.call("DELETE", "/v1/admin/users/admin")[0], 409)
        uid2, t2 = self.make_user("Second", admin=True)
        self.assertEqual(self.jcall("PATCH", "/v1/admin/users/admin", {"role": "user"})[0], 200)
        # Second is now the only admin
        self.assertEqual(self.jcall("PATCH", "/v1/admin/users/" + uid2, {"role": "user"}, token=t2)[0], 409)
        self.assertEqual(self.call("DELETE", "/v1/admin/users/" + uid2, token=t2)[0], 409)

    def test_revoked_token_stops_working_at_once_and_reissue_replaces_it(self):
        uid, token = self.make_user("Sam")
        self.fetch(token, GOOD)
        self.assertEqual(self.call("GET", "/v1/me", token=token)[0], 200)
        code, body = self.jcall("DELETE", "/v1/admin/users/%s/token" % uid)
        self.assertEqual(code, 200)
        self.assertIs(body["user"]["hasToken"], False)
        self.assertEqual(self.call("GET", "/v1/me", token=token)[0], 401)
        self.assertEqual(self.call("GET", "/v1/library", token=token)[0], 401)
        new = self.jcall("POST", "/v1/admin/users/%s/token" % uid)[1]["token"]
        self.assertEqual(self.call("GET", "/v1/me", token=token)[0], 401)
        self.assertEqual(self.call("GET", "/v1/me", token=new)[0], 200)
        self.assertEqual(self.ids(new), [GOOD])  # the list is untouched

    def test_admin_page_is_served_without_cookies(self):
        code, raw, headers = self.call("GET", "/admin", token=None)
        self.assertEqual(code, 200)
        self.assertIn("text/html", headers["Content-Type"])
        html = raw.decode()
        self.assertIn("sessionStorage", html)
        self.assertNotIn("document.cookie", html)
        self.assertIn("smarttube://nas?url=", html)

    # -- migration and CLI --
    def test_migration_is_idempotent_and_gives_existing_downloads_to_admin_once(self):
        cfg_env = {"YTDLP_TOKEN": "migrate-token", "YTDLP_BIN": FAKE, "YTDLP_PORT": "0"}
        with tempfile.TemporaryDirectory() as data:
            for vid, keep, day in (("MIGvideo001", True, 1), ("MIGvideo002", False, 2)):
                with open(os.path.join(data, vid + ".mp4"), "wb") as f:
                    f.write(b"x" * 10)
                with open(os.path.join(data, vid + ".json"), "w") as f:
                    json.dump({"videoId": vid, "title": "", "channelTitle": "", "duration": None,
                               "thumbnailURL": None, "keep": keep,
                               "downloadedAt": "2026-01-0%dT00:00:00Z" % day, "fileSize": 10}, f)
            cfg = server.Config(dict(cfg_env, YTDLP_DATA_DIR=data))

            first = server.JobManager(cfg)
            first.startup_cleanup()
            self.assertIs(first.owner_record("admin", "MIGvideo001")["keep"], True)
            self.assertIs(first.owner_record("admin", "MIGvideo002")["keep"], False)

            second = server.JobManager(cfg)  # restart: nothing changes
            second.startup_cleanup()
            self.assertEqual(set(second.owners["admin"]), {"MIGvideo001", "MIGvideo002"})
            self.assertEqual(len(second.profiles), 1)

            _, ben_token = second.create_user("Ben", "user")
            ben_id = second.authenticate(ben_token)["id"]
            second.grant(ben_id, "MIGvideo001", True)
            self.assertEqual(second.delete_for("admin", "MIGvideo001"), "deleted")

            third = server.JobManager(cfg)  # restart again: the admin's removal is not undone
            third.startup_cleanup()
            self.assertNotIn("MIGvideo001", third.owners["admin"])
            self.assertIn("MIGvideo001", third.owners[ben_id])
            self.assertTrue(os.path.exists(os.path.join(data, "MIGvideo001.mp4")))
            self.assertEqual(third.authenticate("migrate-token")["id"], "admin")
            self.assertEqual(len(third.profiles), 2)

    def test_cli_add_revoke_and_reissue(self):
        import contextlib
        import io

        with tempfile.TemporaryDirectory() as data:
            cfg = server.Config(
                {"YTDLP_TOKEN": "cli-admin", "YTDLP_DATA_DIR": data, "YTDLP_PUBLIC_URL": "https://nas.example.test"}
            )
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(server.run_cli(cfg, ["add-user", "Sam"]), 0)
            text = out.getvalue()
            token = re.findall(r"shown once\)?: (\S+)", text)[-1]
            self.assertIn("smarttube://nas?url=https%3A%2F%2Fnas.example.test&token=" + token, text)
            self.assertEqual(server.JobManager(cfg).authenticate(token)["name"], "Sam")

            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(server.run_cli(cfg, ["revoke-user", "Sam"]), 0)
            self.assertIsNone(server.JobManager(cfg).authenticate(token))

            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(server.run_cli(cfg, ["reissue-user", "Sam"]), 0)
            new = re.findall(r"shown once\)?: (\S+)", out.getvalue())[-1]
            self.assertIsNone(server.JobManager(cfg).authenticate(token))
            self.assertEqual(server.JobManager(cfg).authenticate(new)["name"], "Sam")


if __name__ == "__main__":
    unittest.main()
