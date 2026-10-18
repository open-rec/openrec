#!/usr/bin/env python3
"""Apply explicit node budgets for functional acceptance on a shared CI runner."""

import argparse
import copy
import json
import os
import urllib.request


def with_timeout_floor(graph, timeout_ms):
    if timeout_ms <= 0:
        raise ValueError("node timeout must be positive")
    result = copy.deepcopy(graph)
    for node in result["nodes"]:
        node["timeout"] = max(node["timeout"], timeout_ms)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node-timeout-ms", type=int, required=True)
    parser.add_argument("--server", default="http://127.0.0.1:13579")
    args = parser.parse_args()
    if args.node_timeout_ms <= 0:
        parser.error("--node-timeout-ms must be positive")
    headers = {
        "X-OpenRec-Token": os.environ.get(
            "SERVING_GRAPH_TOKEN", "openrec-serving-graph-token-change-me"
        ),
        "Content-Type": "application/json",
        "X-Graph-Version": "functional-acceptance",
    }
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(url, body=None):
        data = None if body is None else json.dumps(body).encode()
        with opener.open(urllib.request.Request(url, data=data, headers=headers), timeout=15) as response:
            payload = json.load(response)
        if payload.get("code") != 200 or payload.get("status") is not True:
            raise RuntimeError("graph configuration failed: %s" % payload)
        return payload["data"]

    for target in ("item", "user"):
        headers["X-Graph-Target"] = target
        url = args.server.rstrip("/") + "/internal/serving-graph"
        current = request(url + "?target=" + target)
        request(url, with_timeout_floor(current["graph"], args.node_timeout_ms))
        print("%s graph node timeout floor: %d ms" % (target, args.node_timeout_ms))


if __name__ == "__main__":
    main()
