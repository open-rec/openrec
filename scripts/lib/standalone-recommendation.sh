#!/usr/bin/env bash
# Called after fixture initialization; smoke_user and LOG_DIR come from start.sh.
recommend_response=""
recommend_ok=false
recommend() {
  local request_id="$1" response status
  # Capture status separately from the body; older curl lacks --fail-with-body.
  if response="$(curl --connect-timeout 5 --max-time 30 --noproxy '*' -sS -X POST \
    http://127.0.0.1:13579/api/recommend \
    --write-out $'\n%{http_code}' \
    -H 'Content-Type: application/json' \
    --data "{\"requestId\":\"${request_id}\",\"body\":{\"scene\":\"scene_0\",\"size\":12,\"userId\":\"${smoke_user}\",\"deviceId\":\"standalone-smoke\",\"type\":\"click\",\"debug\":false,\"params\":{\"ab\":\"default\",\"query\":\"item\"}}}")"; then
    status="${response##*$'\n'}"
    printf '%s\n' "${response%$'\n'*}"
    if [[ ! "${status}" =~ ^2[0-9][0-9]$ ]]; then
      echo "recommendation ${request_id}: HTTP ${status}" >&2
      return 22
    fi
  else
    status=$?
    printf '%s\n' "${response%$'\n'*}"
    return "${status}"
  fi
}

for attempt in 1 2 3 4 5 6; do
  # A previous smoke request must not affect this attempt through the expose filter.
  docker exec redis redis-cli DEL "event:{${smoke_user}}:scene_0:expose" >/dev/null
  if recommend_response="$(recommend "standalone-smoke-${attempt}")"; then
    request_ok=true
  else
    request_ok=false
    printf 'smoke %s failed: %s\n' "${attempt}" "${recommend_response}" >&2
  fi
  printf 'smoke %s: %s\n' "${attempt}" "${recommend_response}" >>"${LOG_DIR}/recommendation.log"
  if [[ "${request_ok}" == true ]] && python3 -c '
import json, sys
response = json.load(sys.stdin)
if response.get("code") != 200 or response.get("status") is not True:
    raise SystemExit("recommendation did not succeed: %s" % response)
results = (response.get("data") or {}).get("results") or []
channels = {item.get("recallFrom") for item in results if item.get("recallFrom")}
for item in results:
    channels.update((item.get("recallScores") or {}).keys())
required = {"item_cf_i2i", "content_i2i", "user_cf_u2i", "item_seq_emb", "sparse", "hot"}
missing = required - channels
if missing:
    raise SystemExit("missing channels: %s" % ",".join(sorted(missing)))
' <<<"${recommend_response}"; then
    recommend_ok=true
  else
    recommend_ok=false
  fi
  [[ "${recommend_ok}" == true ]] && break
  # Let timed-out cold searches leave the graph executor before starting another assertion.
  sleep 10
done
docker exec redis redis-cli DEL "event:{${smoke_user}}:scene_0:expose" >/dev/null
[[ "${recommend_ok}" == true ]] \
  || die "default weighted-channel smoke missed an enabled recall channel: ${recommend_response}"
# A bypassed RankNode leaves rankScore unset. Do not depend on its INFO log here: container
# logging level and asynchronous flushing can hide that line even though ranking was skipped.
if grep -Eq '"rankScore":[[:space:]]*-?[0-9]' <<<"${recommend_response}"; then
  die "standalone recommendation unexpectedly used rank scores: ${recommend_response}"
fi
if docker logs rec-server 2>&1 \
    | grep -Eq 'rank score failed|KafkaService|KafkaTemplate|KafkaAdmin'; then
  die "standalone log contains an unexpected Rank or Kafka service call"
fi
note "Default weighted-channel smoke passed: item-CF, content, UserCF, embedding, and hot are present; new-item supply is time-dependent; Rank and Kafka are bypassed"
