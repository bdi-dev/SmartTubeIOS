import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import server  # noqa: E402

FAKE = os.path.join(os.path.dirname(__file__), "fake_ytdlp.py")
TOKEN = "test-token"
GOOD = "dQw4w9WgXcQ"  # 11 chars
BAD_RUN = "FAILxxxxxxx"  # 11 chars, fake yt-dlp fails


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
                "YTDLP_RETENTION_HOURS": "1",
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
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if token:
            req.add_header("Authorization", "Bearer " + token)
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, r.read(), dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)

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

    def test_sweep_removes_only_old_files(self):
        manager = self.srv.manager
        old = os.path.join(self.cfg.data_dir, "OLDxxxxxxxx.mp4")
        new = os.path.join(self.cfg.data_dir, "NEWxxxxxxxx.mp4")
        for p in (old, new):
            with open(p, "wb") as f:
                f.write(b"x")
        os.utime(old, (time.time() - 7200, time.time() - 7200))
        self.assertEqual(manager.sweep(), 1)
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(new))
        os.remove(new)

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


if __name__ == "__main__":
    unittest.main()
