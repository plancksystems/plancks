# SPA Monolith Starter

JSON-only Zig backend + Vue 3 SPA in one repo. Vue builds into
`public/` which the Zig server serves alongside the JSON API.

## Layout

```
build.zig
build.zig.zon
app.yaml                        app identity (name, description)
db.yaml                         planck/db config (ports, tuning, wasm hosting)
public/                         vite build output (created on first build)
src/
  main.zig                      native dev entry
  core/ctx.zig                  shared Ctx
  features/tasks/
    routes.zig
    repo.zig                    planck.Model wrapper
    models/task.zig
    handlers/                   list / create / toggle / delete (JSON)
frontend/
  package.json
  vite.config.js                emits to ../public/
  index.html
  src/
    main.js
    App.vue
    style.css
    router.js
    pages/Tasks.vue
    composables/api.js
```

## Run

```sh
# Backend
zig build dev                       # serves on :4000

# Frontend (separate terminal, with HMR)
cd frontend && npm install && npm run dev   # :5173, proxies /tasks → :4000

# Or build once and let the backend serve the bundle
cd frontend && npm run build        # emits to ../public/
# then open http://localhost:4000
```
