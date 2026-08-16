# example standalone

Run the whole open-rec stack on a single machine: Redis + Elasticsearch as the storage layer,
`rec-server` as the online recommendation service, and the sample dataset shipped in this repo.

Verified on **macOS** (Intel / Apple Silicon) and **Ubuntu 22.04 LTS** (x86_64).

![standalone](doc/openrec_standalone.jpg "standalone architecture")

## what you need

| Component | Version | Notes |
|---|---|---|
| JDK | 8 | `rec-server` targets Java 8 |
| Maven | 3.6+ | |
| Redis | 5+ | users, items, events and the i2i / hot / new recall tables |
| Elasticsearch | 8.5.0 | item vectors for embedding recall |

Repos involved — clone them side by side:

| Repo | Why |
|---|---|
| [rec-server](https://github.com/open-rec/rec-server) | the online service; also publishes `rec-proto` to your local Maven repo |
| [sdk](https://github.com/open-rec/sdk) | provides `rec-client`, a build dependency of `example/init` |
| [example](https://github.com/open-rec/example) | this repo — sample data and the data loader |
| [rank-engine](https://github.com/open-rec/rank-engine) | optional, step 8 — the ranking service |
| [rec-algorithm](https://github.com/open-rec/rec-algorithm) | optional — needed to build `rank-engine`'s wheel dependency |

Kafka is **not** needed in standalone mode: the `dev` profile pushes data straight to Redis.
Ranking is optional too — until you set up `rank-engine` (step 8) the `rank` node logs a warning and
the candidate order from recall is returned as-is.

The Redis and Elasticsearch index layout used below is documented in
[recall-engine](https://github.com/open-rec/recall-engine) (`redis/design.md`, `es/design.md`).

---

## 1. install the toolchain

### macOS

```shell
brew install openjdk@8 maven
```

### Ubuntu

```shell
sudo apt update
sudo apt install -y openjdk-8-jdk maven curl
```

Verify:

```shell
java -version   # 1.8.x
mvn -version
```

## 2. install redis

### macOS

```shell
brew install redis
brew services start redis
```

### Ubuntu

```shell
sudo apt install -y redis-server
sudo systemctl enable --now redis-server
```

In a container or WSL without systemd, start it directly instead:

```shell
redis-server --daemonize yes
```

Verify:

```shell
redis-cli ping   # PONG
```

## 3. install elasticsearch

Elasticsearch 8.x turns on TLS and authentication on first boot, so this takes a few more steps
than a plain download.

### macOS

```shell
# Intel
curl -O https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.5.0-darwin-x86_64.tar.gz
# Apple Silicon
curl -O https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.5.0-darwin-aarch64.tar.gz

tar -xzf elasticsearch-8.5.0-darwin-*.tar.gz
cd elasticsearch-8.5.0
./bin/elasticsearch -d -p pid
```

### Ubuntu

Raise `vm.max_map_count` first — Elasticsearch refuses to start below 262144:

```shell
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf   # persist
```

```shell
curl -O https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.5.0-linux-x86_64.tar.gz
tar -xzf elasticsearch-8.5.0-linux-x86_64.tar.gz
```

Elasticsearch **refuses to run as root**. If you are root (common in containers), create a
dedicated user and start it as that user:

```shell
sudo useradd -m -s /bin/bash elastic-run
sudo chown -R elastic-run: elasticsearch-8.5.0
sudo -u elastic-run elasticsearch-8.5.0/bin/elasticsearch -d -p pid
```

Otherwise:

```shell
cd elasticsearch-8.5.0
./bin/elasticsearch -d -p pid
```

### set the elastic password

Started with `-d` there is no terminal attached, so Elasticsearch **does not auto-generate** the
`elastic` password — the log says so explicitly (`Auto-configuration will not generate a password
... as we cannot determine if there is a terminal attached`). Set one yourself:

```shell
./bin/elasticsearch-reset-password -u elastic      # prompts for confirmation
./bin/elasticsearch-reset-password -u elastic -b   # or auto-generate, prints the new value
```

If you started Elasticsearch in the foreground instead, the generated password and enrollment token
are printed once at the end of the startup output.

Keep that password: both the data loader (step 5) and `rec-server` (step 6) need it.

Verify — note the `https` and `-k`, since the default certificate is self-signed:

```shell
curl -k -u elastic:<your-es-password> https://localhost:9200
```

## 4. build rec-server and rec-client

Build `rec-server` **first**: `mvn install` publishes `rec-proto` to your local Maven repo, and both
`rec-client` and the data loader depend on it.

```shell
git clone https://github.com/open-rec/rec-server.git
cd rec-server
mvn clean install -DskipTests
cd ..

git clone https://github.com/open-rec/sdk.git
cd sdk/java-client
mvn clean install -DskipTests
cd ../..
```

## 5. load the sample data

```shell
git clone https://github.com/open-rec/example.git
cd example/init
mvn clean package -DskipTests
cd ..
```

The loader resolves its data directory relative to the **current working directory**, defaulting to
`data/test` — so run it from the repo root (`example/`):

```shell
java -cp init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar \
  com.openrec.example.InitStandalone 127.0.0.1 6379 127.0.0.1 9200 elastic '<your-es-password>'
```

`data/test` holds 10k users, 10k items and 100k events plus the pre-computed i2i / hot / new /
embedding recall tables, spread over scenes `scene_0`, `scene_1` and `scene_2`.

To load a different dataset, pass its directory as an optional 7th argument. The `douban` dataset is
not committed (too large), so generate or download it yourself first:

```shell
java -cp init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar \
  com.openrec.example.InitStandalone 127.0.0.1 6379 127.0.0.1 9200 elastic '<your-es-password>' data/douban
```

### check redis

```shell
redis-cli DBSIZE
redis-cli GET 'user:{user_0}'
redis-cli GET 'item:{item_0}'
redis-cli ZCARD 'event:{user_247}:scene_0:click'
redis-cli ZRANGE 'i2i:{item_2}:scene_0' 0 4 WITHSCORES
redis-cli ZCARD 'hot:{scene_0}'
```

### check elasticsearch

One index per scene, `{scene}-item-vector-index`, holding 10-dimensional item vectors:

```shell
curl -k -u elastic:<your-es-password> 'https://localhost:9200/_cat/indices?v'

curl -k -u elastic:<your-es-password> -X POST \
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

## 6. start rec-server

`rec-server` needs your Elasticsearch password. Either edit
`rec-server/server/src/main/resources/application-dev.properties`:

```properties
es.host=127.0.0.1
es.port=9200
es.user=elastic
es.password=<your-es-password>
```

…or leave the file alone and override it on the command line when starting the jar (verified to take
precedence):

```shell
java -jar target/rec-server-1.0-SNAPSHOT.jar --spring.profiles.active=dev '--es.password=<your-es-password>'
```

Package it:

```shell
cd rec-server
mvn clean package -DskipTests
```

Optionally install the operation-rule plugin. `OperationRuleManager` loads it from
`<working-dir>/plugins/`, so put it next to wherever you launch the jar. Skipping this is fine — the
`operation` node just logs a warning and passes candidates through:

```shell
mkdir -p server/plugins
cp contrib/target/rec-contrib-1.0-SNAPSHOT.jar server/plugins/
```

```shell
cd server
java -jar target/rec-server-1.0-SNAPSHOT.jar --spring.profiles.active=dev
```

## 7. verify

```shell
curl http://localhost:13579/health
```

Ask for recommendations. `user_247` has 12 clicks in `scene_0`, which gives the `userTrigger` node
something to work with:

```shell
curl -s -X POST http://localhost:13579/api/recommend \
  -H 'Content-Type: application/json' -d '{
  "requestId": "test-1",
  "body": {
    "scene": "scene_0",
    "size": 10,
    "userId": "user_247",
    "deviceId": "device-1",
    "type": "click",
    "debug": true
  }
}'
```

`"debug": true` attaches the item detail to the response. The server log reports the candidate count
and latency of every DAG node, which is the quickest way to see which recall channel contributed
what.

Interactive API docs: http://localhost:13579/swagger-ui/index.html

## 8. optional: enable ranking

Everything above works without a ranking stage. To turn it on, run `rank-engine` — it reads user and
item features straight out of the Redis you just seeded, so do this **after** step 5.

`rank-engine` depends on the `rec-algorithm` wheel, so build that first:

```shell
git clone https://github.com/open-rec/rec-algorithm.git
cd rec-algorithm
pip install -r requirements.txt
bash package.sh
pip install dist/rec_algorithm-0.0.1-*.whl
cd ..

git clone https://github.com/open-rec/rank-engine.git
cd rank-engine
pip install -r requirements.txt
bash start.sh          # uvicorn on port 8000
```

A model must be loaded before scoring — `POST /model/score` returns `MODEL_NOT_LOAD_YET` otherwise.
Point it at a checkpoint (a pre-trained one lives in the
[model](https://github.com/open-rec/model) repo as `rank/lr.pth`, or train your own via
`rec-algorithm`'s `test_lr.py::test_train`):

```shell
curl -X POST http://127.0.0.1:8000/model/load \
  -H 'Content-Type: application/json' \
  -d '{"type": "lr", "model": "model/lr.pth", "dim": 63}'

curl -X POST http://127.0.0.1:8000/model/score \
  -H 'Content-Type: application/json' \
  -d '{"user_id": "user_247", "item_ids": ["item_0", "item_1"]}'
```

`dim` must match the feature width the checkpoint was trained with — it depends on the one-hot
cardinality of the data in Redis, so a checkpoint trained on `douban` will not load against
`data/test`. Rank engine docs: http://127.0.0.1:8000/docs

`rec-server` already points at `127.0.0.1:8000` (`rank.host` / `rank.port` in
`application-dev.properties`); re-run the recommend request from step 7 and the `rank` node will
start contributing scores.

---

## troubleshooting

**`can not run elasticsearch as root`** — start it as an unprivileged user, see step 3.

**`max virtual memory areas vm.max_map_count [65530] is too low`** — Linux only, raise it as shown in
step 3.

**Lost the elastic password** — `./bin/elasticsearch-reset-password -u elastic`.

**`Could not resolve dependencies ... rec-client` / `rec-proto`** — build `rec-server` with
`mvn clean install` before the sdk and the loader; `-DskipTests` avoids needing a live Redis/ES at
that point.

**`data dir not found`** — run the loader from the `example/` repo root, or pass the data directory
as the 7th argument.

**`embedding` recalls 0 items on the first few requests** — expected, and it recovers on its own. The
`embedding` node has `"timeout": 100` (ms) in `graph.json`, while the first request pays for the TLS
handshake and index warm-up (~650ms here). The engine cancels the node's future, the resulting
`InterruptedException` is swallowed by `EmbeddingNode`, and the node exports an empty list — the
request still succeeds, just without embedding candidates. Measured on the sample data: 646ms → 0
items, 482ms → 0 items, then 38ms → 10 items. Raise the node's `timeout` in `graph.json` if you want
it to contribute from the first call.

**Recommendations come back empty** — check that the scene exists in the dataset (`scene_0` /
`scene_1` / `scene_2`) and that the user has click events, e.g.
`redis-cli ZCARD 'event:{user_247}:scene_0:click'`. Also note the `collector` node writes a fake
expose record for everything it returns and the `filter` node excludes exposed items for the next
24h, so repeating the same request drains the candidate pool.

**`rank score failed` / `Connection refused` against port 8000 in the log** — `rank-engine` is not
running; recall order is returned unranked. See step 8. Note this degrades silently: recommendations
still come back, just unranked.

**`MODEL_NOT_LOAD_YET` from rank-engine** — call `POST /model/load` first, see step 8.

**`operation load DefaultOperationRule failed`** — the pf4j plugin jar is missing from
`<working-dir>/plugins/`, see step 6.
