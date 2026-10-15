#!/usr/bin/env bash
set -Eeuo pipefail

SUFFIX="$(date -u +%Y%m%dT%H%M%SZ)"
USER_ID="delete_accept_user_${SUFFIX}"
ITEM_ID="delete_accept_item_${SUFFIX}"
TODAY="$(date -u +%F)"
NOW="$(date -u +%s)"

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
push() {
  local type="$1" payload="$2" response
  response="$(curl --noproxy '*' -fsS -H 'Content-Type: application/json' \
    --data "${payload}" "http://127.0.0.1:13579/api/push/${type}")"
  python3 -c 'import json,sys; x=json.load(sys.stdin); assert x.get("status") is True, x' \
    <<<"${response}" || die "${type} push failed: ${response}"
}
redis_exists() { docker exec redis redis-cli EXISTS "$1" | tr -d '\r'; }

note "Insert deterministic user and item"
push user "{\"requestId\":\"${SUFFIX}-user-insert\",\"body\":{\"cmd\":\"INSERT\",\"data\":[{\"id\":\"${USER_ID}\",\"name\":\"delete acceptance\",\"registerTime\":\"${NOW}\"}]}}"
push item "{\"requestId\":\"${SUFFIX}-item-insert\",\"body\":{\"cmd\":\"INSERT\",\"data\":[{\"id\":\"${ITEM_ID}\",\"scene\":\"scene_0\",\"title\":\"delete acceptance\",\"pubTime\":\"${NOW}\",\"modifyTime\":\"${NOW}\",\"status\":1}]}}"

for attempt in {1..60}; do
  [[ "$(redis_exists "user:{${USER_ID}}")" == 1 && "$(redis_exists "item:{${ITEM_ID}}")" == 1 ]] && break
  [[ "${attempt}" -lt 60 ]] || die "insert projection did not reach Redis within 60 seconds"
  sleep 1
done

note "Delete with ID-only v1 mutations"
push user "{\"requestId\":\"${SUFFIX}-user-delete\",\"body\":{\"cmd\":\"DELETE\",\"data\":[{\"id\":\"${USER_ID}\"}]}}"
push item "{\"requestId\":\"${SUFFIX}-item-delete\",\"body\":{\"cmd\":\"DELETE\",\"data\":[{\"id\":\"${ITEM_ID}\"}]}}"

for attempt in {1..60}; do
  if [[ "$(redis_exists "user:{${USER_ID}}")" == 0 \
      && "$(redis_exists "item:{${ITEM_ID}}")" == 0 \
      && "$(docker exec redis redis-cli ZSCORE 'new:{scene_0}' "${ITEM_ID}" | tr -d '\r')" == "" ]]; then
    break
  fi
  [[ "${attempt}" -lt 60 ]] || die "delete projection did not reach Redis within 60 seconds"
  sleep 1
done

note "Verify immutable Hive tombstones"
for type in user item; do
  id_var="${USER_ID}"; [[ "${type}" == item ]] && id_var="${ITEM_ID}"
  found=false
  for attempt in {1..60}; do
    if docker exec namenode hdfs dfs -cat "/openrec/hive/${type}/dt=${TODAY}/*" 2>/dev/null \
        | grep -F "\"operation\":\"DELETE\"" | grep -Fq "\"id\":\"${id_var}\""; then
      found=true; break
    fi
    sleep 1
  done
  [[ "${found}" == true ]] || die "${type} DELETE tombstone was not persisted to HDFS"
done

cat <<EOF

Entity delete acceptance passed.
User: ${USER_ID}
Item: ${ITEM_ID}
Verified: v1 Kafka mutation -> Redis delete/new cleanup -> immutable Hive tombstone
EOF
