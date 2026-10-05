# End-to-end CI

## Runner tiers

Quality, standalone, and cluster workflows use GitHub-hosted Ubuntu runners. The full cluster was
designed for at least 16 CPU cores, 32 GiB RAM, and 100 GiB free storage, so its hosted-runner job
uses reduced development heaps, limits Compose build concurrency, and reduces Spark executor cores.
These limits are CI acceptance sizing rather than production recommendations.

Cluster workflow triggers remain limited to scheduled default-branch runs and
maintainer-initiated manual dispatches because the job starts a large privileged Docker topology.

## Test ownership

- Component unit tests remain in their component repositories.
- `quality.yml` detects cross-repository build and contract drift.
- `standalone-e2e.yml` is the required minimum distribution acceptance.
- `cluster-e2e.yml` proves distributed lifecycle behavior and is required before a stable release.

Every E2E workflow runs cleanup under `always()` and uploads diagnostic logs on failure.
The runner should also use an ephemeral VM or perform an independent post-job cleanup so an aborted
workflow cannot contaminate the next run.

The quality workflow checks out the Java components used by its compatibility build and every
component referenced by the standalone and cluster Compose definitions. Set `OPENREC_COMPONENTS`
to a space-separated list when running `scripts/checkout-components.sh` to select components; when
it is unset, the script continues to check out the complete manifest.
Manifest branch refs are checked out as local tracking branches so a development workspace remains
attached to its branch. Immutable commit and tag refs intentionally use detached HEAD mode.

The quality Java compatibility build and feature parity gate share Maven settings and retry
failed dependency transfers up to three total attempts, waiting 10 and 20 seconds between attempts.
Each attempt forces Maven to recheck previously failed downloads (`-U`) and preserves console logs.
Compilation and test failures are not retried. Persistent repository failures still fail the job.

## Java and recommendation gates

All three distribution workflows provision Temurin JDK 21. Source modules, SDK and example
applications target Java 21; Spark 4.0.4/Scala 2.13 and Flink 2.2.1 use matching Java 21 platform
images. Independent storage daemons retain their configured JVMs. See
[single-JDK builds](java21-unified-build.md) for Java selection and Maven cache permissions.

Both E2E jobs use `RECOMMEND_DEADLINE_MS=10000` and `OPENREC_GRAPH_NODE_TIMEOUT_MS=1000` for
functional acceptance on shared runners. Warmup first uses independent budgets, then verifies
with the deployment's normal configured budgets and opens `/ready`. These CI overrides are not
production latency targets. Docker `/health` checks establish process liveness only.

Recall smoke requires successful, nonempty per-node `recallDiagnostics` from a debug request
before final selection. It does not require every channel in the final twelve results: one item
can be recalled by several channels and later filtered or outranked. Final results remain
mandatory; cluster requires every result to have a rank score, while standalone verifies ranking
and Kafka are bypassed. Cluster ingestion smoke runs after recommendation smoke, so
`upstream_failed` means ingestion was not tested. See [readiness](recommendation-readiness.md).

## Reproducing cluster CI locally

CI runs `scripts/checkout-components.sh` followed by `example_cluster/start.sh`. The checkout pins
component sources to `release/openrec.json`; direct local startup builds whatever is in the
workspace and does not change Git refs. Compare component commits and local modifications first.

`--local` selects package/image-source defaults, including the separate PyTorch training base;
it does not select a different application implementation or skip any bootstrap tasks. Explicit
serving/training image and pip overrides take precedence. The workflow environment in
[cluster-e2e.yml](../.github/workflows/cluster-e2e.yml) defines the full resource overrides, including
ES 1 GiB, Spark workers 1 GiB, two submitted executor cores, and reduced daemon heaps. Setting only
the two recommendation timeout variables reproduces the budgets, not the entire runner setup.

A fresh CI runner has no preexisting model directory or data volumes. The manifest omits the model
repository, so `ensure-model-artifacts.sh` builds the bundle. Local startup reuses a bundle that
passes input/catalog/output hash validation, and stopping services preserves volumes. LR/FM
training does not fix all random state, so fresh valid models can choose different final items.
Record the model manifest/output hashes, image versions and graph configuration when comparing
runs. Use an isolated workspace and independent volumes for a clean-data reproduction; do not
delete an existing deployment's data just to match CI. Cached models and Redis event/model-release
state must not be assumed equivalent to a fresh runner.

Startup installs Hive tables, loads the fixture, starts services and checks feature parity before
triggering Airflow. `openrec_cluster_bootstrap` then checks dependencies, performs authenticated
warmup, verifies recommendations and sends a uniquely named user through Kafka/processor/Redis.
Other lifecycle/rollback scripts are separate acceptance flows and are not all run by startup.

On failure, inspect the matching run ID and task in Airflow. The startup error handler saves
business-service, scheduler and processor logs under `example_cluster/.runtime/logs/` before
stopping services; CI also uploads `.runtime/`. Use request IDs to correlate debug diagnostics
with `graph_trace`. These are application logs, not a guaranteed redacted export.
