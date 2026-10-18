# OpenRec Standalone Example

Run the minimum OpenRec recommendation chain on one machine. Redis and Elasticsearch come from the
sibling `bigdata-platform` repository; the containerized `rec-server` runs with its `standalone`
profile and writes pushed users, items, and events directly to Redis. The standalone rec-console
provides monitoring, entity diagnostics, and Serving Graph management. Kafka, Spark, Airflow, and
`rank-engine` are not required.

```mermaid
flowchart LR
    User[User or application] --> Web[Web Demo or SDK]
    Web --> API[rec-server<br/>standalone profile]

    subgraph Storage[bigdata-platform standalone]
        Redis[(Redis<br/>entities · events · exposure filters)]
        ES[(Elasticsearch<br/>recall and vector indexes)]
    end

    API <-->|entities · behavior · filters| Redis
    API -->|recall · vector queries| ES
    API -->|recommendations| Web

    Source[Entity and event data] --> Algorithm[rec-algorithm<br/>local mode]
    Source -->|online entities and behavior| Redis
    Algorithm --> Dataset[Recall datasets]
    Dataset --> ES
```

The diagram is deployment-level. The recall, filtering, combination, and operation nodes inside
`rec-server` are documented in the rec-server serving DAG and are intentionally not repeated here.

## Prerequisites and layout

Install Docker with the Compose plugin, JDK 21, Maven 3.9+, Python 3, curl, and rsync. Keep the component repositories in
the workspace layout used by this project:

```text
openrec/
├── bigdata-platform/
├── data-processor/      # packaged feature contracts checked during artifact preparation
├── rank-engine/         # build context for the artifact-builder image when needed
├── rec-algorithm/       # required artifact validation and generation tools
├── rec-console/
├── rec-server/
├── sdk/
└── openrec/
```

These are source-build dependencies, not additional standalone services: neither data-processor
nor rank-engine runs as a standalone application. Startup checks the packaged feature contracts
and uses rec-algorithm to validate the model bundle. If it is absent or stale, startup rebuilds
it in the rank-engine image, building that image if necessary. The sibling `model/` directory
may be reused when valid or generated on demand.

All commands below start from the `openrec/` workspace root. The serving containers use the values
defined in `bigdata-platform/.env`:

| Service | Host endpoint | Credentials |
|---|---|---|
| Redis | `127.0.0.1:6380` | none |
| Elasticsearch | `https://127.0.0.1:9200` | `elastic` / `openrec-es-password` |
| rec-server | `http://127.0.0.1:13579` | none |
| rec-console | `http://127.0.0.1:8095` | none |
| Web Demo | `http://127.0.0.1:12345` | none |

The `rec-server` standalone properties already match these defaults. If `.env` is changed, override the
corresponding Spring properties when starting the server and pass the same values to the loader.

## One-command experience

Run the complete chain from infrastructure through the visual demo:

```shell
./openrec/standalone/start.sh
```

The script requires JDK 21 for all Java components, starts and checks the standalone infrastructure, builds the Java client
components, imports the bundled sample entities, behavior, and recall datasets, builds and starts
the rec-server and standalone rec-console containers, and sends a real recommendation request
before starting the Web Demo.
The smoke request explicitly routes to the default experiment and verifies `item_cf_i2i`,
`content_i2i`, `user_cf_u2i`, `item_seq_emb`, `item_search`, and hot
results from its `WeightedChannelOperationRule` while bypassing Rank and Kafka. It intentionally
does not require `new`, whose online item supply belongs to the application.
Open the URL printed at completion: `http://127.0.0.1:12345`. The script exits with a clear error if
either application port is already occupied.

Startup configures automatic server-side warmup using the fixture user, then waits for `/ready`.
The server first uses an independent warmup budget, then requires three consecutive complete
recommendation rounds under normal budgets. Probes do not write synthetic exposure records.
Until this finishes, business recommendation requests return 503 while `/health` remains available.
The Web Demo starts only after readiness and the recall-node/Rank/Kafka smoke checks pass.
Recall availability uses pre-selection `recallDiagnostics`; final results need not cover every channel.
Smoke response bodies are recorded in `.runtime/logs/recommendation.log`.

GitHub's standalone functional acceptance uses `RECOMMEND_DEADLINE_MS=10000` and
`OPENREC_GRAPH_NODE_TIMEOUT_MS=1000`, matching cluster CI's shared-runner budgets. To reproduce
these settings locally, pass both variables to `start.sh`. Without these overrides, the normal
1000 ms request deadline and packaged node deadlines remain in effect.

Java components are built from current sources in an isolated `.runtime/build` tree. This avoids
permission or stale-artifact problems when repository `target/` directories were created in a
container, and does not modify those directories.

Web Demo logs and its PID file are kept under `openrec/standalone/.runtime/`. The rec-server
container is owned by the example Compose project. Stop the applications while retaining data, or
stop storage as well:

```shell
./openrec/standalone/stop.sh
./openrec/standalone/stop.sh --with-storage
```

The detailed steps below remain useful for development and troubleshooting.

## 1. Start the storage containers

Build the two images once, then start only the serving layer. Do not install Redis or Elasticsearch
on the host.

```shell
cd bigdata-platform
./platform.sh build standalone
./platform.sh up standalone
./platform.sh ps
./platform.sh smoke standalone
cd ..
```

Bring-up is asynchronous. If `smoke` fails immediately after `up`, inspect
`./platform.sh logs redis elasticsearch`, wait for both health checks, and run it again.

## 2. Build the Java components

Build in dependency order. `rec-server install` publishes `rec-proto`, and the SDK publishes
`rec-client`; both are required by the example loader.

