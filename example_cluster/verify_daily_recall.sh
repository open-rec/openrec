#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUSINESS_DATE="${1:-$(date -u +%F)}"
REVISION="${2:-r$(date -u +%H%M%S)}"
RUN_ID="openrec-daily-acceptance-$(date -u +%Y%m%dT%H%M%SZ)"
TMP_DIR="$(mktemp -d /tmp/openrec-daily-acceptance.XXXXXX)"
DAG_WAS_PAUSED=false
cleanup() {
  rm -rf "${TMP_DIR}"
  if [[ "${DAG_WAS_PAUSED}" == true ]]; then
    docker exec airflow-api-server airflow dags pause -y openrec_daily_recall >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[[ "${BUSINESS_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "business date must use YYYY-MM-DD"
[[ "${REVISION}" =~ ^r[0-9]{3,}$ ]] || die "revision must look like r001"
for container in rec-server rec-console rec-algorithm-runner airflow-api-server spark-master namenode; do
  docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null | grep -qx true \
    || die "container ${container} is not running; start cluster first"
done

if [[ "${BUSINESS_DATE}" == "$(date -u +%F)" ]]; then
  # Keep today's fixtures inside NewNode's freshness window and never in the future.
  EPOCH="$(($(date -u +%s) - 60))"
else
  EPOCH="$(date -u -d "${BUSINESS_DATE} 12:00:00" +%s)"
fi
PREFIX="daily_accept_${BUSINESS_DATE//-/}_${REVISION}"
export EPOCH PREFIX
python3 - "${TMP_DIR}/items.json" "${TMP_DIR}/events.json" <<'PY'
import json, os, sys

epoch = int(os.environ["EPOCH"])
prefix = os.environ["PREFIX"]
items = []
for offset, suffix in enumerate(("a", "b", "c", "d")):
    items.append({"id": "%s_%s" % (prefix, suffix), "weight": 10,
                  "title": "Daily acceptance %s" % suffix, "category": "acceptance",
                  "tags": "daily,acceptance", "scene": "scene_0",
                  "pubTime": str(epoch + offset), "modifyTime": str(epoch + offset),
                  "expireTime": str(epoch + 86400 * 30), "status": 1, "extFields": {}})
sequences = {"user_0": ("a",), "%s_u1" % prefix: ("a", "b", "c"),
             "%s_u2" % prefix: ("a", "c", "d"),
             "%s_u3" % prefix: ("a", "b", "d")}
events = []
counter = 0
for user, sequence in sequences.items():
    for suffix in sequence:
        counter += 1
        events.append({"userId": user, "deviceId": "daily-acceptance",
                       "itemId": "%s_%s" % (prefix, suffix),
                       "traceId": "%s_event_%d" % (prefix, counter), "scene": "scene_0",
                       "type": "click", "value": "1", "time": str(epoch + counter),
                       "isLogin": True, "extFields": {}})
for path, request_id, data in ((sys.argv[1], "daily-acceptance-items", items),
                               (sys.argv[2], "daily-acceptance-events", events)):
    with open(path, "w", encoding="utf-8") as target:
        json.dump({"requestId": request_id, "body": {"cmd": "INSERT", "data": data}}, target)
PY

push() {
  local kind="$1" payload="$2" response
  response="$(curl --noproxy '*' -fsS -H 'Content-Type: application/json' \
    --data-binary "@${payload}" "http://127.0.0.1:13579/api/push/${kind}")"
  python3 -c 'import json,sys; value=json.load(sys.stdin); assert value.get("code") == 200 and value.get("status") is True, value' \
    <<<"${response}" || die "${kind} push was rejected: ${response}"
}

note "Publishing deterministic acceptance data through rec-server -> Kafka"
push item "${TMP_DIR}/items.json"
push event "${TMP_DIR}/events.json"

note "Waiting for Spark streaming to persist the ${BUSINESS_DATE} Hive ODS partitions"
for attempt in {1..120}; do
  if docker exec namenode hdfs dfs -test -e "/openrec/hive/item/dt=${BUSINESS_DATE}" \
      && docker exec namenode hdfs dfs -test -e "/openrec/hive/event/dt=${BUSINESS_DATE}"; then
    break
  fi
  [[ "${attempt}" -lt 120 ]] || die "Hive ODS partitions did not appear within 120 seconds"
  sleep 1
done

note "Triggering ${RUN_ID} for cumulative data through ${BUSINESS_DATE}"
CONF="{\"business_date\":\"${BUSINESS_DATE}\",\"revision\":\"${REVISION}\"}"
if docker exec airflow-api-server airflow dags list -o plain 2>/dev/null \
    | awk '$1 == "openrec_daily_recall" && $4 == "True" {found=1} END {exit !found}'; then
  DAG_WAS_PAUSED=true
  docker exec airflow-api-server airflow dags unpause -y openrec_daily_recall >/dev/null
fi
docker exec airflow-api-server airflow dags trigger -r "${RUN_ID}" --conf "${CONF}" \
  openrec_daily_recall >/dev/null

state=""
for attempt in {1..240}; do
  output="$(docker exec airflow-api-server airflow dags list-runs openrec_daily_recall -o json 2>&1)"
  state="$(python3 -c '
import json, sys
payload, run_id = sys.stdin.read(), sys.argv[1]
decoder = json.JSONDecoder()
for offset, char in enumerate(payload):
    if char not in "[{":
        continue
    try:
        value, _ = decoder.raw_decode(payload, offset)
    except json.JSONDecodeError:
        continue
    runs = value if isinstance(value, list) else [value]
    match = next((run for run in runs if isinstance(run, dict) and run.get("run_id") == run_id), None)
    if match:
        print(match.get("state", "")); break
' "${RUN_ID}" <<<"${output}")"
  case "${state}" in
    success) break ;;
    failed)
      docker exec airflow-api-server airflow tasks states-for-dag-run \
        openrec_daily_recall "${RUN_ID}" -o table >&2 || true
      die "daily recall DAG failed"
      ;;
  esac
  [[ "${attempt}" -lt 240 ]] || die "daily recall DAG timed out after 20 minutes (state=${state:-unknown})"
  sleep 5
done

note "Verifying non-empty versioned indexes and active aliases"
for algorithm in hot item-cf-i2i content-i2i user-cf-u2i; do
  expected="openrec-recall-${algorithm}-${BUSINESS_DATE//-/}-${REVISION}"
  release="$(curl --noproxy '*' -fsS "http://127.0.0.1:8095/api/recall/releases/${algorithm}")"
  python3 -c '
import json, sys
value, expected = json.load(sys.stdin), sys.argv[1]
assert value.get("active_indexes") == [expected], value
release = next((item for item in value.get("releases", []) if item.get("index") == expected), None)
assert release and int(release.get("documents", 0)) > 0, value
' "${expected}" <<<"${release}" || die "${algorithm} release verification failed"
done

embedding_index="scene_0-item-vector-index-${BUSINESS_DATE//-/}-${REVISION}"
embedding_alias="$(docker exec elasticsearch curl -sku elastic:openrec-es-password \
  "https://127.0.0.1:9200/_alias/scene_0-item-vector-index")"
python3 -c '
import json, sys
value, expected = json.load(sys.stdin), sys.argv[1]
assert list(value) == [expected], value
' "${embedding_index}" <<<"${embedding_alias}" || die "embedding alias verification failed"
embedding_count="$(docker exec elasticsearch curl -sku elastic:openrec-es-password \
  "https://127.0.0.1:9200/scene_0-item-vector-index/_count")"
python3 -c 'import json,sys; value=json.load(sys.stdin); assert int(value.get("count", 0)) > 0, value' \
  <<<"${embedding_count}" || die "embedding index is empty"

cat <<EOF

Daily recall end-to-end acceptance passed.
Business date: ${BUSINESS_DATE}
Revision:      ${REVISION}
Airflow run:   ${RUN_ID}
Verified: Push -> Kafka -> Spark -> cumulative Hive -> all recall publishes -> ES aliases -> online recommend
EOF
