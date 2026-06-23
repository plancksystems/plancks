const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const utils = @import("utils");
const Now = utils.Now;
const LogRecord = @import("../common/common.zig").LogRecord;
const OpKind = @import("../common/common.zig").OpKind;
const VlogEntry = @import("../common/common.zig").VlogEntry;
const proto = @import("proto");
const Store = proto.Store;
const Index = proto.Index;
const User = proto.User;
const Backup = proto.Backup;
const FieldType = proto.FieldType;
const bson = @import("bson");
const ValueLog = @import("vlog.zig").ValueLog;
const BPTree = @import("bptree.zig");
const WriteAheadLog = @import("../durability/write_ahead_log.zig").WriteAheadLog;
const constants = @import("../common/constants.zig");
const SYSTEM_CATALOG_STORE_ID = constants.SYSTEM_CATALOG_STORE_ID;
const SYSTEM_USERS_STORE_ID = constants.SYSTEM_USERS_STORE_ID;
const SYSTEM_USERS_STORE_NS = constants.SYSTEM_USERS_STORE_NS;
const catalogKey = constants.catalogKey;
const USER_STORE_START_ID = constants.USER_STORE_START_ID;
const DocType = proto.DocType;

const log = std.log.scoped(.catalog);

fn catalogDocTypeFromInt(v: u8) ?DocType {
    inline for (std.meta.fields(DocType)) |f| {
        if (f.value == v) {
            const dt: DocType = @enumFromInt(v);
            if (dt == .Document) return null;
            return dt;
        }
    }
    return null;
}

