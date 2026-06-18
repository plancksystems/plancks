# HDA Monolith Starter

Hypermedia-driven, single-process Zig app. One binary serves HTML
fragments rendered server-side from `.zsx` templates; the browser
uses [datastar](https://data-star.dev) for swap-on-event interactions.

## Layout

```
app.yaml                 project identity (name, description)

app/                     the WASM app + its planck/db config
  build.zig
  build.zig.zon
  db.yaml                planck/db storage tuning
  service.yaml           identity + WASM hosting + upstreams
  public/index.html      static shell; navbar + #content placeholder
  src/
    main.zig             native dev entry (schnell HTTP server)
    app.zig              WASM entry (planck/db hosted)
    core/ctx.zig         shared Ctx (planck client + future config)
    features/tasks/      example feature - tasks CRUD
      routes.zig         register(app, ctx) wires the verbs
      repo.zig           planck.Model wrapper - schema + CRUD
      models/task.zig
      handlers/          one fn handle per route
      zsx/task_list.zsx  source template
      fragments/         generated at build time

sse/                     SSE event service (standalone native binary)
  build.zig
  build.zig.zon
  sse.yaml               TCP receive + HTTP serve ports
  src/main.zig           Hub + dispatch + endpoint registrations
  src/handlers/          one file per `store_ns` that ships events
```

## Build

```sh
# WASM app
cd app
zig build                    # WASM → zig-out/wasm/app.wasm
zig build dev-build          # native dev binary → zig-out/bin/app-dev
zig build dev                # build + run native dev on :4000

# SSE service
cd ../sse
zig build                    # native binary → zig-out/bin/<app>_sse
zig build run                # build + run, reads ./sse.yaml
```

`zig build` in `app/` runs `planctl` to transpile
`src/features/*/zsx/*.zsx` → `src/features/*/fragments/*.zig` before
compiling.

## Deploy

From the project root:

```sh
planctl deploy --app --arch mono --profile <p>   # builds + uploads both app/ and sse/
```

`planctl deploy` builds the WASM bundle from `app/` and the sse
binary from `sse/`, uploads both to the workbench, and the workbench
provisions + supervises them as two services under one app.

## Next steps

- Add a feature by mirroring `app/src/features/tasks/`
- Wire auth in `app/src/core/ctx.zig` (add an `app/src/core/auth/`)
- Add SSE endpoints in `sse/src/main.zig` + handlers in
  `sse/src/handlers/<store>.zig` (decode BSON, render HTML, publish)
