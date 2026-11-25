#!/usr/bin/env python3
"""Stand-in for yt-dlp used by the tests. Writes a small file where -o points; fails for ids
containing 'FAIL'. Prints yt-dlp style progress lines."""
import json
import sys

args = sys.argv[1:]
if args == ["--version"]:
    print("2099.01.01")
    sys.exit(0)
url = args[-1]
if "--dump-single-json" in args:
    if "FAIL" in url:
        sys.stderr.write("ERROR: Video unavailable\n")
        sys.exit(1)
    vid = url.rsplit("=", 1)[-1]
    print(json.dumps({"title": "Title " + vid, "channel": "Channel", "duration": 42.7, "thumbnail": "https://t.test/" + vid}))
    sys.exit(0)
out = args[args.index("-o") + 1]
if "FAIL" in url:
    sys.stderr.write("ERROR: Video unavailable\n")
    sys.exit(1)
print("[download]  50.0% of 1.00MiB", flush=True)
print("[download] 100.0% of 1.00MiB", flush=True)
with open(out, "wb") as f:
    f.write(bytes(range(256)) * 4)  # 1024 bytes
