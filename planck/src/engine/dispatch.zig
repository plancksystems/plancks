const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Engine = @import("engine.zig").Engine;
const proto = @import("proto");
const Operation = proto.Operation;
const Status = proto.Status;
const ErrorCode = proto.ErrorCode;
const bson = @import("bson");
const common = @import("../common/common.zig");
const Entry = common.Entry;

pub fn dispatch(engine: *Engine, allocator: Allocator, io: Io, op: *const Operation) !Operation {
    return switch (op.*) {
        .Insert => |data| blk: {
            const key = try engine.post(data.store_ns, data.payload, data.auto_create);
            const key_json = try std.fmt.allocPrint(allocator, "{{\"key\":\"{x:0>32}\"}}", .{key});
            break :blk Operation{ .Reply = .{ .status = .ok, .data = key_json } };
        },
        .BatchInsert => |data| blk: {
            const keys = try engine.postBatch(data.store_ns, data.values, allocator, true);
            defer allocator.free(keys);

            const results = try allocator.alloc([]const u8, keys.len);
            errdefer {
                for (results) |result| {
                    allocator.free(result);
                }
                allocator.free(results);
            }

            for (keys, 0..) |key, i| {
                const key_bytes = try allocator.alloc(u8, 16);
                std.mem.writeInt(u128, key_bytes[0..16], key, .little);
                results[i] = key_bytes;
            }

            break :blk Operation{ .BatchReply = .{ .status = .ok, .results = results } };
        },
        .Read => |data| blk: {
            const value = try engine.get(data.key);
            defer engine.allocator.free(value);
            const dst = try allocator.alloc(u8, value.len + 42);
            writeIdIntoBson(data.key, value, dst);
            break :blk Operation{ .Reply = .{ .status = .ok, .data = dst } };
        },
        .Update => |data| blk: {
            try engine.put(data.store_ns, data.key, data.payload);
            break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
        },
        .Delete => |data| blk: {
            if (data.key) |key| {
                try engine.del(data.store_ns, key);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            } else if (data.query_json) |query_json| {
                const docs = try engine.queryDocs(data.store_ns, query_json);
                defer {
                    for (docs) |doc| allocator.free(doc.value);
                    allocator.free(docs);
                }

                if (docs.len == 0) {
                    break :blk Operation{ .Reply = .{ .status = .not_found, .data = null } };
                }

                for (docs) |doc| {
                    try engine.del(data.store_ns, doc.key);
                }

                var count_doc = bson.BsonDocument.empty(allocator);
                defer count_doc.deinit();
                try count_doc.putInt64("deleted", @intCast(docs.len));
                const count_bytes = count_doc.toBytes();
                const result = try allocator.dupe(u8, count_bytes);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            } else {
                break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
            }
        },
        .Range => |data| blk: {
            const docs = try engine.rangeQuery(data.start_key, data.end_key, 100);
            defer {
                for (docs) |doc| allocator.free(doc.value);
                allocator.free(docs);
            }

            break :blk docsToReply(allocator, docs);
        },
        .Query => |data| blk: {
            if (hasMutationField(data.query_json)) {
                break :blk try handleMutation(engine, allocator, data.store_ns, data.query_json);
            }

            if (hasAggregateField(data.query_json)) {
                const result = try engine.aggregateDocs(data.store_ns, data.query_json);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            }

            if (hasCountField(data.query_json)) {
                const count = try engine.countDocs(data.store_ns, data.query_json);
                var count_doc = bson.BsonDocument.empty(allocator);
                defer count_doc.deinit();
                try count_doc.putInt64("count", @intCast(count));
                const count_bytes = count_doc.toBytes();
                const result = try allocator.dupe(u8, count_bytes);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            }

            const docs = try engine.queryDocs(data.store_ns, data.query_json);
            defer {
                for (docs) |doc| allocator.free(doc.value);
                allocator.free(docs);
            }

            break :blk docsToReply(allocator, docs);
        },
        .Aggregate => |data| blk: {
            const result = try engine.aggregateDocs(data.store_ns, data.aggregate_json);
            break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
        },
        .Scan => |data| blk: {
            const docs = try engine.scanDocs(data.start_key, data.limit, data.skip);
            defer {
                for (docs) |doc| allocator.free(doc.value);
                allocator.free(docs);
            }

            break :blk docsToReply(allocator, docs);
        },
        .List => |data| blk: {
            engine.catalog_mutex.lock(io);
            defer engine.catalog_mutex.unlock(io);

            switch (data.doc_type) {
                .Store => {
                    const bson_data = try engine.catalog.listStoresBson(allocator, data.ns);
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
                },
                .Index => {
                    const bson_data = try engine.catalog.listIndexesBson(allocator, data.ns);
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
                },
                .User => {
                    const bson_data = try engine.catalog.listUsersBson(allocator);
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
                },
                .Backup => {
                    const bson_data = try engine.catalog.listBackupsBson(allocator);
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
                },
                .Service, .Schedule, .Document, .Sequence => {
                    return error.InvalidDocType;
                },
            }
        },
        .NextSequence => |data| blk: {
            const val = try engine.nextSequence(allocator, io, data.name);
            const val_str = try std.fmt.allocPrint(allocator, "{d}", .{val});
            break :blk Operation{ .Reply = .{ .status = .ok, .data = val_str } };
        },
        .Create => |data| blk: {
            const needs_catalog_lock = switch (data.doc_type) {
                .Store, .Index => true,
                .User, .Backup, .Schedule, .Document, .Service, .Sequence => false,
            };

            if (needs_catalog_lock) {
                engine.catalog_mutex.lock(io);
                defer engine.catalog_mutex.unlock(io);
            }

            switch (data.doc_type) {
                .Store => {
                    const already = engine.catalog.findStoreByNamespace(data.ns) != null;
                    _ = try engine.catalog.createStore(data.ns, data.metadata);
                    const status: Status = if (already) .already_exists else .ok;
                    break :blk Operation{ .Reply = .{ .status = status, .data = null } };
                },
                .Index => {
                    var decoder = bson.Decoder.init(allocator, data.payload);
                    const index = try decoder.decode(proto.Index);
                    defer allocator.free(index.field);

                    var parts = try proto.parseNamespace(allocator, data.ns);
                    defer parts.deinit(allocator);

                    const store_ns = parts.store orelse return error.InvalidIndexNamespace;
                    const store = engine.catalog.findStoreByNamespace(store_ns) orelse return error.StoreNotFound;

                    engine.db_mutex.lock(io);
                    defer engine.db_mutex.unlock(io);
                    const already = engine.db.secondary_indexes.contains(data.ns);
                    try engine.db.createSecondaryIndex(store.store_id, data.ns, index.field, index.field_type);
                    const status: Status = if (already) .already_exists else .ok;
                    break :blk Operation{ .Reply = .{ .status = status, .data = null } };
                },
                else => return error.InvalidDocType,
            }
        },
        .Drop => |data| blk: {
            engine.catalog_mutex.lock(io);
            defer engine.catalog_mutex.unlock(io);

            switch (data.doc_type) {
                .Store => {
                    engine.dropStore(data.name) catch |err| {
                        const msg = try ErrorCode.not_found.formatError(allocator, @errorName(err));
                        break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                    };
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                },
                .Index => {
                    engine.dropIndex(data.name) catch |err| {
                        const msg = try ErrorCode.not_found.formatError(allocator, @errorName(err));
                        break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                    };
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                },
                else => return error.InvalidDocType,
            }
        },
        .Flush => blk: {
            try engine.flush();
            break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
        },
        .Authenticate, .Logout => return error.InvalidOperation,
        .Reply, .BatchReply => return error.InvalidOperation,
        .Watch, .WatchReply => return error.InvalidOperation,
        else => return error.InvalidOperation,
    };
}

