# MVCC + Transactions Design

Multi-version concurrency control and ACID transactions for planck/db.

This document proposes a phased migration from the current
single-version, single-writer model to MVCC with snapshot isolation
transactions. It is intentionally conservative: every phase ships a
usable subset of the final design, so we can stop at any point if
production needs are met earlier than expected.

## 1. Goals

Primary:

1. **Eliminate reader-writer interference.** A reader at time `T`
   should never block on a concurrent writer. Today the global
   `db_mutex` is an exclusive lock during every write and every flush;
   readers are starved during long writes (see the gc_test workload
   investigation, June 2026).
2. **Multi-document atomicity.** A client should be able to insert or
   update N documents under one logical commit. Either all are
   visible to subsequent readers or none are.
3. **Predictable read latency.** Eliminate the 500 ms flush stall as
   seen by readers; readers should never see locks held longer than
   the time for one B+tree page swap.

Secondary:

4. **Foundation for richer isolation.** Snapshot Isolation (SI) is the
   first target. The design must leave room for adding Serializable
   Snapshot Isolation (SSI) later without rewriting the primitives.

## 2. Non-Goals

- Distributed transactions across replicas. The replica is read-only;
  multi-node ACID is out of scope.
- Lock-free B+tree writes. Writes still serialize at the index — the
  win is for readers, not writers. Sharding (per-store locks) is the
  path to scale writes and is orthogonal to MVCC.
- Long-running OLAP-style analytic transactions. Snapshot retention
  is bounded by the GC interval; very long reads may be aborted if
  their snapshot ages out.

## 3. Background — current architecture

```
engine.del/post/put
  wal_mutex.lock                       (exclusive)
  wal.append(...)
  db_mutex.lock                        (exclusive RwLock)
  db.del/post/put
    memtable.post                      (in-memory skiplist)
    if memtable_switched:
      db.flush()                       (slow — 500 ms for 1 M rows)
        iterate inactive skiplist
        for each entry:
          vlog.post(entry)             (disk I/O ~10 µs)
          primary_index.insert(...)    (B+tree mutation ~50 µs)
  db_mutex.unlock
  wal_mutex.unlock

engine.get / query.run
  db_mutex.lockShared
  memtable.get(key) or vlog.read(offset)
  db_mutex.unlockShared
```

The contention point is `db_mutex` held exclusively during the
in-line flush. Readers wait. We have analyzed many alternatives
(background flush, cooperative yield, shadow memtable); none
eliminate the 500 ms of B+tree work — they just relocate it.

MVCC is the only model that actually lets readers proceed
concurrently with that B+tree work.

## 4. MVCC design

### 4.1 Version stamping

Every committed write carries a monotonically increasing 64-bit
**commit timestamp (CTS)**. The CTS is assigned at commit time, not
at write time, and is taken from a single atomic counter in the
engine.

Per-document, we maintain a **version chain**: a linked list of
`(value, valid_from_cts, valid_until_cts)` triples. Each visible
version covers a half-open interval `[valid_from, valid_until)`.
A reader at snapshot `S.cts` sees the version whose interval contains
`S.cts`.

```
key 42: 
  v1 (1730, ∞)        ← latest, currently visible
  v2 (1402, 1730)     ← previous, visible to readers with cts ∈ [1402, 1730)
  v3 (1107, 1402)     ← older
```

Tombstones (deletes) are a version too: a "value is gone" marker
with the same interval semantics. They remain in the chain until
garbage-collected.

### 4.2 Storage layout

Two changes from today:

**(a) vlog entries carry CTS.** Today each vlog entry has `lsn`,
`key`, `value`, `timestamp`. We add `commit_ts: u64` after the
existing fields. WAL recovery uses the persisted CTS rather than
generating a new one. Backward compat: a `commit_ts == 0` field on
recovery means "pre-MVCC entry", treated as `valid_from = 0`.

**(b) Primary index becomes versioned.** Today
`primary_index.search(key) → offset` returns one offset. We change
the index to point at a **version chain head**, a small in-memory
structure that records the latest committed version plus a pointer
to the chain of older versions. Older versions live in the chain;
the newest visible version is inlined in the head for fast reads.

```
primary_index[key] → VersionHead {
    latest_cts: u64,
    latest_offset: u64,          // vlog offset of current version
    older: ?*VersionLink,        // chain of pre-image versions
}

VersionLink {
    cts: u64,
    offset: u64,
    next: ?*VersionLink,
}
```

The chain head lives in memory (in the B+tree leaf entry). Older
versions reference vlog offsets — no duplicate value storage in the
chain.

