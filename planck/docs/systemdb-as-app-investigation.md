# Investigation: systemdb as a "system" app + read-only gate + wb→sys rename

Plan items mapped to the actual code on `main` (HEAD = 37d87d0). This doc was iterated after two architectural pushbacks from the user that meaningfully simplified the work; the result below is the final shape.

---

## Architectural decisions arrived at during investigation

1. **systemdb stops being a standalone orphan.** It becomes a service entry under a synthetic `system` app in `wbapps`, structurally identical to a mono app's service entry.
2. **`wbservices` store is deleted entirely** — not renamed to `sysservices`, not kept for back-compat. It was already a deprecated scaffold (the codebase has explicit `// Backward compat: old STORE_SERVICES` comments and a half-finished `migrateServicesToApps` walker). Everything that lived in it now lives in `wbapps[].services[]`.
3. **Read-only enforcement for systemdb is two early-returns in wb's HTTP layer.** Not a server-side `checkPermission` gate (would block wb's own deploy writes — same TCP socket), not a separate identity for the UI. Just: when the wb endpoint that serves the Query Workspace and the Schema Browser sees `service_name == "systemdb"` + a mutating op, reject with a clear message. wb's deploy/app/schedule write paths go through completely different handlers and are unaffected.
4. **`NodeType` enum is added** but is metadata for the UI (drives the "🔒 system" badge + greying out write buttons), not a security boundary on the server. The security boundary is the wb-HTTP-layer gate from #3.

Order of execution recommended: **#4 (rename wb→sys) → #2 (system app + delete wbservices) → #3 (read-only gates) → #1 (NodeType enum)**. Each step is independently shippable and verifiable.

---

## #1 — Add `NodeType` enum in `db/src/common/config.zig`

