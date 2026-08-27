# OpenRec cluster workflows

These DAGs belong to the complete recommendation example, while the Airflow runtime belongs to
`bigdata-platform`. `start.sh` supplies this directory through `AIRFLOW_DAGS_PATH`, starts the
long-running services, and triggers `openrec_cluster_bootstrap`.

The DAGs use only Kafka, Hive, Spark, Redis, Elasticsearch, and HTTP network endpoints. They do not
mount the Docker socket or manage containers.

`openrec_cluster_bootstrap` is manually scheduled and safe to rerun. It validates the platform and
online services, sends a real recommendation, then verifies the Kafka -> data-processor -> Redis
ingestion path.

## Workflow inventory

| DAG | Schedule | Responsibility |
|---|---|---|
| `openrec_cluster_bootstrap` | Manual | Check platform and application health, initialize Hive, push fixture entities, and verify online ingestion |
| `openrec_daily_recall` | Published configuration | Run the ordered recall pipeline, write staging indexes, and request validated activation through rec-console |
| `openrec_recall_rollback` | Manual | Ask rec-console to restore a retained recall-index version |
| `openrec_rank_model` | Manual | Prepare training data, train/evaluate LR or FM, and publish an approved immutable release |
| `openrec_rank_model_rollback` | Manual | Reactivate a retained rank-model release through rec-console and rank-engine |

The daily recall schedule, algorithm order, revision, retention, and retry policy come from the
versioned configuration published by rec-console. Airflow remains the execution and run-state
authority; rec-console never edits the Python DAG source.

## Operation and diagnosis

`example_cluster/start.sh` starts the platform and triggers bootstrap. Use rec-console or the
authenticated Airflow UI on host port 8091 to inspect DagRuns, task attempts, and logs. Tasks are
designed to be retried, while recall and model publication use immutable versions plus explicit
activation so an incomplete run does not replace the active artifact. Complete acceptance commands
and failure-log locations are documented in the parent [cluster guide](../README.md).
