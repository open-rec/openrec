#!/usr/bin/env python3
"""Start authenticated, side-effect-free graph warmup and wait for verified readiness."""
import argparse
import json
import os
import time
import urllib.error
import urllib.request


def request(opener, url, body=None):
    headers = {"Content-Type": "application/json",
               "X-OpenRec-Token": os.environ.get("SERVING_GRAPH_TOKEN", "openrec-serving-graph-token-change-me")}
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with opener.open(req, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code != 503 or not url.endswith("/ready"):
            raise
        return json.load(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default="http://127.0.0.1:13579")
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--scene", default="scene_0")
    parser.add_argument("--target", action="append", choices=("item", "user"),
                        help="Recommendation target to warm; repeat for both routes (default: item)")
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = args.server.rstrip("/")
    samples = [{"userId": args.user_id, "scene": args.scene, "size": 12, "type": "click",
                "targetType": target,
                "params": {"ab": "default", "query": "CN" if target == "user" else "item"}}
               for target in dict.fromkeys(args.target or ["item"])]
    request(opener, base + "/internal/recommendation-warmup", samples)
    deadline = time.monotonic() + args.timeout
    previous = None
    while time.monotonic() < deadline:
        status = request(opener, base + "/ready")
        if status != previous:
            print("Recommendation readiness: " + json.dumps(status), flush=True)
            previous = status
        if status.get("ready") is True:
            return
        if status.get("state") == "FAILED":
            raise RuntimeError("recommendation warmup failed: %s" % status)
        time.sleep(1)
    raise RuntimeError("recommendation readiness timed out: %s" % previous)


if __name__ == "__main__":
    main()