### 4.3 Read visibility

A reader at snapshot `S.cts` resolves a key by:

1. Look up `primary_index[key]` → `VersionHead`.
2. If `head.latest_cts ≤ S.cts`: that version is visible. Return it.
3. Else walk `head.older` until finding `link.cts ≤ S.cts`. Read
   from `link.offset`.
4. If no version with `cts ≤ S.cts` exists, the key did not exist at
   `S.cts`. Return not-found.

Tombstones are handled by storing a sentinel in the chain. A reader
that lands on a tombstone returns not-found.

This walk is `O(chain depth)`. In practice chains stay short because
old versions are GC'd (§4.5). For most reads the latest is visible
and we return without traversal.

### 4.4 Write protocol

Writes still serialize at the B+tree (this is the irreducible work).
The change is that the version chain extension is done atomically:

1. Acquire `db_mutex.lock_exclusive` *only for the chain extension*,
   not for the full flush.
2. Look up `primary_index[key]` (or create new entry).
3. Prepend the new `(cts, offset)` to the chain. The old head moves
   to `older`. New head's `latest_cts = new_cts`.
4. Release `db_mutex`.

Step 2 takes one B+tree traversal — a few µs. Step 3 is a couple
pointer updates. Total ≈ 10 µs vs today's full 50 µs B+tree insert.
And critically, readers running before the chain swap see the old
head; readers running after see the new one. **No reader ever sees
a partial state.**

### 4.5 Version garbage collection

Old versions are reclaimable when no active snapshot can reach them.
The engine maintains a **minimum active snapshot timestamp (MAST)**:
the smallest `cts` of any in-flight transaction. Any version whose
`valid_until_cts ≤ MAST` is dead.

GC runs periodically (e.g. every 30 s, or piggybacked on vlog GC):

1. Walk version chains in primary_index.
2. For each chain: drop `VersionLink` entries whose `cts < MAST`.
3. Their vlog offsets become eligible for compaction in the next
   vlog GC pass.

Memory cost: a `VersionLink` is ~24 bytes. With MAST tracking ≥ 30 s
of writes, that's `write_rate × 30 s × 24 bytes`. At 10k writes/sec
that's ~7 MB. Acceptable.

If MAST goes very old (a long-running read), version chains lengthen
unboundedly. We bound this with a **snapshot timeout**: snapshots
older than `max_snapshot_age` (e.g. 5 min) are revoked; their
transactions get aborted on next operation.

### 4.6 Compatibility with WAL recovery

WAL recovery replays records to reconstruct memtable and primary
index. With MVCC each record carries CTS. The replay assigns CTS
in the same order they were committed, producing the same version
chains. No semantic change to recovery; just an extra field per
record.

## 5. Transaction layer

The transaction layer sits on top of the MVCC primitives.

### 5.1 Transaction lifecycle

```
Begin(isolation = SI):
  txn.id = engine.next_txn_id.fetch_add(1)
  txn.snapshot_cts = engine.next_commit_ts.load()
  txn.state = active
  txn.write_buffer = empty
  engine.active_txns[txn.id] = txn      // for MAST tracking
  → return txn_handle

Read(txn, key):
  if txn.write_buffer contains key:
    return write_buffer[key]            // read your own writes
  else:
    return mvcc_read(key, txn.snapshot_cts)

Write(txn, key, value):
  txn.write_buffer[key] = (value, kind)

Delete(txn, key):
  txn.write_buffer[key] = tombstone

Commit(txn):
  txn.commit_ts = engine.next_commit_ts.fetch_add(1)
  // For SI: just apply.
  // For SSI: validate against concurrent committers (§5.4).
  wal.append(.CommitMarker { txn.id, txn.commit_ts })
  for (key, op) in txn.write_buffer:
    apply_to_mvcc(key, op, txn.commit_ts)
  txn.state = committed
  engine.active_txns.remove(txn.id)

Rollback(txn):
  wal.append(.AbortMarker { txn.id })
  // Nothing to undo — writes never reached MVCC.
  txn.state = aborted
  engine.active_txns.remove(txn.id)
```

Apply is the only step that takes `db_mutex.lock_exclusive`, and
only briefly. Read/write inside a transaction acquire no engine
locks — they touch txn-local state.

### 5.2 Snapshot Isolation guarantees

Under SI, a transaction sees a consistent snapshot of the database
as of `Begin`. Concurrent writes by other txns are invisible until
they commit; even after they commit, this txn doesn't see them.

