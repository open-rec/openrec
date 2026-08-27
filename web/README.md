# OpenRec Web Demo

A visual demo of open-rec. Browse items across four recall tabs, feed behaviour back through
`rec-client`, and watch the recommendations change on the next load.

It answers what the curl walkthrough cannot: *does user feedback actually move the results, and
which behaviours move them?*

## what you get

- **four tabs** — 猜你喜欢 / 相关推荐 / 热门推荐 / 新品推荐
- **five behaviours** — `click`, `expose`, `buy`, `collect`, `stay`, all pushed to rec-server through the java sdk
- **live counters** for the events recorded against the current user — the history that drives the next recommendation
- **NEW badges** on items that were absent from the previous load of the same tab; this is what the feedback loop looks like
- **a reset button**, without which the demo stops working after a few refreshes (see [repeatability](#repeatability))

## prerequisites

1. Redis and Elasticsearch running, seeded by [init](../init) — the demo uses `user_0` and the `scene_0..2` sample data
2. `rec-server` running on port 13579
3. `rec-proto` and `rec-client` installed into the local Maven repo

Full setup: [example_standalone](../example_standalone).

For the shortest path, run `../example_standalone/start.sh` from this directory. It initializes the
whole recommendation chain and starts this demo last on port 12345.

## build and run

```shell
cd example/web
mvn clean package -DskipTests
java -jar target/rec-example-web-1.0-SNAPSHOT.jar
```

Open http://localhost:12345

Anything in `src/main/resources/application.properties` can be overridden on the command line:

```shell
java -jar target/rec-example-web-1.0-SNAPSHOT.jar \
  --rec.server.endpoint=http://127.0.0.1:13579 \
  --spring.redis.host=127.0.0.1 \
  --demo.user-id=user_0 \
  --demo.scene=scene_0
```

## architecture

```
browser ──fetch──> web :12345 ──rec-client sdk──> rec-server :13579 ──> Redis / ES
                      └──────────read──────────> Redis (hot/new tables, item details, counters)
```

The backend is not ceremony. Two things require it:

- **the sdk is java** — feeding behaviour back "through the sdk" means a JVM has to make the call
- **rec-server has no CORS** — `WebfluxConfig` registers none, so a browser cannot call port 13579 directly

## where each tab gets its data

| tab | source | exposure filtering |
|---|---|---|
| 猜你喜欢 | `POST /api/recommend` via sdk, no explicit triggers | DAG `filter`; standalone `collector` records exposure |
| 相关推荐 | `POST /api/recommend` via sdk, with `itemIds=[selected]` | DAG `filter`; standalone `collector` records exposure |
| 热门推荐 | Redis `hot:{scene}` | applied by this module |
| 新品推荐 | Redis `new:{scene}` | applied by this module |

猜你喜欢 is the DAG's own output, so it is a blend of channels rather than one of them. Each card
carries a `meta` line with the full breakdown behind its score:

```
item_5887   [item_cf_i2i]     recall=item_cf_i2i:0.1700; rank=-
item_7888   [content_i2i +1]  recall=content_i2i:0.0959,hot:0.5833; rank=-
item_6689   [hot]        recall=hot:1.0000; rank=-
```

**An item recalled by several channels lists all of them.** De-duplication decides which score
*ranks* the item (the first channel wins), but the other channels' scores are kept rather than
discarded — `item_7888` above is weak in content I2I (0.0959) yet strong in hot (0.5833), and that
disagreement is exactly what you need when adjusting strategy by hand. The badge shows `+n` for the
extra channels; the structured form is in `recallScores` on the API response.

Measured on the sample data with `size=40`: 5 of 40 items were hit by two channels, and `hot`
produced 10 items in total while only 5 of them ranked by their hot score. Before this, those 5 hot
scores were simply lost.

`rank=-` means the rank stage did not run — `rankScore` is null rather than 0, so "the rank engine is
down" stays distinguishable from "the model scored this 0". Start
[rank-engine](https://github.com/open-rec/rank-engine) (step 8) to get real values, which render as
`rank=0.7700`.

Combine de-duplicates channels in configured `recallTypes` order, so the first channel becomes
an item's primary `recallFrom`; every secondary hit remains in `recallScores` / `meta`. The default
standalone operation rule allocates `item_cf_i2i`/`content_i2i`/`user_cf_u2i`/`item_seq_emb`/hot/new candidates using the
ratios in `graph.json` and orders the selected items by score. If a channel is short, its quota is
filled by the highest-scoring
unused candidates, so the observed mix can differ from the target rather than returning fewer items.

Fields on each item in the API response:

| field | meaning |
|---|---|
| `score` | final ordering score after configured recall/rank fusion |
| `recallFrom` | the channel whose score ranks it |
| `recallScore` | score entering the rank stage; null if it never got there |
| `rankScore` | the rank engine's contribution; null if ranking did not run |
| `recallScores` | every channel that recalled it → that channel's score |
| `meta` | the same breakdown as one line, e.g. `recall=content_i2i:0.0959,hot:0.5833; rank=-` |

The last two deliberately do **not** go through `/api/recommend`. The DAG in `graph.json` always runs
every channel and merges them in `combine`; nothing in a request selects one. `RecommendReq.type`
exists but no node reads it, so "hot only" is not expressible — asking anyway would return exactly
what 猜你喜欢 returns, under a label that lies.

`InitStandalone` maps the normalized `new.csv` freshness score into the current Unix-time domain
(`score × one load-time timestamp`). This preserves the source ordering while allowing `NewNode` to
apply its `[now - duration, now]` query. Both `NewNode` and the dedicated tab divide the stored score
by the query-time Unix timestamp before returning it, keeping the displayed business score in the
`0～1` range. The dedicated tab still reads the table directly because a request cannot select only
one DAG channel.

Both tabs display their source in the UI, so nothing personalized-looking is actually a plain table
read.

## which behaviours change recommendations

Three behaviours feed the DAG:

| behaviour | trigger | effect on the next recommendation |
|---|---|---|
| `click` | clicking a card | **yes** — `UserTriggerNode` reads recent clicks and uses them as recall triggers |
| `expose` | standalone: returned by server; cluster: actually visible in browser | **yes** — `FilterNode` excludes anything exposed within its window (24h) |
| `dislike` | 不喜欢商品 / 屏蔽类目 / 屏蔽标签 buttons | **yes** — `BlackNode` loads the structured rules and `CombineNode` applies them |
| `stay` | card leaves the viewport, value = dwell seconds | no — stored only |
| `buy` | 购买 button | no — stored only |
| `collect` | 收藏 button | no — stored only |

**Exposure hides the item.** In standalone, `collector.fake-expose.enabled=true`: `CollectorNode`
records DAG results as synthetic exposure, while the Web backend provides the same fallback for 热门
and 新品. In cluster, that property is false and the Web starts with `demo.exposure-mode=viewport`:
an `IntersectionObserver` batches cards that cross the 50% visibility threshold to the Push API.
This keeps the standalone convenience while making cluster analytics reflect actual displays.

`dislike.value` is structured JSON containing one selected scope: `id`, `category`, or a `tags`
array. It is materialized as prefixed members in Redis. `stay` carries dwell time in `value`, but
that value is not persisted: the ordinary event index is
`event:{userId}:{scene}:{type}` → sorted set of `(itemId, timestamp)`, so there is nowhere to put it.
The event reaches rec-server and the item lands in the sorted set; only the number is dropped.

`UserTriggerNode` consumes click, `FilterNode` consumes expose, and `BlackNode` consumes dislike.
The other three are written correctly to `event:{userId}:{scene}:{type}` and read by nobody. They are still
worth reporting — an offline model would train on them — but the page marks them inert rather than
implying otherwise.

## seeing the feedback loop

1. open 猜你喜欢, note the ids
2. click 3–5 cards (each bumps the `click` counter)
3. press **重新加载**
4. anything carrying a **NEW** badge was not in the previous result set

Underneath: the clicks became members of `event:{user_0}:scene_0:click`; the next request's
`userTrigger` reads them as triggers; `item_cf_i2i` and `item_seq_emb` recall neighbours of those items
instead of the previous ones.

Cross-check from outside the browser:

```shell
redis-cli ZRANGE 'event:{user_0}:scene_0:click' 0 -1 WITHSCORES
```

and in the rec-server log, `userTrigger with trigger size:N` grows as you click.

Measured on the sample dataset, starting from a cold `user_0` (no clicks):

| state | trigger size | item_cf_i2i size | top of 猜你喜欢 |
|---|---|---|---|
| no clicks | 0 | 0 | `item_6689 item_5609 item_5248 …` — all from the hot table |
| after one click on `item_2` | 1 | 26 | `item_5887 item_3209 item_7151 item_5862 item_455 item_1218 …` |

Those six are exactly the top of `item-cf-i2i:{item_2}:scene_0`, so the click propagated all the way from
the sdk into the recall result.

**Pick a well-connected item to see this clearly.** The effect is only visible when the clicked item
has neighbours in the `item_cf_i2i` table. Clicking something absent from it (`item_100`, for instance) still
raises `trigger size`, but `item_cf_i2i size` stays 0 and the page changes only through the exposure filter.
Check first:

```shell
redis-cli ZCARD 'item-cf-i2i:{item_2}:scene_0'
```

## repeatability

Every recommendation makes `CollectorNode` write a synthetic `expose` record for everything it
returned, and `FilterNode` then excludes anything exposed in the last 24h. Refresh enough times and
the candidate pool drains — 猜你喜欢 goes empty and looks broken.

**重置曝光** deletes `event:{userId}:{scene}:expose` and the pool comes back. It writes to Redis
directly because `PushRedisService.pushEvent` only implements INSERT/UPDATE — the sdk has no way to
delete events.

## api

| method | path | purpose |
|---|---|---|
| GET | `/api/config` | page defaults: user, scene list, page size, which behaviours matter |
| GET | `/api/tab/{guess\|related\|hot\|new}` | items for a tab; `?scene=&userId=&size=&itemId=` |
| POST | `/api/feedback` | report one behaviour: `{userId, itemId, scene, type, value}` |
| POST | `/api/feedback/batch` | report visible items together: `{userId, itemIds, scene, type}` |
| GET | `/api/state` | event counters for a user and scene |
| POST | `/api/reset` | clear exposures; `{"clearClicks": true}` also clears clicks |
| POST | `/api/reset/dislike` | clear the current user's dislike rules for one scene |

Usable without a browser:

```shell
curl 'http://localhost:12345/api/tab/guess?scene=scene_0&userId=user_0&size=5'

curl -X POST http://localhost:12345/api/feedback \
  -H 'Content-Type: application/json' \
  -d '{"userId":"user_0","itemId":"item_42","scene":"scene_0","type":"click"}'

curl 'http://localhost:12345/api/state?userId=user_0&scene=scene_0'
```

## notes

**Quoted ids.** Recall tables were written with `GenericJackson2JsonRedisSerializer`, so a sorted-set
member is literally `"item_1069"` — quotes included. rec-server's multi-key
`RedisService.getZSet(List, ...)` does not strip them either, so IDs from `item_cf_i2i` arrive
quoted too (the single-key overload does strip them). `support/Ids.unquote` handles both; without it
`item:{"item_1069"}` misses in Redis and cards render blank.

**Cold start on 相关推荐.** The `item_seq_emb` node has `timeout: 100` (ms) in `graph.json`, while the
first request after a restart pays for the TLS handshake to Elasticsearch — measured at ~650ms. The
engine cancels the node, the interrupt is swallowed, and that channel contributes nothing until
roughly the third request. Raise the timeout in `graph.json` if you want it warm immediately.

**新品推荐 ordering.** The sample dataset's normalized freshness score is rebased at initialization
time. It demonstrates the online time-window query but does not claim the synthetic items were
actually published today.
