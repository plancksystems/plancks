const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("../common/common.zig");
const Entry = common.Entry;
const ParsedQuery = @import("../storage/query_engine.zig").ParsedQuery;
const query_engine = @import("../storage/query_engine.zig");
const FieldExtractor = @import("../storage/field_extractor.zig").FieldExtractor;
const FieldValue = @import("../storage/field_extractor.zig").FieldValue;
const bson = @import("bson");
const proto = @import("proto");

const q = @import("../storage/query_helpers.zig");
const matchesAllPredicates = q.matchesAllPredicates;
const matchesPredicate = q.matchesPredicate;
const compareByField = q.compareByField;
const applyProjection = q.applyProjection;
const compareByMultiFields = q.compareByMultiFields;

const AggregateResult = query_engine.AggregateResult;

const Engine = @import("engine.zig").Engine;
const log = std.log.scoped(.query_executor);

const MAX_AGGREGATE_GROUPS: usize = 1_000_000;

pub fn queryDocs(engine: *Engine, store_ns: []const u8, query_json: []const u8) ![]Entry {

    var parsed = try query_engine.parseJsonQuery(engine.allocator, query_json);
    defer parsed.deinit();

    engine.catalog_mutex.lock(engine.io);
    const store = engine.resolveStore(store_ns) catch |err| {
        engine.catalog_mutex.unlock(engine.io);
        return err;
    };
    const store_id = store.store_id;
    engine.catalog_mutex.unlock(engine.io);

    const actual_limit = parsed.limit orelse std.math.maxInt(u32);
    const actual_offset = parsed.offset;

    var results: std.ArrayList(Entry) = .empty;
    errdefer {
        for (results.items) |entry| {
            engine.allocator.free(entry.value);
        }
        results.deinit(engine.allocator);
    }

    const has_sort = parsed.sort_field != null or parsed.sort_fields.items.len > 0;
    if (has_sort) {
        const sort_fields_to_check: []const []const u8 = if (parsed.sort_fields.items.len > 0) blk: {
            var fields: std.ArrayList([]const u8) = .empty;
            for (parsed.sort_fields.items) |spec| {
                try fields.append(engine.allocator, spec.field);
            }
            break :blk try fields.toOwnedSlice(engine.allocator);
        } else if (parsed.sort_field) |sf| blk: {
            const slice = try engine.allocator.alloc([]const u8, 1);
            slice[0] = sf;
            break :blk slice;
        } else &[_][]const u8{};
        defer if (sort_fields_to_check.len > 0) engine.allocator.free(sort_fields_to_check);

        engine.catalog_mutex.lock(engine.io);
        var indexes = engine.catalog.getIndexesForStore(store_ns, engine.allocator) catch {
            engine.catalog_mutex.unlock(engine.io);
            return error.NoIndexOnField;
        };
        defer indexes.deinit(engine.allocator);
        engine.catalog_mutex.unlock(engine.io);

        for (sort_fields_to_check) |sort_field| {
            var found = false;
            for (indexes.items) |idx| {
                if (std.mem.eql(u8, idx.field, sort_field)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.NoIndexOnField;
        }

        {
            const sort_field = if (parsed.sort_fields.items.len >= 1) parsed.sort_fields.items[0].field else parsed.sort_field.?;
            const ascending = if (parsed.sort_fields.items.len >= 1) parsed.sort_fields.items[0].ascending else parsed.sort_ascending;
            const is_multi_sort = parsed.sort_fields.items.len > 1;

            engine.catalog_mutex.lock(engine.io);
            var idx_list = engine.catalog.getIndexesForStore(store_ns, engine.allocator) catch {
                engine.catalog_mutex.unlock(engine.io);
                return error.NoIndexOnField;
            };
            defer idx_list.deinit(engine.allocator);
            engine.catalog_mutex.unlock(engine.io);

            var index_ns: ?[]const u8 = null;
            for (idx_list.items) |idx| {
                if (std.mem.eql(u8, idx.field, sort_field)) {
                    index_ns = idx.ns;
                    break;
                }
            }

            var skip_orderby_index = false;
            if (index_ns != null and !ascending) {
                const has_predicates = parsed.predicates.items.len > 0 or parsed.or_predicates.items.len > 0;
                if (has_predicates) {
                    const filter_strategy = parsed.getBestIndexStrategy();
                    if (filter_strategy) |fs| {
                        const filter_field = switch (fs) {
                            .eq => |p| p.field_name,
                            .in_list => |il| il.field_name,
                            .range => |r| r.field_name,
                        };
                        const sort_field_name = if (parsed.sort_fields.items.len >= 1)
                            parsed.sort_fields.items[0].field
                        else
                            parsed.sort_field.?;
                        if (!std.mem.eql(u8, filter_field, sort_field_name)) {
                            skip_orderby_index = true;
                        }
                    }
                }
            }

            if (index_ns) |ins| {
                if (skip_orderby_index) {
                } else if (is_multi_sort) {
                    try indexOrderedScanForMultiSort(engine, &results, store_id, &parsed, ins, ascending, actual_limit, actual_offset);

                    const sort_specs = parsed.sort_fields.items;
                    std.sort.pdq(Entry, results.items, sort_specs, struct {
                        fn lessThan(specs: []const query_engine.SortSpec, a: Entry, b: Entry) bool {
                            return compareByMultiFields(a.value, b.value, specs);
                        }
                    }.lessThan);

                    if (actual_offset > 0 or actual_limit < std.math.maxInt(u32)) {
                        const start = @min(actual_offset, @as(u32, @intCast(results.items.len)));
                        const end = @min(start +| actual_limit, @as(u32, @intCast(results.items.len)));
                        for (results.items[0..start]) |entry| {
                            engine.allocator.free(entry.value);
                        }
                        for (results.items[end..]) |entry| {
                            engine.allocator.free(entry.value);
                        }
                        const kept = results.items[start..end];
                        std.mem.copyForwards(Entry, results.items[0..kept.len], kept);
                        results.shrinkRetainingCapacity(kept.len);
                    }
                } else if (!skip_orderby_index) {
                    try indexOrderedScan(engine, &results, store_id, &parsed, ins, ascending, actual_limit, actual_offset);
                }

                if (!skip_orderby_index) {
                    if (parsed.projection_fields) |proj_fields| {
                        for (results.items) |*entry| {
                            const projected = applyProjection(engine.allocator, entry.value, proj_fields) catch continue;
                            engine.allocator.free(entry.value);
                            entry.value = projected;
                        }
                    }

                    return results.toOwnedSlice(engine.allocator);
                }
            }
        }
    }

    const collect_limit: u32 = if (has_sort) std.math.maxInt(u32) else actual_limit;
    const collect_offset: u32 = if (has_sort) 0 else actual_offset;
    const sort_target_k: u32 = if (has_sort and actual_limit < std.math.maxInt(u32))
        actual_offset +| actual_limit
    else
        std.math.maxInt(u32);

    const strategy = parsed.getBestIndexStrategy();

    var used_index = false;

    var seen_keys = std.AutoHashMap(u128, void).init(engine.allocator);
    defer seen_keys.deinit();

    if (strategy) |strat| {
        const target_field: []const u8 = switch (strat) {
            .eq => |pred| pred.field_name,
            .range => |r| r.field_name,
            .in_list => |il| il.field_name,
        };

        engine.catalog_mutex.lock(engine.io);
        var indexes = engine.catalog.getIndexesForStore(store_ns, engine.allocator) catch {
            engine.catalog_mutex.unlock(engine.io);
            try fullScanWithFilter(engine, &results, store_id, &parsed, collect_limit, collect_offset, sort_target_k);
            return results.toOwnedSlice(engine.allocator);
        };
        defer indexes.deinit(engine.allocator);
        engine.catalog_mutex.unlock(engine.io);

        var found_index: ?[]const u8 = null;
        var found_field_type_q: ?proto.FieldType = null;
        for (indexes.items) |idx| {
            if (std.mem.eql(u8, idx.field, target_field)) {
                found_index = idx.ns;
                found_field_type_q = idx.field_type;
                break;
            }
        }

        if (found_index) |index_ns| {
            if (found_field_type_q) |ft| {
                if (ft == .String) {
                    switch (strat) {
                        .range => return error.InvalidFieldType,
                        else => {},
                    }
                }
            }

            const strategy_name: []const u8 = switch (strat) {
                .eq => "eq",
                .range => "range",
                .in_list => "in",
            };
            _ = strategy_name;

            var skipped: u32 = 0;
            var count: u32 = 0;

            {
                engine.db_mutex.lock(engine.io);
                defer engine.db_mutex.unlock(engine.io);

                var active_iter = engine.db.memtable.active.iterator();
                while (active_iter.next()) |entry| {
                    if (count >= collect_limit) break;
                    const ks = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                    if (ks != store_id) continue;
                    try seen_keys.put(entry.key, {});
                    if (entry.kind == .delete) continue;
                    if (!matchesAllPredicates(entry.value, &parsed)) continue;
                    if (skipped < collect_offset) {
                        skipped += 1;
                        continue;
                    }
                    const value_copy = try engine.allocator.dupe(u8, entry.value);
                    try results.append(engine.allocator, Entry{
                        .lsn = entry.lsn,
                        .key = entry.key,
                        .value = value_copy,
                        .timestamp = entry.timestamp,
                        .kind = .read,
                    });
                    count += 1;
                }

                var lists_iter = engine.db.memtable.lists.iterator();
                while (lists_iter.next()) |skl| {
                    var skl_iter = skl.iterator();
                    while (skl_iter.next()) |entry| {
                        if (count >= collect_limit) break;
                        const ks = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                        if (ks != store_id) continue;
                        if (seen_keys.contains(entry.key)) continue;
                        try seen_keys.put(entry.key, {});
                        if (entry.kind == .delete) continue;
                        if (!matchesAllPredicates(entry.value, &parsed)) continue;
                        if (skipped < collect_offset) {
                            skipped += 1;
                            continue;
                        }
                        const value_copy = try engine.allocator.dupe(u8, entry.value);
                        try results.append(engine.allocator, Entry{
                            .lsn = entry.lsn,
                            .key = entry.key,
                            .value = value_copy,
                            .timestamp = entry.timestamp,
                            .kind = .read,
                        });
                        count += 1;
                    }
                }
            }

            engine.db_mutex.lock(engine.io);
            var primary_keys = switch (strat) {
                .eq => |pred| engine.db.findBySecondaryIndex(index_ns, pred.value) catch |err| {
                    engine.db_mutex.unlock(engine.io);
                    log.warn("queryDocs: index eq lookup failed: {}, falling back to full scan", .{err});
                    try fullScanWithFilter(engine, &results, store_id, &parsed, collect_limit, collect_offset, sort_target_k);
                    return results.toOwnedSlice(engine.allocator);
                },
                .range => |r| engine.db.findBySecondaryIndexRange(index_ns, r.min_val, r.max_val, r.min_inclusive, r.max_inclusive) catch |err| {
                    engine.db_mutex.unlock(engine.io);
                    log.warn("queryDocs: index range scan failed: {}, falling back to full scan", .{err});
                    try fullScanWithFilter(engine, &results, store_id, &parsed, collect_limit, collect_offset, sort_target_k);
                    return results.toOwnedSlice(engine.allocator);
                },
                .in_list => |il| engine.db.findBySecondaryIndexMulti(index_ns, il.values) catch |err| {
                    engine.db_mutex.unlock(engine.io);
                    log.warn("queryDocs: index multi-lookup failed: {}, falling back to full scan", .{err});
                    try fullScanWithFilter(engine, &results, store_id, &parsed, collect_limit, collect_offset, sort_target_k);
                    return results.toOwnedSlice(engine.allocator);
                },
            };
            defer primary_keys.deinit(engine.allocator);

            for (primary_keys.items) |key| {
                if (count >= collect_limit) break;
                if (seen_keys.contains(key)) continue;

                const value = engine.db.get(key) catch continue;
                defer engine.allocator.free(value);

                if (!matchesAllPredicates(value, &parsed)) continue;

                if (skipped < collect_offset) {
                    skipped += 1;
                    continue;
                }

                const value_copy = try engine.allocator.dupe(u8, value);
                try results.append(engine.allocator, Entry{
                    .lsn = 0,
                    .key = key,
                    .value = value_copy,
                    .timestamp = engine.now.toMilliSeconds(),
                    .kind = .read,
                });
                count += 1;
                maybeTrimTopK(engine, &results, &parsed, sort_target_k, &count);
            }
            engine.db_mutex.unlock(engine.io);
            used_index = true;
        }
    }

    if (!used_index) {
        try fullScanWithFilter(engine, &results, store_id, &parsed, collect_limit, collect_offset, sort_target_k);
    }

    if (parsed.sort_fields.items.len > 1) {
        const sort_specs = parsed.sort_fields.items;
        const items = results.items;
        std.sort.pdq(Entry, items, sort_specs, struct {
            fn lessThan(specs: []const query_engine.SortSpec, a: Entry, b: Entry) bool {
                return compareByMultiFields(a.value, b.value, specs);
            }
        }.lessThan);

        if (actual_offset > 0 or actual_limit < std.math.maxInt(u32)) {
            const start = @min(actual_offset, @as(u32, @intCast(results.items.len)));
            const end = @min(start +| actual_limit, @as(u32, @intCast(results.items.len)));
            for (results.items[0..start]) |entry| {
                engine.allocator.free(entry.value);
            }
            for (results.items[end..]) |entry| {
                engine.allocator.free(entry.value);
            }
            const kept = results.items[start..end];
            std.mem.copyForwards(Entry, results.items[0..kept.len], kept);
            results.shrinkRetainingCapacity(kept.len);
        }
    } else if (parsed.sort_field) |sort_field| {
        const asc = parsed.sort_ascending;
        const items = results.items;
        std.sort.pdq(Entry, items, SortContext{ .field = sort_field, .ascending = asc }, struct {
            fn lessThan(ctx: SortContext, a: Entry, b: Entry) bool {
                return compareByField(a.value, b.value, ctx.field, ctx.ascending);
            }
        }.lessThan);

        if (actual_offset > 0 or actual_limit < std.math.maxInt(u32)) {
            const start = @min(actual_offset, @as(u32, @intCast(results.items.len)));
            const end = @min(start +| actual_limit, @as(u32, @intCast(results.items.len)));
            for (results.items[0..start]) |entry| {
                engine.allocator.free(entry.value);
            }
            for (results.items[end..]) |entry| {
                engine.allocator.free(entry.value);
            }
            const kept = results.items[start..end];
            std.mem.copyForwards(Entry, results.items[0..kept.len], kept);
            results.shrinkRetainingCapacity(kept.len);
        }
    }

    if (parsed.projection_fields) |proj_fields| {
        for (results.items) |*entry| {
            const projected = applyProjection(engine.allocator, entry.value, proj_fields) catch continue;
            engine.allocator.free(entry.value);
            entry.value = projected;
        }
    }

    return results.toOwnedSlice(engine.allocator);
}

fn maybeTrimTopK(engine: *Engine, results: *std.ArrayList(Entry), parsed: *const ParsedQuery, sort_target_k: u32, count: *u32) void {
    if (sort_target_k == std.math.maxInt(u32) or count.* < sort_target_k *| 2) return;

    if (parsed.sort_fields.items.len > 1) {
        std.sort.pdq(Entry, results.items, parsed.sort_fields.items, struct {
            fn lessThan(specs: []const query_engine.SortSpec, a: Entry, b: Entry) bool {
                return compareByMultiFields(a.value, b.value, specs);
            }
        }.lessThan);
    } else if (parsed.sort_field) |sf| {
        std.sort.pdq(Entry, results.items, SortContext{ .field = sf, .ascending = parsed.sort_ascending }, struct {
            fn lessThan(ctx: SortContext, a: Entry, b: Entry) bool {
                return compareByField(a.value, b.value, ctx.field, ctx.ascending);
            }
        }.lessThan);
    } else return;

    for (results.items[sort_target_k..]) |entry| engine.allocator.free(entry.value);
    results.shrinkRetainingCapacity(sort_target_k);
    count.* = sort_target_k;
}

fn fullScanWithFilter(engine: *Engine, results: *std.ArrayList(Entry), store_id: u16, parsed: *const ParsedQuery, limit: u32, offset: u32, sort_target_k: u32) !void {
    const after_key = parsed.after_key;
    var seen_keys = std.AutoHashMap(u128, void).init(engine.allocator);
    defer seen_keys.deinit();

    var skipped: u32 = 0;
    var count: u32 = 0;

    var memtable_total: u32 = 0;
    var memtable_matched: u32 = 0;

    {
        engine.db_mutex.lock(engine.io);
        defer engine.db_mutex.unlock(engine.io);

        var active_iter = engine.db.memtable.active.iterator();
        while (active_iter.next()) |entry| {
            memtable_total += 1;
            if (count >= limit) break;

            const key_store_id = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
            if (key_store_id != store_id) continue;
            memtable_matched += 1;

            if (entry.kind == .delete) continue;

            if (after_key) |ak| {
                if (entry.key <= ak) continue;
            }

            try seen_keys.put(entry.key, {});

            if (!matchesAllPredicates(entry.value, parsed)) continue;

            if (skipped < offset) {
                skipped += 1;
                continue;
            }

            const value_copy = try engine.allocator.dupe(u8, entry.value);

            try results.append(engine.allocator, Entry{
                .lsn = 0,
                .key = entry.key,
                .value = value_copy,
                .timestamp = engine.now.toMilliSeconds(),
                .kind = .read,
            });
            count += 1;
            maybeTrimTopK(engine, results, parsed, sort_target_k, &count);
        }

        var lists_iter = engine.db.memtable.lists.iterator();
        while (lists_iter.next()) |skl| {
            if (count >= limit) break;

            var skl_iter = skl.iterator();
            while (skl_iter.next()) |entry| {
                if (count >= limit) break;

                const key_store_id = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                if (key_store_id != store_id) continue;

                if (entry.kind == .delete) continue;

                if (after_key) |ak| {
                    if (entry.key <= ak) continue;
                }

                if (seen_keys.contains(entry.key)) continue;
                try seen_keys.put(entry.key, {});

                if (!matchesAllPredicates(entry.value, parsed)) continue;

                if (skipped < offset) {
                    skipped += 1;
                    continue;
                }

                const value_copy = try engine.allocator.dupe(u8, entry.value);

                try results.append(engine.allocator, Entry{
                    .lsn = 0,
                    .key = entry.key,
                    .value = value_copy,
                    .timestamp = engine.now.toMilliSeconds(),
                    .kind = .read,
                });
                count += 1;
                maybeTrimTopK(engine, results, parsed, sort_target_k, &count);
            }
        }
    }

    var index_total: u32 = 0;
    var index_matched: u32 = 0;
    if (count < limit) {
        engine.primary_index_mutex.lock(engine.io);
        defer engine.primary_index_mutex.unlock(engine.io);

        var it = if (after_key) |ak|
            try engine.primary_index.prefetchIteratorAfter(ak)
        else
            try engine.primary_index.prefetchIterator();
        defer it.deinit();

        while (try it.next()) |cell| {
            index_total += 1;
            if (count >= limit) break;

            const key = std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big);

            const key_store_id = @as(u16, @intCast((key >> 112) & 0xFFFF));
            if (key_store_id != store_id) continue;
            index_matched += 1;

            if (seen_keys.contains(key)) continue;

            const has_predicates = parsed.predicates.items.len > 0 or parsed.or_predicates.items.len > 0;
            if (skipped < offset and !has_predicates) {
                skipped += 1;
                continue;
            }

            const vlog_offset = std.mem.readInt(u64, cell.value[0..@sizeOf(u64)], .little);

            engine.db_mutex.lock(engine.io);
            const value = engine.db.getByOffset(@bitCast(key), vlog_offset) catch |err| {
                engine.db_mutex.unlock(engine.io);
                log.warn("Failed to read key={x}: {}", .{ key, err });
                continue;
            };
            engine.db_mutex.unlock(engine.io);

            if (!matchesAllPredicates(value, parsed)) {
                engine.allocator.free(value);
                continue;
            }

            if (skipped < offset) {
                skipped += 1;
                engine.allocator.free(value);
                continue;
            }

            try results.append(engine.allocator, Entry{
                .lsn = 0,
                .key = key,
                .value = value,
                .timestamp = engine.now.toMilliSeconds(),
                .kind = .read,
            });
            count += 1;
            maybeTrimTopK(engine, results, parsed, sort_target_k, &count);
        }
    }
}

fn indexOrderedScan(engine: *Engine, results: *std.ArrayList(Entry), store_id: u16, parsed: *const ParsedQuery, index_ns: []const u8, ascending: bool, limit: u32, offset: u32) !void {
    const has_predicates = parsed.predicates.items.len > 0 or parsed.or_predicates.items.len > 0;

    {
        engine.db_mutex.lock(engine.io);
        var primary_keys = engine.db.findBySecondaryIndexRange(index_ns, null, null, true, true) catch |err| {
            engine.db_mutex.unlock(engine.io);
            return err;
        };
        defer primary_keys.deinit(engine.allocator);
        engine.db_mutex.unlock(engine.io);

        if (!ascending) std.mem.reverse(u128, primary_keys.items);

        var skipped: u32 = 0;
        var count: u32 = 0;

        for (primary_keys.items) |key| {
            if (count >= limit) break;

            const ks = @as(u16, @intCast((key >> 112) & 0xFFFF));
            if (ks != store_id) continue;

            if (skipped < offset and !has_predicates) {
                skipped += 1;
                continue;
            }

            engine.db_mutex.lock(engine.io);
            const value = engine.db.get(key) catch {
                engine.db_mutex.unlock(engine.io);
                continue;
            };
            engine.db_mutex.unlock(engine.io);

            if (has_predicates and !matchesAllPredicates(value, parsed)) {
                engine.allocator.free(value);
                continue;
            }

            if (skipped < offset) {
                skipped += 1;
                engine.allocator.free(value);
                continue;
            }

            try results.append(engine.allocator, Entry{
                .lsn = 0,
                .key = key,
                .value = value,
                .timestamp = engine.now.toMilliSeconds(),
                .kind = .read,
            });
            count += 1;
        }
    }
}

fn indexOrderedScanForMultiSort(engine: *Engine, results: *std.ArrayList(Entry), store_id: u16, parsed: *const ParsedQuery, index_ns: []const u8, ascending: bool, limit: u32, offset: u32) !void {
    const has_predicates = parsed.predicates.items.len > 0 or parsed.or_predicates.items.len > 0;
    const target_count: u32 = offset +| limit;
    const primary_sort_field = parsed.sort_fields.items[0].field;
    const primary_ascending = parsed.sort_fields.items[0].ascending;

    {
        engine.db_mutex.lock(engine.io);
        var primary_keys = engine.db.findBySecondaryIndexRange(index_ns, null, null, true, true) catch |err| {
            engine.db_mutex.unlock(engine.io);
            return err;
        };
        defer primary_keys.deinit(engine.allocator);
        engine.db_mutex.unlock(engine.io);

        if (!ascending) std.mem.reverse(u128, primary_keys.items);

        var count: u32 = 0;
        var collecting_tie_group = false;

        for (primary_keys.items) |key| {
            const ks = @as(u16, @intCast((key >> 112) & 0xFFFF));
            if (ks != store_id) continue;

            engine.db_mutex.lock(engine.io);
            const value = engine.db.get(key) catch {
                engine.db_mutex.unlock(engine.io);
                continue;
            };
            engine.db_mutex.unlock(engine.io);

            if (has_predicates and !matchesAllPredicates(value, parsed)) {
                engine.allocator.free(value);
                continue;
            }

            if (count >= target_count and !collecting_tie_group) {
                collecting_tie_group = true;
            }

            if (collecting_tie_group) {
                if (results.items.len > 0) {
                    const last_value = results.items[results.items.len - 1].value;
                    const a_lt_b = compareByField(last_value, value, primary_sort_field, primary_ascending);
                    const b_lt_a = compareByField(value, last_value, primary_sort_field, primary_ascending);
                    if (a_lt_b or b_lt_a) {
                        engine.allocator.free(value);
                        break;
                    }
                }
            }

            try results.append(engine.allocator, Entry{
                .lsn = 0,
                .key = key,
                .value = value,
                .timestamp = engine.now.toMilliSeconds(),
                .kind = .read,
            });
            count += 1;
        }
    }
}

fn allPredicatesCoveredByStrategy(parsed: *const ParsedQuery, strat: ParsedQuery.IndexStrategy) bool {
    if (parsed.or_predicates.items.len > 0) return false;

    const index_field = switch (strat) {
        .eq => |p| p.field_name,
        .range => |r| r.field_name,
        .in_list => |il| il.field_name,
    };

    for (parsed.predicates.items) |pred| {
        if (!std.mem.eql(u8, pred.field_name, index_field)) return false;
    }
    return true;
}

pub fn countDocs(engine: *Engine, store_ns: []const u8, query_json: []const u8) !u64 {
    var parsed = try query_engine.parseJsonQuery(engine.allocator, query_json);
    defer parsed.deinit();

    engine.catalog_mutex.lock(engine.io);
    const store = engine.resolveStore(store_ns) catch |err| {
        engine.catalog_mutex.unlock(engine.io);
        return err;
    };
    const store_id = store.store_id;
    engine.catalog_mutex.unlock(engine.io);

    const actual_limit: u64 = if (parsed.limit) |lim| @as(u64, lim) else std.math.maxInt(u64);
    const actual_offset: u64 = @as(u64, parsed.offset);

    const strategy = parsed.getBestIndexStrategy();

    var seen_keys = std.AutoHashMap(u128, void).init(engine.allocator);
    defer seen_keys.deinit();

    var count: u64 = 0;

    if (strategy) |strat| {
        const target_field: []const u8 = switch (strat) {
            .eq => |pred| pred.field_name,
            .range => |r| r.field_name,
            .in_list => |il| il.field_name,
        };

        engine.catalog_mutex.lock(engine.io);
        var indexes = engine.catalog.getIndexesForStore(store_ns, engine.allocator) catch {
            engine.catalog_mutex.unlock(engine.io);
            return error.NoIndexOnField;
        };
        defer indexes.deinit(engine.allocator);
        engine.catalog_mutex.unlock(engine.io);

        var found_index: ?[]const u8 = null;
        var found_field_type: ?proto.FieldType = null;
        for (indexes.items) |idx| {
            if (std.mem.eql(u8, idx.field, target_field)) {
                found_index = idx.ns;
                found_field_type = idx.field_type;
                break;
            }
        }
        const index_ns = found_index orelse return error.NoIndexOnField;

        if (found_field_type) |ft| {
            if (ft == .String) {
                switch (strat) {
                    .range => return error.InvalidFieldType,
                    else => {},
                }
            }
        }

        {
            engine.db_mutex.lock(engine.io);
            defer engine.db_mutex.unlock(engine.io);

            var active_iter = engine.db.memtable.active.iterator();
            while (active_iter.next()) |entry| {
                const ks = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                if (ks != store_id) continue;
                try seen_keys.put(entry.key, {});
                if (entry.kind == .delete) continue;
                if (matchesAllPredicates(entry.value, &parsed)) count += 1;
            }

            var lists_iter = engine.db.memtable.lists.iterator();
            while (lists_iter.next()) |skl| {
                var skl_iter = skl.iterator();
                while (skl_iter.next()) |entry| {
                    const ks = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                    if (ks != store_id) continue;
                    if (seen_keys.contains(entry.key)) continue;
                    try seen_keys.put(entry.key, {});
                    if (entry.kind == .delete) continue;
                    if (matchesAllPredicates(entry.value, &parsed)) count += 1;
                }
            }
        }

        {
            engine.db_mutex.lock(engine.io);

            if (allPredicatesCoveredByStrategy(&parsed, strat)) {
                var primary_keys = switch (strat) {
                    .eq => |pred| engine.db.findBySecondaryIndex(index_ns, pred.value) catch {
                        engine.db_mutex.unlock(engine.io);
                        if (actual_offset >= count) return 0;
                        return @min(count - actual_offset, actual_limit);
                    },
                    .range => |r| engine.db.findBySecondaryIndexRange(index_ns, r.min_val, r.max_val, r.min_inclusive, r.max_inclusive) catch {
                        engine.db_mutex.unlock(engine.io);
                        if (actual_offset >= count) return 0;
                        return @min(count - actual_offset, actual_limit);
                    },
                    .in_list => |il| engine.db.findBySecondaryIndexMulti(index_ns, il.values) catch {
                        engine.db_mutex.unlock(engine.io);
                        if (actual_offset >= count) return 0;
                        return @min(count - actual_offset, actual_limit);
                    },
                };
                defer primary_keys.deinit(engine.allocator);

                for (primary_keys.items) |pk| {
                    if (!seen_keys.contains(pk)) count += 1;
                }
            } else {
                var primary_keys = switch (strat) {
                    .eq => |pred| engine.db.findBySecondaryIndex(index_ns, pred.value) catch {
                        engine.db_mutex.unlock(engine.io);
                        if (actual_offset >= count) return 0;
                        return @min(count - actual_offset, actual_limit);
                    },
                    .range => |r| engine.db.findBySecondaryIndexRange(index_ns, r.min_val, r.max_val, r.min_inclusive, r.max_inclusive) catch {
                        engine.db_mutex.unlock(engine.io);
                        if (actual_offset >= count) return 0;
                        return @min(count - actual_offset, actual_limit);
                    },
                    .in_list => |il| engine.db.findBySecondaryIndexMulti(index_ns, il.values) catch {
                        engine.db_mutex.unlock(engine.io);
                        if (actual_offset >= count) return 0;
                        return @min(count - actual_offset, actual_limit);
                    },
                };
                defer primary_keys.deinit(engine.allocator);

                for (primary_keys.items) |pk| {
                    if (seen_keys.contains(pk)) continue;
                    const value = engine.db.get(pk) catch continue;
                    defer engine.allocator.free(value);
                    if (matchesAllPredicates(value, &parsed)) count += 1;
                }
            }
            engine.db_mutex.unlock(engine.io);
        }
    } else if (parsed.predicates.items.len > 0 or parsed.or_predicates.items.len > 0) {
        {
            engine.db_mutex.lock(engine.io);
            defer engine.db_mutex.unlock(engine.io);

            var active_iter = engine.db.memtable.active.iterator();
            while (active_iter.next()) |entry| {
                const ks = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                if (ks != store_id) continue;
                try seen_keys.put(entry.key, {});
                if (entry.kind == .delete) continue;
                if (matchesAllPredicates(entry.value, &parsed)) count += 1;
            }

            var lists_iter = engine.db.memtable.lists.iterator();
            while (lists_iter.next()) |skl| {
                var skl_iter = skl.iterator();
                while (skl_iter.next()) |entry| {
                    const ks = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                    if (ks != store_id) continue;
                    if (seen_keys.contains(entry.key)) continue;
                    try seen_keys.put(entry.key, {});
                    if (entry.kind == .delete) continue;
                    if (matchesAllPredicates(entry.value, &parsed)) count += 1;
                }
            }
        }

        {
            engine.primary_index_mutex.lock(engine.io);
            defer engine.primary_index_mutex.unlock(engine.io);

            var it = try engine.primary_index.prefetchIterator();
            defer it.deinit();

            while (try it.next()) |cell| {
                const key = std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big);
                const ks = @as(u16, @intCast((key >> 112) & 0xFFFF));
                if (ks != store_id) continue;
                if (seen_keys.contains(key)) continue;

                const vlog_offset = std.mem.readInt(u64, cell.value[0..@sizeOf(u64)], .little);

                engine.db_mutex.lock(engine.io);
                const value = engine.db.getByOffset(@bitCast(key), vlog_offset) catch {
                    engine.db_mutex.unlock(engine.io);
                    continue;
                };
                engine.db_mutex.unlock(engine.io);
                defer engine.allocator.free(value);

                if (matchesAllPredicates(value, &parsed)) count += 1;
            }
        }
    } else {
        {
            engine.db_mutex.lock(engine.io);
            defer engine.db_mutex.unlock(engine.io);

            var active_iter = engine.db.memtable.active.iterator();
            while (active_iter.next()) |entry| {
                const ks = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                if (ks != store_id) continue;
                try seen_keys.put(entry.key, {});
                if (entry.kind != .delete) count += 1;
            }

            var lists_iter = engine.db.memtable.lists.iterator();
            while (lists_iter.next()) |skl| {
                var skl_iter = skl.iterator();
                while (skl_iter.next()) |entry| {
                    const ks = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                    if (ks != store_id) continue;
                    if (seen_keys.contains(entry.key)) continue;
                    try seen_keys.put(entry.key, {});
                    if (entry.kind != .delete) count += 1;
                }
            }
        }

        {
            engine.primary_index_mutex.lock(engine.io);
            defer engine.primary_index_mutex.unlock(engine.io);

            var it = try engine.primary_index.prefetchIterator();
            defer it.deinit();

            while (try it.next()) |cell| {
                const key = std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big);
                const ks = @as(u16, @intCast((key >> 112) & 0xFFFF));
                if (ks != store_id) continue;
                if (!seen_keys.contains(key)) count += 1;
            }
        }
    }

    if (actual_offset >= count) return 0;
    const after_skip = count - actual_offset;
    return @min(after_skip, actual_limit);
}