Known SI anomalies:
- **Write skew.** Two txns each read the same key K, each decide to
  write a different key based on K, both commit. Neither saw the
  other's write. Result: an invariant relying on "K was unchanged
  while we both decided" can be violated.
- **Lost update.** Two txns read counter C, each compute C+1, both
  write. Last commit wins; one increment is lost.

SI is acceptable for the vast majority of OLTP workloads and is
what most NoSQL systems offer. SSI eliminates these anomalies at
significant performance cost (§5.4).

### 5.3 Conflict policy

Even under SI we must decide what happens when two committers touch
the same key. Two options:

**(a) Last-write-wins.** Both commits succeed. The later `commit_ts`
prevails as the visible version. Older write is preserved in the
chain (briefly) but never seen.

**(b) First-writer-wins (optimistic).** At commit, for each key in
the write buffer, check whether any version with
`cts > txn.snapshot_cts` exists. If yes, abort with `WriteConflict`.

The choice is configurable per txn or per workload. Default proposal:
**first-writer-wins** — surfaces conflicts to the application so it
can retry, matching what most ORMs / app developers expect from a
transactional DB.

### 5.4 Optional: Serializable Snapshot Isolation (Phase 4)

SSI eliminates write-skew and lost-update by tracking read-write
dependency cycles. The standard algorithm:

- For each committed txn, remember its read-set (keys + cts) and
  write-set.
- At commit time, check for "dangerous structure": this txn read a
  key that a still-active concurrent txn wrote, AND a still-active
  concurrent txn read a key that this txn wrote.
- If detected, abort.

This adds bookkeeping in proportion to read-set size and complicates
the commit path. We propose deferring it to Phase 4 once SI is
proven.

## 6. WAL changes

New record types:

```
TxnBegin   { txn_id }                  // optional — only logged if recovery
                                        // needs to skip aborted writes
TxnWrite   { txn_id, key, value, kind }  // buffered write
TxnCommit  { txn_id, commit_ts }        // commit marker
TxnAbort   { txn_id }                   // abort marker
```

Existing single-statement writes remain as today (they are
implicitly committed at op completion). The transaction records are
a superset.

Recovery becomes:

1. Replay WAL.
2. Per txn_id, collect all `TxnWrite` records.
3. On `TxnCommit`, apply the collected writes with the recorded
   `commit_ts`.
4. On `TxnAbort` (or end-of-WAL with no commit), discard the writes.

### 6.1 Crash recovery semantics

Durability: a `TxnCommit` record is fsync'd before the commit
returns to the client. After recovery, all committed txns are
applied; in-flight txns are aborted. No partial commits.

## 7. Wire protocol additions

New ops in `proto/src/operation.zig`:

```zig
Begin: struct {
    isolation: u8,                  // 0 = SI (default), 1 = SSI (Phase 4)
    timeout_ms: u32 = 30000,        // max txn duration
},
Commit: struct {
    txn_id: u64,
},
Abort: struct {
    txn_id: u64,
},
```

Existing `Insert`, `Update`, `Delete`, `Query`, `Read` ops grow an
optional `txn_id: ?u64` field. When set, the op participates in the
named transaction. When null, the op is executed as a standalone
auto-commit transaction (today's behavior).

Wire compat: clients that don't send `txn_id` see no behavior
change.

### 7.1 Client API

planck-zig-client gains:

```zig
const txn = try client.begin(.{ .isolation = .si });
defer txn.abortIfActive();

try txn.insert("orders", order_doc);
try txn.update("inventory", item_doc);

try txn.commit();
```

Under the hood the client tracks `txn_id` and threads it through
every op. On error or panic, `defer abortIfActive` ensures
WAL-Logged abort.

## 8. Phased rollout

The phases ship usable functionality at each step. We can stop
anywhere.

### Phase 1 — MVCC reads (no client-facing txn API)

- Version chains in primary index.
- Read path uses MAST + snapshot_cts; every standalone read takes a
  snapshot at op start.
- Write path extends chains under brief exclusive lock.
- Version GC.

Goal: eliminate reader-writer interference. Writers still serialize
each other. No client API change. Workbench heavy-write scenarios
stop blocking reads.

**Engineering: ~2–3 weeks. Highest ROI.**

### Phase 2 — Single-statement implicit transactions

Each existing op (Insert, Update, Delete) becomes a degenerate txn
with one write. Internally already true after Phase 1.

Goal: validate the txn machinery with the easiest case before
exposing multi-statement txns. Internal refactor only.

**Engineering: ~1 week.**

### Phase 3 — Multi-statement transactions with Snapshot Isolation

Client API: `begin / commit / abort`. Wire protocol gains `txn_id`.
Conflict policy: first-writer-wins.

Goal: full ACID with SI for any OLTP-style multi-doc workflow.

**Engineering: ~1–2 weeks.**

### Phase 4 (optional) — Serializable Snapshot Isolation

Add read-set tracking and the SSI dependency-cycle check at commit.

Goal: zero anomalies for workloads that need it (financial,
inventory). Most applications won't enable it because of the
conflict-abort rate at scale.

**Engineering: ~1–2 weeks.**

## 9. Performance considerations

### 9.1 Read overhead

A read walks the version chain to find a version with
`cts ≤ snapshot_cts`. For the latest-version case, this is one
pointer comparison: trivial. For older snapshots, the chain depth
depends on write rate and snapshot age. At 10k writes/sec and 30 s
snapshot age, chains average ~30 entries (random distribution
across keys). The B+tree leaf size is more limiting than version
walk cost.

Expected read throughput: 70-90 % of today's. The price of
predictability.

### 9.2 Write overhead

Write becomes "chain extension" instead of "full B+tree insert plus
inline flush." Net write cost goes DOWN per op because flush is no
longer the writer's problem — it's the version GC's problem.

Expected write throughput: similar to today's (still serialized at
the index), but with consistent latency. No 500 ms flush stalls.

