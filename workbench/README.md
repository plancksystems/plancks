# workbench

Control plane for planck: identity, app + service supervision, query
editor, schema browser, deploy receiver, scheduler, backup / restore,
and a live monitoring UI. One Zig binary (`workbench`) that runs
alongside planck/db on the same host.

```
            ┌──────────────────────────────────────────────────┐
browser ───▶│  workbench :2369   (its own launchd/systemd unit) │
            │   ├── /api/*        control + query APIs          │
            │   ├── /             embedded Vue UI               │
            │   └── tasks/                                      │
            │        ├── AppServices  registers each app +      │
            │        │                service as an OS service  │
            │        ├── Scheduler    samples health            │
            │        └── system_db    identity store            │
            └──────────────────────────────────────────────────┘
               │                                  │
               ▼ planck wire (TCP :23469)         ▼ register + start via
        planck/db (system catalog)                  launchd / systemd / SCM
                                          ┌─────────┴──┬──────┬───────┐
                                          ▼            ▼      ▼       ▼
                                        app1         svc1    sse    proxy
                                   (each its own OS service, auto-restarted)
```

Workbench does not host or directly fork the apps it manages. For every
deployed artifact it writes an OS service definition and hands the
process to the platform supervisor (launchd on macOS, systemd on Linux,
SCM on Windows), which owns the lifecycle and restarts it on crash.

## Install

workbench is part of the planck monorepo. Build the binary:

```sh
cd workbench
zig build -Doptimize=ReleaseFast
# binary lands at zig-out/bin/workbench
```

The install script (or `planctl system init`) drops the binary at
`~/.planck/bin/workbench`, writes a default `~/.planck/workbench/config.yaml`,
and starts it on port 2369.

Minimum Zig: 0.16.0.

## Running

```sh
workbench
```

It reads `config.yaml` from the current working directory. Under
`planctl system init` the unit's working directory is
`~/.planck/workbench/`, so that's the config it loads. The HTTP API + UI
come up on `listen_port` (default 2369); open `http://localhost:2369` in
a browser.

`planctl system start | stop | restart | status` shells out to the
right launchd / systemd unit so you don't have to remember the path.

## Configuration

`config.yaml` at the data root:

```yaml
mode: "dev"                        # parsed but currently unused: supervision
                                   # always goes through the OS service manager
planck_dir: "/Users/me/.planck"    # planck home; binaries and data live under here
data_dir:   "/Users/me/.planck"
planck_bin: "/Users/me/.planck/bin/planck"
listen_port: 2369                  # workbench HTTP

logging:
  path: "/Users/me/.planck/logs/workbench.log"
  level: info                      # debug | info | warn | err
  max_size_mb: 10
  max_files: 5

system_db:
  host: "127.0.0.1"
  port: 23469                      # planck/db's system catalog
```

`system_db` is workbench's identity backbone: users, sessions, admin
credentials, deploy state, schedules, and metrics live here. It's a
local planck/db instance.

## What workbench does

### Identity

`system_db` holds the admin user, hashed credentials, and any
additional users you create. Workbench's auth middleware verifies a
session cookie on every request and exposes the user identity to API
handlers.

`planctl` authenticates against workbench (not against planck/db
directly) for deploy and admin operations. The credentials sit in
`~/.planctl/config.yaml` under a profile; workbench validates them
against `system_db` and hands back a session.

### App + service supervision

`AppServices` (in [src/tasks/services.zig](src/tasks/services.zig))
keeps a live map of deployed apps and their child services. On startup
it scans `data_dir/apps/` and brings up everything that was previously
running.

Every deployed artifact is registered as its **own OS service** through
`utils.ServiceControl`: launchd on macOS, systemd on Linux, Windows SCM
on Windows. That includes:

| Artifact                  | Manager                                  | Service label (macOS)        |
| ------------------------- | ---------------------------------------- | ---------------------------- |
| shell / mono app          | `AppManager`                             | `com.planck.app.<app>`       |
| WASM service (`planck/db`)| `ServiceManager`                         | `com.planck.svc.<app>.<svc>` |
| SSE service               | `ServiceManager`                         | `com.planck.svc.<app>.<sse>` |
| reverse proxy (if any)    | `AppManager` (`proxy:` block in app.yaml)| `com.planck.proxy.<app>`     |

(On Linux the prefix is `planck.`, on Windows `Planck.`.) Services are
registered with KeepAlive / `Restart=on-failure` / `start=auto`, so the
platform supervisor relaunches a crashed process on its own. Workbench
queries status by shelling out to `launchctl` / `systemctl` / `sc.exe`,
and runs an additional health-check loop that restarts crashed shell
apps with exponential backoff. Re-deploying an artifact stops and
unregisters the old unit before writing the new one.

