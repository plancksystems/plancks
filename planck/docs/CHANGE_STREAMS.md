# Change streams — operator + developer guide

Change streams in planck let an external consumer subscribe to every DML
event for selected stores and receive them in near-real-time.

## Quick model

- Each `engine.put`/`del`/`postOne`/`postMany` on a configured store
  appends a change frame to an in-memory ring.
- Consumers call the `Watch` RPC (long-poll) and receive batches of
  frames whose `lsn > since_lsn`, parking server-side up to
  `max_wait_ms` until matching frames arrive.
- The consumer owns its position (cursor); planck holds zero per-consumer
  state.

This shape is functionally equivalent to MongoDB change streams
(`db.watch()` is a tailable cursor with `getMore` long-poll under the
hood) — minus durability across crashes (we use an in-memory ring, not
the oplog).

## When to use it

Good fit:
- Live UI fan-out (SSE pushes to browsers — pizzaqsr's tracking +
  kitchen + delivery dashboards are the reference)
- Cache invalidation (Redis / search index follows planck writes)
- Reactor patterns where loss of a few seconds of events on planck crash
  is acceptable

Not a fit:
- Cross-region replication / DR (needs cross-restart durability —
  use planck's `ReplicationManager`)
- Audit / compliance logs (needs at-least-once with disk durability)
- Analytics pipelines that must NEVER lose a record

For the last category, the change-stream feature is the wrong primitive;
a proper CDC-to-disk source is a future work item.

## Config (`db.yaml`)

```yaml
change_streams:
  # Stores eligible for the ring. Writes to stores not listed here are
  # never captured. Omit the block (or `stores: []`) to disable change
  # streams entirely.
  stores:
    - ns: orders
      operations: [insert, update, delete]
    - ns: payments
      operations: [insert, update]
  # In-memory ring size (frames). Older frames evict on overflow.
  # Sizing: peak_write_rate_per_sec × max_acceptable_consumer_lag_sec.
  # Example: 100 writes/sec sustained, 60s lag → 6,000. Default 16,384
  # covers most pizzaqsr-scale workloads comfortably.
  ring_capacity: 16384
```

## The `Watch` op (wire protocol)

OperationTag `Watch = 14`. Args:

| Field | Type | Notes |
|---|---|---|
| `stores` | `[][]const u8` | Consumer's filter (subset of configured streams). Empty = all configured. |
| `since_lsn` | `u64` | Server returns frames with `lsn > since_lsn`. First call uses 0. |
| `max_wait_ms` | `u32` | Server-side park budget. 0 → server default (30s). |
| `max_records` | `u32` | Hard cap on response size. 0 → server default (256). |

Response is `OperationTag.WatchReply = 52`:

| Field | Type | Notes |
|---|---|---|
| `status` | `Status` | `.ok` normal; `.not_found` = `CursorBehindRetention`. |
| `high_lsn` | `u64` | Current server head. Advance cursor to this even on empty batches. |
| `records` | `[][]const u8` | Each entry is an encoded `csf.Frame`. |

Each `records[i]` is a `utils.change_stream_frame.Frame` byte string:

```
[u32 body_len]
[u8 version]
[u8 kind]            // 1=insert, 2=update, 3=delete
[u64 writer_lsn]
[i64 timestamp_ms]
[u16 store_ns_len][store_ns bytes]
[u128 key]
[u32 value_len][value bytes if value_len > 0]
```

Decode via `csf.Frame.decode(bytes) → Parsed`.

## Consumer pattern

The reference implementation is in `samples/pizzaqsr-hda-mono/sse/`.
Skeleton:

```zig
var cursor: u64 = 0;
while (connection_alive) {
    var result = try client.watch(allocator, &.{"orders"}, cursor, 30_000);
    defer result.deinit(allocator);

    if (result.rebootstrap_required) {
        // Cursor behind retention. Snapshot current state via query,
        // emit it, then resume at the new head.
        try emitSnapshot(...);
        cursor = result.high_lsn;
        continue;
    }

    for (result.records) |rec| {
        // rec.lsn / rec.kind / rec.store_ns / rec.key / rec.value
        try processRecord(rec);
    }
    cursor = result.high_lsn; // even when records is empty
}
```

`planck-zig-client` exposes:

- `client.watch(allocator, stores, since_lsn, max_wait_ms) !WatchResult`
- `client.watchOne(allocator, store, since_lsn, max_wait_ms) !WatchResult`
- `WatchResult { records: []ChangeRecord, high_lsn: u64, rebootstrap_required: bool }`
- `WatchResult.deinit(allocator)` — frees per-record duped strings

## Failure modes

| Failure | Effect | Recovery |
|---|---|---|
| planck crashes | In-memory ring lost; in-flight `Watch` fails with TCP error | Consumer reconnects with same cursor; gets `CursorBehindRetention` (ring is empty); rebootstraps from a snapshot query, resumes at new `high_lsn` |
| Consumer crashes | Connection drops; ring keeps filling | Consumer restarts, sends `watch(since_lsn=0)`, gets recent history from the ring, resumes |
| Both crash | Ring lost, consumer position lost | Consumer rebootstraps cleanly from current state |
| Network blip mid-watch | Watch fails | Consumer retries with same cursor; no data loss as long as ring still has the LSNs |
| Slow consumer (writes outpace) | Ring evicts frames before consumer sees them | Next watch returns `CursorBehindRetention` → rebootstrap. Mitigation: size `ring_capacity` for peak write rate × max lag. |
| No DML for `max_wait_ms` | Server responds empty; cursor advances to current head | Consumer reissues immediately |

## Multi-consumer

Each consumer opens its own planck connection and runs its own
`watch` loop. Planck doesn't track consumers — it just answers
`Watch` requests against the same ring. Adding a new consumer is just
running another client; no config change on the planck side.

## Operational signals

- `change_streamer started ({n} stores, ring_capacity {k})` on init.
- Per-consumer logging is consumer-side (the streamer itself is silent
  on the happy path).
- Consumer log spam of "rebootstrap_required" → ring is undersized for
  the workload (or consumers are too slow). Bump `ring_capacity`.

## What changed from the previous design

The previous design used a separate `StreamWal` on disk + flushTask +
syncTask that pushed records over TCP to a fixed consumer endpoint.
That added durability (which most use cases don't need at the cost of
latency we observed) and was a one-consumer-per-engine push.

The current design replaces that with an in-memory ring + pull (`Watch`)
RPC. Trade-offs:
- ✅ Sub-ms latency (no segment-rotate dance)
- ✅ N consumers for free, each with its own cursor
- ✅ Simpler code (~120 lines vs ~350)
- ❌ Ring contents lost on planck crash (consumer rebootstraps)
- ❌ Retention bounded by RAM (~ring_capacity ÷ write_rate)

For pizzaqsr's UI fan-out the trade-offs are right. If you build on
planck and need disk-durable CDC, that's a future feature; talk to us.