```shell
cd rec-server
mvn clean install -DskipTests
cd ../sdk/java-client
mvn clean install -DskipTests
cd ../../openrec/init
mvn clean package -DskipTests
cd ../..
```

## 3. Load the sample data

`start.sh` supports direct mode switching. If cluster application containers or its managed Web
Demo are running, it stops the cluster application layer with `cluster/stop.sh
--keep-platform` before doing any build or data import. Redis, Elasticsearch and the remaining
shared platform stay running. Unrelated processes occupying standalone ports still cause an early,
non-destructive failure.

Run the loader from `openrec/`, because its default `data/test` path is relative to the current
working directory:

```shell
cd openrec
./init/tools/ensure-model-artifacts.sh
java -cp init/target/rec-example-init-0.1.0-jar-with-dependencies.jar \
  com.openrec.example.InitServingData standalone \
  127.0.0.1 6380 127.0.0.1 9200 elastic 'openrec-es-password'
cd ..
```

The start script first validates `model/default.manifest.json` against the raw CSV hashes and rebuilds
stale deployable artifacts. The loader imports users, items, events and feature snapshots into
Redis. It loads hot, new, item-CF I2I, content I2I, UserCF U2I, and item/user BM25 documents into
versioned Elasticsearch indexes behind `openrec-recall-{tableName}-active`, and `item_seq_emb` vectors into the per-scene vector
index. Recall tables are stored only in Elasticsearch; Redis holds online state, including
entities, features and click/exposure history. Direct loader invocation
accepts optional `data_dir` and `model_dir` arguments.

Verify the imported data through the containers:

```shell
docker exec redis redis-cli DBSIZE
docker exec redis redis-cli ZCARD 'event:{user_247}:scene_0:click'
curl -k -u elastic:openrec-es-password 'https://127.0.0.1:9200/_cat/indices?v'
curl -k -u elastic:openrec-es-password \
  'https://127.0.0.1:9200/_alias/openrec-recall-*-active'
```

## 4. Start rec-server

The graph keeps the `rank` node enabled so Cluster can use the same DAG. In Standalone,
`application-standalone.properties` sets `rank.open=false`; RankNode therefore passes the complete
combine result to the operation strategy without contacting `rank-engine`.

```shell
RECOMMEND_WARMUP_USER_ID=user_0 RECOMMEND_WARMUP_SCENE=scene_0 \
  docker compose -f rec-server/docker-compose.standalone.yml up -d --build --wait
```

The default operation rule allocates results across `item_cf_i2i`, `content_i2i`, `user_cf_u2i`,
`item_seq_emb`, hot, and new,
selecting the highest scores available inside those quotas. The image includes the operation plugin.
To try the random insertion strategy instead, set `operationName` to `RandomInsertOperationRule`;
the bundled
configuration reserves 10% hot and 10% new candidates at random positions. Startup verification does
not require the `new` share to be present because applications own the online supply of newly
published items.

## 5. Verify recommendations

```shell
# Wait for automatic warmup; fail explicitly if readiness does not complete.
ready=false
for attempt in $(seq 1 120); do
  if curl -fsS http://127.0.0.1:13579/ready; then
    ready=true
    break
  fi
  sleep 1
done
[ "$ready" = true ] || { echo "Recommendation warmup failed" >&2; exit 1; }

curl -s -X POST http://127.0.0.1:13579/api/recommend/item \
  -H 'Content-Type: application/json' -d '{
  "requestId": "standalone-1",
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

Swagger UI is available at `http://127.0.0.1:13579/swagger-ui/index.html`. With `debug: true`, each
result includes its recall channel and score.

## 6. Start the visual demo

```shell
cd openrec/web
mvn clean package -DskipTests
java -jar target/rec-example-web-0.1.0.jar
```

Open `http://127.0.0.1:12345`.

## Operations and troubleshooting

Manage storage exclusively through `bigdata-platform`:

```shell
cd bigdata-platform
./platform.sh ps
./platform.sh logs redis elasticsearch
./platform.sh restart redis elasticsearch
./platform.sh down
```

- A cold Elasticsearch connection can make the first recommendation incomplete. Warm the service
  with a request and retry; keep the serving DAG latency limits unchanged.
- Repeated requests can exhaust the visible sample candidates because `collector` records exposure
  and `filter` excludes exposed items for 24 hours.
- If the loader cannot connect, confirm that Redis uses host port `6380`, not its container port
  `6379`, and that the Elasticsearch password still matches `bigdata-platform/.env`.
- `./platform.sh down -v` also deletes stored data. Use it only when a complete reset is intended,
  then rerun the loader.


Optional semantic recall: configure the local model mount and GPU as described in
[the vLLM infrastructure guide](https://github.com/open-rec/bigdata-platform/blob/master/vllm/README.md), then export
`EMBEDDING_ENABLED=true` before starting this profile. Startup verifies online/offline
embedding compatibility and initializes `item_title_emb.csv` into the Qwen aliases.
Default startup does not require vLLM or GPU. Graph overrides from previous deployments
need the new query timeout/configuration. Direct component Compose deployments must
initialize candidate vectors separately before enabling online query embeddings.

Default artifact initialization uses the CPU bundle (v19) and requires no Qwen
weights or transformers. Existing verified `item_title_emb.csv` is preserved during
rebuilds. To enable query embedding, provide matching precomputed title vectors
and the inference service; the default bootstrap does not generate language vectors.

## Raw-data initialization

Both modes accept `OPENREC_DATA_DIR` and `OPENREC_MODEL_ROOT`. Missing or stale
model bundles are rebuilt from raw CSVs before import. Mode-specific initialization
lives in each mode’s `init.sh`, with a shared Java storage loader. See
[initialization inputs, reuse rules, and existing-data behavior](../docs/initialization.md).
