const std = @import("std");
const common = @import("../common.zig");
const writeFile = common.writeFile;

pub fn create(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const pkg_name = common.pkgName(name);
    const lang_name = "go";
    var proj_dir = try common.createProjectDirs(allocator, io, name, .go);
    defer proj_dir.close(io);

    {
        const content = try std.fmt.allocPrint(allocator,
            \\module {s}
            \\
            \\go 1.21
            \\
            \\require (
            \\    github.com/planck/schnell-go v0.0.0
            \\    github.com/planck/planck-go-client v0.0.0
            \\)
            \\
            \\replace (
            \\    github.com/planck/schnell-go => ../../schnell-go
            \\    github.com/planck/planck-go-client => ../../planck-go-client
            \\)
            \\
        , .{pkg_name});
        defer allocator.free(content);
        try writeFile(proj_dir, io, "go.mod", content);
    }

    {
        try writeFile(proj_dir, io, "main.go",
            \\package main
            \\
            \\import (
            \\    "unsafe"
            \\    schnell "github.com/planck/schnell-go"
            \\    planck "github.com/planck/planck-go-client"
            \\    "api"
            \\)
            \\
            \\var app *schnell.WasmApp
            \\var client *planck.WasmClient
            \\
            \\//export init
            \\func init_app() int32 {
            \\    client = planck.NewWasmClient()
            \\    app = schnell.NewApp()
            \\
            \\    app.Route(schnell.GET, "/items", api.FindAll)
            \\    app.Route(schnell.POST, "/items", api.Create)
            \\
            \\    app.OnResponse(func(req *schnell.Request, res *schnell.Response, buf []byte) {
            \\        n, _ := res.ToBytes(buf)
            \\        schnell.Respond(buf[:n])
            \\    })
            \\
            \\    return 0
            \\}
            \\
            \\//export process
            \\func process_request(ptr uintptr, len uint32) int32 {
            \\    return app.Process(ptr, len)
            \\}
            \\
            \\func main() {}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/domain/item.go",
            \\package domain
            \\
            \\type Item struct {
            \\    ID     string  `json:"id"`
            \\    Name   string  `json:"name"`
            \\    Price  float64 `json:"price"`
            \\    Active bool    `json:"active"`
            \\}
            \\
            \\type ItemParams struct {
            \\    ID string `json:"id"`
            \\}
            \\
            \\type CreateItemBody struct {
            \\    Name  string  `json:"name"`
            \\    Price float64 `json:"price"`
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/api/find_all.go",
            \\package api
            \\
            \\import schnell "github.com/planck/schnell-go"
            \\
            \\func FindAll(req *schnell.Request) (*schnell.Response, error) {
            \\    res := schnell.NewResponse()
            \\    res.HTML("<div><h1>Items</h1><p>TODO: implement</p></div>")
            \\    return res, nil
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/api/create.go",
            \\package api
            \\
            \\import schnell "github.com/planck/schnell-go"
            \\
            \\func Create(req *schnell.Request) (*schnell.Response, error) {
            \\    res := schnell.NewResponse()
            \\    res.HTML("<span>Item created</span>")
            \\    return res, nil
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/gsx/item_list.gsx",
            \\package ui
            \\
            \\import "domain"
            \\
            \\type ItemList struct {
            \\    Items []domain.Item
            \\}
            \\
            \\func (il *ItemList) Render(b *strings.Builder) {
            \\    return (
            \\        <div class="page">
            \\            <h1>Items</h1>
            \\            <table class="striped">
            \\                <thead>
            \\                    <tr>
            \\                        <th>ID</th>
            \\                        <th>Name</th>
            \\                        <th>Price</th>
            \\                    </tr>
            \\                </thead>
            \\                <tbody>
            \\                    {for item in il.Items}
            \\                        <tr>
            \\                            <td>{item.ID}</td>
            \\                            <td>{item.Name}</td>
            \\                            <td>{item.Price}</td>
            \\                        </tr>
            \\                    {/for}
            \\                </tbody>
            \\            </table>
            \\        </div>
            \\    )
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "public/index.html",
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\    <meta charset="UTF-8" />
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            \\    <title>planck dev</title>
            \\    <script src="https://cdn.tailwindcss.com"></script>
            \\    <script src="https://unpkg.com/htmx.org@2.0.4"></script>
            \\</head>
            \\<body class="bg-gray-950 text-gray-100 min-h-screen">
            \\    <nav class="bg-gray-900 border-b border-gray-800 px-6 py-3 flex items-center justify-between">
            \\        <h1 class="text-lg font-semibold text-white">zxt <span class="text-gray-500 font-normal text-sm">dev</span></h1>
            \\        <span class="text-xs text-gray-500">http://127.0.0.1:3000</span>
            \\    </nav>
            \\    <main class="max-w-4xl mx-auto p-6">
            \\        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 mb-4">
            \\            <h2 class="text-xl font-semibold mb-2">Welcome to Planck</h2>
            \\            <p class="text-gray-400 mb-4">Your dev server is running. Edit .zsx components, rebuild, and refresh.</p>
            \\            <div class="flex gap-3">
            \\                <button hx-get="/items" hx-target="#content" hx-swap="innerHTML"
            \\                    class="bg-blue-600 hover:bg-blue-500 text-white text-sm px-4 py-2 rounded transition">
            \\                    Load Items
            \\                </button>
            \\            </div>
            \\        </div>
            \\        <div id="content" class="bg-gray-900 rounded-lg border border-gray-800 p-4 min-h-[4rem]"></div>
            \\    </main>
            \\</body>
            \\</html>
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/ui/.gitkeep", "");
    }

    try common.writeServiceManifest(allocator, proj_dir, io, pkg_name);

    std.debug.print(
        \\
        \\Created project: {s} (lang: {s})
        \\
        \\  {s}/
        \\    db.yaml                      <- planck/db storage tuning
        \\    service.yaml                 <- identity + WASM hosting + upstreams
        \\    go.mod
        \\    main.go                      <- WASM entry point (WasmApp + routes)
        \\    src/
        \\      domain/
        \\        item.go                  <- Item struct + JSON tags
        \\      api/
        \\        find_all.go              <- GET /items handler
        \\        create.go                <- POST /items handler
        \\      gsx/                       <- .gsx templates (hand-edit these)
        \\        item_list.gsx
        \\      ui/                        <- auto-generated from gsx/ (do not edit)
        \\    public/
        \\      index.html                 <- dev landing page (HTMX + Tailwind)
        \\
        \\Build:
        \\  cd {s}
        \\  GOOS=wasip1 GOARCH=wasm go build -o {s}.wasm
        \\
    , .{ name, lang_name, name, name, pkg_name });
    std.debug.print("planctl: created Go WASM project \"{s}\"\n", .{pkg_name});
}
