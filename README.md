# example

Everything needed to get `open-rec` running locally: a sample dataset, a loader that seeds Redis and
Elasticsearch, and step-by-step guides for both deployment modes.

New here? Go straight to **[example_standalone](example_standalone)** — it walks through a full working
stack on one machine (macOS or Linux).

## contents

| Directory | Contents |
|---|---|
| [data](data) | sample datasets — a committed synthetic one, plus notes on the Douban dataset |
| [init](init) | `InitStandalone`, the loader that writes a dataset into Redis / Elasticsearch |
| [web](web) | a visual demo: four recall tabs, live behaviour feedback through the sdk |
| [example_standalone](example_standalone) | single-machine setup: Redis + Elasticsearch + rec-server |
| [example_cluster](example_cluster) | distributed setup via Kafka (incomplete — `data-processor` is unpublished) |

## architecture

### standalone

Redis + Elasticsearch + `rec-server`. Pushed data goes straight into Redis and the offline recall
tables are loaded from CSV. Everything required is in this repo.

![standalone](example_standalone/doc/openrec_standalone.jpg "standalone")

More details: [example_standalone](example_standalone)

### cluster

Ingest moves to Kafka and processing is distributed. The serving path is unchanged — same DAG, same key
layout. The stream/batch processor is not published yet, so this mode cannot currently be run to
completion.

![cluster](example_cluster/doc/openrec_cluster.jpg "cluster")

More details: [example_cluster](example_cluster)

## init data

Build the loader — `rec-proto` (from `rec-server`) and `rec-client` (from `sdk`) must be in your local
Maven repo first — then run it from this directory:

```shell
cd init && mvn clean package -DskipTests && cd ..

java -cp init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar \
  com.openrec.example.InitStandalone <redis_host> <redis_port> <es_host> <es_port> <es_user> <es_password> [data_dir]
```

`data_dir` is optional and resolved relative to the working directory, defaulting to `data/test` — the
synthetic dataset committed here:

```shell
java -cp init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar \
  com.openrec.example.InitStandalone 127.0.0.1 6379 127.0.0.1 9200 elastic '<es-password>'
```

Full argument reference, the expected CSV layout and what gets written where: [init](init).

## check the data

### redis

```shell
redis-cli DBSIZE
redis-cli GET 'user:{user_0}'
redis-cli GET 'item:{item_0}'
redis-cli ZCARD 'event:{user_247}:scene_0:click'
redis-cli ZRANGE 'i2i:{item_2}:scene_0' 0 4 WITHSCORES
redis-cli ZCARD 'hot:{scene_0}'
```

Users and items are stored as JSON strings:

```
127.0.0.1:6379> GET 'item:{item_0}'
{"id":"item_0","weight":5,"title":"title_0","category":"category_98","tags":"tags_26",
 "scene":"scene_2","pubTime":"1667355833","modifyTime":"1667037573","expireTime":"1667494042",
 "status":1,"extFields":"{}"}
```

Events, i2i, hot and new are sorted sets — events scored by timestamp, the recall tables by relevance.
The full key layout is documented in
[recall-engine](https://github.com/open-rec/recall-engine/blob/main/redis/design.md).

### elasticsearch

One vector index per scene, `{scene}-item-vector-index`:

```shell
curl -k -u elastic:<password> 'https://localhost:9200/_cat/indices/*vector*?v'

curl -k -u elastic:<password> -X POST \
  https://localhost:9200/scene_0-item-vector-index/_search \
  -H 'Content-Type: application/json' -d '{
  "knn": {
    "field": "vector",
    "query_vector": [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9],
    "k": 10,
    "num_candidates": 20
  },
  "fields": ["id"],
  "size": 5
}'
```

Elasticsearch 8 needs `https`, and `-k` because the default certificate is self-signed.

## related repos

| Repo | Role |
|---|---|
| [rec-server](https://github.com/open-rec/rec-server) | the online recommendation service |
| [sdk](https://github.com/open-rec/sdk) | `rec-client`, the Java client |
| [recall-engine](https://github.com/open-rec/recall-engine) | Redis / Elasticsearch install scripts and index design |
| [rec-algorithm](https://github.com/open-rec/rec-algorithm) | offline recall and rank computation |
| [rank-engine](https://github.com/open-rec/rank-engine) | online ranking service (optional) |
| [model](https://github.com/open-rec/model) | pre-computed Douban recall tables and a trained model |
| [bigdata-platform](https://github.com/open-rec/bigdata-platform) | Kafka / ZooKeeper / Spark for cluster mode |
