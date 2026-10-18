#!/usr/bin/env bash
# Shared preparation/import primitives; each mode owns openrec_initialize.
openrec_init_paths() {
    export OPENREC_DATA_DIR OPENREC_MODEL_ROOT
    OPENREC_DATA_DIR="$(realpath -m "${OPENREC_DATA_DIR:-${WORKSPACE}/openrec/data/test}")"
    OPENREC_MODEL_ROOT="$(realpath -m "${OPENREC_MODEL_ROOT:-${WORKSPACE}/model}")"
    local settings
    settings="$(python3 "${WORKSPACE}/openrec/init/tools/init-input.py" \
        --data "${OPENREC_DATA_DIR}")" || return 1
    eval "${settings}"
    if [[ "${OPENREC_FIXTURE_INPUT}" == true ]]; then
        smoke_user=user_0
        smoke_scene=scene_0
        smoke_item_query=item
        smoke_user_query=CN
    fi
}

openrec_prepare_init() {
    openrec_init_paths
    note "Preparing model artifacts from ${OPENREC_DATA_DIR}"
    "${WORKSPACE}/openrec/init/tools/ensure-model-artifacts.sh"
    # Namespace restored rank releases by the validated bundle, so another dataset's
    # persisted model cannot silently override the bootstrap model.
    OPENREC_MODEL_STATE_DIR="/models/active/$(sha256sum "${OPENREC_MODEL_ROOT}/default.manifest.json" | cut -d ' ' -f 1)"
    export OPENREC_MODEL_STATE_DIR
}

openrec_import_data() {
    local mode="${1:?initialization mode is required}"
    # Recheck after builds, immediately before modifying serving stores.
    PYTHONPATH="${WORKSPACE}/rec-algorithm" python3 \
        "${WORKSPACE}/rec-algorithm/tool/check_default_artifacts.py" \
        --data "${OPENREC_DATA_DIR}" --model-root "${OPENREC_MODEL_ROOT}" \
        || { die "input/model artifacts changed since preparation; restart initialization"; return 1; }
    note "Importing ${OPENREC_DATA_DIR} with artifacts from ${OPENREC_MODEL_ROOT}"
    "${JAVA}" -cp "${BUILD_DIR}/openrec/init/target/rec-example-init-0.1.0-jar-with-dependencies.jar" \
        com.openrec.example.InitServingData "${mode}" \
        127.0.0.1 6380 127.0.0.1 9200 elastic openrec-es-password \
        "${OPENREC_DATA_DIR}" "${OPENREC_MODEL_ROOT}"
}

openrec_verify_custom_data() {
    python3 "${WORKSPACE}/openrec/scripts/runtime/verify-init-recommendation.py" \
        --mode "$1" --user "${smoke_user}" --scene "${smoke_scene}" \
        --item-query "${smoke_item_query}" --user-query "${smoke_user_query}"
}
