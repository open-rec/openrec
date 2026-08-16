# web

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

> **rec-server must include the push-event key fix.** Before it, `PushRedisService` built its key
> from a template with two placeholders while passing three arguments, so the userId was dropped and
> events landed in `event:scene_0:click:{}` instead of `event:{user_0}:scene_0:click`. Feedback was
> accepted with HTTP 200 but no recall channel could ever read it, so recommendations never changed.
> If your results look frozen, check `PushRedisService.java` first.

## build and run

```shell
cd example/web
mvn clean package -DskipTests
java -jar target/rec-example-web-1.0-SNAPSHOT.jar
```

Open http://localhost:8080

Anything in `src/main/resources/application.properties` can be overridden on the command line:

```shell
java -jar target/rec-example-web-1.0-SNAPSHOT.jar \
  --server.port=9090 \
  --rec.server.endpoint=http://127.0.0.1:13579 \
  --spring.redis.host=127.0.0.1 \
  --demo.user-id=user_0 \
  --demo.scene=scene_0
```

## architecture

```
browser ──fetch──> web :8080 ──rec-client sdk──> rec-server :13579 ──> Redis / ES
                      └──────────read──────────> Redis (hot/new tables, item details, counters)
```

The backend is not ceremony. Two things require it:

- **the sdk is java** — feeding behaviour back "through the sdk" means a JVM has to make the call
- **rec-server has no CORS** — `WebfluxConfig` registers none, so a browser cannot call port 13579 directly

## where each tab gets its data

| tab | source |
|---|---|
| 猜你喜欢 | `POST /api/recommend` via sdk, no explicit triggers |
| 相关推荐 | `POST /api/recommend` via sdk, with `itemIds=[selected]` |
| 热门推荐 | Redis `hot:{scene}` |
| 新品推荐 | Redis `new:{scene}` |

The last two deliberately do **not** go through `/api/recommend`. The DAG in `graph.json` always runs
every channel and merges them in `combine`; nothing in a request selects one. `RecommendReq.type`
exists but no node reads it, so "hot only" is not expressible — asking anyway would return exactly
what 猜你喜欢 returns, under a label that lies.

The `new` channel has a second problem: `InitStandalone` writes a 0..1 normalized score into
`new:{scene}`, while `NewNode` filters by a `[now - duration, now]` **timestamp** range. Those never
intersect, so that channel returns 0 items on this dataset no matter what. Reading the table directly
is the only way to show what the tab is named after.

Both tabs display their source in the UI, so nothing personalized-looking is actually a plain table
read.

## which behaviours change recommendations

Only two of the five feed the DAG:

| behaviour | trigger | effect on the next recommendation |
|---|---|---|
| `click` | clicking a card | **yes** — `UserTriggerNode` reads recent clicks and uses them as recall triggers |
| `expose` | card scrolls into view (`IntersectionObserver`, once per item per load) | **yes** — `FilterNode` excludes anything exposed within its window (24h) |
| `stay` | card leaves the viewport, value = dwell seconds | no — stored only |
| `buy` | 购买 button | no — stored only |
| `collect` | 收藏 button | no — stored only |

`UserTriggerNode` hardcodes `filterType = "click"` and `FilterNode` hardcodes `"expose"`, so the other
three are written correctly to `event:{userId}:{scene}:{type}` and read by nobody. They are still
worth reporting — an offline model would train on them — but the page marks them inert rather than
implying otherwise.

## seeing the feedback loop

1. open 猜你喜欢, note the ids
2. click 3–5 cards (each bumps the `click` counter)
3. press **重新加载**
4. anything carrying a **NEW** badge was not in the previous result set

Underneath: the clicks became members of `event:{user_0}:scene_0:click`; the next request's
`userTrigger` node read them as triggers; `i2i` and `embedding` recalled neighbours of those items
instead of the previous ones.

Cross-check from outside the browser:

```shell
redis-cli ZRANGE 'event:{user_0}:scene_0:click' 0 -1 WITHSCORES
```

and in the rec-server log, `userTrigger with trigger size:N` grows as you click.

Measured on the sample dataset, starting from a cold `user_0` (no clicks):

| state | trigger size | i2i size | top of 猜你喜欢 |
|---|---|---|---|
| no clicks | 0 | 0 | `item_6689 item_5609 item_5248 …` — all from the hot table |
| after one click on `item_2` | 1 | 26 | `item_5887 item_3209 item_7151 item_5862 item_455 item_1218 …` |

Those six are exactly the top of `i2i:{item_2}:scene_0`, so the click propagated all the way from
the sdk into the recall result.

**Pick a well-connected item to see this clearly.** The effect is only visible when the clicked item
has neighbours in the i2i table. Clicking something absent from it (`item_100`, for instance) still
raises `trigger size`, but `i2i size` stays 0 and the page changes only through the exposure filter.
Check first:

```shell
redis-cli ZCARD 'i2i:{item_2}:scene_0'
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
| GET | `/api/state` | event counters for a user and scene |
| POST | `/api/reset` | clear exposures; `{"clearClicks": true}` also clears clicks |

Usable without a browser:

```shell
curl 'http://localhost:8080/api/tab/guess?scene=scene_0&userId=user_0&size=5'

curl -X POST http://localhost:8080/api/feedback \
  -H 'Content-Type: application/json' \
  -d '{"userId":"user_0","itemId":"item_42","scene":"scene_0","type":"click"}'

curl 'http://localhost:8080/api/state?userId=user_0&scene=scene_0'
```

## notes

**Quoted ids.** Recall tables were written with `GenericJackson2JsonRedisSerializer`, so a sorted-set
member is literally `"item_1069"` — quotes included. rec-server's multi-key
`RedisService.getZSet(List, ...)` does not strip them either, so ids from the i2i channel arrive
quoted too (the single-key overload does strip them). `support/Ids.unquote` handles both; without it
`item:{"item_1069"}` misses in Redis and cards render blank.

**Cold start on 相关推荐.** The `embedding` node has `timeout: 100` (ms) in `graph.json`, while the
first request after a restart pays for the TLS handshake to Elasticsearch — measured at ~650ms. The
engine cancels the node, the interrupt is swallowed, and that channel contributes nothing until
roughly the third request. Raise the timeout in `graph.json` if you want it warm immediately.

**新品推荐 ordering.** The sample dataset's `pub_time` values are all from 2022, so nothing is
genuinely new. The tab shows `new:{scene}` ordered by its freshness score, which is the most that
data supports.
