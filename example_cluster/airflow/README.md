# OpenRec cluster workflows

These DAGs belong to the complete recommendation example, while the Airflow runtime belongs to
`bigdata-platform`. `start.sh` supplies this directory through `AIRFLOW_DAGS_PATH`, starts the
long-running services, and triggers `openrec_cluster_bootstrap`.

The DAGs use only Kafka, Hive, Spark, Redis, Elasticsearch, and HTTP network endpoints. They do not
mount the Docker socket or manage containers.

`openrec_cluster_bootstrap` is manually scheduled and safe to rerun. It validates the platform and
online services, sends a real recommendation, then verifies the Kafka -> data-processor -> Redis
ingestion path.
