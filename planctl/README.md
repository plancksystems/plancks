# planctl

The command-line toolchain for the Planck stack. One binary handles
project scaffolding, `.zsx` template compilation, deployments to a
Workbench-supervised host, runtime lifecycle control, and backup /
restore.

```
planctl <command> [args...]
```

`planctl --help` (or any invocation with no command) prints a short
usage screen; this README is the long form.

---

## Quickstart

```bash
# Scaffold a hypermedia + monolith project
planctl new myapp --type hda --arch mono
cd myapp


# Deploy to a configured profile (mono project → --arch mono)
planctl deploy --all --arch mono --profile dev
```

The four supported architecture styles are described in [Project
templates](#project-templates) below.

---

## Configuration

`planctl` reads its target host(s) from `~/.planctl/config.yaml`. A
config file declares one or more **profiles**; each profile lists one
or more workbench **nodes**.

```yaml
profiles:
  - name: dev
    nodes:
      - server: http://127.0.0.1:2369
        uid: admin
        key: <wb-admin-key>

  - name: prod
    nodes:
      - server: https://prod-wb.example.com
        uid: admin
        key: <wb-admin-key>
      - server: https://prod-wb-replica.example.com
        uid: admin
        key: <wb-admin-key>
```

When a profile has multiple nodes, every command iterates them in
order and runs against each one.

Every command that talks to a Workbench requires `--profile <name>`,
which selects a profile from `~/.planctl/config.yaml`. There are no
built-in defaults: a profile is required. The profile is the only way
to point `planctl` at a host; there are currently no per-invocation
`--server` / `--uid` / `--key` overrides or `PLANCTL_*` environment
variables.

---

## Commands

### `planctl system <subcommand>`

One-time host setup. Installs the workbench + system database, creates
the supervisor service definitions (launchd on macOS, systemd on Linux,
SCM on Windows), and arranges the directory layout under the
OS-specific install root (see the table below).

| Subcommand      | Effect                                                      |
| --------------- | ----------------------------------------------------------- |
| `system init`   | Install workbench + sysdb, register supervised services     |
| `system start`  | Start every Planck-supervised process on this host          |
| `system stop`   | Stop every Planck-supervised process                        |
| `system deinit` | Unregister services; binaries and data files remain on disk |

`system init` always registers Workbench and the system database as
OS-managed services and starts them. The install root and the service
manager are determined by the host OS; there is no mode flag:

| OS      | Install root              | Service manager                    |
| ------- | ------------------------- | ---------------------------------- |
| macOS   | `$HOME/.planck`           | launchd (`/Library/LaunchDaemons`) |
| Linux   | `/opt/planck`             | systemd (`/etc/systemd/system`)    |
| Windows | `C:\Program Files\Planck` | Windows SCM (`sc.exe`)             |

### `planctl new <name> --type <hda|spa> --arch <mono|micro>`

Materialize one of four embedded templates into `./<name>/`.

| Type  | Arch    | Result                                                                    |
| ----- | ------- | ------------------------------------------------------------------------- |
| `hda` | `mono`  | Hypermedia-driven monolith (single binary, datastar + planck/db WASM)     |
| `hda` | `micro` | Hypermedia-driven micro (shell + per-feature WASM services + SSE service) |
| `spa` | `mono`  | SPA monolith (Vue bundle + single API + planck/db WASM)                   |
| `spa` | `micro` | SPA micro (Vue bundle + per-feature WASM services + SSE service)          |

All four templates ship with an `sse/` subproject: the live-updates
service built on `ssehub` (in-process WatchClient + EventBus + per-
subscriber queues). See the scaffolded
[`sse/src/handlers/README.md`](./templates/hda-mono/sse/src/handlers/README.md)
for a worked SSE consumer.

**Flags:**

| Flag          | Meaning                                                       |
| ------------- | ------------------------------------------------------------- |
| `--type`      | `hda` (server-rendered HTML + datastar) or `spa` (Vue bundle) |
| `--arch`      | `mono` (single deployable) or `micro` (shell + services)      |
| `--force, -f` | Overwrite an existing `<name>/` directory                     |

**Reverse proxy is intentionally not scaffolded.** By default the
shell binary, SSE service, and per-feature services each bind their
own port and the browser reaches them directly via CORS. Add your
own Caddyfile / nginx.conf / etc. in production. planctl doesn't
pick one for you.

### `planctl add <name> --type <feature|service> [--arch <hypermedia|rest>]`

In-project augmentation. Run inside an existing project root.

| Type      | Where it works                            | What it adds                                      |
| --------- | ----------------------------------------- | ------------------------------------------------- |
| `feature` | Mono projects (`hda-mono`, `spa-mono`)    | New `src/features/<name>/` with the Tasks pattern |
| `service` | Micro projects (`hda-micro`, `spa-micro`) | New `services/<name>/` with the Tasks pattern     |

**Flags:**

| Flag          | Meaning                                                                          |
| ------------- | -------------------------------------------------------------------------------- |
| `--type`      | `feature` for mono, `service` for micro                                          |
| `--arch`      | `hypermedia` (zsx-rendered routes) or `rest` (JSON-only). Inferred from project. |
| `--port <n>`  | Service port for `--type service` (default: scanned next-available)              |
| `--force, -f` | Overwrite an existing `<name>/` directory under features/ or services/           |

### `planctl deploy <target> [--arch <mono|micro>] --profile <name>`

Build + upload artifacts to the Workbench for the chosen profile.
Every node in the profile is contacted in turn (see Configuration).

| Target             | Action                                                                          |
| ------------------ | ------------------------------------------------------------------------------- |
| `--app`            | Build + upload the shell (mono = WASM hosted by planck; micro = native binary)  |
| `--service <name>` | Build + upload a single WASM service (micro projects only)                      |
| `--sse`            | Build + upload only the SSE subproject (`./sse/`). Same builder used by `--all` |
| `--all`            | `--app` + iterate `services/*` (micro) OR just `--app` (mono), then `--sse`     |

**`--sse` is for fast iteration on the SSE service.** When you're
tweaking templates, render functions, or topic logic, you don't want
to rebuild and re-upload the WASM app and static assets every time.
`--sse` runs only the `sse/` build and uploads only that artifact.

**`--all` auto-includes SSE.** If `./sse/build.zig` exists, `--all`
builds and uploads the SSE service last (so the topic is alive
before browsers can connect). Mechanically equivalent to running
the per-target commands in order: `--app`, each `--service <name>`,
`--sse`.

Pre-deploy port validator runs before any upload: refuses `port: 0`,
intra-project duplicate ports, and cross-app collisions. See
[`src/deploy/validate.zig`](./src/deploy/validate.zig).

**Flags:**

| Flag            | Meaning                                                                     |
| --------------- | --------------------------------------------------------------------------- |
| `--arch <m>`    | `mono` or `micro` (default: micro for backward compat. Set this explicitly) |
| `--profile <n>` | Required. Picks a profile from `~/.planctl/config.yaml`                     |

### `planctl undeploy <target> --profile <name>`

Remove previously deployed artifacts. Mirrors `deploy`'s target shape.

| Target             | Action                                                |
| ------------------ | ----------------------------------------------------- |
| `--app`            | Delete the shell app (services must be removed first) |
| `--service <name>` | Undeploy a single WASM service                        |
| `--all`            | Undeploy every service then delete the app            |

**Flags:**

| Flag               | Meaning                   |
| ------------------ | ------------------------- |
| `--profile <name>` | Required                  |
| `--force, -f`      | Skip confirmation prompts |

### `planctl start | stop | restart | status <target> --profile <name>`

Lifecycle commands against deployed artifacts. Use these to bring an
app back up after a deploy or to gather quick health info.

| Target             | Meaning                                                                |
| ------------------ | ---------------------------------------------------------------------- |
| `--app`            | The shell / mono binary                                                |
| `--service <name>` | A specific WASM service                                                |
| `--sse <app>`      | Sugar for `--service <app>_sse` (matches the deploy naming convention) |
| `--all`            | Everything under this app                                              |

`planctl status` defaults to `--all` when no target is given.

### `planctl backup --app <name> --profile <p> [--output <dir>]`

Trigger a backup of the app's data on the Workbench. CLI parity with
the workbench UI's create-backup action. Useful when ops wants to
drive a one-off backup from outside the UI.

| Flag               | Meaning                                                    |
| ------------------ | ---------------------------------------------------------- |
| `--app <name>`     | App to back up                                             |
| `--output <dir>`   | Local directory to download the backup into (default: cwd) |
| `--profile <name>` | Required                                                   |

### `planctl restore --backup <path> --profile <p>`

Restore an app, an app+service, or the whole system from a backup
archive. Mode is selected by which flags are present.

| Mode                               | Flags                                                        |
| ---------------------------------- | ------------------------------------------------------------ |
| App restore                        | `--app <name> --backup <path> --profile <p>`                 |
| App + service restore              | `--app <name> --service <svc> --backup <path> --profile <p>` |
| System (workbench + sysdb) restore | `--system --backup <path>`                                   |

### `planctl create | drop store | index`

Data-definition (DDL) against a deployed service's database. These drive
the Workbench's `/api/schema` endpoint, so they run wherever the service
is deployed. Writes go to the **primary** node in the profile; async
replication propagates them to replicas.

`--app` and `--service` pick the target database (the slug
`<app>_<service_name>`). Examples below pass them explicitly; from inside a
project tree you can omit them and they are resolved from `app.yaml` /
`db.yaml`, the same way `deploy` works.

```bash
# Create / drop a store
planctl create store orders --app shop --service orders --description "customer orders" --profile dev
planctl drop   store orders --app shop --service orders --force --profile dev

# Create / drop a secondary index. The index name is <store>.<index>, and
# the indexed field defaults to the index segment (override with --field).
planctl create index orders.status --app shop --service orders --profile dev
planctl create index orders.total  --app shop --service orders --type f64 --unique --profile dev
planctl drop   index orders.status --app shop --service orders --force --profile dev

# Mono only: from inside the project tree, --app / --service are optional
# (resolves to <app>_db). Micro apps must pass --service <name>.
planctl create store orders --profile dev
```

**Targeting.** The store/index lives in one service, addressed by the slug
`<app>_<service_name>` (for a mono app `shop` whose `db.yaml` service is
`db`, that is `shop_db`). With `--app` / `--service` you can target any
deployed service from anywhere; omit them inside the project tree to resolve
from `app.yaml` / `db.yaml` (default service `db` for mono).

> **Mono apps:** the service is always `db`, so the target is `<app>_db`.
> Inside the project tree you can omit both flags. **Run from anywhere
> else and you must pass `--app <name>`** (`--service` still defaults to
> `db` for mono). Only micro apps have multiple, individually named
> services.

**Flags:**

| Flag                | Meaning                                                                                           |
| ------------------- | ------------------------------------------------------------------------------------------------- |
| `--type <t>`        | Index field type: `string` (default), `i32`/`i64`/`u32`/`u64`/`f32`/`f64`/`bool`, `int` (= `i64`) |
| `--unique`          | Make the index unique (default: non-unique)                                                       |
| `--field <name>`    | Indexed field, when it differs from the index name's last segment                                 |
| `--description <d>` | Optional description (store)                                                                      |
| `--app <name>`      | Target app (else resolved from the project tree)                                                  |
| `--service <name>`  | Target service name (else resolved from `db.yaml`, default `db`)                                  |
| `--force, -f`       | Skip the confirmation prompt on `drop`                                                            |
| `--profile <name>`  | Required                                                                                          |

> The Workbench reports the engine's idempotent "already exists" as a
> generic error, so re-running `create store` / `create index` currently
> reports a failure rather than a no-op.

### `planctl export | import --manifest <file.yaml> --profile <p>`

Move data out of and into a store via a YAML manifest. planctl forwards
the manifest to the Workbench's `/api/export` / `/api/import` endpoints; the
engine reads and writes the data files itself, on the planck host. The
manifest is the only input.

```bash
planctl export --manifest orders-export.yaml --app shop --service orders --profile dev
planctl import --manifest orders-import.yaml --app shop --service orders --force --profile dev
```

(Mono only: run from inside the project tree, `--app` / `--service` are
optional and resolve to `<app>_db`. Micro apps must pass `--service <name>`,
since the project root has no single service.)

A manifest names one store, a format, and the entity layout:

```yaml
store: stores.orders
format: json # bson | json | csv
# output_dir: /data/exim   # optional; defaults to <base_dir>/exim on the host
# query: orders.filter(status = "shipped")   # optional export filter
entities:
  - name: orders
    role: parent
    file: orders.json
```

> **Mono apps:** the service is always `db`, so the target is `<app>_db`.
> Inside the project tree you can omit both flags. **Run from anywhere
> else and you must pass `--app <name>`** (`--service` still defaults to
> `db` for mono). Only micro apps have multiple, individually named
> services.

**Files are server-side.** Exports are written to, and imports read from, a
folder on the **planck host**, not your machine. When the manifest omits
`output_dir`, the engine defaults it to `<base_dir>/exim` (or the
`exim_dir` set in `db.yaml`) and creates it, the same way `backup_dir`
works. For a large import source, copy the files to that folder out of band
(scp / rsync); planctl transfers only the manifest.

**Flags:**

| Flag                | Meaning                                          |
| ------------------- | ------------------------------------------------ |
| `--manifest <file>` | Required. Path to the YAML manifest.             |
| `--app <name>`      | Target app (else resolved from the project tree) |
| `--service <name>`  | Target service name (else `db`)                  |
| `--force, -f`       | Skip the confirmation prompt on `import`         |
| `--profile <name>`  | Required                                         |

See [`ddl-exim.md`](./ddl-exim.md) for the full design and manifest schema.

### `planctl <file.zsx>` (transform single file)

Compile one `.zsx` template to stdout. Useful for one-off inspection.

```bash
planctl src/features/tasks/zsx/task_list.zsx > /tmp/task_list.zig
```

### `planctl <in_dir> <out_dir>` (batch transform)

Walk `in_dir` for `.zsx` files and emit corresponding `.zig` files
into `out_dir`. Output mirrors the input tree. This is what `zig
build` invokes per-project under the hood; you rarely call it directly.

**Both the WASM app and the SSE subproject use this.** App features
keep their `.zsx` under `src/features/<feature>/zsx/` with generated
fragments under `src/features/<feature>/fragments/`. The SSE
subproject mirrors the same pattern at the project root: `sse/src/zsx/`
and `sse/src/fragments/`. Both `build.zig` files invoke
`planctl src/zsx/ src/fragments/` (or the per-feature variants) before
compiling, so editing a `.zsx` is enough; the fragment regenerates on
the next build.

**Flags:**

| Flag              | Meaning                                                       |
| ----------------- | ------------------------------------------------------------- |
| `--target <lang>` | `zig` (default), `rust`, or `go`. Selects the codegen backend |

### `planctl --watch <in_dir> <out_dir>`

Same as batch transform but watches the input directory and
re-compiles on change. Good for live-edit development.

### `planctl clean <out_dir>`

Remove generated `.zig` files from `out_dir`. Companion to the
transform commands.

### `planctl init <name> [--type wasm|app]` (deprecated)

Legacy alias for the original scaffolders. Kept during transition;
prefer `planctl new <name> --type hda --arch mono` (etc.). Prints a
deprecation note and forwards to the old shell/wasm code paths.

---

## Workflow recipes

### From zero to deployed in five commands

```bash
# 1. One-time host setup
planctl system init
planctl system start

# 2. New project
planctl new mystore --type hda --arch mono
cd mystore

# 3. Configure a profile (or use an existing one)
# Edit ~/.planctl/config.yaml. See the Configuration section above.

# 4. Deploy
planctl deploy --all --arch mono --profile dev
```

### Add a feature to a mono project

```bash
cd myapp
planctl add billing --type feature
# A new src/features/billing/ is scaffolded with routes, handlers,
# a repo, models, and zsx templates following the Tasks pattern.

planctl deploy --app --arch mono --profile dev
```

### Add a service to a micro project

```bash
cd myapp
planctl add orders --type service --port 4501
# A new services/orders/ subproject is created.

planctl deploy --service orders --arch micro --profile dev
```

### Deploy + then restart just the SSE service

```bash
planctl deploy --all --arch mono --profile dev
planctl restart --sse myapp --profile dev
```

### Tear down and start over

```bash
planctl undeploy --all --profile dev --force
planctl deploy --all --arch mono --profile dev
```

### Take a backup before a risky migration

```bash
planctl backup --app myapp --profile prod --output ./backups
# Later, restore if needed:
planctl restore --app myapp --backup ./backups/myapp-2025-06-01.tar --profile prod
```

### How deployed apps are supervised

Workbench does not host or fork the apps itself. For every artifact you
deploy (the shell/mono app, each WASM service, the SSE service, and the
optional per-app reverse proxy), it writes an OS service definition and
starts it through the host's service manager:

| OS      | Service manager | Unit location / name                        |
| ------- | --------------- | ------------------------------------------- |
| macOS   | launchd         | `/Library/LaunchDaemons/com.planck.*.plist` |
| Linux   | systemd         | `/etc/systemd/system/planck.*.service`      |
| Windows | SCM             | `Planck.*` services                         |

These units are registered with KeepAlive / `Restart=on-failure`, so the
OS relaunches a crashed process automatically. `planctl start | stop |
restart | status` and Workbench's lifecycle endpoints both act on these
same units. `undeploy` stops and unregisters them.

### Path-dep rewriting

The templates declare local-path deps for in-monorepo dependencies
(`schnell`, `ssehub`, `utils`, `planck-zig-client`). When materializing
into an out-of-tree project, `planctl new` rewrites these to be
relative paths from the new project's `build.zig.zon` to the monorepo
copy of each dep. This means a project lives self-contained but still
picks up local source changes without re-publishing tagged releases.

The downside: scaffolded projects assume the monorepo is reachable on
disk via the rewritten relative paths. If you move the project out of
the monorepo tree, you'll need to switch the affected zon entries to
tagged URL deps yourself.

---

## License

MIT, see [LICENSE](./LICENSE).