const SortContext = struct {
    field: []const u8,
    ascending: bool,
};

pub fn scanDocs(engine: *Engine, start_key: ?u128, limit_count: u32, skip_count: u32) ![]Entry {
    const seek_key = start_key orelse 0;

    engine.primary_index_mutex.lock(engine.io);
    defer engine.primary_index_mutex.unlock(engine.io);
    engine.db_mutex.lock(engine.io);
    defer engine.db_mutex.unlock(engine.io);

    const has_inactive = engine.db.memtable.lists.len > 0;

    if (!has_inactive) {
        var active_iter = engine.db.memtable.active.seekIterator(seek_key);

        const btree_populated = engine.btree_has_data.load(.acquire);

        if (!btree_populated) {
            var active_peek: ?Entry = active_iter.next();
            while (active_peek != null and active_peek.?.kind == .delete) {
                active_peek = active_iter.next();
            }

            var skipped: usize = 0;
            while (skipped < skip_count) {
                if (active_peek == null) break;
                active_peek = active_iter.next();
                while (active_peek != null and active_peek.?.kind == .delete) {
                    active_peek = active_iter.next();
                }
                skipped += 1;
            }

            var results: std.ArrayList(Entry) = .empty;
            errdefer {
                for (results.items) |entry| {
                    engine.allocator.free(entry.value);
                }
                results.deinit(engine.allocator);
            }

            var count: usize = 0;
            while (count < limit_count) {
                const entry = active_peek orelse break;
                if (entry.kind == .delete) {
                    active_peek = active_iter.next();
                    continue;
                }
                const value = try engine.allocator.dupe(u8, entry.value);
                try results.append(engine.allocator, Entry{
                    .lsn = 0,
                    .key = entry.key,
                    .value = value,
                    .timestamp = engine.now.toMilliSeconds(),
                    .kind = .read,
                });
                count += 1;
                active_peek = active_iter.next();
            }

            return results.toOwnedSlice(engine.allocator);
        }

        var start_key_buf: [@sizeOf(u128)]u8 = undefined;
        std.mem.writeInt(u128, &start_key_buf, seek_key, .big);
        var btree_iter = try engine.primary_index.tree.rangeScan(&start_key_buf, null);
        defer btree_iter.deinit();

        var btree_peek: ?u128 = if (try btree_iter.next()) |cell|
            std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big)
        else
            null;

        var active_peek: ?Entry = active_iter.next();

        while (active_peek != null and active_peek.?.kind == .delete) {
            active_peek = active_iter.next();
        }

        var results: std.ArrayList(Entry) = .empty;
        errdefer {
            for (results.items) |entry| {
                engine.allocator.free(entry.value);
            }
            results.deinit(engine.allocator);
        }

        var collected: usize = 0;
        const total_needed: usize = @as(usize, skip_count) + @as(usize, limit_count);

        while (collected < total_needed) {
            const chosen_from_mem = if (active_peek != null and btree_peek != null)
                active_peek.?.key <= btree_peek.?
            else if (active_peek != null)
                true
            else if (btree_peek != null)
                false
            else
                break;

            const chosen_key = if (chosen_from_mem) active_peek.?.key else btree_peek.?;

            if (chosen_from_mem) {
                const chosen_value = active_peek.?.value;
                if (btree_peek != null and btree_peek.? == chosen_key) {
                    btree_peek = if (try btree_iter.next()) |cell|
                        std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big)
                    else
                        null;
                }
                active_peek = active_iter.next();
                while (active_peek != null and active_peek.?.kind == .delete) {
                    active_peek = active_iter.next();
                }

                collected += 1;
                if (collected > skip_count) {
                    const value = try engine.allocator.dupe(u8, chosen_value);
                    try results.append(engine.allocator, Entry{
                        .lsn = 0,
                        .key = chosen_key,
                        .value = value,
                        .timestamp = engine.now.toMilliSeconds(),
                        .kind = .read,
                    });
                }
            } else {
                if (active_peek != null and active_peek.?.key == chosen_key) {
                    const mem_value = active_peek.?.value;
                    active_peek = active_iter.next();
                    while (active_peek != null and active_peek.?.kind == .delete) {
                        active_peek = active_iter.next();
                    }
                    btree_peek = if (try btree_iter.next()) |cell|
                        std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big)
                    else
                        null;
                    collected += 1;
                    if (collected > skip_count) {
                        const value = try engine.allocator.dupe(u8, mem_value);
                        try results.append(engine.allocator, Entry{
                            .lsn = 0,
                            .key = chosen_key,
                            .value = value,
                            .timestamp = engine.now.toMilliSeconds(),
                            .kind = .read,
                        });
                    }
                    continue;
                }
                btree_peek = if (try btree_iter.next()) |cell|
                    std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big)
                else
                    null;

                collected += 1;
                if (collected > skip_count) {
                    const value = engine.db.get(@bitCast(chosen_key)) catch continue;
                    try results.append(engine.allocator, Entry{
                        .lsn = 0,
                        .key = chosen_key,
                        .value = value,
                        .timestamp = engine.now.toMilliSeconds(),
                        .kind = .read,
                    });
                }
            }
        }

        return results.toOwnedSlice(engine.allocator);
    }

    var active_iter = engine.db.memtable.active.seekIterator(seek_key);

    const SkipListIter = @TypeOf(active_iter);
    var inactive_iters_buf: [8]SkipListIter = undefined;
    var inactive_peeks_buf: [8]?Entry = undefined;
    var num_inactive: usize = 0;

    var list_iter = engine.db.memtable.lists.iterator();
    while (list_iter.next()) |skiplist| {
        if (num_inactive < 8) {
            inactive_iters_buf[num_inactive] = skiplist.seekIterator(seek_key);
            num_inactive += 1;
        }
    }

    for (0..num_inactive) |i| {
        inactive_peeks_buf[i] = inactive_iters_buf[i].next();
    }

    var start_key_buf: [@sizeOf(u128)]u8 = undefined;
    std.mem.writeInt(u128, &start_key_buf, seek_key, .big);
    var btree_iter = try engine.primary_index.tree.rangeScan(&start_key_buf, null);
    defer btree_iter.deinit();

    var active_peek: ?Entry = active_iter.next();
    var btree_peek: ?u128 = if (try btree_iter.next()) |cell|
        std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big)
    else
        null;

    var results: std.ArrayList(Entry) = .empty;
    errdefer {
        for (results.items) |entry| {
            engine.allocator.free(entry.value);
        }
        results.deinit(engine.allocator);
    }

    var collected: usize = 0;
    const total_needed: usize = @as(usize, skip_count) + @as(usize, limit_count);
    var last_key: ?u128 = null;

    while (collected < total_needed) {
        var min_key: ?u128 = null;

        if (active_peek) |e| {
            if (e.kind != .delete) {
                min_key = e.key;
            }
        }
        for (inactive_peeks_buf[0..num_inactive]) |maybe_e| {
            if (maybe_e) |e| {
                if (e.kind != .delete) {
                    if (min_key == null or e.key < min_key.?) min_key = e.key;
                }
            }
        }
        if (btree_peek) |bk| {
            if (min_key == null or bk < min_key.?) min_key = bk;
        }

        if (min_key == null) {
            var any_left = false;
            if (active_peek) |e| {
                if (e.kind == .delete) {
                    active_peek = active_iter.next();
                    any_left = true;
                }
            }
            for (0..num_inactive) |i| {
                if (inactive_peeks_buf[i]) |e| {
                    if (e.kind == .delete) {
                        inactive_peeks_buf[i] = inactive_iters_buf[i].next();
                        any_left = true;
                    }
                }
            }
            if (!any_left) break;
            continue;
        }

        const mk = min_key.?;

        if (active_peek) |e| {
            if (e.key == mk) active_peek = active_iter.next();
        }
        for (0..num_inactive) |i| {
            if (inactive_peeks_buf[i]) |e| {
                if (e.key == mk) inactive_peeks_buf[i] = inactive_iters_buf[i].next();
            }
        }
        if (btree_peek) |bk| {
            if (bk == mk) {
                btree_peek = if (try btree_iter.next()) |cell|
                    std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big)
                else
                    null;
            }
        }

        if (last_key != null and last_key.? == mk) continue;
        last_key = mk;

        collected += 1;
        if (collected > skip_count) {
            const value = engine.db.get(@bitCast(mk)) catch continue;
            try results.append(engine.allocator, Entry{
                .lsn = 0,
                .key = mk,
                .value = value,
                .timestamp = engine.now.toMilliSeconds(),
                .kind = .read,
            });
        }
    }

    return results.toOwnedSlice(engine.allocator);
}
pub fn aggregateDocs(engine: *Engine, store_ns: []const u8, query_json: []const u8) ![]u8 {
    const GroupAccumulator = query_engine.GroupAccumulator;

    var parsed = query_engine.parseJsonQuery(engine.allocator, query_json) catch |err| {
        return err;
    };
    defer parsed.deinit();

    engine.catalog_mutex.lock(engine.io);
    const store = engine.resolveStore(store_ns) catch |err| {
        engine.catalog_mutex.unlock(engine.io);
        return err;
    };
    const store_id = store.store_id;
    engine.catalog_mutex.unlock(engine.io);

    var groups = std.StringHashMap(GroupAccumulator).init(engine.allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            engine.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        groups.deinit();
    }

    var extractor = FieldExtractor.init(engine.allocator);

    var seen_keys = std.AutoHashMap(u128, void).init(engine.allocator);
    defer seen_keys.deinit();

    const processDoc = struct {
        fn process(allocator: std.mem.Allocator, value: []const u8, p: *const query_engine.ParsedQuery, g: *std.StringHashMap(GroupAccumulator), ext: *FieldExtractor, self_ptr: *Engine) !void {
            var matches = true;
            for (p.predicates.items) |pred| {
                if (!matchesPredicate(value, pred)) {
                    matches = false;
                    break;
                }
            }
            if (!matches) return;

            const group_key = computeGroupKey(self_ptr, value, p.group_by_fields, ext) catch |err| {
                return err;
            };
            defer allocator.free(group_key);

            if (g.count() >= MAX_AGGREGATE_GROUPS and g.get(group_key) == null)
                return error.AggregateGroupLimitExceeded;

            const gop = try g.getOrPut(group_key);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, group_key);
                gop.value_ptr.* = GroupAccumulator.init(allocator);
            }

            for (p.aggregations.items) |agg| {
                const field_value: ?FieldValue = if (agg.field_name) |fn_name| blk: {
                    if (ext.extractI64(value, fn_name)) |opt_i64| {
                        if (opt_i64) |i| {
                            break :blk FieldValue{ .i64_val = i };
                        }
                    } else |_| {}

                    if (ext.extractF64(value, fn_name)) |opt_f64| {
                        if (opt_f64) |f| {
                            break :blk FieldValue{ .f64_val = f };
                        }
                    } else |_| {}

                    if (ext.extractU64(value, fn_name)) |opt_u64| {
                        if (opt_u64) |u| {
                            break :blk FieldValue{ .u64_val = u };
                        }
                    } else |_| {}

                    if (ext.extractString(value, fn_name)) |opt_str| {
                        if (opt_str) |str| {
                            defer allocator.free(str);
                            if (std.fmt.parseFloat(f64, str)) |parsed_float| {
                                break :blk FieldValue{ .f64_val = parsed_float };
                            } else |_| {
                                if (std.fmt.parseInt(i64, str, 10)) |parsed_int| {
                                    break :blk FieldValue{ .i64_val = parsed_int };
                                } else |_| {}
                            }
                        }
                    } else |_| {}

                    break :blk null;
                } else null;

                gop.value_ptr.update(agg.name, agg.function, field_value) catch |err| {
                    return err;
                };
            }
        }
    }.process;

    var used_index = false;
    var no_index_on_field = false;
    const strategy = parsed.getBestIndexStrategy();

    if (strategy) |strat| idx_blk: {
        const target_field: []const u8 = switch (strat) {
            .eq => |pred| pred.field_name,
            .range => |r| r.field_name,
            .in_list => |il| il.field_name,
        };
        const strategy_name: []const u8 = switch (strat) {
            .eq => "eq",
            .range => "range",
            .in_list => "in",
        };
        _ = strategy_name;
        engine.catalog_mutex.lock(engine.io);
        var indexes = engine.catalog.getIndexesForStore(store_ns, engine.allocator) catch {
            engine.catalog_mutex.unlock(engine.io);
            break :idx_blk;
        };
        defer indexes.deinit(engine.allocator);
        engine.catalog_mutex.unlock(engine.io);

        var found_index: ?[]const u8 = null;
        var found_field_type_a: ?proto.FieldType = null;
        for (indexes.items) |idx| {
            if (std.mem.eql(u8, idx.field, target_field)) {
                found_index = idx.ns;
                found_field_type_a = idx.field_type;
                break;
            }
        }

        const index_ns = found_index orelse {
            no_index_on_field = true;
            break :idx_blk;
        };

        if (found_field_type_a) |ft| {
            if (ft == .String) {
                switch (strat) {
                    .range => return error.InvalidFieldType,
                    else => {},
                }
            }
        }

        {
            engine.db_mutex.lock(engine.io);
            defer engine.db_mutex.unlock(engine.io);

            var active_iter = engine.db.memtable.active.iterator();
            while (active_iter.next()) |entry| {
                const key_store_id = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                if (key_store_id != store_id) continue;
                if (entry.kind == .delete) continue;

                try seen_keys.put(entry.key, {});
                try processDoc(engine.allocator, entry.value, &parsed, &groups, &extractor, engine);
            }

            var lists_iter = engine.db.memtable.lists.iterator();
            while (lists_iter.next()) |skl| {
                var skl_iter = skl.iterator();
                while (skl_iter.next()) |entry| {
                    const key_store_id = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                    if (key_store_id != store_id) continue;
                    if (entry.kind == .delete) continue;
                    if (seen_keys.contains(entry.key)) continue;

                    try seen_keys.put(entry.key, {});
                    try processDoc(engine.allocator, entry.value, &parsed, &groups, &extractor, engine);
                }
            }
        }

        {
            engine.db_mutex.lock(engine.io);

            var primary_keys = switch (strat) {
                .eq => |pred| engine.db.findBySecondaryIndex(index_ns, pred.value) catch {
                    engine.db_mutex.unlock(engine.io);
                    break :idx_blk;
                },
                .range => |r| engine.db.findBySecondaryIndexRange(index_ns, r.min_val, r.max_val, r.min_inclusive, r.max_inclusive) catch {
                    engine.db_mutex.unlock(engine.io);
                    break :idx_blk;
                },
                .in_list => |il| engine.db.findBySecondaryIndexMulti(index_ns, il.values) catch {
                    engine.db_mutex.unlock(engine.io);
                    break :idx_blk;
                },
            };
            defer primary_keys.deinit(engine.allocator);

            for (primary_keys.items) |pk| {
                if (seen_keys.contains(pk)) continue;

                const value = engine.db.get(@bitCast(pk)) catch continue;
                defer engine.allocator.free(value);

                try processDoc(engine.allocator, value, &parsed, &groups, &extractor, engine);
            }
            engine.db_mutex.unlock(engine.io);
        }

        used_index = true;
    }

    if (!used_index) {
        if (no_index_on_field) {
            return error.NoIndexOnField;
        }
        {
            engine.db_mutex.lock(engine.io);
            defer engine.db_mutex.unlock(engine.io);

            var active_iter = engine.db.memtable.active.iterator();
            while (active_iter.next()) |entry| {
                const key_store_id = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                if (key_store_id != store_id) continue;
                if (entry.kind == .delete) continue;

                try seen_keys.put(entry.key, {});
                try processDoc(engine.allocator, entry.value, &parsed, &groups, &extractor, engine);
            }

            var lists_iter = engine.db.memtable.lists.iterator();
            while (lists_iter.next()) |skl| {
                var skl_iter = skl.iterator();
                while (skl_iter.next()) |entry| {
                    const key_store_id = @as(u16, @intCast((entry.key >> 112) & 0xFFFF));
                    if (key_store_id != store_id) continue;
                    if (entry.kind == .delete) continue;
                    if (seen_keys.contains(entry.key)) continue;

                    try seen_keys.put(entry.key, {});
                    try processDoc(engine.allocator, entry.value, &parsed, &groups, &extractor, engine);
                }
            }
        }

        {
            engine.primary_index_mutex.lock(engine.io);
            defer engine.primary_index_mutex.unlock(engine.io);

            var iter = try engine.primary_index.prefetchIterator();
            defer iter.deinit();

            while (try iter.next()) |cell| {
                const key = std.mem.readInt(u128, cell.key[0..@sizeOf(u128)], .big);

                const key_store_id = @as(u16, @intCast((key >> 112) & 0xFFFF));
                if (key_store_id != store_id) continue;
                if (seen_keys.contains(key)) continue;

                const offset = std.mem.readInt(u64, cell.value[0..@sizeOf(u64)], .little);

                engine.db_mutex.lock(engine.io);
                const value = engine.db.getByOffset(@bitCast(key), offset) catch {
                    engine.db_mutex.unlock(engine.io);
                    continue;
                };
                engine.db_mutex.unlock(engine.io);
                defer engine.allocator.free(value);

                try processDoc(engine.allocator, value, &parsed, &groups, &extractor, engine);
            }
        }
    }

    return try aggregateResultsToBson(engine, &groups, &parsed);
}

