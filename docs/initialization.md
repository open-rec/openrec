# Initialization from raw data

Both startup modes accept the same raw input contract. The default input is
`openrec/data/test`; `model/` is a reusable generated artifact directory, not a
required source of precomputed data.

```bash
# Run from openrec/. Relative paths are resolved from the invoking directory.
OPENREC_DATA_DIR=/absolute/path/to/my-data \
OPENREC_MODEL_ROOT=/absolute/path/to/my-models \
./standalone/start.sh

OPENREC_DATA_DIR=/absolute/path/to/my-data \
OPENREC_MODEL_ROOT=/absolute/path/to/my-models \
./cluster/start.sh
```

The input directory must contain `user.csv`, `item.csv`, and `event.csv`, with the
columns used by `data/test`. IDs and scene names may differ from the fixture.
Inputs must contain unique nonempty IDs, valid user/item references, consistent
event/item scenes, and click events for recommendation warmup. Training also needs
enough usable positive/negative examples; arbitrary or tiny datasets can fail the
existing model quality gate. `OPENREC_DEFAULT_MIN_AUC` controls that gate (default
0.70); errors stop initialization rather than falling back to unrelated artifacts.

## Responsibilities

- `standalone/init.sh` owns standalone import and serving-store checks.
- `cluster/init.sh` owns cluster import and serving-store checks.
- `init/tools/init.sh` shares path resolution, preparation, and import primitives.
- `init/tools/init-input.py` checks the raw input contract and selects warmup samples.
- `init/tools/ensure-model-artifacts.sh` invokes rec-algorithm's artifact validator and
  builder. It reuses a bundle only when raw-file hashes, build/schema versions,
  feature catalog, required files, and output checksums match. A missing or stale
  bundle is built in a temporary directory and validated before publication. A
  build failure leaves the prior bundle in place and stops startup. Publishing is
  not a transaction across all files; an interrupted copy is rejected on the next
  validation. Do not run concurrent initializations against the same model root.
- `init/` remains the shared Java storage loader. Its entry point
  `com.openrec.example.InitServingData` requires `standalone` or `cluster` as its
  first CLI argument and selects the corresponding task chain. The tasks import
  raw entities/events and generated feature snapshots into Redis, and recall,
  search, and embedding tables into Elasticsearch. Calling the Java class directly
  bypasses the preparation checks; use the mode startup scripts for normal usage.

Startup revalidates the bundle immediately before import, after Java/image builds.
The input and artifact directories should remain unchanged during initialization.
An empty model directory is supported: the builder produces recall tables and
item/user LR, FM, and LightGBM artifacts from the raw data. Initial generation
requires the training image and can take substantially longer than reuse.
Standalone still bypasses online ranking even though it prepares the common bundle.

Cluster mounts the selected model root into rank-engine. Persisted active-model
state is namespaced by the bootstrap manifest hash, so a different bundle does not
restore a model published for the previous bundle. Releases within the same bundle
continue to survive restarts. On the first startup after this change, the legacy
unnamespaced `/models/active` state is not restored; the selected bootstrap LR models
are used. Existing release artifacts are retained and can be published again.

## Verification and existing data

`init/tools/fixture-inputs.json` records the raw hashes of the bundled acceptance
fixture (update it deliberately when replacing that fixture). Unmodified bundled fixtures retain the full existing recall-channel acceptance
checks and cluster bootstrap DAG. Custom datasets use input-derived users, scenes,
and text queries, warm both recommendation routes, and verify nonempty results and
the mode's expected ranking behavior. They do not assert that every recall algorithm
has candidates for a sparse custom dataset. Fixture-specific standalone search checks
and the cluster bootstrap DAG remain fixture acceptance tools.

Initialization is a serving-data import, not a full platform reset. It replaces
active recall indexes and overwrites imported Redis entities/features, but does not
purge unrelated Redis keys, Kafka/Hive history, or previously published control-plane
records. Use a clean deployment for fully isolated datasets; changing the input
path on an existing cluster does not erase its historical data. The web demo's
sample defaults are also independent of initialization; use the API with your own
user IDs and scenes for custom data.

## Java task chains

`InitServingData.standaloneTasks()` and `clusterTasks()` explicitly compose each
mode's tasks. Both currently seed the same online serving stores; Kafka/Hive
streaming lifecycle remains in cluster startup. Add mode-specific tasks to the
appropriate composition when their import behavior differs.

The `task/` package owns the actual import implementations:

- `RedisUserTask`, `RedisItemTask`, `RedisEventTask`: raw entities and histories.
- `RedisFeatureTask`: user/item feature snapshots, selected by entity type.
- `RecallTableTask`: a named recall table and its artifact path.
- `SearchIndexTask`: item/user text-search indexes.
- `SequenceEmbeddingTask`: per-scene item sequence vectors.
- `LanguageEmbeddingTask`: optional title vectors when `EMBEDDING_ENABLED=true`.

Each `InitTask` declares its name, required input files, and execution logic.
`ValidateInputsTask` checks all selected files before any writes. The runner logs
start/completion, stops at the first error, and reports the task name with its cause.
Already completed writes are retained. `InitContext` owns invocation-local paths
and lazy storage clients and closes them on success or failure. Model fingerprint
validation and artifact generation remain in the shared preparation scripts before
Java execution; a direct Java invocation performs file checks, not model training.

Direct callers must now supply the mode before the Redis arguments. For example:
`com.openrec.example.InitServingData cluster 127.0.0.1 6380 127.0.0.1 9200 elastic PASSWORD DATA_DIR MODEL_DIR`.

The [tool directory guide](../scripts/README.md) lists the remaining runtime, CI, and release entry points.
