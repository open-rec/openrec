#!/usr/bin/env bash
set -Eeuo pipefail

BUSINESS_DATE="${1:-$(date -u +%F)}"
STAMP="$(date -u +%H%M%S)"
REVISION_ONE="${2:-r${STAMP}1}"
REVISION_TWO="${3:-r${STAMP}2}"
PREFIX="rank_accept_${BUSINESS_DATE//-/}_${STAMP}"
TMP_DIR="$(mktemp -d /tmp/openrec-rank-acceptance.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
[[ "${BUSINESS_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "date must use YYYY-MM-DD"

for container in rec-server rec-console rank-engine rec-algorithm-runner airflow-api-server; do
  docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null | grep -qx true || die "${container} is not running"
done

EPOCH="$(date -u +%s)" PREFIX="${PREFIX}" python3 - "${TMP_DIR}" <<'PY'
import json, os, pathlib, sys
root, prefix, now = pathlib.Path(sys.argv[1]), os.environ["PREFIX"], int(os.environ["EPOCH"])
users = [{"id": f"{prefix}_u{i}", "deviceId": f"d{i}", "name": f"Rank User {i}",
          "gender": "male" if i % 2 == 0 else "female", "age": 20 + i,
          "country": "CN", "city": "HZ", "tags": ["rank", "acceptance"],
          "registerTime": str(now - 1000),
          "loginTime": str(now), "extFields": {}} for i in range(4)]
items = [{"id": f"{prefix}_i{i}", "title": f"Rank Item {i}", "category": "rank",
          "tags": "rank,acceptance", "scene": "scene_0", "pubTime": str(now - 100),
          "modifyTime": str(now), "expireTime": str(now + 86400), "status": 1,
          "weight": i + 1, "extFields": {}} for i in range(4)]
events = []
for u in range(4):
    for i in range(4):
        kind = "click" if (u + i) % 2 == 0 else "expose"
        events.append({"userId": f"{prefix}_u{u}", "deviceId": f"d{u}",
                       "itemId": f"{prefix}_i{i}", "traceId": f"{prefix}_{u}_{i}",
                       "scene": "scene_0", "type": kind, "value": "1",
                       "time": str(now + u * 4 + i), "isLogin": True, "extFields": {}})
for kind, data in (("user", users), ("item", items), ("event", events)):
    (root / f"{kind}.json").write_text(json.dumps({"requestId": f"{prefix}-{kind}",
        "body": {"cmd": "INSERT", "data": data}}))
PY

note "Publishing deterministic users, items, clicks, and exposures"
for kind in user item event; do
  response="$(curl --noproxy '*' -fsS -H 'Content-Type: application/json' --data-binary "@${TMP_DIR}/${kind}.json" "http://127.0.0.1:13579/api/push/${kind}")"
  python3 -c 'import json,sys; x=json.load(sys.stdin); assert x.get("status") is True,x' <<<"${response}" || die "${kind} push failed"
done

note "Waiting for cumulative Hive partitions"
for attempt in {1..120}; do
  ready=true
  for kind in user item event; do
    docker exec namenode hdfs dfs -cat "/openrec/hive/${kind}/dt=${BUSINESS_DATE}/*" 2>/dev/null \
      | grep -Fq "${PREFIX}" || ready=false
  done
  [[ "${ready}" == true ]] && break
  [[ "${attempt}" -lt 120 ]] || die "rank fixtures did not reach Hive within 120 seconds"
  sleep 1
done

run_model() {
  local revision="$1" run_id="openrec-rank-acceptance-${revision}-$(date -u +%Y%m%dT%H%M%SZ)" state="" output
  docker exec airflow-api-server airflow dags unpause -y openrec_rank_model >/dev/null
  docker exec airflow-api-server airflow dags trigger -r "${run_id}" --conf \
    "{\"business_date\":\"${BUSINESS_DATE}\",\"revision\":\"${revision}\",\"scene\":\"scene_0\",\"epochs\":2,\"min_auc\":0.0}" openrec_rank_model >/dev/null
  for attempt in {1..240}; do
    output="$(docker exec airflow-api-server airflow dags list-runs openrec_rank_model -o json 2>&1)"
    state="$(python3 -c 'import json,sys
p,r=sys.stdin.read(),sys.argv[1]; d=json.JSONDecoder()
for i,c in enumerate(p):
  if c not in "[{": continue
  try: v,_=d.raw_decode(p,i)
  except json.JSONDecodeError: continue
  for x in v if isinstance(v,list) else [v]:
    if isinstance(x,dict) and x.get("run_id")==r: print(x.get("state","")); raise SystemExit
' "${run_id}" <<<"${output}")"
    [[ "${state}" == success ]] && { echo "${run_id}"; return; }
    if [[ "${state}" == failed ]]; then
      docker exec airflow-api-server airflow tasks states-for-dag-run openrec_rank_model "${run_id}" -o table >&2 || true
      die "rank model DAG failed for ${revision}"
    fi
    sleep 5
  done
  die "rank model DAG timed out for ${revision}"
}

note "Training, evaluating, and publishing first model"
RUN_ONE="$(run_model "${REVISION_ONE}")"
note "Training, evaluating, and publishing second model"
RUN_TWO="$(run_model "${REVISION_TWO}")"

VERSION_ONE="${BUSINESS_DATE//-/}-${REVISION_ONE}"
VERSION_TWO="${BUSINESS_DATE//-/}-${REVISION_TWO}"
listing="$(curl --noproxy '*' -fsS http://127.0.0.1:8095/api/models/releases/scene_0)"
python3 -c 'import json,sys
x=json.load(sys.stdin); expected=set(sys.argv[1:]); assert x.get("active_version")==sys.argv[2],x
assert expected.issubset({r.get("version") for r in x.get("releases",[])}),x
assert all(r.get("gate",{}).get("passed") for r in x["releases"] if r.get("version") in expected),x
' "${VERSION_ONE}" "${VERSION_TWO}" <<<"${listing}" || die "model publish verification failed"

note "Rolling back atomically to the first retained model"
rollback="$(curl --noproxy '*' -fsS -H 'Content-Type: application/json' --data \
  "{\"scene\":\"scene_0\",\"target_version\":\"${VERSION_ONE}\"}" \
  http://127.0.0.1:8095/api/models/releases/rollback)"
python3 -c 'import json,sys; x=json.load(sys.stdin); assert x.get("active_version")==sys.argv[1],x' \
  "${VERSION_ONE}" <<<"${rollback}" || die "model rollback verification failed"

health="$(curl --noproxy '*' -fsS http://127.0.0.1:8123/health)"
python3 -c 'import json,sys; x=json.load(sys.stdin); d=x.get("data",{}); assert d.get("ready") and sys.argv[1] in d.get("model",{}).get("path",""),x' \
  "${VERSION_ONE}" <<<"${health}" || die "rank-engine did not serve the rolled-back model"

cat <<EOF

Rank model lifecycle acceptance passed.
First version:  ${VERSION_ONE}
Second version: ${VERSION_TWO}
Active after rollback: ${VERSION_ONE}
Airflow runs: ${RUN_ONE}, ${RUN_TWO}
Verified: cumulative Hive -> active-item filter -> train -> evaluate -> publish -> rank-engine -> rollback
EOF
