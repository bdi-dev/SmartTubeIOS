#!/usr/bin/env python3
"""Stand-in for yt-dlp used by the tests. Writes a small file where -o points; fails for ids
containing 'FAIL'; sleeps before writing for ids containing 'SLOW' (so a job stays in flight).
Prints yt-dlp style progress lines. If FAKE_YTDLP_LOG is set, appends one line per run:
"describe <id>" or "download <id>", so tests can count runs."""
import json
import os
import sys
import time

args = sys.argv[1:]
if args == ["--version"]:
    print("2099.01.01")
    sys.exit(0)
url = args[-1]
vid = url.rsplit("=", 1)[-1]
kind = "describe" if "--dump-single-json" in args else "download"
log = os.environ.get("FAKE_YTDLP_LOG")
if log:
    with open(log, "a") as f:
        f.write("%s %s\n" % (kind, vid))
if kind == "describe":
    if "FAIL" in url:
        sys.stderr.write("ERROR: Video unavailable\n")
        sys.exit(1)
    print(json.dumps({"title": "Title " + vid, "channel": "Channel", "duration": 42.7, "thumbnail": "https://t.test/" + vid}))
    sys.exit(0)
out = args[args.index("-o") + 1]
if "FAIL" in url:
    sys.stderr.write("ERROR: Video unavailable\n")
    sys.exit(1)
print("[download]  50.0% of 1.00MiB", flush=True)
if "SLOW" in url:
    time.sleep(0.5)
print("[download] 100.0% of 1.00MiB", flush=True)
with open(out, "wb") as f:
    f.write(bytes(range(256)) * 4)  # 1024 bytes
