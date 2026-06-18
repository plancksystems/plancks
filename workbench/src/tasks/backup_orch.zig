
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const planck = @import("planck");
const utils = @import("utils");

const services_mod = @import("services.zig");
const AppServices = services_mod.AppServices;
const ServiceKind = services_mod.ServiceKind;
const WbStorage = @import("storage.zig").WbStorage;

const log = std.log.scoped(.backup_orch);

pub const Result = struct {
    output_path: []const u8,
    bytes: u64,
    services_captured: u32,
};

pub const BackupKind = enum { manual, scheduled };

const QuiesceCtx = struct {
    services: *AppServices,
};

fn quiesceService(
    ctx_opaque: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    service_name: []const u8,
    output_dir: []const u8
) anyerror!void {
    const qctx: *QuiesceCtx = @ptrCast(@alignCast(ctx_opaque.?));

    const conn = try qctx.services.pool.acquire(service_name);
    defer qctx.services.pool.release(service_name, false);

    const reply_bson = try conn.client.adminBackup(output_dir);
    defer allocator.free(reply_bson);

    var doc = try planck.bson.BsonDocument.init(allocator, reply_bson, false);
    defer doc.deinit();
    const engine_path = (try doc.getString("backup_path")) orelse return error.NoBackupPathInReply;

    const target = try std.fmt.allocPrint(allocator, "{s}/data.planck", .{output_dir});
    defer allocator.free(target);
    try Dir.rename(.cwd(), engine_path, .cwd(), target, io);
}

pub fn backupApp(
    services: *AppServices,
    allocator: Allocator,
    app_name: []const u8,
    output_dir_in: []const u8,
    kind: BackupKind
) !Result {
    const storage = services.storage orelse return error.StorageUnavailable;

    const app_doc_opt = try storage.getApp(app_name);
    const app_doc = app_doc_opt orelse return error.AppNotFound;
    defer allocator.free(app_doc.value);

    var adoc = try planck.bson.BsonDocument.init(allocator, app_doc.value, false);
    defer adoc.deinit();

    const services_arr = (try adoc.getArray("services")) orelse return error.AppHasNoServices;
    const count = try services_arr.len();

    var qlist: std.ArrayList(utils.backup.ServiceQuiesce) = .empty;
    defer qlist.deinit(allocator);

    const qctx_box = try allocator.create(QuiesceCtx);
    defer allocator.destroy(qctx_box);
    qctx_box.* = .{ .services = services };

    var svc_name_dupes: std.ArrayList([]const u8) = .empty;
    defer {
        for (svc_name_dupes.items) |s| allocator.free(s);
        svc_name_dupes.deinit(allocator);
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const val = (try services_arr.get(i)) orelse continue;
        const svc_bytes = switch (val) {
            .document => |d| d.data,
            else => continue,
        };
        var sdoc = try planck.bson.BsonDocument.init(allocator, svc_bytes, false);
        defer sdoc.deinit();
        const name = (try sdoc.getString("name")) orelse continue;

        const svc_kind = ServiceKind.fromBsonStr((sdoc.getString("kind") catch null) orelse "") orelse .wasm;
        if (svc_kind != .wasm) {
            log.info("backupApp '{s}': skipping non-DB service '{s}' (kind={s})", .{ app_name, name, svc_kind.toBsonStr() });
            continue;
        }

        const name_dup = try allocator.dupe(u8, name);
        try svc_name_dupes.append(allocator, name_dup);
        try qlist.append(allocator, .{
            .name = name_dup,
            .ctx = qctx_box,
            .quiesce = quiesceService,
        });
    }

    const output_dir = if (output_dir_in.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir_in, app_name })
    else
        try std.fmt.allocPrint(allocator, "{s}/backups/{s}", .{ services.wb_config.data_dir, app_name });
    defer allocator.free(output_dir);

    try Dir.createDirPath(.cwd(), services.io, output_dir);

    const ts = (utils.Now{ .io = services.io }).toMilliSeconds();
    const out_path = try std.fmt.allocPrint(allocator, "{s}/backup_{d}.tar.gz", .{ output_dir, ts });
    errdefer allocator.free(out_path);

    const staging = try std.fmt.allocPrint(allocator, "{s}/.staging-{d}", .{ output_dir, ts });
    defer allocator.free(staging);

    const app_dir = try std.fmt.allocPrint(allocator, "{s}/apps/{s}", .{ services.wb_config.data_dir, app_name });
    defer allocator.free(app_dir);

    const orch_result = try utils.backup.createAppArchive(allocator, services.io, .{
        .app_dir = app_dir,
        .output_path = out_path,
        .format = .tar_gz,
        .services = qlist.items,
        .staging_dir = staging,
    });
    allocator.free(orch_result.output_path);

    writeBackupRecord(allocator, storage, app_name, out_path, kind, orch_result.bytes, ts, svc_name_dupes.items) catch |err| {
        log.warn("backupApp '{s}': sysbackups insert failed: {}", .{ app_name, err });
    };

    return .{
        .output_path = out_path,
        .bytes = orch_result.bytes,
        .services_captured = orch_result.services_captured,
    };
}

fn writeBackupRecord(
    allocator: Allocator,
    storage: *WbStorage,
    app: []const u8,
    backup_path: []const u8,
    kind: BackupKind,
    size_bytes: u64,
    created_at_ms: i64,
    service_names: []const []const u8
) !void {
    var doc = planck.bson.BsonDocument.empty(allocator);
    defer doc.deinit();
    try doc.putString("app", app);
    try doc.putString("backup_path", backup_path);
    try doc.putString("kind", switch (kind) {
        .manual => "manual",
        .scheduled => "scheduled",
    });
    try doc.putString("status", "ok");
    try doc.putString("format", "tar_gz");
    try doc.putInt64("size_bytes", @intCast(size_bytes));
    try doc.putInt64("created_at_ms", created_at_ms);

    var arr_buf: std.ArrayList(u8) = .empty;
    defer arr_buf.deinit(allocator);
    try arr_buf.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
    for (service_names, 0..) |n, idx| {
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch "0";
        try arr_buf.append(allocator, 0x02);
        try arr_buf.appendSlice(allocator, idx_str);
        try arr_buf.append(allocator, 0);
        const slen: i32 = @intCast(n.len + 1);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &len_bytes, slen, .little);
        try arr_buf.appendSlice(allocator, &len_bytes);
        try arr_buf.appendSlice(allocator, n);
        try arr_buf.append(allocator, 0);
    }
    try arr_buf.append(allocator, 0);
    const new_size: i32 = @intCast(arr_buf.items.len);
    @memcpy(arr_buf.items[0..4], std.mem.asBytes(&std.mem.nativeToLittle(i32, new_size)));
    const arr = planck.bson.BsonArray.init(allocator, arr_buf.items);
    try doc.putArray("services", arr);

    _ = try storage.put(WbStorage.STORE_BACKUPS, doc.toBytes());
    storage.flush();
}
