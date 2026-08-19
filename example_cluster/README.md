# example cluster

The distributed deployment: data arrives through Kafka, is processed by a streaming/batch pipeline, and
lands in Redis and Elasticsearch for `rec-server` to serve.

> **Status: incomplete.** The stream/batch processing component (`data-processor`) is not published
> yet, so this guide cannot be followed end to end. Everything below — the infrastructure and
> `rec-server` in `prod` mode — does work, and is useful for testing the Kafka ingest path. For a
> setup that runs to completion today, use [example_standalone](../example_standalone).

![cluster](doc/openrec_cluster.jpg "cluster architecture")

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
| [rec-algorithm](https://github.com/open-rec/rec-algorithm) | recall/rank computation | available (single-machine; distributed version pending) |
| [recall-engine](https://github.com/open-rec/recall-engine) | Redis + Elasticsearch install and index design | available |
| [bigdata-platform](https://github.com/open-rec/bigdata-platform) | ZooKeeper, Kafka, Spark via Docker Compose | available |
| `data-processor` | Kafka → Redis/ES pipeline | **not published** |
| Hadoop, Hive, Flink | batch/stream infrastructure | not provided by this project |

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

## 3. spark (optional, for offline compute)

```shell
bash start_spark_cluster.sh          # master 8080, workers 8081/8082, JupyterLab 8888
```

`rec-algorithm` currently runs on a single machine (pandas / torch); there is no Spark job in the repo
yet. Use this cluster to prototype the distributed version.

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

## 5. the missing link

With `pushKafkaService` active, nothing consumes those topics yet — that is `data-processor`'s job:
read the `item` / `user` / `event` topics, apply the index layout from
[recall-engine](https://github.com/open-rec/recall-engine/blob/main/redis/design.md), and write Redis
and Elasticsearch.

Until it is published, you can still exercise the ingest path by consuming the topics manually:

```shell
docker exec -it <kafka-container> \
  kafka-console-consumer --bootstrap-server kafka-1:19092 --topic event --from-beginning
```

To seed data for serving in the meantime, run the standalone loader — it writes Redis and
Elasticsearch directly, bypassing Kafka:

```shell
cd example
java -cp init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar \
  com.openrec.example.InitStandalone <redis_host> 6379 <es_host> 9200 elastic '<password>'
```

## verify

```shell
curl http://<server>:13579/health
```

Then issue a recommend request as in
[example_standalone](../example_standalone#7-verify).
