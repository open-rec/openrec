#!/usr/bin/env python3
"""Check custom-data recommendations without assuming every recall table is dense."""
import argparse
import json
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=("standalone", "cluster"))
    parser.add_argument("--user", required=True)
    parser.add_argument("--scene", required=True)
    parser.add_argument("--item-query", required=True)
    parser.add_argument("--user-query", required=True)
    args = parser.parse_args()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for target, suffix, query in (("item", "", args.item_query), ("user", "/user", args.user_query)):
        body = {"requestId": f"init-{uuid.uuid4().hex}", "body": {
            "userId": args.user, "scene": args.scene, "size": 12, "type": "click",
            "debug": True, "params": {"query": query, "ab": "default"}}}
        request = urllib.request.Request(
            "http://127.0.0.1:13579/api/recommend" + suffix,
            data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        with opener.open(request, timeout=30) as response:
            payload = json.load(response)
        results = (payload.get("data") or {}).get("results") or []
        if payload.get("code") != 200 or payload.get("status") is not True or not results:
            raise RuntimeError(f"{target} recommendation failed: {payload}")
        ranked = [row.get("rankScore") is not None for row in results]
        if (args.mode == "cluster" and not all(ranked)) or (args.mode == "standalone" and any(ranked)):
            raise RuntimeError(f"unexpected {args.mode} ranking behavior: {payload}")
        print(f"{target} recommendation passed: {len(results)} results")


if __name__ == "__main__":
    main()
