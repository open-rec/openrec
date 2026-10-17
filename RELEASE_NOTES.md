# OpenRec v0.1.0

Released: 2026-10-05

OpenRec distribution. First coordinated OpenRec source release.

## Features

- One versioned assembly of the online service, algorithms, ranking, streaming, control plane, infrastructure and SDKs.
- Standalone quick start and a distributed cluster reference deployment with committed fixture data.
- Item/user recommendation APIs, multi-channel recall, feature consistency and model/recall/graph lifecycle management.
- Java 21 source builds, recommendation readiness/warmup, recall diagnostics and ranked recommendation acceptance.
- Immutable component manifest, compatibility checks, source bundle and SHA-256 checksum assets.

## Installation and compatibility

Use `scripts/checkout-components.sh` to obtain the exact component commits in `release/openrec.json`. All OpenRec Java modules and clients require Java 21. Maven artifacts and the rec-algorithm package are now `0.1.0`; old `1.0-SNAPSHOT` jar names and `0.0.1` wheel references must be updated together.

This is a source distribution for evaluation, development and distributed integration. Standalone bypasses ranking; cluster enables the full lifecycle. The console has no authentication, sample credentials must be replaced, and the supplied cluster is not a production HA topology. Functional CI timeout overrides are not latency guarantees.

## Validation and known boundaries

See this repository's README for build/test commands and deployment requirements. The coordinated release's [validation record](https://github.com/open-rec/openrec/blob/v0.1.0/release/VALIDATION.md) distinguishes checks executed for this release from historical integration evidence.

This initial release establishes a versioned source baseline. Source archives and checksums are published; external package registries and container registries are not populated by the source-release workflow. Upgrade the complete compatible distribution, retain data/checkpoints/artifacts, and preserve prior component refs for rollback.

## Component versions

See [the exact component commits](release/COMPONENTS.md) and [distribution manifest](release/openrec.json). Every product repository is tagged `v0.1.0` on its `release/0.1.0` branch.

## Workspace bootstrap artifact layout v12

Use companion rec-algorithm builder/checker changes and rank-engine Compose paths together:
`rank/{item,user}/{lr,fm,lightgbm}/` and `recall/{item,user}/`. The initializer reads item LR
snapshots and item recall tables. Additional user/query CSVs are available as offline
artifacts; their presence does not activate new serving channels. The component refs above remain
published release refs; this workspace change must be pinned to new companion commits before a
new distribution release. To roll back, restore the v11 bundle and matching consumers together.

## Recall naming migration (bootstrap v13)

Apply rec-algorithm, rec-server, rec-console and example companion changes together. The item
vector table is now `item-seq-emb`, with `{scene}-item-seq-emb-index` aliases and matching
versioned indexes. User algorithm/task/CSV names are `user_als_u2u`; daily Hive output is
`openrec.recall_user_als_u2u`. The existing `user-als-u2u` serving table and `user_als_u2u`
response channel remain the mapping for user recall. Local bootstrap data now uses implicit ALS.

Before enabling the updated graph, republish item embeddings under the new alias (or rerun
standalone initialization). Existing deployed DAG-config overrides must replace the old user
algorithm name with `user_als_u2u`. Existing runtime graph overrides must update both item
embedding table names. Old indexes/Hive tables are retained; rollback requires the prior graph,
DAG configuration and component versions together. No running services or stored overrides are
modified by these source changes.

## Query embedding naming (bootstrap v14)

Only query-related names change: the user query CSV becomes `user_als_emb.csv`;
the item file remains `query_embedding.csv`. Both preserve their vector values.
Existing rank, item-sequence and user-ALS artifacts and algorithms are unchanged.

The Qwen experiment channel is `query_qwen_emb`, including its graph references and weights.
It reads the separate `query-title-emb-index`; optional embedding-enabled bootstrap now
loads Qwen3-Embedding-0.6B title vectors into this index. Historical experiment vectors remain separate.
Qwen query vectors must use the same model and preprocessing as its candidate index.
`params.queryEmbedding` and the generic vector API remain compatible. Existing graph releases
must migrate the query channel, weights and table together. Historical experiment results and
upstream cache filenames are retained. Roll back graph and artifact naming versions together.

## Bootstrap v16: distinguish ALS vectors and U2U edges

`recall/user/user_als_emb.csv` now contains `scene,user,vector`; the former edge table
is `user_als_u2u.csv` (`scene,left_user,right_user,score`). The v15-to-v16 migration
preserves all artifact bytes and stages both files before promotion to prevent name collisions.
Airflow/Spark algorithm and graph channel become `user_als_u2u`; the serving table becomes
`user-als-u2u`. Deploy the companion rec-algorithm, rec-console and rec-server changes together,
republish the U2U index, and update persisted DAG/graph overrides from the old ALS names.
Existing live indexes and runtime configurations are not automatically modified by this source migration.

Bootstrap v17 renames item/user `sparse.csv` to `text_search.csv`, preserving their
contents. The removed Qwen-only manifest is no longer required or emitted; the bundle
manifest continues to checksum all artifacts. Serving now uses channels `item_search` / `user_search`, with `item-search` and `user-search` tables.

Bootstrap v18 removes optional `item_content_emb.csv` from the default bundle and retains
`item_title_emb.csv`. The generator supports `--include-content` for explicit offline generation.
The default manifest covers 40 artifacts (27 rank files and 13 recall tables).

The rec-server full-text recall implementation now uses `SearchNode` / `SearchConfig`
(type `item.search`). The graphs use `item_search` / `user_search`, with `item-search` / `user-search` serving tables.
Persisted graph overrides must update the old sparse Java class/config names and type;
loading only the old node class against the new server is not supported.


Search table migration requires companion rec-server, rec-algorithm, and rec-console changes
in this workspace before rebuilding either distribution profile. Republish saved daily DAG
configurations to replace `sparse` with `text_search`; the user DAG includes `text_search`
with `target_type=user`. Reinitialize both model text tables before activating graph overrides.
Persisted graph overrides must use `item.search` / `user.search`, `SearchConfig`, channels
`item_search` / `user_search`, and tables `item-search` / `user-search`. Old `openrec-recall-sparse-active`
indexes are not reused. Pinned release refs still describe the previous released distribution
until these companion changes are committed and a new release is pinned.

## CPU bootstrap without language-model dependencies (v19)

Default standalone and cluster artifact generation no longer loads Qwen or requires
transformers. Existing title vectors are reused when item data and checksums match;
explicit offline generation uses `--include-text-embeddings`. Quality checks run with
source components alone and skip only checks requiring an optional precomputed bundle.
