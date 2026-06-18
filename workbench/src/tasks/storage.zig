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

        const old_size = std.mem.readInt(i32, services_arr.data[0..4], .little);
        const old_content_end = @as(usize, @intCast(old_size)) - 1;

        var arr_buf: std.ArrayList(u8) = .empty;
        defer arr_buf.deinit(self.allocator);

        try arr_buf.appendSlice(self.allocator, services_arr.data[0..old_content_end]);

        try arr_buf.append(self.allocator, 0x03);
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{count}) catch "0";
        try arr_buf.appendSlice(self.allocator, idx_str);
        try arr_buf.append(self.allocator, 0);
        try arr_buf.appendSlice(self.allocator, service_bson);

        try arr_buf.append(self.allocator, 0);

        const new_size: i32 = @intCast(arr_buf.items.len);
        @memcpy(arr_buf.items[0..4], std.mem.asBytes(&std.mem.nativeToLittle(i32, new_size)));

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
                try new_doc.put(name, val);
            }
        }

        const new_arr = bson.BsonArray.init(self.allocator, arr_buf.items);
        try new_doc.putArray("services", new_arr);

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

        var arr_buf: std.ArrayList(u8) = .empty;
        defer arr_buf.deinit(self.allocator);

        try arr_buf.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        var new_idx: usize = 0;
        for (0..count) |i| {
            const val = (try services_arr.get(i)) orelse continue;
            const svc_doc_data = switch (val) {
                .document => |d| d.data,
                else => continue,
            };

            var svc_doc = try bson.BsonDocument.init(self.allocator, svc_doc_data, false);
            const name = (try svc_doc.getString("name")) orelse {
                var idx_buf: [16]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{new_idx}) catch "0";
                try arr_buf.append(self.allocator, 0x03);
                try arr_buf.appendSlice(self.allocator, idx_str);
                try arr_buf.append(self.allocator, 0);
                try arr_buf.appendSlice(self.allocator, svc_doc_data);
                new_idx += 1;
                continue;
            };

            if (std.mem.eql(u8, name, service_name)) continue;

            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{new_idx}) catch "0";
            try arr_buf.append(self.allocator, 0x03);
            try arr_buf.appendSlice(self.allocator, idx_str);
            try arr_buf.append(self.allocator, 0);
            try arr_buf.appendSlice(self.allocator, svc_doc_data);
            new_idx += 1;
        }

        try arr_buf.append(self.allocator, 0);

        const new_size: i32 = @intCast(arr_buf.items.len);
        @memcpy(arr_buf.items[0..4], std.mem.asBytes(&std.mem.nativeToLittle(i32, new_size)));

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
                try new_doc.put(fname, val);
            }
        }

        const new_arr = bson.BsonArray.init(self.allocator, arr_buf.items);
        try new_doc.putArray("services", new_arr);

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
            const key = bsonGetKeyHex(doc_bytes) orelse 0;

            try results.append(allocator, .{
                .key = key,
                .value = try allocator.dupe(u8, doc_bytes),
            });

            pos += doc_size;
        }

        return results.toOwnedSlice(allocator);
    }

    fn bsonGetKeyHex(data: []const u8) ?u128 {
        if (data.len < 5) return null;
        var pos: usize = 4;
        while (pos < data.len - 1) {
            const element_type = data[pos];
            if (element_type == 0x00) break;
            pos += 1;

            const name_start = pos;
            while (pos < data.len and data[pos] != 0) : (pos += 1) {}
            if (pos >= data.len) return null;
            const name = data[name_start..pos];
            pos += 1;

            if (element_type == 0x02 and std.mem.eql(u8, name, "key")) {
                if (pos + 4 > data.len) return null;
                const str_len = std.mem.readInt(i32, data[pos..][0..4], .little);
                pos += 4;
                if (str_len < 2) return null;
                const ustr_len = @as(usize, @intCast(str_len));
                if (pos + ustr_len > data.len) return null;
                const hex_str = data[pos .. pos + ustr_len - 1];
                return std.fmt.parseInt(u128, hex_str, 16) catch null;
            }

            pos = skipBsonValue(data, pos, element_type) orelse return null;
        }
        return null;
    }

    fn skipBsonValue(data: []const u8, pos: usize, element_type: u8) ?usize {
        var p = pos;
        switch (element_type) {
            0x01 => p += 8,
            0x02 => {
                if (p + 4 > data.len) return null;
                const len = std.mem.readInt(i32, data[p..][0..4], .little);
                if (len < 0) return null;
                const ulen = @as(usize, @intCast(len));
                if (p + 4 + ulen > data.len) return null;
                p += 4 + ulen;
            },
            0x03, 0x04 => {
                if (p + 4 > data.len) return null;
                const len = std.mem.readInt(i32, data[p..][0..4], .little);
                if (len < 0) return null;
                const ulen = @as(usize, @intCast(len));
                if (p + ulen > data.len) return null;
                p += ulen;
            },
            0x05 => {
                if (p + 4 > data.len) return null;
                const len = std.mem.readInt(i32, data[p..][0..4], .little);
                if (len < 0) return null;
                const ulen = @as(usize, @intCast(len));
                if (p + 5 + ulen > data.len) return null;
                p += 5 + ulen;
            },
            0x07 => p += 12,
            0x08 => p += 1,
            0x09 => p += 8,
            0x0A => {},
            0x10 => p += 4,
            0x11 => p += 8,
            0x12 => p += 8,
            0x00 => return null,
            else => return null,
        }
        return p;
    }
};