fn docsToReply(allocator: Allocator, docs: []const Entry) !Operation {
    var total_len: usize = 0;
    for (docs) |doc| {
        total_len += doc.value.len + 42;
    }

    if (total_len == 0) {
        return Operation{ .Reply = .{ .status = .ok, .data = null } };
    }

    const value = try allocator.alloc(u8, total_len);
    errdefer allocator.free(value);

    var pos: usize = 0;
    for (docs) |doc| {
        const seg = value[pos .. pos + doc.value.len + 42];
        writeIdIntoBson(doc.key, doc.value, seg);
        pos += seg.len;
    }

    return Operation{ .Reply = .{ .status = .ok, .data = value } };
}

fn handleMutation(engine: *Engine, allocator: Allocator, store_ns: []const u8, query_json: []const u8) !Operation {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, query_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const mutation = parsed.value.object.get("mutation") orelse return error.InvalidRequest;
    if (mutation != .object) return error.InvalidRequest;

    const type_val = mutation.object.get("type") orelse return error.InvalidRequest;
    if (type_val != .string) return error.InvalidRequest;
    const mutation_type = type_val.string;

    if (std.mem.eql(u8, mutation_type, "delete")) {
        const docs = try engine.queryDocs(store_ns, query_json);
        defer {
            for (docs) |doc| allocator.free(doc.value);
            allocator.free(docs);
        }

        if (docs.len == 0) {
            return Operation{ .Reply = .{ .status = .not_found, .data = null } };
        }

        for (docs) |doc| {
            try engine.del(store_ns, doc.key);
        }

        var count_doc = bson.BsonDocument.empty(allocator);
        defer count_doc.deinit();
        try count_doc.putInt64("deleted", @intCast(docs.len));
        const count_bytes = count_doc.toBytes();
        return Operation{ .Reply = .{ .status = .ok, .data = try allocator.dupe(u8, count_bytes) } };
    }

    if (std.mem.eql(u8, mutation_type, "update")) {
        const payload_val = mutation.object.get("payload") orelse return error.InvalidRequest;
        if (payload_val != .string) return error.InvalidRequest;
        const b64 = payload_val.string;

        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
        const bson_payload = try allocator.alloc(u8, decoded_len);
        defer allocator.free(bson_payload);
        try std.base64.standard.Decoder.decode(bson_payload, b64);

        const docs = try engine.queryDocs(store_ns, query_json);
        defer {
            for (docs) |doc| allocator.free(doc.value);
            allocator.free(docs);
        }

        if (docs.len == 0) {
            return Operation{ .Reply = .{ .status = .not_found, .data = null } };
        }

        const update_doc = try bson.BsonDocument.init(allocator, bson_payload, false);

        const update_fields = try update_doc.getFieldNames(allocator);
        defer {
            for (update_fields) |f| allocator.free(f);
            allocator.free(update_fields);
        }

        for (docs) |doc| {
            const existing = try bson.BsonDocument.init(allocator, doc.value, false);

            const existing_fields = try existing.getFieldNames(allocator);
            defer {
                for (existing_fields) |f| allocator.free(f);
                allocator.free(existing_fields);
            }

            var merged = bson.BsonDocument.empty(allocator);
            defer merged.deinit();

            for (existing_fields) |field_name| {
                var is_updated = false;
                for (update_fields) |uf| {
                    if (std.mem.eql(u8, field_name, uf)) {
                        is_updated = true;
                        break;
                    }
                }
                if (!is_updated) {
                    if (try existing.getField(field_name)) |val| {
                        try merged.put(field_name, val);
                    }
                }
            }

            for (update_fields) |field_name| {
                if (try update_doc.getField(field_name)) |val| {
                    try merged.put(field_name, val);
                }
            }

            try engine.put(store_ns, doc.key, merged.toBytes());
        }

        var count_doc = bson.BsonDocument.empty(allocator);
        defer count_doc.deinit();
        try count_doc.putInt64("updated", @intCast(docs.len));
        const count_bytes = count_doc.toBytes();
        return Operation{ .Reply = .{ .status = .ok, .data = try allocator.dupe(u8, count_bytes) } };
    }

    return error.InvalidRequest;
}

pub fn writeIdIntoBson(key: u128, src: []const u8, dst: []u8) void {
    const new_doc_len: u32 = @intCast(src.len + 42);
    std.mem.writeInt(u32, dst[0..4], new_doc_len, .little);

    var p: usize = 4;
    dst[p] = 0x02;
    p += 1;
    @memcpy(dst[p .. p + 4], "key\x00");
    p += 4;
    std.mem.writeInt(i32, dst[p..][0..4], 33, .little);
    p += 4;
    const hi: u64 = @truncate(key >> 64);
    const lo: u64 = @truncate(key);
    _ = std.fmt.bufPrint(dst[p .. p + 32], "{x:0>16}{x:0>16}", .{ hi, lo }) catch unreachable;
    p += 32;
    dst[p] = 0x00;
    p += 1;

    @memcpy(dst[p..], src[4..]);
}

fn hasAggregateField(query_json: []const u8) bool {
    return std.mem.indexOf(u8, query_json, "\"aggregate\"") != null;
}

fn hasCountField(query_json: []const u8) bool {
    return std.mem.indexOf(u8, query_json, "\"count\":true") != null;
}

fn hasMutationField(query_json: []const u8) bool {
    return std.mem.indexOf(u8, query_json, "\"mutation\"") != null;
}
