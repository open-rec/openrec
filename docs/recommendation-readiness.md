# Recommendation startup readiness

The distribution requires the companion rec-server and bigdata-platform refs in
`release/openrec.json`. `/health` remains a liveness/control-plane check. Business recommendation
traffic is admitted only after `/ready` returns HTTP 200; an unready recommendation route returns
HTTP 503. Push and query APIs remain usable during data initialization.

The startup sequence is:

1. Load fixture data and start dependencies.
2. Start rec-server with a representative fixture user configured for automatic restart warmup.
3. Run the complete recommendation graph with an independent warmup budget (10-second request,
   2-second node floor by default), without changing the published graph or writing exposures.
4. Require three consecutive successful rounds under the configured normal request/node budgets.
5. Mark the covered target/experiment graphs ready, run product smoke assertions, then start Web Demo.

Standalone uses `scripts/wait-recommendation-ready.py`; the cluster bootstrap DAG uses the same
server API. Airflow receives `SERVING_GRAPH_TOKEN` from the platform Compose environment. Keep
this value consistent with rec-server when overriding it. The internal POST is authenticated and
returns 202; `/ready` reports progress and returns 503 until verification succeeds.

The bundled startup sample covers the default item graph. Deployments serving user recommendations,
additional experiments, scenes or vector-query variants must supply representative samples through
`/internal/recommendation-warmup`. Unwarmed target/experiment routes remain blocked. Samples supplied
by POST are not persisted: reapply them after a restart, or supply startup automation. Graph changes
invalidate readiness and automatically rewarm the configured samples. A failed attempt resets the
normal verification streak; exhaustion stays closed until an operator retries after fixing the cause.

Container healthchecks intentionally use liveness to avoid a bootstrap dependency cycle. An external
load balancer must use `/ready`, rather than interpreting a successful `/health` as recommendation
readiness. rec-console's dependency health checks confirm control-plane availability, not this traffic gate.

Rollback requires matching component refs and startup scripts: older servers do not implement the
readiness endpoints. Recommendation payloads and the Kafka envelope are unchanged.

## Local verification

- rec-server: full Maven tests, 146 passed and two existing tests skipped; covers admission over real
  HTTP, warmup authentication, isolated deadlines, normal-budget streaks, graph invalidation and
  exposure suppression.
- SDK: six tests passed, including HTTP 503 transport handling.
- Distribution scripts: 23 tests passed, including readiness polling and persistent failure handling.
- Standalone: complete source-build startup passed, followed by two cold restarts. Both reached READY
  after one independent warmup and three normal-budget rounds; requests before readiness were 503,
  exposure records were unchanged by probes, and ten subsequent business recommendations succeeded.
- Cluster: `RECOMMEND_DEADLINE_MS=10000 OPENREC_GRAPH_NODE_TIMEOUT_MS=1000 ./example_cluster/start.sh --local`
  passed with the CI functional budgets, including Kafka/processor feature parity, ranked recommendations
  and ingestion. All 13 tasks in `openrec-start-20261005T022508Z` succeeded; the readiness warmup task
  completed before recommendation smoke. These are local integration results, not a remote CI run.
