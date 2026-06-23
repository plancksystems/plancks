const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const planck = @import("planck");
const PlacnkClient = planck.Client;
const Query = planck.Query;
const proto = planck.proto;

const log = std.log.scoped(.wb_storage);

pub const WbStorage = struct {
    pub const STORE_SCHEDULES: u16 = 2;
    pub const STORE_STATS: u16 = 3;
    pub const STORE_APPS: u16 = 4;
    pub const STORE_BACKUPS: u16 = 5;

    allocator: Allocator,
    io: Io,
    slots: [POOL_SIZE]ClientSlot,

    pub const POOL_SIZE: usize = 4;

    pub const ClientSlot = struct {
        client: *PlacnkClient,
        mutex: Io.Mutex,
    };

    pub fn init(allocator: Allocator, io: Io, conn_str: []const u8) !*WbStorage {
        const self = try allocator.create(WbStorage);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.io = io;

        var initialized: usize = 0;
        errdefer {
            for (self.slots[0..initialized]) |*slot| {
                slot.client.disconnect();
                slot.client.deinit();
            }
        }
        for (&self.slots) |*slot| {
            slot.client = try PlacnkClient.init(allocator, io);
            slot.mutex = Io.Mutex.init;
            var auth = try slot.client.connect(conn_str);
            auth.deinit();
            initialized += 1;
        }

        self.ensureStores();

        log.info("wb storage connected to system db ({d} slots)", .{POOL_SIZE});
        return self;
    }

    fn ensureConnected(self: *WbStorage) void {
        for (&self.slots, 0..) |*slot, i| {
            if (!slot.client.isConnected()) {
                log.warn("system DB slot {d} connection lost, attempting reconnect", .{i});
                slot.client.reconnect() catch |err| {
                    log.err("system DB slot {d} reconnect failed: {}", .{ i, err });
                    continue;
                };
                log.info("system DB slot {d} reconnected", .{i});
            }
        }
    }

    fn ensureStores(self: *WbStorage) void {
        const client = self.slots[0].client;
        inline for (.{
            .{ "sysschedules", "Scheduled tasks" },
            .{ "sysstats", "Service stats snapshots" },
            .{ "sysapps", "Registered apps with services" },
            .{ "sysbackups", "Centralized backup records" },
        }) |entry| {
            client.create(proto.Store{
                .id = 0,
                .store_id = 0,
                .ns = entry[0],
                .description = entry[1],
            }) catch {};
        }
    }

    pub fn deinit(self: *WbStorage) void {
        log.warn("WbStorage.deinit - closing {d} system DB connections", .{POOL_SIZE});
        for (&self.slots) |*slot| {
            slot.client.disconnect();
            slot.client.deinit();
        }
        self.allocator.destroy(self);
    }

    fn acquireSlot(self: *WbStorage) *ClientSlot {
        for (&self.slots) |*slot| {
            if (slot.mutex.tryLock()) return slot;
        }
        self.slots[0].mutex.lockUncancelable(self.io);
        return &self.slots[0];
    }

    fn releaseSlot(self: *WbStorage, slot: *ClientSlot) void {
        slot.mutex.unlock(self.io);
    }


    pub fn flush(self: *WbStorage) void {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        slot.client.flush() catch |err| {
            log.warn("flush failed: {}", .{err});
        };
    }


    pub fn put(self: *WbStorage, store_id: u16, value: []const u8) !u128 {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        const ns = storeNs(store_id);

        const data = try slot.client.adminPutService(ns, value);
        if (data) |d| {
            defer self.allocator.free(d);
            return parseKeyFromJson(d) orelse 0;
        }
        return 0;
    }

    pub fn saveStats(self: *WbStorage, store_id: u16, value: []const u8) !void {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        const ns = storeNs(store_id);
        try slot.client.adminSaveStats(ns, value);
    }

    fn parseKeyFromJson(data: []const u8) ?u128 {
        const prefix = "\"key\":\"";
        const start = std.mem.indexOf(u8, data, prefix) orelse return null;
        const hex_start = start + prefix.len;
        const hex_end = std.mem.indexOfScalarPos(u8, data, hex_start, '"') orelse return null;
        const hex_str = data[hex_start..hex_end];
        return std.fmt.parseInt(u128, hex_str, 16) catch null;
    }


    pub fn get(self: *WbStorage, store_id: u16, key: u128) !?[]const u8 {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        const ns = storeNs(store_id);

        const packet = slot.client.doOperation(.{
            .Read = .{
                .store_ns = ns,
                .key = key,
            },
        }) catch return null;
        defer proto.Packet.free(self.allocator, packet);

        switch (packet.op) {
            .Reply => |reply| {
                if (reply.status != .ok or reply.data == null) return null;
                return try self.allocator.dupe(u8, reply.data.?);
            },
            else => return null,
        }
    }


    pub fn update(self: *WbStorage, store_id: u16, key: u128, value: []const u8) !void {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        const ns = storeNs(store_id);

        const packet = try slot.client.doOperation(.{
            .Update = .{
                .store_ns = ns,
                .key = key,
                .payload = value,
            },
        });
        defer proto.Packet.free(self.allocator, packet);

        switch (packet.op) {
            .Reply => |reply| {
                if (reply.status != .ok) {
                    log.err("update failed: {s}", .{if (reply.data) |d| d else "unknown"});
                    return error.StorageUpdateFailed;
                }
            },
            else => return error.InvalidResponse,
        }
    }


    pub fn delete(self: *WbStorage, store_id: u16, key: u128) !void {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        var q = Query.initWithAllocator(slot.client, self.allocator);
        defer q.deinit();
        _ = q.store(storeNs(store_id)).deleteByKey(key);
        var resp = try q.run();
        defer resp.deinit();
    }


    pub fn list(self: *WbStorage, store_id: u16) ![]Document {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        var q = Query.init(slot.client);
        defer q.deinit();

        var result = try q.store(storeNs(store_id))
            .limit(10000)
            .run();
        defer result.deinit();

        if (!result.success or result.data == null) return &.{};
        return try parseDocArray(self.allocator, result.data.?);
    }

    pub fn freeDocuments(self: *WbStorage, docs: []Document) void {
        for (docs) |doc| {
            self.allocator.free(doc.value);
        }
        self.allocator.free(docs);
    }


    pub fn putApp(
        self: *WbStorage,
        name: []const u8,
        description: []const u8,
        path: []const u8,
        kind: []const u8
    ) !u128 {
        const bson = planck.bson;
        var doc = bson.BsonDocument.empty(self.allocator);
        defer doc.deinit();

        try doc.putString("name", name);
        try doc.putString("description", description);
        try doc.putString("path", path);
        try doc.putString("kind", if (kind.len > 0) kind else "shell");
        try doc.putString("status", "running");
        const Now = planck.utils.Now;
        try doc.putInt64("created_at", (Now{ .io = self.io }).toMilliSeconds());
        const empty_array = bson.BsonArray.init(self.allocator, &[_]u8{ 5, 0, 0, 0, 0 });
        try doc.putArray("services", empty_array);

        const key = try self.put(STORE_APPS, doc.toBytes());
        self.flush();
        return key;
    }

    pub fn addServiceToApp(self: *WbStorage, app_name: []const u8, service_bson: []const u8) !void {
        const bson = planck.bson;

        const found = try self.findByField(STORE_APPS, "name", app_name) orelse return error.AppNotFound;
        defer self.allocator.free(found.value);

        var doc = try bson.BsonDocument.init(self.allocator, found.value, false);

        const services_arr = (try doc.getArray("services")) orelse {
            const empty = bson.BsonArray.init(self.allocator, &[_]u8{ 5, 0, 0, 0, 0 });
            try doc.putArray("services", empty);
            return self.addServiceToApp(app_name, service_bson);
        };
        const count = try services_arr.len();

        // Rebuild the services array via the bson lib: existing elements + the new service.
        var arr_doc = bson.BsonDocument.empty(self.allocator);
        defer arr_doc.deinit();

        for (0..count) |i| {
            var val = (try services_arr.get(i)) orelse continue;
            defer val.deinit(self.allocator);
            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch "0";
            try arr_doc.put(idx_str, val);
        }
        {
            const svc_doc = try bson.BsonDocument.init(self.allocator, service_bson, false);
            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{count}) catch "0";
            try arr_doc.put(idx_str, .{ .document = svc_doc });
        }

        const field_names = try doc.getFieldNames(self.allocator);
        defer {
            for (field_names) |n| self.allocator.free(n);
            self.allocator.free(field_names);
        }

        var new_doc = bson.BsonDocument.empty(self.allocator);
        defer new_doc.deinit();

        for (field_names) |name| {
            if (std.mem.eql(u8, name, "services")) continue;
            if (try doc.getField(name)) |val| {
                var v = val;
                defer v.deinit(self.allocator);
                try new_doc.put(name, v);
            }
        }

        try new_doc.putArray("services", bson.BsonArray.init(self.allocator, arr_doc.toBytes()));

        self.delete(STORE_APPS, found.key) catch {};
        _ = try self.put(STORE_APPS, new_doc.toBytes());
        self.flush();
    }

    pub fn removeServiceFromApp(self: *WbStorage, app_name: []const u8, service_name: []const u8) !void {
        const bson = planck.bson;

        const found = try self.findByField(STORE_APPS, "name", app_name) orelse return;
        defer self.allocator.free(found.value);

        var doc = try bson.BsonDocument.init(self.allocator, found.value, false);

        const services_arr = (try doc.getArray("services")) orelse return;
        const count = try services_arr.len();
        if (count == 0) return;

        // Rebuild the services array via the bson lib, dropping the named service.
        var arr_doc = bson.BsonDocument.empty(self.allocator);
        defer arr_doc.deinit();

        var new_idx: usize = 0;
        for (0..count) |i| {
            var val = (try services_arr.get(i)) orelse continue;
            defer val.deinit(self.allocator);

            const svc_doc_data = switch (val) {
                .document => |d| d.data,
                else => continue,
            };

            const svc_doc = try bson.BsonDocument.init(self.allocator, svc_doc_data, false);
            if (svc_doc.getString("name") catch null) |name| {
                defer self.allocator.free(name);
                if (std.mem.eql(u8, name, service_name)) continue;
            }

            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{new_idx}) catch "0";
            try arr_doc.put(idx_str, val);
            new_idx += 1;
        }

        const field_names = try doc.getFieldNames(self.allocator);
        defer {
            for (field_names) |n| self.allocator.free(n);
            self.allocator.free(field_names);
        }

        var new_doc = bson.BsonDocument.empty(self.allocator);
        defer new_doc.deinit();

        for (field_names) |fname| {
            if (std.mem.eql(u8, fname, "services")) continue;
            if (try doc.getField(fname)) |val| {
                var v = val;
                defer v.deinit(self.allocator);
                try new_doc.put(fname, v);
            }
        }

        try new_doc.putArray("services", bson.BsonArray.init(self.allocator, arr_doc.toBytes()));

        self.delete(STORE_APPS, found.key) catch {};
        _ = try self.put(STORE_APPS, new_doc.toBytes());
        self.flush();
    }

    pub fn listApps(self: *WbStorage) ![]Document {
        return self.list(STORE_APPS);
    }

    pub fn deleteApp(self: *WbStorage, name: []const u8) !void {
        if (try self.findByField(STORE_APPS, "name", name)) |found| {
            defer self.allocator.free(found.value);
            self.delete(STORE_APPS, found.key) catch {};
            self.flush();
        }
    }

    pub fn getApp(self: *WbStorage, name: []const u8) !?Document {
        return self.findByField(STORE_APPS, "name", name);
    }


    pub fn listByField(self: *WbStorage, store_id: u16, field_name: []const u8, field_value: []const u8) ![]Document {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        var q = Query.init(slot.client);
        defer q.deinit();

        var result = try q.store(storeNs(store_id))
            .where(field_name, .eq, .{ .string = field_value })
            .limit(10000)
            .run();
        defer result.deinit();

        if (!result.success or result.data == null) return &.{};
        return try parseDocArray(self.allocator, result.data.?);
    }


    pub fn findByField(self: *WbStorage, store_id: u16, field_name: []const u8, field_value: []const u8) !?Document {
        const slot = self.acquireSlot();
        defer self.releaseSlot(slot);

        var q = Query.init(slot.client);
        defer q.deinit();

        var result = try q.store(storeNs(store_id))
            .where(field_name, .eq, .{ .string = field_value })
            .limit(1)
            .run();
        defer result.deinit();

        if (!result.success or result.data == null) return null;

        var docs = try parseDocArray(self.allocator, result.data.?);
        defer {
            if (docs.len > 1) {
                for (docs[1..]) |doc| self.allocator.free(doc.value);
            }
            self.allocator.free(docs);
        }

        if (docs.len == 0) return null;

        return docs[0];
    }


    pub const Document = struct {
        key: u128,
        value: []const u8,
    };


    fn storeNs(store_id: u16) []const u8 {
        return switch (store_id) {
            STORE_SCHEDULES => "sysschedules",
            STORE_STATS => "sysstats",
            STORE_APPS => "sysapps",
            STORE_BACKUPS => "sysbackups",
            else => "unknown",
        };
    }

    fn parseDocArray(allocator: Allocator, data: []const u8) ![]Document {
        var results: std.ArrayList(Document) = .empty;
        errdefer {
            for (results.items) |doc| allocator.free(doc.value);
            results.deinit(allocator);
        }

        var pos: usize = 0;
        while (pos + 5 <= data.len) {
            const doc_size = @as(usize, @intCast(std.mem.readInt(i32, data[pos..][0..4], .little)));
            if (doc_size < 5 or pos + doc_size > data.len) break;

            const doc_bytes = data[pos .. pos + doc_size];
            const key = bsonGetKeyHex(allocator, doc_bytes) orelse 0;

            try results.append(allocator, .{
                .key = key,
                .value = try allocator.dupe(u8, doc_bytes),
            });

            pos += doc_size;
        }

        return results.toOwnedSlice(allocator);
    }

    fn bsonGetKeyHex(allocator: Allocator, data: []const u8) ?u128 {
        const doc = planck.bson.BsonDocument.init(allocator, data, false) catch return null;
        const hex_str = (doc.getString("key") catch null) orelse return null;
        defer allocator.free(hex_str);
        return std.fmt.parseInt(u128, hex_str, 16) catch null;
    }
};

