# Streaming handlers

Each file here is one `routeStreaming` handler, the entry point for
a browser EventSource connection. The shape is small and uniform:

```zig
pub fn handle(
    ctx_ptr: ?*anyopaque,
    handler_allocator: std.mem.Allocator,
    req: *const schnell.Request,
    writer: *std.Io.Writer,
) anyerror!void {
    const ctx: *HubCtx = @ptrCast(@alignCast(ctx_ptr.?));

    try ssehub.wire.writeHeaders(writer);
    try ssehub.wire.writeRetry(writer, ctx.bus.config.retry_ms);
    try writer.flush();

    const sub = try ssehub.Subscriber.init(
        handler_allocator, writer, ctx.io, ssehub.DEFAULT_QUEUE_SIZE);
    defer sub.deinit();

    try ctx.bus.subscribe(MY_TOPIC, sub, .{ .last_event_id = last_id });
    defer ctx.bus.unsubscribe(MY_TOPIC, sub);

    sub.runWriter();  // blocks until topic deleted or socket fails
}
```

That's it. The handler is purely a subscription registration: no
polling, no planck calls, no domain logic. The bus's dispatcher
delivers events via the subscriber's bounded queue; `runWriter`
drains the queue to the writer until done.

## Where the domain logic lives

The watch loop in `../main.zig` invokes `hub.processFrame` for every
change record. Each render fn (`render_<feature>.zig`) decodes
`frame.value` as its own model and publishes a `datastar-patch-elements`
patch to a topic. Adding a feature typically means:

1. **Model**: add `src/models/<feature>.zig` with the BSON shape your
   handler will decode.
2. **Template**: add `src/zsx/<feature>_card.zsx` (or similar). The
   build step auto-runs `planctl src/zsx/ src/fragments/` so any
   `.zsx` you drop in compiles to `src/fragments/<feature>_card.zig`
   on the next `zig build`. The generated file imports `web` for
   HTML-safe value escaping; that module is already wired in
   `build.zig`.
3. **Topic**: pick a name. Static (`"kitchen"`) for shared
   dashboards, templated (`"order:<key>"`) for per-entity streams.
4. **Register if static**: in `main.zig`,
   `bus.registerTopic("<topic>", .{ .replay_buffer_size = N })`.
5. **Render**: add `src/render_<feature>.zig` that decodes the frame
   body, calls the fragment's `.render(...)`, prepends `"elements "`
   to the HTML, and calls `c.bus.publish(topic, ...)`. See
   `render_example.zig` for the pattern.
6. **Branch in `hub.processFrame`**: invoke the render fn for the
   relevant `frame.store_ns` / `frame.kind`.
7. **Handler**: copy `example.zig` to `<feature>.zig`, change the
   subscribe topic, and register the route in `main.zig` via
   `app.routeStreaming(.get, "/<feature>/events", <feature>.handle, &hub_ctx)`.

## Last-Event-ID resume

`EventSource` automatically reconnects with a `Last-Event-ID: N`
header containing the highest event id it saw. The handler parses
this and passes it via `SubscribeOptions{ .last_event_id = N }`;
the bus then walks the topic's replay ring and delivers any events
with `id > N` before live publishes resume.

The replay ring is bounded (configured per topic at
`bus.registerTopic`). Reconnects within the ring's window catch up
cleanly; longer outages lose the in-window-but-evicted events.

## CORS

`ssehub.wire.writeHeaders` writes permissive CORS (`*` origin,
`GET, OPTIONS` methods, `*` headers). That's appropriate for native dev where the
browser hits the SSE service on a different port than the app.
Behind a same-origin reverse proxy in production, drop the wildcard
to a specific origin. Edit `ssehub/src/wire.zig` or write the
headers yourself before subscribing.

## Worked example

See `samples/pizzaqsr-hda-mono/sse/` for a complete consumer:

- `handlers/order_tracking.zig`: per-order topic `"order:<key>"`
- `handlers/kitchen.zig`: static topic `"kitchen"`
- `handlers/delivery.zig`: static topic `"delivery"`

Plus `hub.zig` showing the routing logic (decode header, update
in-memory mirror, fan out to per-order topic + dashboard topics +
delete terminal topics).
