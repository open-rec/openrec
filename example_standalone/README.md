# example standalone

Run the minimum OpenRec recommendation chain on one machine. Redis and Elasticsearch come from the
sibling `bigdata-platform` repository; `rec-server` runs with its `dev` profile and writes pushed
users, items, and events directly to Redis. Kafka, Spark, and `rank-engine` are not required.

![standalone](doc/openrec_standalone.jpg "standalone architecture")

## Prerequisites and layout

Install Docker with the Compose plugin, JDK 8, and Maven 3.6+. Keep the component repositories in
the workspace layout used by this project:

```text
openrec/
├── bigdata-platform/
├── rec-server/
├── sdk/
└── example/
```

All commands below start from the `openrec/` workspace root. The serving containers use the values
defined in `bigdata-platform/.env`:

| Service | Host endpoint | Credentials |
|---|---|---|
| Redis | `127.0.0.1:6380` | none |
| Elasticsearch | `https://127.0.0.1:9200` | `elastic` / `openrec-es-password` |
| rec-server | `http://127.0.0.1:13579` | none |
| Web Demo | `http://127.0.0.1:12345` | none |

The `rec-server` dev properties already match these defaults. If `.env` is changed, override the
corresponding Spring properties when starting the server and pass the same values to the loader.

## One-command experience

Run the complete chain from infrastructure through the visual demo:

```shell
./example/example_standalone/start.sh
```

The script requires JDK 8, starts and checks the standalone containers, builds Java components,
loads sample data, then starts rec-server and the Web Demo in the background. Open the URL printed
at completion: `http://127.0.0.1:12345`. The script exits with a clear error if that port is already
occupied.

Java components are built from current sources in an isolated `.runtime/build` tree. This avoids
permission or stale-artifact problems when repository `target/` directories were created in a
container, and does not modify those directories.

Application logs and PID files are kept under `example/example_standalone/.runtime/`. Stop the two
Java applications while retaining data, or stop storage as well:

```shell
./example/example_standalone/stop.sh
./example/example_standalone/stop.sh --with-storage
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
cd ../../example/init
mvn clean package -DskipTests
cd ../..
```

## 3. Load the sample data

Run the loader from `example/`, because its default `data/test` path is relative to the current
working directory:

```shell
cd example
java -cp init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar \
  com.openrec.example.InitStandalone \
  127.0.0.1 6380 127.0.0.1 9200 elastic 'openrec-es-password'
cd ..
```

This imports users, items, events, i2i/hot/new tables, and embedding vectors. Pass an optional final
argument to load another directory, for example `data/douban`.

Verify the imported data through the containers:

```shell
docker exec redis redis-cli DBSIZE
docker exec redis redis-cli ZCARD 'event:{user_247}:scene_0:click'
curl -k -u elastic:openrec-es-password 'https://127.0.0.1:9200/_cat/indices?v'
```

## 4. Start rec-server

The default graph has `open=false` on the `rank` node for the Standalone chain. Recall results therefore
flow from `combine` directly through the disabled rank node without contacting `rank-engine`.

```shell
cd rec-server/server
java -jar target/rec-server-1.0-SNAPSHOT.jar --spring.profiles.active=standalone
```

The default operation rule allocates results as 30% i2i, 30% embedding, 20% hot, and 20% new,
selecting the highest scores available inside those quotas. For this manual startup, copy the plugin
before launching the server:

```shell
mkdir -p plugins
cp ../contrib/target/rec-contrib-1.0-SNAPSHOT.jar plugins/
```

The one-command launcher copies the plugin and passes its absolute path automatically. To try the
random insertion strategy instead, set `operationName` to `RandomInsertOperationRule`; the bundled
configuration reserves 10% hot and 10% new candidates at random positions.

## 5. Verify recommendations

```shell
curl http://127.0.0.1:13579/health

curl -s -X POST http://127.0.0.1:13579/api/recommend \
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
cd example/web
mvn clean package -DskipTests
java -jar target/rec-example-web-1.0-SNAPSHOT.jar
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

- A cold embedding query may exceed its 100 ms DAG timeout while Elasticsearch warms up. Retry the
  request or raise the embedding timeout in `graph.json`.
- Repeated requests can exhaust the visible sample candidates because `collector` records exposure
  and `filter` excludes exposed items for 24 hours.
- If the loader cannot connect, confirm that Redis uses host port `6380`, not its container port
  `6379`, and that the Elasticsearch password still matches `bigdata-platform/.env`.
- `./platform.sh down -v` also deletes stored data. Use it only when a complete reset is intended,
  then rerun the loader.