pub const Catalog = struct {
    allocator: Allocator,
    stores: std.StringHashMap(*Store),
    stores_by_id: std.AutoHashMap(u16, *Store),
    next_store_id: u16,
    indexes: std.StringHashMap(*Index),
    indexes_by_store: std.AutoHashMap(u16, std.ArrayList(*Index)),
    users: std.StringHashMap(*User),
    backups: std.StringHashMap(*Backup),
    system_vlog: *ValueLog,
    system_index: *BPTree.Index(u128, u64),
    wal: *WriteAheadLog,
    io: std.Io,
    now: Now,

    pub fn init(allocator: Allocator, io: std.Io, wal: *WriteAheadLog, system_vlog: *ValueLog, system_index: *BPTree.Index(u128, u64)) !*Catalog {
        const catalog = try allocator.create(Catalog);
        catalog.* = .{
            .allocator = allocator,
            .io = io,
            .stores = std.StringHashMap(*Store).init(allocator),
            .stores_by_id = std.AutoHashMap(u16, *Store).init(allocator),
            .next_store_id = USER_STORE_START_ID,
            .indexes = std.StringHashMap(*Index).init(allocator),
            .indexes_by_store = std.AutoHashMap(u16, std.ArrayList(*Index)).init(allocator),
            .users = std.StringHashMap(*User).init(allocator),
            .backups = std.StringHashMap(*Backup).init(allocator),
            .system_vlog = system_vlog,
            .system_index = system_index,
            .wal = wal,
            .now = Now{ .io = io },
        };
        return catalog;
    }

    pub fn loadFromVlog(self: *Catalog) !void {
        self.clearMaps();

        var iter = try self.system_index.iterator();
        defer iter.deinit();

        var loaded: usize = 0;
        while (try iter.next()) |cell| {
            if (cell.key.len < 16 or cell.value.len < 8) continue;
            const key = mem.readInt(u128, cell.key[0..16], .big);
            const offset = mem.readInt(u64, cell.value[0..8], .little);

            var entry = self.system_vlog.get(offset) catch |err| {
                log.warn("loadFromVlog: failed to read at offset {d}: {}", .{ offset, err });
                continue;
            };
            defer entry.deinit(self.allocator);

            if (entry.tombstone) continue;

            const doc_type_int: u8 = @truncate((key >> 104) & 0xFF);
            const doc_type = catalogDocTypeFromInt(doc_type_int) orelse {
                log.warn("loadFromVlog: unknown doc_type {} for key {}", .{ doc_type_int, key });
                continue;
            };

            self.applyEntryToMaps(doc_type, entry.value) catch |err| {
                log.warn("loadFromVlog: decode error for doc_type {}: {}", .{ doc_type_int, err });
                continue;
            };
            loaded += 1;
        }

        log.info("Loaded Catalogue: Stores={} Indexes={} Users={} Backups={}", .{
            self.stores.count(),
            self.indexes.count(),
            self.users.count(),
            self.backups.count(),
        });
    }

    fn applyEntryToMaps(self: *Catalog, doc_type: DocType, bson_data: []const u8) !void {
        switch (doc_type) {
            .Store => {
                const s = try bson.decode(self.allocator, Store, bson_data);
                if (self.stores.contains(s.ns)) {
                    self.freeStoreStrings(s);
                    return;
                }
                const store = try self.allocator.create(Store);
                store.* = s;
                try self.stores.put(store.ns, store);
                try self.stores_by_id.put(store.store_id, store);
                if (store.store_id >= self.next_store_id) {
                    self.next_store_id = store.store_id + 1;
                }
            },
            .Index => {
                const i = try bson.decode(self.allocator, Index, bson_data);
                if (self.indexes.contains(i.ns)) {
                    self.freeIndexStrings(i);
                    return;
                }
                const idx = try self.allocator.create(Index);
                idx.* = i;
                try self.indexes.put(idx.ns, idx);
                const gop = try self.indexes_by_store.getOrPut(idx.store_id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, idx);
            },
            .User => {
                const u = try bson.decode(self.allocator, User, bson_data);
                if (self.users.contains(u.username)) {
                    self.allocator.free(@constCast(u.username));
                    self.allocator.free(@constCast(u.password_hash));
                    return;
                }
                const user = try self.allocator.create(User);
                user.* = u;
                try self.users.put(user.username, user);
            },
            .Backup => {
                const b = try bson.decode(self.allocator, Backup, bson_data);
                if (self.backups.contains(b.name)) {
                    self.allocator.free(@constCast(b.name));
                    self.allocator.free(@constCast(b.backup_path));
                    if (b.description) |d| self.allocator.free(@constCast(d));
                    return;
                }
                const backup = try self.allocator.create(Backup);
                backup.* = b;
                try self.backups.put(backup.name, backup);
            },
            .Service, .Schedule, .Document, .Sequence => {},
        }
    }

    pub fn createStore(self: *Catalog, ns: []const u8, description: ?[]const u8) !*Store {
        if (self.stores.get(ns)) |existing| return existing;

        const ts = self.now.toMilliSeconds();
        const store_id: u16 = self.next_store_id;
        self.next_store_id += 1;

        const store = Store{
            .id = @intCast(self.stores.count()),
            .store_id = store_id,
            .ns = ns,
            .description = description,
            .created_at = ts,
        };
        const key = catalogKey(.Store, ns);
        const lsn = self.wal.incrementLSN();

        const bson_bytes = try bson.encode(self.allocator, store);
        defer self.allocator.free(bson_bytes);

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = bson_bytes, .timestamp = ts, .kind = .insert });
        try self.wal.flush();

        const offset = try self.system_vlog.post(.{ .key = key, .lsn = lsn, .value = bson_bytes, .timestamp = ts });
        try self.system_index.insert(key, offset);
        self.system_vlog.flush() catch |err| {
            log.err("Failed to flush system vlog after creating store: {}", .{err});
            return err;
        };
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after creating store: {}", .{err});
            return err;
        };

        const ns_owned = try self.allocator.dupe(u8, ns);
        errdefer self.allocator.free(ns_owned);
        const desc_owned = if (description) |d| try self.allocator.dupe(u8, d) else null;

        const store_ptr = try self.allocator.create(Store);
        store_ptr.* = Store{
            .id = store.id,
            .store_id = store_id,
            .ns = ns_owned,
            .description = desc_owned,
            .created_at = ts,
        };
        try self.stores.put(ns_owned, store_ptr);
        try self.stores_by_id.put(store_id, store_ptr);
        return store_ptr;
    }

    pub fn createStoreWithId(self: *Catalog, ns: []const u8, description: ?[]const u8, store_id: u16) !*Store {
        if (self.stores.get(ns)) |existing| return existing;

        const ts = self.now.toMilliSeconds();
        const store = Store{
            .id = @intCast(self.stores.count()),
            .store_id = store_id,
            .ns = ns,
            .description = description,
            .created_at = ts,
        };
        const key = catalogKey(.Store, ns);
        const lsn = self.wal.incrementLSN();

        const bson_bytes = try bson.encode(self.allocator, store);
        defer self.allocator.free(bson_bytes);

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = bson_bytes, .timestamp = ts, .kind = .insert });
        try self.wal.flush();

        const offset = try self.system_vlog.post(.{ .key = key, .lsn = lsn, .value = bson_bytes, .timestamp = ts });
        try self.system_index.insert(key, offset);
        self.system_vlog.flush() catch |err| {
            log.err("Failed to flush system vlog after creating store: {}", .{err});
            return err;
        };
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after creating store: {}", .{err});
            return err;
        };

        const ns_owned = try self.allocator.dupe(u8, ns);
        errdefer self.allocator.free(ns_owned);
        const desc_owned = if (description) |d| try self.allocator.dupe(u8, d) else null;

        const store_ptr = try self.allocator.create(Store);
        store_ptr.* = Store{
            .id = store.id,
            .store_id = store_id,
            .ns = ns_owned,
            .description = desc_owned,
            .created_at = ts,
        };
        try self.stores.put(ns_owned, store_ptr);
        try self.stores_by_id.put(store_id, store_ptr);
        if (store_id >= self.next_store_id) {
            self.next_store_id = store_id + 1;
        }
        return store_ptr;
    }

    pub fn ensureSystemStores(self: *Catalog) !void {
        _ = try self.createStoreWithId(SYSTEM_USERS_STORE_NS, "System user accounts", SYSTEM_USERS_STORE_ID);
    }

    pub fn dropStore(self: *Catalog, store_ns: []const u8) !void {
        const key = catalogKey(.Store, store_ns);
        const offset = (try self.system_index.search(key)) orelse return error.StoreNotFound;

        const ts = self.now.toMilliSeconds();
        const lsn = self.wal.incrementLSN();

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = &.{}, .timestamp = ts, .kind = .delete });
        try self.wal.flush();

        _ = try self.system_vlog.del(offset);
        try self.system_index.delete(key);
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after dropping store: {}", .{err});
            return err;
        };

        if (self.stores.fetchRemove(store_ns)) |entry| {
            const store = entry.value;
            _ = self.stores_by_id.remove(store.store_id);
            self.freeStoreStrings(store.*);
            self.allocator.destroy(store);
        }
    }

    pub fn listStores(self: *Catalog, allocator: Allocator) !std.ArrayList(*Store) {
        var result: std.ArrayList(*Store) = .empty;
        var iter = self.stores.iterator();
        while (iter.next()) |entry| {
            try result.append(allocator, entry.value_ptr.*);
        }
        return result;
    }

    pub fn listStoresBson(self: *Catalog, allocator: Allocator, ns_filter: ?[]const u8) ![]const u8 {
        var list: std.ArrayList(Store) = .empty;
        defer list.deinit(allocator);
        var iter = self.stores.valueIterator();
        while (iter.next()) |store_ptr| {
            const store = store_ptr.*;
            if (ns_filter) |filter| {
                if (!mem.startsWith(u8, store.ns, filter)) continue;
            }
            try list.append(allocator, store.*);
        }
        const wrapper = struct { stores: []Store }{ .stores = list.items };
        var encoder = bson.Encoder.init(allocator);
        defer encoder.deinit();
        return try encoder.encode(wrapper);
    }

    pub fn getStore(self: *Catalog, ns: []const u8) ?*Store {
        return self.stores.get(ns);
    }

    pub fn findStoreByNamespace(self: *Catalog, ns: []const u8) ?*Store {
        return self.getStore(ns);
    }

    pub fn getStoreById(self: *Catalog, store_id: u16) ?*Store {
        return self.stores_by_id.get(store_id);
    }

    pub fn createIndexForStore(self: *Catalog, store_id: u16, index_ns: []const u8, field: []const u8, field_type: FieldType, unique: bool, index_path: []const u8) !*Index {
        if (self.indexes.get(index_ns)) |existing| return existing;

        const ts = self.now.toMilliSeconds();
        const idx = Index{
            .id = @intCast(self.indexes.count() + 1),
            .store_id = store_id,
            .ns = index_ns,
            .field = field,
            .field_type = field_type,
            .unique = unique,
            .description = null,
            .created_at = ts,
            .index_path = index_path,
        };
        const key = catalogKey(.Index, index_ns);
        const lsn = self.wal.incrementLSN();

        const bson_bytes = try bson.encode(self.allocator, idx);
        defer self.allocator.free(bson_bytes);

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = bson_bytes, .timestamp = ts, .kind = .insert });
        try self.wal.flush();

        const offset = try self.system_vlog.post(.{ .key = key, .lsn = lsn, .value = bson_bytes, .timestamp = ts });
        try self.system_index.insert(key, offset);
        self.system_vlog.flush() catch |err| {
            log.err("Failed to flush system vlog after creating space: {}", .{err});
            return err;
        };
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after creating space: {}", .{err});
            return err;
        };

        const ns_owned = try self.allocator.dupe(u8, index_ns);
        errdefer self.allocator.free(ns_owned);
        const field_owned = try self.allocator.dupe(u8, field);
        errdefer self.allocator.free(field_owned);
        const index_path_owned = try self.allocator.dupe(u8, index_path);

        const idx_ptr = try self.allocator.create(Index);
        idx_ptr.* = Index{
            .id = idx.id,
            .store_id = store_id,
            .ns = ns_owned,
            .field = field_owned,
            .field_type = field_type,
            .unique = unique,
            .description = null,
            .created_at = ts,
            .index_path = index_path_owned,
        };
        try self.indexes.put(ns_owned, idx_ptr);

        const gop = try self.indexes_by_store.getOrPut(store_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, idx_ptr);

        return idx_ptr;
    }

    pub fn getIndexesByStoreId(self: *Catalog, store_id: u16) ?*std.ArrayList(*Index) {
        return self.indexes_by_store.getPtr(store_id);
    }

    pub fn dropIndex(self: *Catalog, index_ns: []const u8) !void {
        const key = catalogKey(.Index, index_ns);
        const offset = (try self.system_index.search(key)) orelse return error.IndexNotFound;

        const ts = self.now.toMilliSeconds();
        const lsn = self.wal.incrementLSN();

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = &.{}, .timestamp = ts, .kind = .delete });
        try self.wal.flush();

        _ = try self.system_vlog.del(offset);
        try self.system_index.delete(key);
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after creating space: {}", .{err});
            return err;
        };

        if (self.indexes.fetchRemove(index_ns)) |entry| {
            const idx = entry.value;
            if (self.indexes_by_store.getPtr(idx.store_id)) |list| {
                for (list.items, 0..) |item, i| {
                    if (mem.eql(u8, item.ns, index_ns)) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
            }
            self.freeIndexStrings(idx.*);
            self.allocator.destroy(idx);
        }
    }

    pub fn listIndexes(self: *Catalog, allocator: Allocator) !std.ArrayList(*Index) {
        var result: std.ArrayList(*Index) = .empty;
        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            try result.append(allocator, entry.value_ptr.*);
        }
        return result;
    }

    pub fn listIndexesBson(self: *Catalog, allocator: Allocator, ns_filter: ?[]const u8) ![]const u8 {
        var list: std.ArrayList(Index) = .empty;
        defer list.deinit(allocator);
        var iter = self.indexes.valueIterator();
        while (iter.next()) |index_ptr| {
            const idx = index_ptr.*;
            if (ns_filter) |filter| {
                if (!mem.startsWith(u8, idx.ns, filter)) continue;
            }
            try list.append(allocator, idx.*);
        }
        const wrapper = struct { indexes: []Index }{ .indexes = list.items };
        var encoder = bson.Encoder.init(allocator);
        defer encoder.deinit();
        return try encoder.encode(wrapper);
    }

    pub fn hasIndex(self: *Catalog, index_ns: []const u8) bool {
        return self.indexes.contains(index_ns);
    }

    pub fn getIndexesForStore(self: *Catalog, store_ns: []const u8, allocator: Allocator) !std.ArrayList(*Index) {
        var result: std.ArrayList(*Index) = .empty;
        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            const idx = entry.value_ptr.*;
            if (self.getStoreById(idx.store_id)) |store| {
                if (mem.eql(u8, store.ns, store_ns)) {
                    try result.append(allocator, idx);
                }
            }
        }
        return result;
    }

    pub fn createUser(self: *Catalog, username: []const u8, password_hash: []const u8, role: u8) !*User {
        if (self.users.get(username)) |existing| return existing;

        const ts = self.now.toMilliSeconds();
        const user = User{
            .id = @intCast(self.users.count()),
            .username = username,
            .password_hash = password_hash,
            .role = role,
            .created_at = ts,
        };
        const key = catalogKey(.User, username);
        const lsn = self.wal.incrementLSN();

        const bson_bytes = try bson.encode(self.allocator, user);
        defer self.allocator.free(bson_bytes);

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = bson_bytes, .timestamp = ts, .kind = .insert });
        try self.wal.flush();

        const offset = try self.system_vlog.post(.{ .key = key, .lsn = lsn, .value = bson_bytes, .timestamp = ts });
        try self.system_index.insert(key, offset);
        self.system_vlog.flush() catch |err| {
            log.err("Failed to flush system vlog after creating user: {}", .{err});
            return err;
        };
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after creating space: {}", .{err});
            return err;
        };

        const username_owned = try self.allocator.dupe(u8, username);
        const ph_owned = try self.allocator.dupe(u8, password_hash);

        const user_ptr = try self.allocator.create(User);
        user_ptr.* = User{
            .id = user.id,
            .username = username_owned,
            .password_hash = ph_owned,
            .role = role,
            .created_at = ts,
        };
        try self.users.put(username_owned, user_ptr);
        return user_ptr;
    }

    pub fn dropUser(self: *Catalog, username: []const u8) !void {
        const key = catalogKey(.User, username);
        const offset = (try self.system_index.search(key)) orelse return error.UserNotFound;

        const ts = self.now.toMilliSeconds();
        const lsn = self.wal.incrementLSN();

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = &.{}, .timestamp = ts, .kind = .delete });
        try self.wal.flush();

        _ = try self.system_vlog.del(offset);
        try self.system_index.delete(key);
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after dropping user: {}", .{err});
            return err;
        };

        if (self.users.fetchRemove(username)) |entry| {
            const user = entry.value;
            self.allocator.free(@constCast(user.username));
            self.allocator.free(@constCast(user.password_hash));
            self.allocator.destroy(user);
        }
    }

    pub fn updateUserPassword(self: *Catalog, username: []const u8, new_password_hash: []const u8) !void {
        const user_ptr = self.users.get(username) orelse return error.UserNotFound;

        const key = catalogKey(.User, username);
        const old_offset = (try self.system_index.search(key)) orelse return error.UserNotFound;

        self.allocator.free(@constCast(user_ptr.password_hash));
        user_ptr.password_hash = try self.allocator.dupe(u8, new_password_hash);

        const user = User{
            .id = user_ptr.id,
            .username = user_ptr.username,
            .password_hash = user_ptr.password_hash,
            .role = user_ptr.role,
            .created_at = user_ptr.created_at,
        };
        const ts = self.now.toMilliSeconds();
        const lsn = self.wal.incrementLSN();

        const bson_bytes = try bson.encode(self.allocator, user);
        defer self.allocator.free(bson_bytes);

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = bson_bytes, .timestamp = ts, .kind = .insert });
        try self.wal.flush();

        _ = try self.system_vlog.del(old_offset);
        const new_offset = try self.system_vlog.post(.{ .key = key, .lsn = lsn, .value = bson_bytes, .timestamp = ts });
        try self.system_index.delete(key);
        try self.system_index.insert(key, new_offset);
        self.system_vlog.flush() catch |err| {
            log.err("Failed to flush system vlog after updating user: {}", .{err});
            return err;
        };
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after updating user: {}", .{err});
            return err;
        };
    }

    pub fn updateUserRole(self: *Catalog, username: []const u8, new_role: u8) !void {
        const user_ptr = self.users.get(username) orelse return error.UserNotFound;

        const key = catalogKey(.User, username);
        const old_offset = (try self.system_index.search(key)) orelse return error.UserNotFound;

        user_ptr.role = new_role;

        const user = User{
            .id = user_ptr.id,
            .username = user_ptr.username,
            .password_hash = user_ptr.password_hash,
            .role = user_ptr.role,
            .created_at = user_ptr.created_at,
        };
        const ts = self.now.toMilliSeconds();
        const lsn = self.wal.incrementLSN();

        const bson_bytes = try bson.encode(self.allocator, user);
        defer self.allocator.free(bson_bytes);

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = bson_bytes, .timestamp = ts, .kind = .insert });
        try self.wal.flush();

        _ = try self.system_vlog.del(old_offset);
        const new_offset = try self.system_vlog.post(.{ .key = key, .lsn = lsn, .value = bson_bytes, .timestamp = ts });
        try self.system_index.delete(key);
        try self.system_index.insert(key, new_offset);
        self.system_vlog.flush() catch |err| {
            log.err("Failed to flush system vlog after updating user role: {}", .{err});
            return err;
        };
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after updating user role: {}", .{err});
            return err;
        };
    }

    pub fn listUsersBson(self: *Catalog, allocator: Allocator) ![]const u8 {
        var list: std.ArrayList(User) = .empty;
        defer list.deinit(allocator);
        var iter = self.users.valueIterator();
        while (iter.next()) |user_ptr| {
            try list.append(allocator, user_ptr.*.*);
        }
        const wrapper = struct { users: []User }{ .users = list.items };
        var encoder = bson.Encoder.init(allocator);
        defer encoder.deinit();
        return try encoder.encode(wrapper);
    }

    pub fn createBackup(self: *Catalog, name: []const u8, backup_path: []const u8, size_bytes: u64, description: ?[]const u8) !*Backup {
        if (self.backups.get(name)) |existing| return existing;

        const ts = self.now.toMilliSeconds();
        const backup = Backup{
            .id = @intCast(self.backups.count()),
            .name = name,
            .backup_path = backup_path,
            .size_bytes = size_bytes,
            .created_at = ts,
            .description = description,
        };
        const key = catalogKey(.Backup, name);
        const lsn = self.wal.incrementLSN();

        const bson_bytes = try bson.encode(self.allocator, backup);
        defer self.allocator.free(bson_bytes);

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = bson_bytes, .timestamp = ts, .kind = .insert });
        try self.wal.flush();

        const offset = try self.system_vlog.post(.{ .key = key, .lsn = lsn, .value = bson_bytes, .timestamp = ts });
        try self.system_index.insert(key, offset);
        self.system_vlog.flush() catch |err| {
            log.err("Failed to flush system vlog after creating space: {}", .{err});
            return err;
        };
        self.system_index.flush() catch |err| {
            log.err("Failed to flush system index after creating space: {}", .{err});
            return err;
        };

        const name_owned = try self.allocator.dupe(u8, name);
        const path_owned = try self.allocator.dupe(u8, backup_path);
        const desc_owned = if (description) |d| try self.allocator.dupe(u8, d) else null;

        const backup_ptr = try self.allocator.create(Backup);
        backup_ptr.* = Backup{
            .id = backup.id,
            .name = name_owned,
            .backup_path = path_owned,
            .size_bytes = size_bytes,
            .created_at = ts,
            .description = desc_owned,
        };
        try self.backups.put(name_owned, backup_ptr);
        return backup_ptr;
    }

    pub fn dropBackup(self: *Catalog, name: []const u8) !void {
        const key = catalogKey(.Backup, name);
        const offset = (try self.system_index.search(key)) orelse return error.BackupNotFound;

        if (self.backups.get(name)) |backup| {
            std.Io.Dir.deleteFile(.cwd(), self.io, backup.backup_path) catch |err| {
                log.warn("Failed to delete backup file {s}: {}", .{ backup.backup_path, err });
            };
        }

        const ts = self.now.toMilliSeconds();
        const lsn = self.wal.incrementLSN();

        try self.wal.append(.{ .lsn = lsn, .key = key, .value = &.{}, .timestamp = ts, .kind = .delete });
        try self.wal.flush();

        _ = try self.system_vlog.del(offset);
        try self.system_index.delete(key);

        if (self.backups.fetchRemove(name)) |entry| {
            const backup = entry.value;
            self.allocator.free(@constCast(backup.name));
            self.allocator.free(@constCast(backup.backup_path));
            if (backup.description) |d| self.allocator.free(@constCast(d));
            self.allocator.destroy(backup);
        }
    }

    pub fn listBackupsBson(self: *Catalog, allocator: Allocator) ![]const u8 {
        var list: std.ArrayList(Backup) = .empty;
        defer list.deinit(allocator);
        var iter = self.backups.valueIterator();
        while (iter.next()) |backup_ptr| {
            try list.append(allocator, backup_ptr.*.*);
        }
        const wrapper = struct { backups: []Backup }{ .backups = list.items };
        var encoder = bson.Encoder.init(allocator);
        defer encoder.deinit();
        return try encoder.encode(wrapper);
    }

    pub fn applyRecovery(self: *Catalog, record: LogRecord) !bool {
        const store_id_bits: u16 = @truncate((record.key >> 112) & 0xFFFF);
        if (store_id_bits != SYSTEM_CATALOG_STORE_ID) return false;

        const doc_type_int: u8 = @truncate((record.key >> 104) & 0xFF);
        const doc_type = catalogDocTypeFromInt(doc_type_int) orelse {
            log.warn("applyRecovery: unknown doc_type {} in key {}", .{ doc_type_int, record.key });
            return false;
        };

        switch (record.kind) {
            .insert => {
                if (try self.system_index.search(record.key)) |existing_offset| {
                    var existing = self.system_vlog.get(existing_offset) catch return false;
                    defer existing.deinit(self.allocator);
                    if (!existing.tombstone and existing.lsn >= record.lsn) return false;
                    const offset = try self.system_vlog.post(.{
                        .key = record.key,
                        .lsn = record.lsn,
                        .value = record.value,
                        .timestamp = record.timestamp,
                    });
                    try self.system_index.update(record.key, offset);
                    self.system_index.flush() catch |err| {
                        log.err("Failed to flush system index after creating space: {}", .{err});
                        return err;
                    };
                } else {
                    const offset = try self.system_vlog.post(.{
                        .key = record.key,
                        .lsn = record.lsn,
                        .value = record.value,
                        .timestamp = record.timestamp,
                    });
                    try self.system_index.insert(record.key, offset);
                    self.system_index.flush() catch |err| {
                        log.err("Failed to flush system index after creating space: {}", .{err});
                        return err;
                    };
                }
                try self.applyEntryToMaps(doc_type, record.value);
                return true;
            },
            .delete => {
                const existing_offset = (try self.system_index.search(record.key)) orelse return false;
                {
                    var existing = self.system_vlog.get(existing_offset) catch return false;
                    defer existing.deinit(self.allocator);
                    if (existing.tombstone) {
                        try self.system_index.delete(record.key);
                        self.system_index.flush() catch |err| {
                            log.err("Failed to flush system index after creating space: {}", .{err});
                            return err;
                        };
                        self.removeFromMapsByKey(doc_type, record.key);
                        return true;
                    }
                    if (existing.lsn >= record.lsn) return false;
                }
                _ = try self.system_vlog.del(existing_offset);

                try self.system_index.delete(record.key);
                self.system_index.flush() catch |err| {
                    log.err("Failed to flush system index after creating space: {}", .{err});
                    return err;
                };
                self.removeFromMapsByKey(doc_type, record.key);
                return true;
            },
            else => return false,
        }
    }

    fn removeFromMapsByKey(self: *Catalog, doc_type: DocType, key: u128) void {
        switch (doc_type) {
            .Store => {
                var iter = self.stores.iterator();
                while (iter.next()) |entry| {
                    if (catalogKey(.Store, entry.value_ptr.*.ns) != key) continue;
                    const ns = entry.key_ptr.*;
                    _ = self.stores_by_id.remove(entry.value_ptr.*.store_id);
                    if (self.stores.fetchRemove(ns)) |removed| {
                        self.freeStoreStrings(removed.value.*);
                        self.allocator.destroy(removed.value);
                    }
                    return;
                }
            },
            .Index => {
                var iter = self.indexes.iterator();
                while (iter.next()) |entry| {
                    const idx = entry.value_ptr.*;
                    if (catalogKey(.Index, idx.ns) != key) continue;
                    const ns = entry.key_ptr.*;
                    if (self.indexes_by_store.getPtr(idx.store_id)) |list| {
                        for (list.items, 0..) |item, i| {
                            if (mem.eql(u8, item.ns, idx.ns)) {
                                _ = list.swapRemove(i);
                                break;
                            }
                        }
                    }
                    if (self.indexes.fetchRemove(ns)) |removed| {
                        self.freeIndexStrings(removed.value.*);
                        self.allocator.destroy(removed.value);
                    }
                    return;
                }
            },
            .User => {
                var iter = self.users.iterator();
                while (iter.next()) |entry| {
                    if (catalogKey(.User, entry.value_ptr.*.username) != key) continue;
                    const username = entry.key_ptr.*;
                    if (self.users.fetchRemove(username)) |removed| {
                        self.allocator.free(@constCast(removed.value.username));
                        self.allocator.free(@constCast(removed.value.password_hash));
                        self.allocator.destroy(removed.value);
                    }
                    return;
                }
            },
            .Backup => {
                var iter = self.backups.iterator();
                while (iter.next()) |entry| {
                    if (catalogKey(.Backup, entry.value_ptr.*.name) != key) continue;
                    const name = entry.key_ptr.*;
                    if (self.backups.fetchRemove(name)) |removed| {
                        self.allocator.free(@constCast(removed.value.name));
                        self.allocator.free(@constCast(removed.value.backup_path));
                        if (removed.value.description) |d| self.allocator.free(@constCast(d));
                        self.allocator.destroy(removed.value);
                    }
                    return;
                }
            },
            .Service, .Schedule, .Document, .Sequence => {},
        }
    }

    fn freeStoreStrings(self: *Catalog, store: Store) void {
        self.allocator.free(@constCast(store.ns));
        if (store.description) |d| self.allocator.free(@constCast(d));
    }

    fn freeIndexStrings(self: *Catalog, idx: Index) void {
        self.allocator.free(@constCast(idx.ns));
        self.allocator.free(@constCast(idx.field));
        if (idx.description) |d| self.allocator.free(@constCast(d));
        self.allocator.free(@constCast(idx.index_path));
    }

    fn clearMaps(self: *Catalog) void {
        var store_iter = self.stores.iterator();
        while (store_iter.next()) |pair| {
            self.freeStoreStrings(pair.value_ptr.*.*);
            self.allocator.destroy(pair.value_ptr.*);
        }
        self.stores.clearRetainingCapacity();
        self.stores_by_id.clearRetainingCapacity();
        self.next_store_id = USER_STORE_START_ID;

        var index_iter = self.indexes.iterator();
        while (index_iter.next()) |pair| {
            self.freeIndexStrings(pair.value_ptr.*.*);
            self.allocator.destroy(pair.value_ptr.*);
        }
        self.indexes.clearRetainingCapacity();

        var ibs_iter = self.indexes_by_store.iterator();
        while (ibs_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.indexes_by_store.clearRetainingCapacity();

        var user_iter = self.users.iterator();
        while (user_iter.next()) |pair| {
            const user = pair.value_ptr.*;
            self.allocator.free(@constCast(user.username));
            self.allocator.free(@constCast(user.password_hash));
            self.allocator.destroy(user);
        }
        self.users.clearRetainingCapacity();

        var backup_iter = self.backups.iterator();
        while (backup_iter.next()) |pair| {
            const backup = pair.value_ptr.*;
            self.allocator.free(@constCast(backup.name));
            self.allocator.free(@constCast(backup.backup_path));
            if (backup.description) |d| self.allocator.free(@constCast(d));
            self.allocator.destroy(backup);
        }
        self.backups.clearRetainingCapacity();
    }

    pub fn deinit(self: *Catalog) void {
        self.clearMaps();
        self.stores.deinit();
        self.stores_by_id.deinit();
        self.indexes.deinit();
        self.indexes_by_store.deinit();
        self.users.deinit();
        self.backups.deinit();
        self.allocator.destroy(self);
    }
};
