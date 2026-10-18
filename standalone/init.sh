#!/usr/bin/env bash
# Sourced by start.sh after Java/build paths are configured.
source "${WORKSPACE}/openrec/init/tools/init.sh"

openrec_initialize() {
    openrec_import_data standalone

    redis_size="$(docker exec redis redis-cli DBSIZE | tr -d '\r')"
    [[ "${redis_size}" =~ ^[1-9][0-9]*$ ]] || die "sample data was not loaded into Redis"
    if [[ "${OPENREC_FIXTURE_INPUT}" == true ]]; then
        read -r smoke_user smoke_item < <(python3 - "${OPENREC_DATA_DIR}" "${OPENREC_MODEL_ROOT}" <<'PY'
import csv, pathlib, sys
data = pathlib.Path(sys.argv[1])
model = pathlib.Path(sys.argv[2])
left = {row["left_item"] for row in csv.DictReader(
    (model / "recall/item/item_cf_i2i.csv").open()) if row["scene"] == "scene_0"}
user_cf = {row["user"] for row in csv.DictReader(
    (model / "recall/item/user_cf_u2i.csv").open()) if row["scene"] == "scene_0"}
for row in csv.DictReader((data / "event.csv").open()):
    if (row["scene"] == "scene_0" and row["type"] == "click" and
            row["item_id"] in left and row["user_id"] in user_cf):
        print(row["user_id"], row["item_id"]); break
else:
    raise SystemExit("no scene_0 click has an i2i recall table")
PY
        )
        # Recall tables live in Elasticsearch; Redis only holds the user's click history.
        i2i_query="$(python3 -c 'import json, sys; print(json.dumps({"query": {"bool": {"filter": [
            {"term": {"scene": "scene_0"}}, {"term": {"left_item": sys.argv[1]}}
        ]}}}))' "${smoke_item}")"
        i2i_count="$(docker exec elasticsearch curl -fksS -u elastic:openrec-es-password \
          -H 'Content-Type: application/json' \
          'https://localhost:9200/openrec-recall-item-cf-i2i-active/_count' \
          --data "${i2i_query}" | python3 -c 'import json, sys; print(json.load(sys.stdin)["count"])')" \
          || die "could not query the active Elasticsearch i2i recall index"
        [[ "${i2i_count}" =~ ^[1-9][0-9]*$ ]] \
          || die "the default i2i trigger item has no recall data in the active Elasticsearch index"
        docker exec redis redis-cli ZSCORE "event:{${smoke_user}}:scene_0:click" "\"${smoke_item}\"" | grep -Eq '[0-9]+' \
          || die "the default user has no i2i-covered click event"
        docker exec elasticsearch curl -fksS -u elastic:openrec-es-password \
          'https://localhost:9200/_cat/indices/scene_0-item-seq-emb-index?h=index' >/dev/null \
          || die "sample vectors were not loaded into Elasticsearch"
        for recall_kind in hot item-cf-i2i content-i2i user-cf-u2i item-search user-search; do
          docker exec elasticsearch curl -fksS -u elastic:openrec-es-password \
            "https://localhost:9200/_alias/openrec-recall-${recall_kind}-active" >/dev/null \
            || die "${recall_kind} recall alias was not loaded into Elasticsearch"
        done

    fi

    export RECOMMEND_WARMUP_USER_ID="${smoke_user}"
    export RECOMMEND_WARMUP_SCENE="${smoke_scene}"
}
