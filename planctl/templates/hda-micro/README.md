# HDA Micro Starter

Hypermedia-driven microservices. Each feature is its own binary
(WASM-hosted in prod, native dev for local iteration); a thin
shell serves the static `public/` and is the natural home for any
future auth flow. Caddy fronts the stack and routes by path prefix.

## Layout

```
build.zig                       shell
build.zig.zon
app.yaml                        shell identity + port (no proxy config)
dev.sh                          one-command build + run (expects a Caddyfile)
public/index.html               static shell
src/
  main.zig                      shell entry
  ctx.zig

services/
  tasks/                        example service
    build.zig
    build.zig.zon
    db.yaml                     planck/db storage tuning + wire port
    service.yaml                identity + route + wasm http port
    src/
      app.zig                   WASM entry
      dev.zig                   native entry
      ctx.zig
      routes.zig
      repo.zig                  planck.Model wrapper
      models/task.zig
      handlers/                 list / create / toggle / delete
      zsx/task_list.zsx
      fragments/                generated at build time
```

 

 