fn testDocWithKey(a: Allocator, hex: []const u8) ![]const u8 {
    var doc = planck.bson.BsonDocument.empty(a);
    defer doc.deinit();
    try doc.putString("key", hex);
    return a.dupe(u8, doc.toBytes());
}

test "store namespace maps known store ids" {
    try std.testing.expectEqualStrings("sysschedules", WbStorage.storeNs(WbStorage.STORE_SCHEDULES));
    try std.testing.expectEqualStrings("sysstats", WbStorage.storeNs(WbStorage.STORE_STATS));
    try std.testing.expectEqualStrings("sysapps", WbStorage.storeNs(WbStorage.STORE_APPS));
    try std.testing.expectEqualStrings("sysbackups", WbStorage.storeNs(WbStorage.STORE_BACKUPS));
}

test "store namespace falls back to unknown" {
    try std.testing.expectEqualStrings("unknown", WbStorage.storeNs(999));
}

test "document key is parsed from its hex string" {
    const a = std.testing.allocator;
    const d = try testDocWithKey(a, "1a2b");
    defer a.free(d);
    try std.testing.expectEqual(@as(?u128, 0x1a2b), WbStorage.bsonGetKeyHex(a, d));
}

test "document key is null when the field is absent" {
    const a = std.testing.allocator;
    var doc = planck.bson.BsonDocument.empty(a);
    defer doc.deinit();
    try doc.putString("name", "x");
    const d = try a.dupe(u8, doc.toBytes());
    defer a.free(d);
    try std.testing.expect(WbStorage.bsonGetKeyHex(a, d) == null);
}

test "document key is null for malformed bytes" {
    try std.testing.expect(WbStorage.bsonGetKeyHex(std.testing.allocator, &[_]u8{ 0, 0 }) == null);
}

test "concatenated documents are split into rows" {
    const a = std.testing.allocator;
    const d1 = try testDocWithKey(a, "01");
    defer a.free(d1);
    const d2 = try testDocWithKey(a, "02");
    defer a.free(d2);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, d1);
    try buf.appendSlice(a, d2);

    const docs = try WbStorage.parseDocArray(a, buf.items);
    defer {
        for (docs) |doc| a.free(doc.value);
        a.free(docs);
    }
    try std.testing.expectEqual(@as(usize, 2), docs.len);
    try std.testing.expectEqual(@as(u128, 1), docs[0].key);
    try std.testing.expectEqual(@as(u128, 2), docs[1].key);
}

test "empty input yields no rows" {
    const docs = try WbStorage.parseDocArray(std.testing.allocator, "");
    defer std.testing.allocator.free(docs);
    try std.testing.expectEqual(@as(usize, 0), docs.len);
}
