# Feature time and event identity contract

This contract applies to the version-1 Kafka mutation envelope and feature catalog version 2.

## Time fields

- `occurredAt` is the mutation ordering time in epoch milliseconds. For one entity or event id, the
  mutation with the greatest value wins; `DELETE` wins a tie. Consumers must not let an older
  mutation overwrite or resurrect newer state.
- `event.time` is the business event time in epoch seconds. Behaviour windows and labels use this
  field, not Kafka arrival time or `occurredAt`.
- An offline snapshot at `as_of` may use only profile mutations with
  `occurredAt <= as_of * 1000`. Rank training performs a separate point-in-time join for every
  label: profile state is selected at `label.time`, and behaviour requires both its latest visible
  mutation at that time and `event.time < label.time`. A later UPDATE or DELETE must not rewrite an
  earlier sample, and a label event cannot enter its own features.
- Window boundaries are `[as_of - window, as_of]`. Online serving re-materializes recency and
  window counts at feature-refresh time from the event-time histogram in the snapshot.

## Identities

- `eventId` is the optional stable identity of one action and is the preferred deduplication and
  retraction key. Producers should keep it unchanged across retries, UPDATE, and DELETE.
- `traceId` identifies recommendation or impression context. An expose and its later click may have
  the same `traceId`; consumers must not deduplicate actions by `traceId` alone.
- Legacy events without `eventId` use
  `(userId,itemId,scene,type,time,traceId)` as their compatibility identity.

Event DELETE is a retraction. The latest DELETE removes the event from cumulative offline reads and
from realtime aggregate state. An older INSERT or UPDATE cannot resurrect it.

## Parity gate

`example/scripts/verify-feature-parity.sh` validates the catalog copies and replays the canonical
event fixture through Python, Flink, and Spark adapters. Any difference in identity, window
boundaries, counts, recency, or top-category output fails the gate.

## Compatibility

`eventId` is additive and optional, so old clients remain readable. Catalog version 2 intentionally
invalidates fitted version-1 feature spaces because correcting event identity changes feature
values. Rank artifacts must be rebuilt before the new catalog is deployed.
