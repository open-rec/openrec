# example cluster

The distributed deployment: data arrives through Kafka, is processed by a streaming/batch pipeline, and
lands in Redis and Elasticsearch for `rec-server` to serve.

> `data-processor` now provides equivalent Flink and Spark Structured Streaming implementations.
> Choose one engine in production; both write online features to Redis and durable training data to HDFS.

![cluster](doc/openrec_cluster.jpg "cluster architecture")

## quick start

From this directory, one command builds and starts the complete local cluster demo:

```shell
./start.sh
```

It starts the complete `bigdata-platform`, installs the daily-partition Hive tables, submits the
Spark `data-processor`, starts `rank-engine`, loads serving samples, and starts cluster-mode
`rec-server` plus the Web Demo. It also verifies a real recommendation and the
`rec-server -> Kafka -> Spark -> Redis` ingestion path before returning.

Stop every OpenRec demo application, streaming job, rank container, and cluster platform service:

```shell
./stop.sh
```

Stop applications while retaining the platform containers and data for a faster restart:

```shell
./stop.sh --keep-platform
```

Runtime builds, PID files, and logs are isolated under `.runtime/`. Startup failures trigger the
same safe cleanup automatically. Docker volumes are retained even when the platform containers are
stopped; only an explicit `bigdata-platform/platform.sh down -v` deletes stored data.

## how it differs from standalone

| | standalone | cluster |
|---|---|---|
| ingest | push API writes Redis directly (`pushRedisService`) | push API publishes to Kafka (`pushKafkaService`) |
| processing | offline scripts run by hand | streaming + batch pipeline |
| offline compute | `rec-algorithm` on one machine | Spark / Hive |
| profile | `--spring.profiles.active=standalone` | `--spring.profiles.active=cluster` |

The serving path is identical — same DAG, same Redis/Elasticsearch key layout. Only how data gets in
changes.

## dependencies

| Component | Where | Status |
|---|---|---|
| [rec-server](https://github.com/open-rec/rec-server) | the online service | available |
| [rec-algorithm](https://github.com/open-rec/rec-algorithm) | local and distributed Spark recall/rank computation | available |
| [recall-engine](https://github.com/open-rec/recall-engine) | Redis + Elasticsearch install and index design | available |
| [bigdata-platform](https://github.com/open-rec/bigdata-platform) | ZooKeeper, Kafka, Spark via Docker Compose | available |
| `data-processor` | Kafka → Redis/HDFS feature pipeline | available (Flink and Spark) |
| Hadoop, Hive, Spark | storage and compute infrastructure | available in `bigdata-platform` |
| Flink runtime | alternative streaming runtime | available in `bigdata-platform` |

## 1. storage

Redis and Elasticsearch, same as standalone. The install scripts cover macOS and Linux:

```shell
git clone https://github.com/open-rec/recall-engine.git
cd recall-engine
bash redis/local/install.sh
bash es/local/install.sh
```

Elasticsearch 8 starts with TLS and auth enabled and, when started with `-d`, does **not** generate an
`elastic` password — set one with `bin/elasticsearch-reset-password -u elastic`. Keep it; `rec-server`
needs it.

For a real cluster, replace these single-node installs with managed or multi-node deployments; the key
layout in [recall-engine](https://github.com/open-rec/recall-engine) is cluster-safe (ids are wrapped
in `{}` hash tags so related keys share a slot).

## 2. kafka

A three-broker cluster with ZooKeeper:

```shell
git clone https://github.com/open-rec/bigdata-platform.git
cd bigdata-platform
bash start_kafka_cluster.sh          # brokers on 19092 / 29092 / 39092
```

The brokers advertise their **container** hostnames, so a client on the host needs
`127.0.0.1 kafka-1 kafka-2 kafka-3` in `/etc/hosts` — see the
[bigdata-platform README](https://github.com/open-rec/bigdata-platform#connecting-to-kafka-from-the-host)
for the alternatives.

Or run a single broker from the Apache distribution:

```shell
curl -O https://archive.apache.org/dist/kafka/2.5.0/kafka_2.12-2.5.0.tgz
tar -xzf kafka_2.12-2.5.0.tgz
cd kafka_2.12-2.5.0
bash bin/zookeeper-server-start.sh config/zookeeper.properties &
bash bin/kafka-server-start.sh config/server.properties &
```

`rec-server` publishes to three topics, configurable via `spring.kafka.topic.*`:

| Topic | Payload |
|---|---|
| `item` | item rows |
| `user` | user rows |
| `event` | behaviour events |

## 3. real-time feature processor

```shell
bash start_spark_cluster.sh          # master 8080, workers 8081/8082, JupyterLab 8888
cd ../data-processor
mvn -pl spark -am -DskipTests package
spark-submit --class com.openrec.dp.spark.SparkFeatureJob \
  --master spark://spark-master:7077 spark/target/rec-spark-1.0-SNAPSHOT.jar
```

Alternatively start `bigdata-platform/start_flink_cluster.sh`, build `-pl flink`, and submit
`com.openrec.dp.flink.DpJob` to its Flink 1.14 cluster.
Both jobs use the shared `feature-core` formulas, update Redis snapshots, and append raw records plus
feature snapshots to HDFS. The persisted data can be joined by entity and `asOfTime` for offline
`rec-algorithm` training.

## 4. rec-server in cluster mode

```shell
git clone https://github.com/open-rec/rec-server.git
cd rec-server
mvn clean package -DskipTests
```

Set the storage and Kafka endpoints in `server/src/main/resources/application-cluster.properties`:

```properties
server.pushService=pushKafkaService
redis.hostName=<redis-host>
es.host=<es-host>
es.password=<your-es-password>
spring.kafka.bootstrap-servers=kafka-1:19092,kafka-2:29092,kafka-3:39092
```

```shell
cd server
java -jar target/rec-server-1.0-SNAPSHOT.jar --spring.profiles.active=cluster
```

The `prod` profile only changes where **pushed data** goes: `POST /api/push/*` now produces to Kafka
instead of writing Redis. Recommendation serving still reads Redis and Elasticsearch directly.

## 5. feature data flow

With `pushKafkaService` active, `data-processor` consumes the `item`, `user`, and `event` topics.
Inspect the source stream when diagnosing ingestion:

```shell
docker exec -it <kafka-container> \
  kafka-console-consumer --bootstrap-server kafka-1:19092 --topic event --from-beginning
```

Raw records are stored under `/openrec/raw`; online user/item behavioral snapshots are stored under
`/openrec/features` and Redis keys `feature:user:{id}` / `feature:item:{id}`.

## verify

```shell
curl http://<server>:13579/health
```

Then issue a recommend request as in
[example_standalone](../example_standalone#7-verify).
