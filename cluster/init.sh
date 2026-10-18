#!/usr/bin/env bash
# Sourced by start.sh after Java/build paths are configured.
source "${WORKSPACE}/openrec/init/tools/init.sh"

openrec_initialize() {
    openrec_import_data cluster

    note "Verifying loaded cluster serving data"
    docker exec redis redis-cli EXISTS "user:{${smoke_user}}" | grep -qx 1 \
      || die "sample user was not loaded into Redis"
    if [[ "${OPENREC_FIXTURE_INPUT}" == true ]]; then
        for recall_kind in hot item-cf-i2i content-i2i user-cf-u2i; do
          wait_for_es_documents "${recall_kind} recall alias" \
            "openrec-recall-${recall_kind}-active"
        done
        wait_for_es_documents "embedding recall index" "scene_0-item-seq-emb-index"

    fi

    export RECOMMEND_WARMUP_USER_ID="${smoke_user}"
    export RECOMMEND_WARMUP_SCENE="${smoke_scene}"
}