### 9.3 Memory overhead

Per active key with N versions in chain: 16 bytes for `VersionHead`
plus 24 bytes per `VersionLink`. For 1 M live keys with chains
averaging 5 versions: 1 M × (16 + 5 × 24) ≈ 140 MB. Tolerable.

For long-running snapshots, chains can grow. Snapshot timeout
bounds this.

### 9.4 GC overhead

GC walks all primary_index entries periodically. At 1 M keys and a
30 s cadence, that's 30k keys/sec of background work. Easily kept
under 1 % of a core.

## 10. Open questions

These need decision before Phase 1 implementation:

- **Snapshot acquisition cost.** Single atomic load of
  `next_commit_ts`? Or batched per-session? Atomic is correct but
  contended; per-session adds complexity.
- **B+tree leaf layout for VersionHead.** Inlined in the leaf
  (faster, larger leaves, more splits) or pointer to heap (slower
  hop, simpler resizing).
- **CTS allocation under high concurrency.** A single atomic counter
  caps commit rate to ~50M CTS/sec on modern hardware. Far above any
  realistic workload; not a real concern but worth measuring.
- **Replica consistency.** Replica replays the primary's WAL; with
  CTS in WAL records, replica naturally constructs the same version
  chains. No protocol change needed — verify with tests.
- **MAST tracking under partition.** What if an aborted txn's
  rollback record never reaches the engine (process crash)? Need a
  scavenger that times out stale entries in `active_txns`.

## 11. Risks

- **Implementation complexity.** MVCC B+tree code is well-trodden
  but not trivial. Bugs in version visibility are subtle and may
  manifest only under contention. Plan for an extended test phase
  with fault injection.
- **Memory pressure.** Long chains + snapshot timeout failure modes
  can balloon RAM. Aggressive snapshot revocation + memory caps
  needed.
- **Read latency degradation for some patterns.** Cold reads of
  rarely-touched keys with many old versions in chain hit worst-
  case walk. Bound chain depth at GC time (e.g. cap at 100 versions;
  beyond that, compact).

## 12. Alternatives considered and rejected

- **Just live with the 500 ms flush stall.** Acceptable for offline
  bulk loads but blocks online workloads with mixed writes/reads.
  Cooperative yield (≤ 50 lines of code) is a cheaper partial fix
  but doesn't enable transactions.
- **Per-store locks.** Helps write scalability across stores but
  doesn't help a single hot store, and doesn't give transactional
  semantics. Orthogonal to MVCC; can be done independently if write
  throughput becomes a problem.
- **Distributed consensus (Raft / Paxos) for transactions.** Out of
  scope for a single-node MVCC story. Useful only when multi-node
  ACID is required, which is a separate design problem.

## 13. Decision points before starting

1. **Do we need transactions in 2026?** If yes, start Phase 1 now.
   If no, do the cheap cooperative-yield band-aid and revisit when
   product needs them.
2. **SI or SSI as the long-term target?** SI is plenty for 95 % of
   OLTP. SSI adds correctness at cost. Pick based on the workloads
   actually being built.
3. **Wire-protocol breaking change acceptable?** Adding `txn_id` to
   existing ops is wire-additive (optional field), so existing
   clients are unaffected. Confirm no other clients in flight that
   need to bump too.