fn computeGroupKey(engine: *Engine, doc_json: []const u8, group_by_fields: ?[][]const u8, extractor: *FieldExtractor) ![]u8 {
    _ = extractor;
    const fields = group_by_fields orelse return try engine.allocator.dupe(u8, "_default");

    var key_parts: std.ArrayList(u8) = .empty;
    errdefer key_parts.deinit(engine.allocator);

    const doc = bson.BsonDocument.init(engine.allocator, doc_json, false) catch {
        return try engine.allocator.dupe(u8, "_error");
    };
    var doc_mut = doc;
    defer doc_mut.deinit();

    for (fields, 0..) |field, i| {
        if (i > 0) try key_parts.append(engine.allocator, '|');

        if (doc.getNestedField(field)) |val_opt| {
            if (val_opt) |val| {
                switch (val) {
                    .string => |s| try key_parts.appendSlice(engine.allocator, s),
                    .int32 => |v| {
                        var buf: [32]u8 = undefined;
                        const formatted = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0";
                        try key_parts.appendSlice(engine.allocator, formatted);
                    },
                    .int64 => |v| {
                        var buf: [32]u8 = undefined;
                        const formatted = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0";
                        try key_parts.appendSlice(engine.allocator, formatted);
                    },
                    .double => |v| {
                        var buf: [64]u8 = undefined;
                        const formatted = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0";
                        try key_parts.appendSlice(engine.allocator, formatted);
                    },
                    .boolean => |v| try key_parts.appendSlice(engine.allocator, if (v) "true" else "false"),
                    else => try key_parts.appendSlice(engine.allocator, "null"),
                }
            } else {
                try key_parts.appendSlice(engine.allocator, "null");
            }
        } else |_| {
            try key_parts.appendSlice(engine.allocator, "null");
        }
    }

    return try key_parts.toOwnedSlice(engine.allocator);
}

