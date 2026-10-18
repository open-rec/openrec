#!/usr/bin/env bash
set -Eeuo pipefail

BUSINESS_DATE="${1:-$(date -u +%F)}"
STAMP="$(date -u +%H%M%S)"
PREFIX="analytics_accept_${BUSINESS_DATE//-/}_${STAMP}"
TMP_FILE="$(mktemp /tmp/openrec-analytics.XXXXXX.json)"
trap 'rm -f "${TMP_FILE}"' EXIT

[[ "${BUSINESS_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
  echo "error: date must use YYYY-MM-DD" >&2; exit 1;
}

EPOCH="$(date -u +%s)" PREFIX="${PREFIX}" python3 - "${TMP_FILE}" <<'PY'
import json, os, sys
p, now = os.environ["PREFIX"], os.environ["EPOCH"]
events = [
    {"userId": p+"_u1", "itemId": p+"_i1", "type": "expose"},
    {"userId": p+"_u1", "itemId": p+"_i1", "type": "click"},
    {"userId": p+"_u1", "itemId": p+"_i1", "type": "buy",
     "extFields": {"quantity": 2, "price": 12.5}},
    {"userId": p+"_u2", "itemId": p+"_i2", "type": "expose"},
]
for index, event in enumerate(events):
    event.update({"deviceId": p+"_device", "traceId": f"{p}_{index}", "scene": p,
                  "value": "1", "time": str(int(now) + index), "isLogin": True})
    event.setdefault("extFields", {})
with open(sys.argv[1], "w") as output:
    json.dump({"requestId": p, "body": {"cmd": "INSERT", "data": events}}, output)
PY

echo "==> Publishing deterministic analytics events"
curl --noproxy '*' -fsS -H 'Content-Type: application/json' --data-binary "@${TMP_FILE}" \
  http://127.0.0.1:13579/api/push/event >/dev/null

echo "==> Waiting for Spark to persist the Hive event partition"
for attempt in {1..60}; do
  partition="$(docker exec namenode hdfs dfs -cat "/openrec/hive/event/dt=${BUSINESS_DATE}/*" 2>/dev/null || true)"
  grep -Fq "${PREFIX}_3" <<<"${partition}" && break
  [[ "${attempt}" -lt 60 ]] || { echo "error: analytics events did not reach Hive" >&2; exit 1; }
  sleep 2
done

echo "==> Querying rec-console business analytics"
result="$(curl --noproxy '*' -fsS \
  "http://127.0.0.1:8095/api/analytics/business?date_from=${BUSINESS_DATE}&date_to=${BUSINESS_DATE}&scene=${PREFIX}&refresh=true")"
python3 -c 'import json,sys
x=json.load(sys.stdin); s=x["summary"]
assert s["exposes"] == 2 and s["clicks"] == 1 and s["purchases"] == 1, x
assert s["browsing_users"] == 2 and s["click_users"] == 1 and s["purchase_users"] == 1, x
assert s["active_items"] == 2 and s["gmv"] == 25 and s["gmv_valid_orders"] == 1, x
assert s["pv_ctr"] == .5 and s["uv_ctr"] == .5 and s["pv_cvr"] == 1 and s["uv_cvr"] == 1, x
' <<<"${result}"

echo "Data analytics acceptance passed: PV/UV CTR, PV/UV CVR, active items, and GMV."
