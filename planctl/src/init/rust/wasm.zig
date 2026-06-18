const std = @import("std");
const common = @import("../common.zig");
const writeFile = common.writeFile;

pub fn create(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const pkg_name = common.pkgName(name);
    const lang_name = "rust";
    var proj_dir = try common.createProjectDirs(allocator, io, name, .rust);
    defer proj_dir.close(io);

    {
        const content = try std.fmt.allocPrint(allocator,
            \\[package]
            \\name = "{s}"
            \\version = "0.1.0"
            \\edition = "2021"
            \\
            \\[lib]
            \\crate-type = ["cdylib"]
            \\
            \\[dependencies]
            \\schnell = {{ path = "../../schnell-rust" }}
            \\planck = {{ path = "../../planck-rust-client" }}
            \\serde = {{ version = "1", features = ["derive"] }}
            \\serde_json = "1"
            \\bson = "2"
            \\
        , .{pkg_name});
        defer allocator.free(content);
        try writeFile(proj_dir, io, "Cargo.toml", content);
    }

    {
        try writeFile(proj_dir, io, "src/main.rs",
            \\use schnell::*;
            \\use planck::WasmClient;
            \\
            \\mod domain;
            \\mod api;
            \\
            \\static mut APP: Option<WasmApp> = None;
            \\static mut CLIENT: Option<WasmClient> = None;
            \\
            \\#[no_mangle]
            \\pub extern "C" fn init() -> i32 {
            \\    let mut app = WasmApp::new();
            \\
            \\    app.route(Method::Get, "/items", api::find_all::handler);
            \\    app.route(Method::Post, "/items", api::create::handler);
            \\
            \\    app.on_response(|_req, res, buf| {
            \\        if let Ok(bytes) = res.to_bytes(buf) {
            \\            WasmApp::respond(bytes);
            \\        }
            \\    });
            \\
            \\    unsafe {
            \\        CLIENT = Some(WasmClient::new());
            \\        APP = Some(app);
            \\    }
            \\    0
            \\}
            \\
            \\#[no_mangle]
            \\pub extern "C" fn process(ptr: *const u8, len: u32) -> i32 {
            \\    unsafe {
            \\        APP.as_mut().map_or(-1, |app| app.process(ptr, len))
            \\    }
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/domain/mod.rs",
            \\pub mod item;
            \\pub use item::*;
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/domain/item.rs",
            \\use serde::{Deserialize, Serialize};
            \\
            \\#[derive(Debug, Clone, Serialize, Deserialize, Default)]
            \\pub struct Item {
            \\    #[serde(default)]
            \\    pub id: String,
            \\    #[serde(default)]
            \\    pub name: String,
            \\    #[serde(default)]
            \\    pub price: f64,
            \\    #[serde(default = "default_active")]
            \\    pub active: bool,
            \\}
            \\
            \\fn default_active() -> bool { true }
            \\
            \\#[derive(Debug, Deserialize, Default)]
            \\pub struct ItemParams {
            \\    pub id: Option<String>,
            \\}
            \\
            \\#[derive(Debug, Deserialize)]
            \\pub struct CreateItemBody {
            \\    pub name: String,
            \\    pub price: f64,
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/api/mod.rs",
            \\pub mod find_all;
            \\pub mod create;
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/api/find_all.rs",
            \\use schnell::*;
            \\
            \\pub fn handler(req: &Request) -> Result<Response, String> {
            \\    // TODO: Use planck WasmClient to query items
            \\    let mut res = Response::new();
            \\    res.html("<div><h1>Items</h1><p>TODO: implement</p></div>");
            \\    Ok(res)
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/api/create.rs",
            \\use schnell::*;
            \\
            \\pub fn handler(req: &Request) -> Result<Response, String> {
            \\    // TODO: Use planck WasmClient to create item
            \\    let mut res = Response::new();
            \\    res.html("<span>Item created</span>");
            \\    Ok(res)
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/rsx/item_list.rsx",
            \\use schnell::*;
            \\use crate::domain::Item;
            \\
            \\pub struct ItemList {
            \\    pub items: Vec<Item>,
            \\}
            \\
            \\impl ItemList {
            \\    pub fn render(&self, h: &mut String) {
            \\        return (
            \\            <div class="page">
            \\                <h1>Items</h1>
            \\                <table class="striped">
            \\                    <thead>
            \\                        <tr>
            \\                            <th>ID</th>
            \\                            <th>Name</th>
            \\                            <th>Price</th>
            \\                        </tr>
            \\                    </thead>
            \\                    <tbody>
            \\                        {for item in self.items}
            \\                            <tr>
            \\                                <td>{item.id}</td>
            \\                                <td>{item.name}</td>
            \\                                <td>{item.price}</td>
            \\                            </tr>
            \\                        {/for}
            \\                    </tbody>
            \\                </table>
            \\            </div>
            \\        );
            \\    }
            \\}
            \\
        );
    }

    try common.writeServiceManifest(allocator, proj_dir, io, pkg_name);

    std.debug.print(
        \\
        \\Created project: {s} (lang: {s})
        \\
        \\  {s}/
        \\    db.yaml                      <- planck/db storage tuning
        \\    service.yaml                 <- identity + WASM hosting + upstreams
        \\    Cargo.toml
        \\    src/
        \\      main.rs                    <- WASM entry point (WasmApp + routes)
        \\      domain/
        \\        mod.rs
        \\        item.rs                  <- Item struct + serde derives
        \\      api/
        \\        mod.rs
        \\        find_all.rs              <- GET /items handler
        \\        create.rs                <- POST /items handler
        \\      rsx/                       <- .rsx templates (hand-edit these)
        \\        item_list.rsx
        \\      ui/                        <- auto-generated from rsx/ (do not edit)
        \\    public/
        \\      index.html                 <- dev landing page (HTMX + Tailwind)
        \\
        \\Build:
        \\  cd {s}
        \\  cargo build --target wasm32-unknown-unknown --release
        \\
    , .{ name, lang_name, name, name });
    std.debug.print("planctl: created Rust WASM project \"{s}\"\n", .{pkg_name});
}