fn aggregateResultsToBson(engine: *Engine, groups: *std.StringHashMap(query_engine.GroupAccumulator), parsed: *const ParsedQuery) ![]u8 {
    const GroupEntry = struct { key: []const u8, acc: *query_engine.GroupAccumulator };
    var entries: std.ArrayList(GroupEntry) = .empty;
    defer entries.deinit(engine.allocator);

    var collect_it = groups.iterator();
    while (collect_it.next()) |entry| {
        try entries.append(engine.allocator, .{ .key = entry.key_ptr.*, .acc = entry.value_ptr });
    }

    if (parsed.sort_field) |sort_field| {
        const asc = parsed.sort_ascending;

        var sort_key_index: ?usize = null;
        if (parsed.group_by_fields) |fields| {
            for (fields, 0..) |field, idx| {
                if (std.mem.eql(u8, field, sort_field)) {
                    sort_key_index = idx;
                    break;
                }
            }
        }

        const SortCtx = struct {
            key_index: ?usize,
            agg_name: []const u8,
            ascending: bool,

            fn lessThan(ctx: @This(), a: GroupEntry, b: GroupEntry) bool {
                if (ctx.key_index) |ki| {
                    const a_part = getKeyPart(a.key, ki);
                    const b_part = getKeyPart(b.key, ki);

                    const a_num = std.fmt.parseFloat(f64, a_part) catch null;
                    const b_num = std.fmt.parseFloat(f64, b_part) catch null;

                    if (a_num != null and b_num != null) {
                        return if (ctx.ascending) a_num.? < b_num.? else a_num.? > b_num.?;
                    }

                    const order = std.mem.order(u8, a_part, b_part);
                    return if (ctx.ascending) order == .lt else order == .gt;
                } else {
                    const a_result: ?AggregateResult = a.acc.getResult(ctx.agg_name);
                    const b_result: ?AggregateResult = b.acc.getResult(ctx.agg_name);

                    const a_val = resultToF64(a_result);
                    const b_val = resultToF64(b_result);

                    return if (ctx.ascending) a_val < b_val else a_val > b_val;
                }
            }

            fn getKeyPart(key: []const u8, index: usize) []const u8 {
                var parts = std.mem.splitSequence(u8, key, "|");
                var i: usize = 0;
                while (parts.next()) |part| {
                    if (i == index) return part;
                    i += 1;
                }
                return key;
            }

            fn resultToF64(result: ?AggregateResult) f64 {
                if (result) |r| {
                    return switch (r) {
                        .int => |v| @floatFromInt(v),
                        .float => |v| v,
                        .string => 0.0,
                    };
                }
                return 0.0;
            }
        };

        std.sort.pdq(GroupEntry, entries.items, SortCtx{
            .key_index = sort_key_index,
            .agg_name = sort_field,
            .ascending = asc,
        }, SortCtx.lessThan);
    }

    var arr_doc = bson.BsonDocument.empty(engine.allocator);
    defer arr_doc.deinit();

    for (entries.items, 0..) |entry, group_idx| {
        var key_doc = bson.BsonDocument.empty(engine.allocator);
        defer key_doc.deinit();

        if (parsed.group_by_fields) |fields| {
            var key_parts = std.mem.splitSequence(u8, entry.key, "|");
            for (fields) |field| {
                if (key_parts.next()) |part| {
                    try key_doc.putString(field, part);
                }
            }
        }

        var values_doc = bson.BsonDocument.empty(engine.allocator);
        defer values_doc.deinit();

        for (parsed.aggregations.items) |agg| {
            if (entry.acc.getResult(agg.name)) |agg_result| {
                switch (agg_result) {
                    .int => |v| try values_doc.putInt64(agg.name, v),
                    .float => |v| try values_doc.putDouble(agg.name, v),
                    .string => |v| try values_doc.putString(agg.name, v),
                }
            } else {
                try values_doc.putNull(agg.name);
            }
        }

        var group_doc = bson.BsonDocument.empty(engine.allocator);
        defer group_doc.deinit();

        if (parsed.group_by_fields != null) {
            try group_doc.putDocument("key", key_doc);
        } else {
            try group_doc.putNull("key");
        }
        try group_doc.putDocument("values", values_doc);

        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{group_idx}) catch "0";
        try arr_doc.put(idx_str, .{ .document = group_doc });
    }

    var root_doc = bson.BsonDocument.empty(engine.allocator);
    defer root_doc.deinit();

    try root_doc.putArray("groups", bson.BsonArray.init(engine.allocator, arr_doc.toBytes()));
    try root_doc.putInt32("total_groups", @intCast(groups.count()));

    return try engine.allocator.dupe(u8, root_doc.toBytes());
}
