# OpenRec v0.2.0

Released: 2026-10-18

Coordinated source release of the refactored OpenRec recommendation stack, covering
standalone and cluster deployments. Exact component commits are recorded in
[the manifest](release/openrec.json) and [component table](release/COMPONENTS.md).

## Changes since v0.1.0

- Online serving uses unified request triggers, aligned item/user graph channels,
  Elasticsearch-only recall and configurable virtual-thread graph execution.
- Ranking separates model lifecycle, feature snapshots and inference execution,
  with batched scoring, cached projections and CPU/CUDA implementations.
- Offline Spark jobs and streaming Flink/Spark jobs have explicit responsibility
  boundaries while preserving shared feature and versioned mutation contracts.
- The console manages aligned recall publications and optional scheduled title
  embeddings. Java, Go and Python SDK diagnostics and error handling are aligned.
- Initialization and regression tooling use the committed `data/test` fixture.
  Bootstrap build 19 organizes models by target/model family and makes language
  vectors optional for CPU-only initialization.

## Installation and deployment modes

Check out `v0.2.0`, then run `scripts/release/checkout-components.sh` to obtain the
exact runtime/source-build dependencies. All OpenRec Java modules require Java 21.
Maven artifacts, the rec-algorithm wheel and Python SDK package are versioned
`0.2.0`; rebuild dependent services and update any external jar/wheel paths.

Standalone retains monitoring, entities and serving-graph operations and may
bypass ranking. Cluster enables Kafka projections, offline jobs, model/recall
lifecycle management and rank-engine. Recall storage is Elasticsearch-only in both
profiles; Redis remains the online entity/feature store. Remove obsolete
`RECALL_STORE` / `recall.store` settings.

Query encoding and scheduled title generation are opt-in. Enable the optional
vLLM service and matching model/preprocessing/dimensions before enabling title
vector publication or online query encoding. The default embedding configuration
uses Qwen3-Embedding-0.6B with 1024 dimensions; historical experiment vectors are
not interchangeable with these vectors.

## Upgrade from v0.1.0

Upgrade the complete compatible component set. Back up persisted graph/DAG
configurations, release state, indexes, feature/model artifacts and checkpoints.
Source updates do not automatically migrate stored configuration overrides.

- Graphs now expose `requestTrigger`, containing `triggerItems`, `triggerUsers`,
  `triggerSelf` and `triggerQuery`. Custom nodes using old standalone trigger ports
  must migrate with the graph implementation.
- Persisted graph overrides must use `item.search` / `user.search`, `SearchConfig`,
  channels `item_search` / `user_search` and tables `item-search` / `user-search`.
  Republish text indexes; old sparse indexes are not reused. Persisted daily DAG
  configurations must replace `sparse` with `text_search`, including `target_type=user`
  for user search.
- Item sequence embeddings use `item-seq-emb` and `{scene}-item-seq-emb-index`.
  The online query channel is `query_title_emb`, reading `query-title-emb-index`.
  Reinitialize or republish corresponding indexes before activating new graphs.
- ALS neighbor edges use algorithm/channel `user_als_u2u`, table `user-als-u2u`
  and CSV `user_als_u2u.csv` (`scene,left_user,right_user,score`). ALS factors use
  `user_als_emb.csv` (`scene,user,vector`). Update saved DAG/graph overrides together.
- Airflow publication task IDs use `publish-<tableName>`, such as
  `publish-item-search` and `publish-item-seq-emb`. Finish or stop old runs and
  reparse both DAGs before starting new runs. Historical task IDs are unchanged.
- Bootstrap models live under `rank/{item,user}/{lr,fm,lightgbm}/`; recall tables
  live under `recall/{item,user}/`. Text CSVs are named `text_search.csv`.
  Build 19 defaults to 39 outputs; the companion model release retains verified
  optional title vectors for 40 checksummed outputs. The bundle manifest is the
  checksum authority. Always keep fitted feature sidecars with checkpoints.
- Go/Python SDK callers must handle HTTP failures explicitly; they now return or
  raise errors rather than silently yielding empty responses. Go consumers use
  the additional `go-client/v0.2.0` module tag.

## Validation, publication and rollback

See the [validation record](release/VALIDATION.md) for local release checks and
maintainer-reported prior CI/integration results. The maintainer triggers remote
acceptance workflows separately; prior successful runs are not presented as
verification of the new release commits.

This is a source release: GitHub Actions publishes source archives and SHA-256
checksums, not Maven Central/PyPI packages or versioned OCI images. The console
has no authentication/RBAC and the reference cluster is not a production HA
architecture. Existing documented deployment and latency boundaries still apply.

For rollback, restore the complete v0.1.0 component set together with its matching
saved graph/DAG configurations, artifact layout and index aliases. Retain old
indexes and backed-up state until acceptance completes; do not reuse a partially
migrated configuration with old binaries. Historical v0.1.0 tags are unchanged.