Lifecycle endpoints:

| Endpoint                  | Method | Purpose                       |
| ------------------------- | ------ | ----------------------------- |
| `/api/apps`               | GET    | List deployed apps            |
| `/api/apps`               | POST   | Create a new app entry        |
| `/api/app-lifecycle`      | POST   | Start / stop / restart an app |
| `/api/services`           | GET    | List services per app         |
| `/api/connect`            | POST   | Connect to a service's DB     |
| `/api/disconnect`         | POST   | Disconnect from a service     |
| `/api/databases`          | GET    | List stores in the current DB |

### Scheduler + health

The `Scheduler` watches every running service, samples metrics, and
classifies each as healthy / degraded / down. Used by the dashboard
to surface failing services without polling them yourself.

| Endpoint                  | Method | Purpose                       |
| ------------------------- | ------ | ----------------------------- |
| `/api/health`             | GET    | One-shot health probe         |
| `/api/monitor`            | GET    | Current health snapshot       |
| `/api/stats`              | GET    | Per-service request + storage |
| `/api/monitor/gc`         | POST   | Trigger vlog GC on a target   |
| `/api/schedules`          | GET    | List scheduled jobs           |
| `/api/schedules`          | POST   | Pause / resume / run-now      |

### Query editor + schema

The UI ships a query editor over the live planck wire. Schema and
query both run against whichever DB the operator picked in the left
pane.

| Endpoint                  | Method | Purpose                                       |
| ------------------------- | ------ | --------------------------------------------- |
| `/api/left-pane`          | GET    | Tree of apps + services + stores              |
| `/api/schema`             | POST   | Apply schema operations (create store, index) |
| `/api/query`              | POST   | Run a PQL query against the connected DB      |

### Deploy receiver

`planctl deploy` posts WASM + config bundles to workbench:

| Endpoint                  | Method | Purpose                       |
| ------------------------- | ------ | ----------------------------- |
| `/api/deploy`             | POST   | Receive a planctl deploy      |

Workbench writes the bundle to `data_dir/apps/<name>/`, registers it as
an OS service (launchd / systemd / SCM), and starts it through that
supervisor. `planctl` polls `/api/health` until the service comes up.

### Import / export

| Endpoint                  | Method | Purpose                                  |
| ------------------------- | ------ | ---------------------------------------- |
| `/api/import`             | POST   | Import a store from JSON / BSON / CSV    |
| `/api/export`             | POST   | Export a store to JSON / BSON / CSV      |

Both accept the same YAML manifest shape that `planctl import` /
`planctl export` consume.

### Logs

| Endpoint                  | Method | Purpose                       |
| ------------------------- | ------ | ----------------------------- |
| `/api/logs`               | GET    | Tail the per-service log file |

### Admin

| Endpoint                       | Method | Purpose                              |
| ------------------------------ | ------ | ------------------------------------ |
| `/api/admin`                   | POST   | Reset admin credentials, key rotate  |
| `/api/system-db/status`        | GET    | Is the system DB reachable?          |
| `/api/system-db/connect`       | POST   | Connect to a remote system DB        |
| `/api/system-db/logout`        | POST   | Drop the system DB session           |

## TLS

Mono apps default to TLS 1.3 with a self-signed cert generated at
first start. Two escape hatches:

- Drop your own cert/key into `data_dir/tls/` and point `db.yaml` at
  it (per service).
- Disable TLS entirely when workbench sits behind a proxy (Caddy,
  nginx) that terminates it for you.

The reverse proxy is your choice; workbench doesn't pick one. See
the [planctl README](../planctl/README.md) for the rationale on why
proxy config stays user-managed.

## UI

The Vue UI is built once and embedded into the workbench binary
(`@embedFile` on `src/ui/dist/{index.html, index.css, index.js}`),
so the binary is self-contained.

Rebuilding the UI:

```sh
cd ui              # Vue source lives at the repo root
npm install
npm run build      # builds and copies the bundle into workbench/src/ui/dist/
cd ../workbench
zig build -Doptimize=ReleaseFast   # picks up the new bundle
```

## Phase 7 rename

In Phase 7 the project is renamed from `workbench` to `Control
Center`: the directory becomes `planck/cc`, the binary becomes `cc`,
and the UI title becomes "Control Center". Internal symbols and API
paths stay the same. Existing deployments don't break; the CLI
gains an alias.

## License

MIT, see [LICENSE](./LICENSE).
