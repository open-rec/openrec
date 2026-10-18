# OpenRec Example Data Loader

This bootstrap utility loads deterministic example data and generated artifacts. It is intended for
development and acceptance testing, not as a production ingestion path.

Loads a CSV dataset into a running Redis + Elasticsearch so `rec-server` has something to recommend.
This is the bootstrap step of
[standalone](../standalone) and [cluster](../cluster); it is a one-shot batch job, not a service.

Entry point: `com.openrec.example.InitServingData`.

## build

Use JDK 21 and Maven 3.9+. The loader, `rec-proto` and `rec-client` all target `--release 21`.
`rec-proto` (from `rec-server`) and `rec-client` (from `sdk`) must be in your local Maven repo first:

```shell
cd rec-server && mvn clean install -DskipTests && cd ..
cd sdk/java-client && mvn clean install -DskipTests && cd ../..
cd openrec/init && mvn clean package -DskipTests
```

Produces `target/rec-example-init-0.2.0-jar-with-dependencies.jar`.

## run

Start Redis and Elasticsearch from the sibling `bigdata-platform` repository first:

```shell
cd bigdata-platform
./platform.sh up standalone
./platform.sh smoke standalone
cd ..
```

```shell
java -cp init/target/rec-example-init-0.2.0-jar-with-dependencies.jar \
  com.openrec.example.InitServingData <standalone|cluster> <redis_host> <redis_port> <es_host> <es_port> <es_user> <es_password> [data_dir] [model_dir]
```

| Argument | Example |
|---|---|
| `mode` | required: `standalone` or `cluster` |
| `redis_host` `redis_port` | `127.0.0.1` `6380` |
| `es_host` `es_port` | `127.0.0.1` `9200` |
| `es_user` `es_password` | `elastic` `openrec-es-password` |
| `data_dir` | optional, defaults to `data/test` |
| `model_dir` | optional, defaults to sibling `../model` |

`data_dir` is resolved **relative to the working directory**, so run it from the repo root:

```shell
cd openrec
java -cp init/target/rec-example-init-0.2.0-jar-with-dependencies.jar \
  com.openrec.example.InitServingData standalone 127.0.0.1 6380 127.0.0.1 9200 elastic 'openrec-es-password'
```

Import time depends on storage and host load. The loader writes entities, events, feature snapshots,
five Elasticsearch item table-recall families, per-scene vector indexes, and the
item/user search indexes. Verify the required aliases and sample keys after loading instead of relying on an
old fixed index/key count or duration estimate.

All selected task inputs are checked before any storage client is opened. Redis tasks run before
Elasticsearch tasks. Missing files, client-creation failures, and import errors abort the chain with
a nonzero exit code and the failed task name. Completed writes are not rolled back. Clients are
closed on success and failure.

## expected data layout

```
openrec/data/test/
├── item.csv          id,title,category,tags,scene,pub_time,modify_time,expire_time,status,weight,ext_fields
├── user.csv          id,device_id,name,gender,age,country,city,phone,tags,register_time,login_time,ext_fields
└── event.csv         id,user_id,item_id,trace_id,scene,type,value,time,is_login,ext_fields

model/
├── rank/item/lr/
│   ├── user_feature.csv
│   └── item_feature.csv
└── recall/item/
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
| `rank/item/lr/user_feature.csv` | `feature:user:{userId}` | JSON feature snapshot |
| `rank/item/lr/item_feature.csv` | `feature:item:{itemId}` | JSON feature snapshot |
| `recall/item/item_cf_i2i.csv` | `openrec-recall-item-cf-i2i-active` | Elasticsearch alias |
| `recall/item/content_i2i.csv` | `openrec-recall-content-i2i-active` | Elasticsearch alias |
| `recall/item/user_cf_u2i.csv` | `openrec-recall-user-cf-u2i-active` | Elasticsearch alias |
| `recall/item/hot.csv` | `openrec-recall-hot-active` | Elasticsearch alias |
| `recall/item/new.csv` | `openrec-recall-new-active` | Elasticsearch alias |
| `recall/item/item_seq_emb.csv` | `{scene}-item-seq-emb-index` | Elasticsearch, `dense_vector` (10 dims) |

Recall CSVs are loaded only into versioned Elasticsearch indexes behind their
`openrec-recall-{tableName}-active` aliases. The vector indexes are **dropped and recreated** on
every run; Redis keys are overwritten in place, so
stale keys from a previous dataset survive. Flush Redis if you switch datasets.

The shared standalone/cluster initializer reads `model/recall/item/text_search.csv`
(`scene,item,text`) and `model/recall/user/text_search.csv` (`scene,user,text`). It loads BM25
indexes, verifies document counts, then atomically switches `openrec-recall-item-search-active`
and `openrec-recall-user-search-active`, respectively. Requests use `params.query`.

`new.csv` supplies a normalized freshness score in `[0, 1]`. The loader preserves that
`score` and derives `publish_time` by multiplying it by one Unix timestamp captured at
the start of the import. Elasticsearch filters by `publish_time` and returns the stored
normalized score. This bootstrap approximation differs from offline releases that supply
an actual publication timestamp.

The active online recall contract, stable aliases, and storage implementations are documented in
the [`rec-server` RecallStore guide](https://github.com/open-rec/rec-server#recall-store).

## verify

```shell
docker exec redis redis-cli DBSIZE
docker exec redis redis-cli GET 'user:{user_0}'
docker exec redis redis-cli ZCARD 'event:{user_247}:scene_0:click'
curl -k -u elastic:openrec-es-password 'https://localhost:9200/_cat/indices/*item-seq-emb-index*?v'
```

## notes

- **It logs almost nothing on success.** There is no `log4j2.xml`, so Log4j2 defaults to root level ERROR and the per-table "finished" messages are discarded. Verify by querying Redis/ES, not by reading the output.
- Elasticsearch 8 requires `https` and credentials; self-signed certificates are trusted deliberately (`EsUtil` uses an unsafe trust manager) since this is a local bootstrap tool.
- Redis entities/events are written row by row. Elasticsearch table recall uses bulk batches of 1,000 documents; loading time grows with the dataset.


When `EMBEDDING_ENABLED=true`, the initializer also reads `recall/item/item_title_emb.csv`,
validates finite normalized vectors (`EMBEDDING_DIMENSIONS`, default 1024), stages one
global cosine index, verifies unique item counts, and switches the
`query-title-emb-index` alias atomically. Scene is ignored; repeated item IDs are
deduplicated, and conflicting vectors for the same ID reject activation. The source CSV
is streamed in batches. Existing active aliases remain
available until validation succeeds; previous indexes remain available for rollback.
The example startup performs the inference compatibility check before this import.

Raw-data validation and model preparation live in `tools/`; see the
[tool directory guide](../scripts/README.md). Mode startup scripts source `tools/init.sh`
before invoking the Java task chain.
