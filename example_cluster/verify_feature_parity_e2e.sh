#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE="${WORKSPACE}/rec-algorithm/algorithm/feature/definitions/event-feature-parity.json"
TMP_DIR="$(mktemp -d /tmp/openrec-feature-e2e.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT
PREFIX="parity_$(date -u +%s)_$RANDOM"

docker inspect -f '{{.State.Running}}' redis 2>/dev/null | grep -qx true || {
  echo "error: cluster Redis container is not running" >&2
  exit 1
}

python3 - "${FIXTURE}" "${TMP_DIR}/mutations.jsonl" "${TMP_DIR}/expected.json" "${PREFIX}" <<'PY'
import json, pathlib, sys
fixture=json.loads(pathlib.Path(sys.argv[1]).read_text()); prefix=sys.argv[4]
mutations=[]
for i,event in enumerate(fixture["events"]):
    value=dict(event)
    if value["time"] == "invalid" or int(value["time"]) > fixture["as_of_time"]: continue
    event_id=value.pop("event_id", f"{value['trace_id']}_{value['type']}_{value['time']}")
    operation=value.pop("operation", "INSERT")
    occurred_at=value.pop("occurred_at", i + 1)
    value.update(eventId=f"{prefix}_{event_id}",
                 userId=f"{prefix}_{value.pop('user_id')}",
                 itemId=f"{prefix}_{value.pop('item_id')}", traceId=value.pop("trace_id"),
                 extFields={})
    envelope={"schemaVersion":1,"entityType":"event","operation":operation,
              "occurredAt":occurred_at,"data":value}
    mutations.append(f"{value['userId']}\t{json.dumps(envelope, separators=(',', ':'))}")
pathlib.Path(sys.argv[2]).write_text("\n".join(mutations) + "\n")
expected={f"feature:user:{{{prefix}_u1}}": fixture["expected_user"]}
expected.update({f"feature:item:{{{prefix}_{key}}}": value
                 for key,value in fixture["expected_items"].items()})
pathlib.Path(sys.argv[3]).write_text(json.dumps(expected))
PY

docker exec -i kafka-1 kafka-console-producer.sh --bootstrap-server kafka-1:9092 --topic event \
  --property parse.key=true --property key.separator=$'\t' < "${TMP_DIR}/mutations.jsonl"

for attempt in {1..60}; do
  ready=true
  while IFS= read -r key; do
    docker exec redis redis-cli EXISTS "${key}" | grep -qx 1 || ready=false
  done < <(python3 -c 'import json,sys; print(*json.load(open(sys.argv[1])),sep="\n")' "${TMP_DIR}/expected.json")
  [[ "${ready}" == true ]] && break
  [[ "${attempt}" -lt 60 ]] || { echo "feature parity Redis snapshots timed out" >&2; exit 1; }
  sleep 1
done

python3 - "${TMP_DIR}/expected.json" <<'PY'
import json, subprocess, sys
expected=json.load(open(sys.argv[1]))
for key, values in expected.items():
    raw=subprocess.check_output(["docker","exec","redis","redis-cli","--raw","GET",key])
    actual=json.loads(raw)["features"]
    for name,value in values.items():
        assert actual.get(name) == value, (key,name,value,actual.get(name))
print("Kafka -> data-processor -> Redis feature parity passed")
PY
