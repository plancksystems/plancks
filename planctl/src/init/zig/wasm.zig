const std = @import("std");
const common = @import("../common.zig");
const writeFile = common.writeFile;

pub fn create(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const pkg_name = common.pkgName(name);
    const lang_name = "zig";
    var proj_dir = try common.createProjectDirs(allocator, io, name, .zig);
    defer proj_dir.close(io);

    {
        const content = try std.fmt.allocPrint(allocator,
            \\.{{
            \\    .name = .{s},
            \\    .version = "0.1.0",
            \\    .fingerprint = 0x0000000000000000,
            \\    .dependencies = .{{
            \\       .planck_zig_client = .{{
            \\          .url = "https://github.com/plancksystems/planck-zig-client/archive/refs/tags/v0.1.0.tar.gz",
            \\          .hash = "planck_zig_client-0.1.0-Xx6aRIzHAgB7jkrPk3aecFBIclAfv3152H3skppHZ_kV",
            \\        }},
            \\      .bson = .{{
            \\          .url = "https://github.com/plancksystems/bson/archive/refs/tags/v0.1.0.tar.gz",
            \\          .hash = "bson-0.1.0-QwoLYQNWAQD7PNOL2uyJacKGneUmsih-_8PrvAT3Mskz",
            \\        }},
            \\      .tls = .{{
            \\          .url = "https://github.com/plancksystems/tls/archive/refs/tags/v0.1.0.tar.gz",
            \\          .hash = "tls-0.1.0-ER2e0ruABQA_nKN96K_-p9LfNkb9fCYybiNXmHLfQqGw",
            \\        }},
            \\      .proto = .{{
            \\          .url = "https://github.com/plancksystems/proto/archive/refs/tags/v0.1.0.tar.gz",
            \\          .hash = "proto-0.1.0-nDgOj_b1AAC36uLbcXHmjyWT7rYW7tFBMM1WzJl78YEz",
            \\        }},
            \\      .utils = .{{
            \\          .url = "https://github.com/plancksystems/utils/archive/refs/tags/v0.1.0.tar.gz",
            \\          .hash = "utils-0.1.0-Ldej_iawAQCEgGJ9UuYGcgBIRe0LZv8lGbV-YA8b6mSv",
            \\        }},
            \\      .schnell = .{{
            \\          .url = "https://github.com/plancksystems/schnell/archive/refs/tags/v0.1.0.tar.gz",
            \\          .hash = "schnell-0.1.0-qlxSCpedBgCm_KfPDKoG1coC0FImc_GupGaiZQ87swfH",
            \\        }},
            \\    }},
            \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
            \\}}
            \\
        , .{pkg_name});
        defer allocator.free(content);
        try writeFile(proj_dir, io, "build.zig.zon", content);
    }

    {
        const content = try std.fmt.allocPrint(allocator,
            \\ const std = @import("std");
            \\
            \\ pub fn build(b: *std.Build) void {{
            \\     const target = b.standardTargetOptions(.{{}});
            \\     const optimize = b.standardOptimizeOption(.{{}});
            \\
            \\     const deps = wireDeps(b, target, optimize);
            \\
            \\     // Preprocess .zsx → .zig
            \\     const clean_ui = b.addSystemCommand(&.{{ "planctl", "clean", "src/ui/" }});
            \\     const preprocess_ui = b.addSystemCommand(&.{{ "planctl", "src/zsx/", "src/ui/" }});
            \\     preprocess_ui.step.dependOn(&clean_ui.step);
            \\
            \\     // WASM Module
            \\     const wasm_target = b.resolveTargetQuery(.{{
            \\         .cpu_arch = .wasm32,
            \\         .os_tag = .freestanding,
            \\     }});
            \\
            \\     const wasm = b.addExecutable(.{{
            \\         .name = "{s}",
            \\         .root_module = b.createModule(.{{
            \\             .root_source_file = b.path("src/app.zig"),
            \\             .target = wasm_target,
            \\             .optimize = .ReleaseSmall,
            \\             .imports = &.{{
            \\                 .{{ .name = "web", .module = deps.web }},
            \\                 .{{ .name = "planck", .module = deps.planck_zig_client }},
            \\             }},
            \\         }}),
            \\     }});
            \\     wasm.entry = .disabled;
            \\     wasm.rdynamic = true;
            \\     wasm.step.dependOn(&preprocess_ui.step);
            \\     const wasm_install = b.addInstallArtifact(wasm, .{{
            \\         .dest_dir = .{{ .override = .{{ .custom = "wasm" }} }},
            \\     }});
            \\
            \\     // Dev Server (Native + schnell HTTP)
            \\     const dev_exe = b.addExecutable(.{{
            \\         .name = "{s}-dev",
            \\         .root_module = b.createModule(.{{
            \\             .root_source_file = b.path("src/dev.zig"),
            \\             .target = target,
            \\             .optimize = optimize,
            \\             .imports = &.{{
            \\                 .{{ .name = "web", .module = deps.web }},
            \\                 .{{ .name = "schnell", .module = deps.schnell }},
            \\                 .{{ .name = "planck", .module = deps.planck_zig_client }},
            \\             }},
            \\         }}),
            \\     }});
            \\     dev_exe.step.dependOn(&preprocess_ui.step);
            \\     b.installArtifact(dev_exe);
            \\
            \\     const run_dev = b.addRunArtifact(dev_exe);
            \\     run_dev.step.dependOn(b.getInstallStep());
            \\
            \\     // Tests
            \\     const domain_mod = b.createModule(.{{
            \\         .root_source_file = b.path("src/domain/item.zig"),
            \\         .target = target,
            \\         .optimize = optimize,
            \\         .imports = &.{{
            \\             .{{ .name = "web", .module = deps.web }},
            \\         }},
            \\     }});
            \\     const test_domain = b.addTest(.{{
            \\         .root_module = b.createModule(.{{
            \\             .root_source_file = b.path("tests/domain_test.zig"),
            \\             .target = target,
            \\             .optimize = optimize,
            \\             .imports = &.{{
            \\                 .{{ .name = "domain", .module = domain_mod }},
            \\             }},
            \\         }}),
            \\     }});
            \\     const test_schema = b.addTest(.{{
            \\         .root_module = b.createModule(.{{
            \\             .root_source_file = b.path("tests/schema_test.zig"),
            \\             .target = target,
            \\             .optimize = optimize,
            \\             .imports = &.{{
            \\                 .{{ .name = "domain", .module = domain_mod }},
            \\                 .{{ .name = "web", .module = deps.web }},
            \\             }},
            \\         }}),
            \\     }});
            \\     const test_step = b.step("test", "Run unit tests");
            \\     test_step.dependOn(&b.addRunArtifact(test_domain).step);
            \\     test_step.dependOn(&b.addRunArtifact(test_schema).step);
            \\
            \\     b.step("wasm", "Build WASM Module").dependOn(&wasm_install.step);
            \\     b.step("dev", "Run dev server (Native + HTTP)").dependOn(&run_dev.step);
            \\     const preprocess_step = b.step("preprocess", "Preprocess only");
            \\     preprocess_step.dependOn(&preprocess_ui.step);
            \\     b.default_step = &wasm_install.step;
            \\ }}
            \\
            \\ const Deps = struct {{
            \\     bson: *std.Build.Module,
            \\     utils: *std.Build.Module,
            \\     tls: *std.Build.Module,
            \\     proto: *std.Build.Module,
            \\     planck_zig_client: *std.Build.Module,
            \\     schnell: *std.Build.Module,
            \\     web: *std.Build.Module,
            \\ }};
            \\
            \\ fn wireDeps(b: *std.Build, target: anytype, optimize: anytype) Deps {{
            \\
            \\     const bson_dep = b.dependency("bson", .{{}});
            \\     const bson = b.createModule(.{{
            \\         .root_source_file = bson_dep.path("src/root.zig"),
            \\         .target = target,
            \\         .optimize = optimize,
            \\     }});
            \\
            \\     const utils_dep = b.dependency("utils", .{{}});
            \\     const utils = b.createModule(.{{
            \\         .root_source_file = utils_dep.path("src/root.zig"),
            \\         .target = target,
            \\         .optimize = optimize,
            \\     }});
            \\
            \\     const tls_dep = b.dependency("tls", .{{}});
            \\     const tls = b.createModule(.{{
            \\         .root_source_file = tls_dep.path("src/root.zig"),
            \\         .target = target,
            \\         .optimize = optimize,
            \\     }});
            \\
            \\     const proto_dep = b.dependency("proto", .{{}});
            \\     const proto = b.createModule(.{{
            \\         .root_source_file = proto_dep.path("src/root.zig"),
            \\         .target = target,
            \\         .optimize = optimize,
            \\     }});
            \\     proto.addImport("utils", utils);
            \\
            \\     const planck_dep = b.dependency("planck_zig_client", .{{}});
            \\     const planck_zig_client = b.createModule(.{{
            \\         .root_source_file = planck_dep.path("src/root.zig"),
            \\         .target = target,
            \\         .optimize = optimize,
            \\     }});
            \\     planck_zig_client.addImport("tls", tls);
            \\     planck_zig_client.addImport("bson", bson);
            \\     planck_zig_client.addImport("utils", utils);
            \\     planck_zig_client.addImport("proto", proto);
            \\
            \\     const schnell_dep = b.dependency("schnell", .{{}});
            \\     const schnell = b.createModule(.{{
            \\         .root_source_file = schnell_dep.path("src/root.zig"),
            \\         .target = target,
            \\         .optimize = optimize,
            \\     }});
            \\     schnell.addImport("bson", bson);
            \\     schnell.addImport("utils", utils);
            \\     schnell.addImport("tls", tls);
            \\     schnell.addImport("proto", proto);
            \\     schnell.addImport("planck_zig_client", planck_zig_client);
            \\
            \\     const web = b.createModule(.{{
            \\         .root_source_file = schnell_dep.path("src/web/root.zig"),
            \\         .target = target,
            \\         .optimize = optimize,
            \\     }});
            \\     web.addImport("bson", bson);
            \\     web.addImport("schnell", schnell);
            \\
            \\     return .{{
            \\         .bson = bson,
            \\         .utils = utils,
            \\         .tls = tls,
            \\         .proto = proto,
            \\         .planck_zig_client = planck_zig_client,
            \\         .schnell = schnell,
            \\         .web = web,
            \\     }};
            \\ }}
            \\
        , .{ pkg_name, pkg_name });
        defer allocator.free(content);
        try writeFile(proj_dir, io, "build.zig", content);
    }

    {
        try writeFile(proj_dir, io, "src/domain/item.zig",
            \\const web = @import("web");
            \\const Schema = web.Schema;
            \\
            \\ // Domain entity - user-defined struct with business logic.
            \\pub const Item = struct {
            \\    id: []const u8 = "",
            \\    name: []const u8 = "",
            \\    price: f64 = 0,
            \\    active: bool = true,
            \\
            \\    pub fn isExpensive(self: Item) bool {
            \\        return self.price > 100;
            \\    }
            \\};
            \\
            \\ // Schema - validates Item before DB writes.
            \\pub const ItemSchema = Schema(&.{
            \\    .{ "name", .{ .field_type = .string, .required = true, .min_length = 1, .max_length = 100 } },
            \\    .{ "price", .{ .field_type = .double, .required = true, .min = 0 } },
            \\    .{ "active", .{ .field_type = .boolean } },
            \\});
            \\
            \\ // Query/path params deserialization target.
            \\pub const ItemParams = struct {
            \\    id: ?[]const u8 = null,
            \\    name: ?[]const u8 = null,
            \\};
            \\
            \\ // POST/PUT body deserialization target.
            \\pub const CreateItemBody = struct {
            \\    name: []const u8,
            \\    price: f64,
            \\};
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/api/find_all_items_handler.zig",
            \\const std = @import("std");
            \\const planck = @import("planck");
            \\const web = @import("web");
            \\const Item = @import("../domain/item.zig").Item;
            \\const ItemList = @import("../ui/item_list.zig").ItemList;
            \\
            \\pub const FindAllItemsHandler = struct {
            \\    client: *planck.Client,
            \\
            \\    pub fn handle(self: *FindAllItemsHandler, allocator: std.mem.Allocator, request: *anyopaque) ![]const u8 {
            \\        _ = request;
            \\        var q = planck.Query.initWithAllocator(self.client, allocator);
            \\        defer q.deinit();
            \\        var resp = q.store("items").limit(20).skip(0).run() catch |err| return err;
            \\        defer resp.deinit();
            \\        const items = resp.decode(allocator, Item) catch |err| return err;
            \\        defer {
            \\            for (items) |item| {
            \\                if (item.id.len > 0) allocator.free(item.id);
            \\                if (item.name.len > 0) allocator.free(item.name);
            \\            }
            \\            allocator.free(items);
            \\        }
            \\        var out: std.ArrayList(u8) = .empty;
            \\        try ItemList.render(.{ .items = items }, &out, allocator);
            \\        return out.items;
            \\    }
            \\};
            \\
        );
        try writeFile(proj_dir, io, "src/api/find_item_by_id_handler.zig",
            \\const std = @import("std");
            \\
            \\pub const FindItemByIdHandler = struct {
            \\    pub fn handle(self: *FindItemByIdHandler, allocator: std.mem.Allocator, request: *anyopaque) ![]const u8 {
            \\        _ = self;
            \\        _ = request;
            \\        return try allocator.dupe(u8, "<p>Item detail</p>");
            \\    }
            \\};
            \\
        );
        try writeFile(proj_dir, io, "src/api/create_item_handler.zig",
            \\const std = @import("std");
            \\const planck = @import("planck");
            \\const web = @import("web");
            \\const Item = @import("../domain/item.zig").Item;
            \\const CreateItemBody = @import("../domain/item.zig").CreateItemBody;
            \\
            \\pub const CreateItemHandler = struct {
            \\    client: *planck.Client,
            \\
            \\    pub fn handle(self: *CreateItemHandler, allocator: std.mem.Allocator, request: *anyopaque) ![]const u8 {
            \\        const body: *CreateItemBody = @ptrCast(@alignCast(request));
            \\        const item = Item{ .name = body.name, .price = body.price };
            \\        var qi = planck.Query.initWithAllocator(self.client, allocator);
            \\        defer qi.deinit();
            \\        var create_resp = try (try qi.store("items").create(item)).run();
            \\        defer create_resp.deinit();
            \\        return try allocator.dupe(u8, "<span>Item created</span>");
            \\    }
            \\};
            \\
        );
        try writeFile(proj_dir, io, "src/api/update_item_handler.zig",
            \\const std = @import("std");
            \\
            \\pub const UpdateItemHandler = struct {
            \\    pub fn handle(self: *UpdateItemHandler, allocator: std.mem.Allocator, request: *anyopaque) ![]const u8 {
            \\        _ = self;
            \\        _ = request;
            \\        return try allocator.dupe(u8, "<span>Updated</span>");
            \\    }
            \\};
            \\
        );
        try writeFile(proj_dir, io, "src/api/delete_item_handler.zig",
            \\const std = @import("std");
            \\
            \\pub const DeleteItemHandler = struct {
            \\    pub fn handle(self: *DeleteItemHandler, allocator: std.mem.Allocator, request: *anyopaque) ![]const u8 {
            \\        _ = self;
            \\        _ = request;
            \\        return try allocator.dupe(u8, "<span>Deleted</span>");
            \\    }
            \\};
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/zsx/item_list.zsx",
            \\const std = @import("std");
            \\const Item = @import("../domain/item.zig").Item;
            \\
            \\ // Render component - writes HTML directly to the writer.
            \\pub const ItemList = struct {
            \\    items: []const Item,
            \\
            \\    pub fn render(self: ItemList, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
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
            \\};
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/app.zig",
            \\const std = @import("std");
            \\const planck = @import("planck");
            \\const web = @import("web");
            \\
            \\const FindAllItemsHandler = @import("api/find_all_items_handler.zig").FindAllItemsHandler;
            \\const FindItemByIdHandler = @import("api/find_item_by_id_handler.zig").FindItemByIdHandler;
            \\const CreateItemHandler = @import("api/create_item_handler.zig").CreateItemHandler;
            \\const UpdateItemHandler = @import("api/update_item_handler.zig").UpdateItemHandler;
            \\const DeleteItemHandler = @import("api/delete_item_handler.zig").DeleteItemHandler;
            \\const ItemParams = @import("domain/item.zig").ItemParams;
            \\const CreateItemBody = @import("domain/item.zig").CreateItemBody;
            \\
            \\extern fn host_respond(ptr: [*]const u8, len: u32) void;
            \\extern fn host_sse_publish(event_ptr: [*]const u8, event_len: u32, data_ptr: [*]const u8, data_len: u32) void;
            \\
            \\var app: web.WasmApp = undefined;
            \\var client: planck.Client = undefined;
            \\
            \\var find_all: FindAllItemsHandler = undefined;
            \\var find_by_id: FindItemByIdHandler = undefined;
            \\var create: CreateItemHandler = undefined;
            \\var update: UpdateItemHandler = undefined;
            \\var del: DeleteItemHandler = undefined;
            \\
            \\export fn init(config_ptr: ?[*]const u8, config_len: u32) i32 {
            \\    const allocator = std.heap.wasm_allocator;
            \\
            \\    client = planck.Client.init(allocator, 8 * 1024) catch return -1;
            \\
            \\    find_all = .{ .client = &client };
            \\    find_by_id = .{};
            \\    create = .{ .client = &client };
            \\    update = .{};
            \\    del = .{};
            \\
            \\    const yaml_text = if (config_ptr) |ptr| ptr[0..config_len] else &.{};
            \\    app = web.WasmApp.init(allocator, .{}, yaml_text) catch return -1;
            \\
            \\    app.route(FindAllItemsHandler, ItemParams, null, .get, "/items", &find_all, null) catch return -1;
            \\    app.route(FindItemByIdHandler, ItemParams, null, .get, "/items/:id", &find_by_id, null) catch return -1;
            \\    app.route(CreateItemHandler, null, CreateItemBody, .post, "/items", &create, null) catch return -1;
            \\    app.route(UpdateItemHandler, null, CreateItemBody, .put, "/items/:id", &update, null) catch return -1;
            \\    app.route(DeleteItemHandler, ItemParams, null, .delete, "/items/:id", &del, null) catch return -1;
            \\
            \\    app.onResponse(struct {
            \\        fn hook(req: *const web.WasmRequest, res: *web.WasmResponse, resp_buf: []u8) void {
            \\            _ = req;
            \\            const bytes = res.toBytes(resp_buf) catch return;
            \\            host_respond(bytes.ptr, @intCast(bytes.len));
            \\        }
            \\    }.hook);
            \\
            \\    return 0;
            \\}
            \\
            \\export fn process(req_ptr: [*]const u8, req_len: u32) i32 {
            \\    app.process(req_ptr, req_len) catch return -1;
            \\    return 0;
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/dev.zig",
            \\const std = @import("std");
            \\const schnell = @import("schnell");
            \\const planck = @import("planck");
            \\
            \\const FindAllItemsHandler = @import("api/find_all_items_handler.zig").FindAllItemsHandler;
            \\const FindItemByIdHandler = @import("api/find_item_by_id_handler.zig").FindItemByIdHandler;
            \\const CreateItemHandler = @import("api/create_item_handler.zig").CreateItemHandler;
            \\const UpdateItemHandler = @import("api/update_item_handler.zig").UpdateItemHandler;
            \\const DeleteItemHandler = @import("api/delete_item_handler.zig").DeleteItemHandler;
            \\const ItemParams = @import("domain/item.zig").ItemParams;
            \\const CreateItemBody = @import("domain/item.zig").CreateItemBody;
            \\
            \\pub fn main() !void {
            \\    const allocator = std.heap.smp_allocator;
            \\
            \\    var threaded: std.Io.Threaded = .init(allocator, .{});
            \\    defer threaded.deinit();
            \\    const io = threaded.io();
            \\
            \\    \\ Connect to Planck
            \\    const client = try planck.Client.init(allocator, io);
            \\    var auth = try client.connect("127.0.0.1:24000;uid=admin;key=<key>;tls=false");
            \\    auth.deinit();
            \\    std.debug.print("Connected to Planck\n", .{});
            \\
            \\    \\ Handler instances
            \\    var find_all: FindAllItemsHandler = .{ .client = client };
            \\    var find_by_id: FindItemByIdHandler = .{};
            \\    var create: CreateItemHandler = .{ .client = client };
            \\    var update: UpdateItemHandler = .{};
            \\    var del: DeleteItemHandler = .{};
            \\
            \\    \\ App - encapsulates server, router, mediator, middleware, rendering
            \\    var app = try schnell.App.init(allocator, .{
            \\        .ip = .{ 127, 0, 0, 1 },
            \\        .port = 3000,
            \\        .static_dir = "public",
            \\    });
            \\    defer app.deinit();
            \\
            \\    \\ Routes
            \\    try app.route(FindAllItemsHandler, ItemParams, null, .get, "/items", &find_all, null);
            \\    try app.route(FindItemByIdHandler, ItemParams, null, .get, "/items/:id", &find_by_id, null);
            \\    try app.route(CreateItemHandler, null, CreateItemBody, .post, "/items", &create, null);
            \\    try app.route(UpdateItemHandler, null, CreateItemBody, .put, "/items/:id", &update, null);
            \\    try app.route(DeleteItemHandler, ItemParams, null, .delete, "/items/:id", &del, null);
            \\
            \\    std.debug.print("Dev server running on http:\\127.0.0.1:3000\n", .{});
            \\    try app.run(io);
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "tests/domain_test.zig",
            \\const std = @import("std");
            \\const domain = @import("domain");
            \\const Item = domain.Item;
            \\
            \\test "Item default values" {
            \\    const item = Item{};
            \\    try std.testing.expectEqualStrings("", item.id);
            \\    try std.testing.expectEqualStrings("", item.name);
            \\    try std.testing.expectEqual(@as(f64, 0), item.price);
            \\    try std.testing.expect(item.active);
            \\}
            \\
            \\test "Item.isExpensive" {
            \\    const cheap = Item{ .price = 50 };
            \\    const expensive = Item{ .price = 150 };
            \\    try std.testing.expect(!cheap.isExpensive());
            \\    try std.testing.expect(expensive.isExpensive());
            \\}
            \\
        );
        try writeFile(proj_dir, io, "tests/schema_test.zig",
            \\const std = @import("std");
            \\const domain = @import("domain");
            \\const Item = domain.Item;
            \\const ItemSchema = domain.ItemSchema;
            \\
            \\test "schema validates valid item" {
            \\    const item = Item{ .name = "Widget", .price = 9.99 };
            \\    const err = try ItemSchema.validate(std.testing.allocator, item);
            \\    try std.testing.expect(err == null);
            \\}
            \\
            \\test "schema rejects empty name" {
            \\    const item = Item{ .name = "", .price = 9.99 };
            \\    if (try ItemSchema.validate(std.testing.allocator, item)) |*verr| {
            \\        var ve = verr.*;
            \\        defer ve.deinit();
            \\        try std.testing.expect(ve.errors.len > 0);
            \\    } else {
            \\        return error.ExpectedValidationError;
            \\    }
            \\}
            \\
            \\test "schema rejects negative price" {
            \\    const item = Item{ .name = "Widget", .price = -5 };
            \\    if (try ItemSchema.validate(std.testing.allocator, item)) |*verr| {
            \\        var ve = verr.*;
            \\        defer ve.deinit();
            \\        try std.testing.expect(ve.errors.len > 0);
            \\    } else {
            \\        return error.ExpectedValidationError;
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
        \\    build.zig
        \\    build.zig.zon
        \\    src/
        \\      app.zig                    <- WASM entry point (WasmApp + routes)
        \\      dev.zig                    <- native dev server (schnell.App + routes)
        \\      domain/                    <- entities + schemas + param/body types
        \\        item.zig
        \\      api/                       <- request handlers (one per use case)
        \\        find_all_items_handler.zig
        \\        find_item_by_id_handler.zig
        \\        create_item_handler.zig
        \\        update_item_handler.zig
        \\        delete_item_handler.zig
        \\      zsx/                      <- .zsx templates (hand-edit these)
        \\        item_list.zsx
        \\      ui/                        <- auto-generated from zsx/ (do not edit)
        \\    public/
        \\      index.html                 <- dev landing page (HTMX + Tailwind)
        \\    tests/
        \\      domain_test.zig
        \\      schema_test.zig
        \\
        \\Develop:
        \\  cd {s}
        \\  PLANCK_CONN="host:port;uid=admin;key=<key>" zig build dev
        \\  zig build test
        \\
        \\Deploy:
        \\  zig build wasm               <- produces zig-out/wasm/{s}.wasm
        \\
    , .{ name, lang_name, name, name, pkg_name });
    std.debug.print("planctl: created Zig WASM project \"{s}\"\n", .{pkg_name});
}