**Current state.** No role/type field in `Config`. The Config struct ([db/src/common/config.zig:14-60](../src/common/config.zig#L14-L60)) is purely about networking, durability, buffers, paths. `db.yaml` has no role field either. Clean slate — pure addition.

**Change needed**:

| File | Change |
|---|---|
| [db/src/common/config.zig](../src/common/config.zig) | Add at top: `pub const NodeType = enum { system, user };`. Add field in `Config` struct: `node_type: NodeType = .user;` (default user so existing app configs don't need touching). Update the YAML parser branch that walks top-level keys to recognize `node_type:` and parse it via `std.meta.stringToEnum(NodeType, value)`. Update `toString`/`toYaml` (if present) to emit it. |
| [db/db.yaml](../db.yaml) (systemdb's own config) | Add `node_type: "system"` at the top. Tenants' generated `db.yaml` (from `planctl deploy`) defaults to `node_type: "user"` — explicit or omitted (default kicks in). |
| [ctl/src/deploy/*](../../ctl/src/deploy/) | Where templates emit a `db.yaml`, add `node_type: "user"` line. Optional — default handles it. |

**What it's NOT for**: there is no server-side gate on `node_type` in `checkPermission`. The enforcement lives in wb's HTTP layer (#3). The enum exists so the UI can render systemdb visually distinct and so wb's `/api/apps` response can carry an explicit `node_type: "system"` flag for the system app entry.

---

## #2 — Show systemdb under a synthetic "system" app + delete `wbservices` entirely

**Current state.** systemdb is rendered as a **standalone orphan service** — not nested under any app. The codebase has multiple "Backward compat: old STORE_SERVICES" markers indicating an in-progress migration that was never finished:

- [wb/src/api/services.zig:87-88](../src/api/services.zig#L87-L88): `// Backward compat: old STORE_SERVICES.`
- [wb/src/tasks/scheduler.zig:392](../src/tasks/scheduler.zig#L392): `// Search in old STORE_SERVICES first, then scan apps`
- [wb/src/tasks/services.zig:425](../src/tasks/services.zig#L425): `migrateServicesToApps` walker
- [wb/src/tasks/services.zig:175-199](../src/tasks/services.zig#L175-L199): inserts systemdb into `wbservices` with `app = ""`
- [ui/src/components/Sidebar.vue:86-88](../../ui/src/components/Sidebar.vue#L86-L88): explicit `orphans` list + `showSystemDb` toggle
- [ui/src/components/UnifiedDashboard.vue:112](../../ui/src/components/UnifiedDashboard.vue#L112), [SchedulesPanel.vue:92](../../ui/src/components/SchedulesPanel.vue#L92), [ServicesTable.vue:109,130,491](../../ui/src/components/ServicesTable.vue#L109): every dashboard view branches on "standalone services"
- [ServerOverviewPanel.vue:80](../../ui/src/components/ServerOverviewPanel.vue#L80): `serviceName === 'systemdb'` hardcoded for the Permissions tab

**The new shape.** systemdb lives in `wbapps`:

```
wbapps[
  { name: "system", node_type: "system", services: [{ name: "systemdb", host, port, kind: "db", ... }] },
  { name: "pizzaqsr-hda-mono", services: [...] },
  ...
]
```

`wbservices` ceases to exist. The half-finished migration walker goes too — there's nothing left to migrate from, and bootstrap is fundamentally a different concern from runtime migration.

**Change needed**:

| File | Change |
|---|---|
| [wb/src/tasks/storage.zig:15](../src/tasks/storage.zig#L15) | Delete `pub const STORE_SERVICES: u16 = 1;`. Renumber the remaining `STORE_*` constants if needed (they're internal, no wire impact). |
| [wb/src/tasks/storage.zig:66-70](../src/tasks/storage.zig#L66-L70) | Drop `wbservices` from the `ensureStores` table. |
| [wb/src/tasks/storage.zig:496-500](../src/tasks/storage.zig#L496-L500) | Drop `STORE_SERVICES => "wbservices"` from `storeNs` switch. |
| [wb/src/tasks/services.zig:175-199](../src/tasks/services.zig#L175-L199) | Rewrite systemdb registration: instead of `put(STORE_SERVICES, ...)`, ensure the `system` app exists in `wbapps` (use the existing `putApp` path) and put the systemdb service entry into its `services[]` array. Same shape any mono app uses. |
| [wb/src/tasks/services.zig:284,325,425,712](../src/tasks/services.zig#L284) | **Delete** the `migrateServicesToApps` walker + every other STORE_SERVICES read/delete/list. No back-compat needed (pre-release codebase). |
| [wb/src/api/services.zig:87-92](../src/api/services.zig#L87-L92) | Delete the "Backward compat: old STORE_SERVICES" branch. The list now comes solely from `wbapps[].services[]`. |
| [wb/src/api/connect.zig:64](../src/api/connect.zig#L64) | Delete the STORE_SERVICES lookup fallback. Services are only resolved via the apps hierarchy. |
| [wb/src/tasks/scheduler.zig:392-450](../src/tasks/scheduler.zig#L392-L450) | Delete the "old STORE_SERVICES first, then scan apps" path. Apps hierarchy is the only source. |
| [ui/src/components/Sidebar.vue:86-95](../../ui/src/components/Sidebar.vue#L86-L95) | Delete the `orphans` branch + `showSystemDb` toggle. systemdb arrives in the regular apps list under the `system` app. |
| [ui/src/components/ServicesTable.vue:109,130,491](../../ui/src/components/ServicesTable.vue#L109) | Drop the "standalone services" rendering branch. Single app-with-services rendering handles everything. |
| [ui/src/components/UnifiedDashboard.vue:112](../../ui/src/components/UnifiedDashboard.vue#L112), [SchedulesPanel.vue:92](../../ui/src/components/SchedulesPanel.vue#L92) | Delete the orphan-rendering branches. |
| [ui/src/components/ServerOverviewPanel.vue:80](../../ui/src/components/ServerOverviewPanel.vue#L80) | Replace `serviceName === 'systemdb'` with `nodeType === 'system'` (passed as prop from `/api/apps`). |

**Estimated LOC**: ~120 deleted, ~30 added. Net negative — a real simplification.

**Migration plan**: hard cutover. Wipe `~/.planck` + `planctl system init`. Pre-release codebase, no real installs to preserve.

---

## #3 — Read-only enforcement for systemdb

**The contradiction the user caught.** A server-side `checkPermission` gate keyed on `node_type` would block writes from *every* TCP client — including wb's own deploy/app-create handler, which writes to `wbapps` over the same socket. Making it work would require either merging wb and systemdb into one process (big), or giving wb a separate identity that bypasses the gate (defeats the purpose). Neither is worth it.

**The right place for the gate is wb's HTTP layer, not systemdb's wire layer.**

Operators have two paths that hit systemdb's mutable state from the UI:

1. **Query Workspace** (PQL inserts/updates/deletes) → [wb/src/api/query.zig](../src/api/query.zig)
2. **Schema Browser** (create-store, drop-store, create-index, drop-index) → [wb/src/api/schema.zig](../src/api/schema.zig)

wb's deploy / app-create / schedule-create flows go through entirely different handlers (`/api/apps`, `/api/deploy`, `/api/schedules`) that talk to `WbStorage` methods, not these two endpoints. So a check in just these two files blocks UI-driven mutations without touching wb's own legitimate writes.

**Change needed — two early returns, ~10 LOC total**:

**File 1**: [wb/src/api/query.zig:53](../src/api/query.zig#L53) — after `query_ast` parsing succeeds (line 52) and before any store work (line 54). Mutations are already centralized at line 116 in `query_ast.mutation` (variants: `.insert` / `.update` / `.delete`); one nil-check covers all three:

```zig
if (std.mem.eql(u8, service_name, "systemdb") and query_ast.mutation != null) {
    try res.json(try json.serialize(allocator, QueryResponse{
        .success = false,
        .@"error" = "systemdb is read-only — use Apps / Schedules / Deploy panels to modify state",
    }));
    return;
}
```

**File 2**: [wb/src/api/schema.zig:37](../src/api/schema.zig#L37) — after `service_name` resolution (line 36). Every action in `schema.zig` is destructive (`create-store`, `create-index`, `drop-store`, `drop-index`), so block the entire endpoint when target is systemdb:

```zig
if (std.mem.eql(u8, service_name, "systemdb")) {
    try res.json(try json.serialize(allocator, SchemaResponse{
        .success = false,
        .@"error" = "systemdb is read-only — schema changes are managed by the workbench bootstrap",
    }));
    return;
}
```

**Why this is safe**:
- wb's own writes never touch query.zig or schema.zig. They go through `WbStorage.putApp` / `putService` / `putSchedule` from `services.zig` / `app.zig` / etc. — different code paths, different handlers.
- The check is the string `"systemdb"` matching what [services.zig:198](../src/tasks/services.zig#L198) registers in the pool. When the `system` app rename is wired up in #2, this string stays the same (the *service* name is still "systemdb"; what changes is its parent in the apps hierarchy).
- Reads (filter, order, group, aggregate, count) on systemdb still work — operators can inspect any system store.
- No server-side change. No new `ErrorCode`. No `checkPermission` modification.

**UI follow-up (optional)**: in the Schema Browser, when viewing systemdb, grey out / hide the Insert Document / Drop Store / Create Index buttons. Pure UX — the server enforcement above is the security boundary. Recommended but not required.

---

## #4 — Rename `wb*` → `sys*` in remaining stores

After #2 deletes `wbservices`, four stores remain to rename:

| Today | New name |
|---|---|
| `wbschedules` | `sysschedules` |
| `wbstats` | `sysstats` |
| `wbapps` | `sysapps` |
| `wb_backups` | `sysbackups` *(also fixes the inconsistent underscore)* |

**Change needed**:

| File | Hits | Change |
|---|---|---|
| [wb/src/tasks/storage.zig:66-70](../src/tasks/storage.zig#L66-L70) | 4 (the `ensureStores` table after #2's deletion) | Rename string literals. Keep `STORE_*` constant identifiers. |
| [wb/src/tasks/storage.zig:496-500](../src/tasks/storage.zig#L496-L500) | 4 (`storeNs` switch) | Same rename. |
| [wb/src/tasks/services.zig](../src/tasks/services.zig) | scan | Any embedded literal references. |
| [wb/src/tasks/backup_orch.zig](../src/tasks/backup_orch.zig) | scan | Any embedded literal references. |
| [db/src/tcp/server.zig](../src/tcp/server.zig) | scan | Any `_sys.*`-prefix exemption logic — verify it still allows the new `sys*` names. |
| [ctl/src/deploy/restore.zig](../../ctl/src/deploy/restore.zig) | scan | Restore path names stores by string. |
| [ui/src/api/index.js:278](../../ui/src/api/index.js#L278) | comment only | Update the `wb_backups` reference in the comment. |

**Compatibility**: hard cutover (same reasoning as #2 — pre-release, no real data).

---

## Order of execution

| # | Step | Risk | Verification |
|---|---|---|---|
| 1 | **#4 — rename `wb*` → `sys*`** | Low (mechanical search/replace) | systemdb boots, `/api/apps` returns sensibly, deploys still work |
| 2 | **#2 — delete `wbservices`, register systemdb under `system` app, drop UI orphan branches** | Medium (touches several UI files but each is a delete) | systemdb appears in apps list under "system"; no orphan rendering; deploys still work |
| 3 | **#3 — early-return gates in query.zig + schema.zig** | Trivial (~10 LOC additive) | Query Workspace insert against systemdb → rejected; Schema Browser drop-store on `sysapps` → rejected; deploys still work; apps queries still work |
| 4 | **#1 — `NodeType` enum in config + db.yaml** | Trivial (pure addition, defaults preserve behavior) | New `db.yaml` parses; `/api/apps` exposes `node_type` flag; UI renders "🔒 system" badge |

Each step independently shippable. None of them changes wire protocol or persistence format beyond the optional `wb*→sys*` store renames in #4 (covered by hard cutover).

---

## What I'm still uncertain about

1. **The `_sys.*`-prefix exemption in server.zig.** [db/src/tcp/server.zig](../src/tcp/server.zig) blocks data ops on namespaces starting with `_sys.`. The new `sys*` names (`sysapps`, `sysschedules`, etc.) don't have the underscore prefix, so they wouldn't match this exemption. Need to verify the user-facing protection still works correctly after the rename — likely a one-line change to also block `sys*` prefix, or no change if the existing check is already permissive enough for wb's admin connection.
2. **Whether [wb/src/tasks/services.zig:198](../src/tasks/services.zig#L198) (`pool.register("systemdb", host, port, uid, key)`) is the only auth path from wb to systemdb.** If there's another bypass path, #3's gate still works (it's at wb's HTTP layer, not on systemdb), but worth knowing for future refactors.
3. **Whether the migration walker has been needed in practice** or just sits unused. If unused, deleting it in #2 is risk-free. If still used by anyone's existing install — pre-release codebase says no real installs exist, so this is moot.

These can be confirmed in ~5 minutes each before the relevant step. None block decisions; they refine implementation.
