#!/usr/bin/env python3
"""HTTP contract acceptance against a standalone server with disposable Redis data.

Requires a running server, Redis and Elasticsearch. Use an isolated deployment;
this test exercises entity writes/deletes and the default serving graph.
"""
import argparse
import json
import time
import urllib.error
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--token", required=True)
    args = parser.parse_args()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(path, body=None, headers=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(args.url.rstrip("/") + path, data=data,
                                     headers={"Content-Type": "application/json", **(headers or {})})
        with opener.open(req, timeout=15) as response:
            return response.read().decode()

    def api(path, body=None, headers=None):
        result = json.loads(request(path, body, headers))
        assert result["code"] == 200 and result["status"] is True, result
        return result["data"]

    def push(kind, cmd, values):
        return api("/api/push/" + kind, {"requestId": "jdk21-acceptance", "body": {"cmd": cmd, "data": values}})

    suffix = uuid.uuid4().hex[:12]
    scene = "jdk21_" + suffix
    user = {"id": "jdk21_user_" + suffix}
    item = {"id": "jdk21_item_" + suffix, "title": "Java 升级兼容测试", "scene": scene, "status": 1,
            "pubTime": str(int(time.time())), "extFields": {"enabled": True, "value": 1.5}}
    event = {"userId": user["id"], "itemId": item["id"], "scene": scene,
             "type": "click", "time": str(int(time.time()))}
    assert api("/health") == "health check"
    docs = json.loads(request("/v3/api-docs"))
    assert "/api/recommend/item" in docs["paths"]
    assert "jvm_memory_used_bytes" in request("/actuator/prometheus")
    try:
        request("/internal/serving-graph")
        raise AssertionError("graph endpoint accepted a request without a token")
    except urllib.error.HTTPError as error:
        assert error.code == 401, error.code
    api("/internal/serving-graph", headers={"X-OpenRec-Token": args.token})
    try:
        push("user", "INSERT", [user])
        push("item", "INSERT", [item])
        assert api("/api/query/user/" + user["id"])["id"] == user["id"]
        stored = api("/api/query/item/" + item["id"])
        assert stored["title"] == item["title"] and stored["extFields"] == item["extFields"]
        item["title"] = "updated"
        push("item", "UPDATE", [item])
        assert api("/api/query/item/" + item["id"])["title"] == "updated"
        push("event", "INSERT", [event])
        events_path = "/api/query/event/{}/{}/click".format(user["id"], scene)
        assert api(events_path)[0]["id"] == item["id"]
        push("event", "DELETE", [event])
        assert api(events_path) == []
        recommendation = api("/api/recommend/item", {"body": {
            "scene": scene, "size": 10, "userId": user["id"], "params": {}, "debug": True}})
        assert item["id"] in [entry["id"] for entry in recommendation["results"]], recommendation
        push("item", "DELETE", [item])
        assert api("/api/query/item/" + item["id"]) is None
        push("user", "DELETE", [user])
        assert api("/api/query/user/" + user["id"]) is None
    finally:
        push("event", "DELETE", [event, dict(event, type="expose")])
        push("item", "DELETE", [item])
        push("user", "DELETE", [user])
    print("PASS: health, OpenAPI, metrics, graph authorization, entity CRUD, events and recommendation")


if __name__ == "__main__":
    main()
