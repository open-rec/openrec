# init

Loads a CSV dataset into a running Redis + Elasticsearch so `rec-server` has something to recommend.
This is the bootstrap step of
[example_standalone](../example_standalone); it is a one-shot batch job, not a service.

Entry point: `com.openrec.example.InitStandalone`.

## build

`rec-proto` (from `rec-server`) and `rec-client` (from `sdk`) must be in your local Maven repo first:

```shell
cd rec-server && mvn clean install -DskipTests && cd ..
cd sdk/java-client && mvn clean install -DskipTests && cd ../..
cd example/init && mvn clean package -DskipTests
```

Produces `target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar`.

## run

Start Redis and Elasticsearch from the sibling `bigdata-platform` repository first:

```shell
cd bigdata-platform
./platform.sh up standalone
./platform.sh smoke standalone
cd ..
```

```shell
java -cp init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar \
  com.openrec.example.InitStandalone <redis_host> <redis_port> <es_host> <es_port> <es_user> <es_password> [data_dir] [model_dir]
```

| Argument | Example |
|---|---|
| `redis_host` `redis_port` | `127.0.0.1` `6380` |
| `es_host` `es_port` | `127.0.0.1` `9200` |
| `es_user` `es_password` | `elastic` `openrec-es-password` |
| `data_dir` | optional, defaults to `data/test` |
| `model_dir` | optional, defaults to sibling `../model` |

`data_dir` is resolved **relative to the working directory**, so run it from the repo root:

```shell
cd example
java -cp init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar \
  com.openrec.example.InitStandalone 127.0.0.1 6380 127.0.0.1 9200 elastic 'openrec-es-password'
```

Loading the bundled sample dataset takes roughly 20 seconds and writes about 58,000 Redis keys plus
three Elasticsearch indexes.

Redis and Elasticsearch are loaded independently: if one fails the error is logged and the other still
runs, so check the output rather than assuming an exit code of 0 means everything landed.

## expected data layout

```
example/data/test/
├── item.csv          id,title,category,tags,scene,pub_time,modify_time,expire_time,status,weight,ext_fields
├── user.csv          id,device_id,name,gender,age,country,city,phone,tags,register_time,login_time,ext_fields
└── event.csv         id,user_id,item_id,trace_id,scene,type,value,time,is_login,ext_fields

model/
├── feature/default/
│   ├── user_feature.csv
│   └── item_feature.csv
└── recall/
    ├── item_cf_i2i.csv  scene,left_item,right_item,score
    ├── content_i2i.csv  scene,left_item,right_item,score
    ├── user_cf_u2i.csv  scene,user,item,score
    ├── hot.csv          scene,item,score
    ├── new.csv          scene,item,score
    └── item_seq_emb.csv scene,item,vector
```

Headers must match because columns are read by name. The startup scripts validate the model bundle
against SHA-256 hashes of the three raw input files and rebuild stale artifacts before invoking the
loader.

## what it writes

| Source | Destination | Type |
|---|---|---|
| `item.csv` | `item:{itemId}` | JSON string |
| `user.csv` | `user:{userId}` | JSON string |
| `event.csv` | `event:{userId}:{scene}:{type}` | sorted set, score = event time |
| `feature/default/user_feature.csv` | `feature:user:{userId}` | JSON feature snapshot |
| `feature/default/item_feature.csv` | `feature:item:{itemId}` | JSON feature snapshot |
| `recall/item_cf_i2i.csv` | `item-cf-i2i:{leftItem}:{scene}` | sorted set |
| `recall/content_i2i.csv` | `content-i2i:{leftItem}:{scene}` | sorted set |
| `recall/user_cf_u2i.csv` | `user-cf-u2i:{userId}:{scene}` | sorted set |
| `recall/hot.csv` | `hot:{scene}` | sorted set |
| `recall/new.csv` | `new:{scene}` | sorted set, score = normalized score × load-time Unix timestamp |
| `recall/item_seq_emb.csv` | `{scene}-item-vector-index` | Elasticsearch, `dense_vector` (10 dims) |

The same recall CSVs are also loaded into versioned Elasticsearch indexes behind their
`openrec-recall-{tableName}-active` aliases. The vector indexes are **dropped and recreated** on
every run; Redis keys are overwritten in place, so
stale keys from a previous dataset survive. Flush Redis if you switch datasets.

`new.csv` supplies a normalized freshness score in `[0, 1]`. The loader projects it onto the Unix
time domain expected by `NewNode` by multiplying every score by one timestamp captured at the start
of the new-table import. This preserves ordering and lets the configured duration query select the
freshest rows. `NewNode` and the Web Demo divide the stored value by the query-time Unix timestamp
before returning it, so clients continue to receive a normalized score. Future online writes can
use their event Unix timestamp directly.

The active online recall contract, stable aliases, and storage implementations are documented in
the [`rec-server` RecallStore guide](https://github.com/open-rec/rec-server#recall-store).

## verify

```shell
docker exec redis redis-cli DBSIZE
docker exec redis redis-cli GET 'user:{user_0}'
docker exec redis redis-cli ZCARD 'event:{user_247}:scene_0:click'
curl -k -u elastic:openrec-es-password 'https://localhost:9200/_cat/indices/*vector*?v'
```

## notes

- **It logs almost nothing on success.** There is no `log4j2.xml`, so Log4j2 defaults to root level ERROR and the per-table "finished" messages are discarded. Verify by querying Redis/ES, not by reading the output.
- Elasticsearch 8 requires `https` and credentials; self-signed certificates are trusted deliberately (`EsUtil` uses an unsafe trust manager) since this is a local bootstrap tool.
- The loader writes row by row without pipelining. Fine for the sample data; expect it to be slow on the full Douban `item_cf_i2i` table (~1M rows).
