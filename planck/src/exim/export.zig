const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const bson = @import("bson");
const BsonDocument = bson.BsonDocument;
const BsonArray = bson.BsonArray;
const Value = bson.Value;
const KeyGen = @import("../common/keygen.zig").KeyGen;
const Catalog = @import("../storage/catalog.zig").Catalog;
const Db = @import("../storage/db.zig").Db;
const Index = @import("../storage/bptree.zig").Index;
const query_engine = @import("../storage/query_engine.zig");
const query_helpers = @import("../storage/query_helpers.zig");
const ParsedQuery = query_engine.ParsedQuery;
const manifest = @import("utils").manifest;
const EximManifest = manifest.EximManifest;

const log = std.log.scoped(.exim_export);

const ChildFile = struct {
    fw: FileWriter,
    name: []const u8,
    path: []const u8,
};

pub const ExportFormat = enum {
    bson,
    json,
    csv,

    pub fn fromString(s: []const u8) ?ExportFormat {
        if (std.mem.eql(u8, s, "bson")) return .bson;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "csv")) return .csv;
        return null;
    }
};

const FileWriter = struct {
    allocator: Allocator,
    io: Io,
    file: File,
    buf: std.ArrayList(u8),
    offset: u64,

    const FLUSH_THRESHOLD = 64 * 1024;

    fn init(allocator: Allocator, io: Io, file: File) FileWriter {
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .buf = std.ArrayList(u8).empty,
            .offset = 0,
        };
    }

    fn writeAll(self: *FileWriter, data: []const u8) !void {
        try self.buf.appendSlice(self.allocator, data);
        if (self.buf.items.len >= FLUSH_THRESHOLD) {
            try self.flush();
        }
    }

    fn writeByte(self: *FileWriter, byte: u8) !void {
        try self.buf.append(self.allocator, byte);
        if (self.buf.items.len >= FLUSH_THRESHOLD) {
            try self.flush();
        }
    }

    fn print(self: *FileWriter, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.writeAll(s);
    }

    fn flush(self: *FileWriter) !void {
        if (self.buf.items.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buf.items, self.offset);
        self.offset += self.buf.items.len;
        self.buf.clearRetainingCapacity();
    }

    fn close(self: *FileWriter) void {
        self.flush() catch {};
        self.file.close(self.io);
        self.buf.deinit(self.allocator);
    }
};

pub const Exporter = struct {
    allocator: Allocator,
    io: Io,
    catalog: *Catalog,
    db: *Db,
    primary_index: *Index(u128, u64),
    filter: ?ParsedQuery = null,

    pub fn init(allocator: Allocator, io: Io, catalog: *Catalog, db: *Db, primary_index: *Index(u128, u64)) Exporter {
        return .{
            .allocator = allocator,
            .io = io,
            .catalog = catalog,
            .db = db,
            .primary_index = primary_index,
        };
    }

    pub fn setFilter(self: *Exporter, query_json: []const u8) !void {
        self.filter = try query_engine.parseJsonQuery(self.allocator, query_json);
    }

    pub fn deinit(self: *Exporter) void {
        if (self.filter) |*f| f.deinit();
    }

    fn matchesFilter(self: *const Exporter, doc_bson: []const u8) bool {
        if (self.filter) |*f| {
            return query_helpers.matchesAllPredicates(doc_bson, f);
        }
        return true;
    }

    fn createFile(self: *Exporter, path: []const u8) !FileWriter {
        const file = try Dir.createFile(.cwd(), self.io, path, .{ .read = false, .truncate = true });
        return FileWriter.init(self.allocator, self.io, file);
    }

    pub fn exportStore(self: *Exporter, store_ns: []const u8, format_str: []const u8, file_path: []const u8) ![]const u8 {
        const format = ExportFormat.fromString(format_str) orelse return error.UnsupportedFormat;

        const store = self.catalog.findStoreByNamespace(store_ns) orelse return error.StoreNotFound;
        const store_id = store.store_id;

        return switch (format) {
            .bson => try self.exportBson(store_id, file_path),
            .json => try self.exportJson(store_id, file_path),
            .csv => try self.exportCsv(store_id, store_ns, file_path),
        };
    }


    fn exportBson(self: *Exporter, store_id: u16, file_path: []const u8) ![]const u8 {
        var fw = try self.createFile(file_path);
        defer fw.close();

        var doc_count: u64 = 0;
        var skipped_key: u64 = 0;
        var skipped_vlog: u64 = 0;
        var skipped_get: u64 = 0;
        var skipped_tomb: u64 = 0;
        var total_cells: u64 = 0;

        const range = KeyGen.storeKeyRange(store_id);
        var sk_buf: [16]u8 = undefined;
        var ek_buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &sk_buf, range.min, .big);
        std.mem.writeInt(u128, &ek_buf, range.max, .big);
        var iter = try self.primary_index.tree.rangeScan(&sk_buf, &ek_buf);
        defer iter.deinit();

        while (try iter.next()) |cell| {
            total_cells += 1;
            if (cell.key.len < 16 or cell.value.len < 8) {
                skipped_key += 1;
                continue;
            }

            const key = std.mem.readInt(u128, cell.key[0..16], .big);
            const offset = std.mem.readInt(u64, cell.value[0..8], .little);
            const metadata = KeyGen.extractMetadata(key);

            if (metadata.store_id != store_id) {
                skipped_key += 1;
                continue;
            }

            const vlog = self.db.vlogs.get(metadata.vlog_id) orelse {
                skipped_vlog += 1;
                continue;
            };
            var entry = vlog.get(offset) catch {
                skipped_get += 1;
                continue;
            };
            defer entry.deinit(self.allocator);

            if (entry.tombstone) {
                skipped_tomb += 1;
                continue;
            }
            if (!self.matchesFilter(entry.value)) continue;

            try fw.writeAll(entry.value);
            doc_count += 1;
        }

        log.info("BSON export: {d} docs, {d} cells, skipped: key={d} vlog={d} get={d} tomb={d}", .{ doc_count, total_cells, skipped_key, skipped_vlog, skipped_get, skipped_tomb });
        return try std.fmt.allocPrint(self.allocator, "exported {d} documents to {s}", .{ doc_count, file_path });
    }

    fn exportJson(self: *Exporter, store_id: u16, file_path: []const u8) ![]const u8 {
        var fw = try self.createFile(file_path);
        defer fw.close();

        var doc_count: u64 = 0;

        try fw.writeAll("[\n");

        const range = KeyGen.storeKeyRange(store_id);
        var sk_buf: [16]u8 = undefined;
        var ek_buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &sk_buf, range.min, .big);
        std.mem.writeInt(u128, &ek_buf, range.max, .big);
        var iter = try self.primary_index.tree.rangeScan(&sk_buf, &ek_buf);
        defer iter.deinit();

        while (try iter.next()) |cell| {
            if (cell.key.len < 16 or cell.value.len < 8) continue;

            const key = std.mem.readInt(u128, cell.key[0..16], .big);
            const offset = std.mem.readInt(u64, cell.value[0..8], .little);
            const metadata = KeyGen.extractMetadata(key);

            if (metadata.store_id != store_id) continue;

            const vlog = self.db.vlogs.get(metadata.vlog_id) orelse continue;
            var entry = vlog.get(offset) catch continue;
            defer entry.deinit(self.allocator);

            if (entry.tombstone) continue;
            if (!self.matchesFilter(entry.value)) continue;

            const json = bson.toJson(self.allocator, entry.value) catch continue;
            defer self.allocator.free(json);

            if (doc_count > 0) try fw.writeAll(",\n");
            try fw.writeAll(json);
            doc_count += 1;
        }

        try fw.writeAll("\n]\n");

        log.info("JSON export: {d} documents to {s}", .{ doc_count, file_path });
        return try std.fmt.allocPrint(self.allocator, "exported {d} documents to {s}", .{ doc_count, file_path });
    }

    fn exportCsv(self: *Exporter, store_id: u16, store_ns: []const u8, file_path: []const u8) ![]const u8 {
        var field_names = std.ArrayList([]const u8).empty;
        defer {
            for (field_names.items) |name| self.allocator.free(name);
            field_names.deinit(self.allocator);
        }

        var has_subdocs = false;
        var subdoc_fields = std.StringHashMap(void).init(self.allocator);
        defer subdoc_fields.deinit();

        var sample_count: u32 = 0;
        const max_samples: u32 = 50;

        const range = KeyGen.storeKeyRange(store_id);

        {
            var sk_buf: [16]u8 = undefined;
            var ek_buf: [16]u8 = undefined;
            std.mem.writeInt(u128, &sk_buf, range.min, .big);
            std.mem.writeInt(u128, &ek_buf, range.max, .big);
            var iter = try self.primary_index.tree.rangeScan(&sk_buf, &ek_buf);
            defer iter.deinit();

            while (try iter.next()) |cell| {
                if (sample_count >= max_samples) break;
                if (cell.key.len < 16 or cell.value.len < 8) continue;

                const key = std.mem.readInt(u128, cell.key[0..16], .big);
                const offset = std.mem.readInt(u64, cell.value[0..8], .little);
                const metadata = KeyGen.extractMetadata(key);
                if (metadata.store_id != store_id) continue;

                const vlog = self.db.vlogs.get(metadata.vlog_id) orelse continue;
                var entry = vlog.get(offset) catch continue;
                defer entry.deinit(self.allocator);
                if (entry.tombstone) continue;
                if (!self.matchesFilter(entry.value)) continue;

                try self.sampleDocument(entry.value, &field_names, &subdoc_fields, &has_subdocs);
                sample_count += 1;
            }
        }

        if (has_subdocs) {
            return try self.exportCsvFlatten(store_id, store_ns, file_path, &field_names, &subdoc_fields);
        } else {
            return try self.exportCsvSimple(store_id, file_path, &field_names);
        }
    }

    fn sampleDocument(self: *Exporter, bson_data: []const u8, field_names: *std.ArrayList([]const u8), subdoc_fields: *std.StringHashMap(void), has_subdocs: *bool) !void {
        var doc = BsonDocument.init(self.allocator, bson_data, false) catch return;
        defer doc.deinit();

        const names = doc.getFieldNames(self.allocator) catch return;
        defer {
            for (names) |n| self.allocator.free(n);
            self.allocator.free(names);
        }

        for (names) |name| {
            var found = false;
            for (field_names.items) |existing| {
                if (std.mem.eql(u8, existing, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try field_names.append(self.allocator, try self.allocator.dupe(u8, name));
            }

            var val = (doc.getField(name) catch null) orelse continue;
            defer val.deinit(self.allocator);

            switch (val) {
                .document => {
                    has_subdocs.* = true;
                    if (!subdoc_fields.contains(name)) {
                        try subdoc_fields.put(try self.allocator.dupe(u8, name), {});
                    }
                },
                .array => |arr| {
                    var first = (arr.get(0) catch null) orelse continue;
                    defer first.deinit(self.allocator);
                    switch (first) {
                        .document => {
                            has_subdocs.* = true;
                            if (!subdoc_fields.contains(name)) {
                                try subdoc_fields.put(try self.allocator.dupe(u8, name), {});
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    fn exportCsvSimple(self: *Exporter, store_id: u16, file_path: []const u8, field_names: *std.ArrayList([]const u8)) ![]const u8 {
        var fw = try self.createFile(file_path);
        defer fw.close();

        var doc_count: u64 = 0;

        try fw.writeAll("_id");
        for (field_names.items) |name| {
            try fw.writeByte(',');
            try writeCsvField(&fw, name);
        }
        try fw.writeByte('\n');

        const range = KeyGen.storeKeyRange(store_id);
        var sk_buf: [16]u8 = undefined;
        var ek_buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &sk_buf, range.min, .big);
        std.mem.writeInt(u128, &ek_buf, range.max, .big);
        var iter = try self.primary_index.tree.rangeScan(&sk_buf, &ek_buf);
        defer iter.deinit();

        while (try iter.next()) |cell| {
            if (cell.key.len < 16 or cell.value.len < 8) continue;

            const key = std.mem.readInt(u128, cell.key[0..16], .big);
            const offset = std.mem.readInt(u64, cell.value[0..8], .little);
            const metadata = KeyGen.extractMetadata(key);
            if (metadata.store_id != store_id) continue;

            const vlog = self.db.vlogs.get(metadata.vlog_id) orelse continue;
            var entry = vlog.get(offset) catch continue;
            defer entry.deinit(self.allocator);
            if (entry.tombstone) continue;
            if (!self.matchesFilter(entry.value)) continue;

            try fw.print("{x}", .{key});

            const doc = BsonDocument.init(self.allocator, entry.value, false) catch continue;
            for (field_names.items) |name| {
                try fw.writeByte(',');
                if (doc.getField(name) catch null) |val| {
                    try writeValueAsCsv(self.allocator, &fw, val);
                }
            }
            try fw.writeByte('\n');
            doc_count += 1;
        }

        log.info("CSV export: {d} documents to {s}", .{ doc_count, file_path });
        return try std.fmt.allocPrint(self.allocator, "exported {d} documents to {s}", .{ doc_count, file_path });
    }

    fn exportCsvFlatten(self: *Exporter, store_id: u16, store_ns: []const u8, file_path: []const u8, field_names: *std.ArrayList([]const u8), subdoc_fields: *std.StringHashMap(void)) ![]const u8 {
        const base_name = if (std.mem.endsWith(u8, file_path, ".csv"))
            file_path[0 .. file_path.len - 4]
        else
            file_path;

        var scalar_fields = std.ArrayList([]const u8).empty;
        defer scalar_fields.deinit(self.allocator);

        var parent_key_fields = std.ArrayList([]const u8).empty;
        defer parent_key_fields.deinit(self.allocator);

        for (field_names.items) |name| {
            if (subdoc_fields.contains(name)) continue;
            try scalar_fields.append(self.allocator, name);

            if (std.mem.endsWith(u8, name, "_id") or std.mem.eql(u8, name, "id")) {
                try parent_key_fields.append(self.allocator, name);
            }
        }

        const parent_path = try std.fmt.allocPrint(self.allocator, "{s}.csv", .{base_name});
        defer self.allocator.free(parent_path);
        var parent_fw = try self.createFile(parent_path);
        defer parent_fw.close();

        try parent_fw.writeAll("_id");
        for (scalar_fields.items) |name| {
            try parent_fw.writeByte(',');
            try writeCsvField(&parent_fw, name);
        }
        try parent_fw.writeByte('\n');

        var child_files = std.ArrayList(ChildFile).empty;
        defer {
            for (child_files.items) |*cf| {
                cf.fw.close();
                self.allocator.free(cf.path);
            }
            child_files.deinit(self.allocator);
        }

        var subdoc_iter = subdoc_fields.iterator();
        while (subdoc_iter.next()) |kv| {
            const child_path = try std.fmt.allocPrint(self.allocator, "{s}_{s}.csv", .{ base_name, kv.key_ptr.* });
            const child_fw = try self.createFile(child_path);

            try child_files.append(self.allocator, .{
                .fw = child_fw,
                .name = kv.key_ptr.*,
                .path = child_path,
            });
        }

        var child_headers_written = std.StringHashMap(bool).init(self.allocator);
        defer child_headers_written.deinit();

        var doc_count: u64 = 0;
        var child_row_count: u64 = 0;
        const range = KeyGen.storeKeyRange(store_id);
        var sk_buf: [16]u8 = undefined;
        var ek_buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &sk_buf, range.min, .big);
        std.mem.writeInt(u128, &ek_buf, range.max, .big);
        var iter = try self.primary_index.tree.rangeScan(&sk_buf, &ek_buf);
        defer iter.deinit();

        while (try iter.next()) |cell| {
            if (cell.key.len < 16 or cell.value.len < 8) continue;

            const key = std.mem.readInt(u128, cell.key[0..16], .big);
            const offset = std.mem.readInt(u64, cell.value[0..8], .little);
            const metadata = KeyGen.extractMetadata(key);
            if (metadata.store_id != store_id) continue;

            const vlog = self.db.vlogs.get(metadata.vlog_id) orelse continue;
            var entry = vlog.get(offset) catch continue;
            defer entry.deinit(self.allocator);
            if (entry.tombstone) continue;
            if (!self.matchesFilter(entry.value)) continue;

            const doc = BsonDocument.init(self.allocator, entry.value, false) catch continue;

            try parent_fw.print("{x}", .{key});
            for (scalar_fields.items) |name| {
                try parent_fw.writeByte(',');
                if (doc.getField(name) catch null) |val| {
                    try writeValueAsCsv(self.allocator, &parent_fw, val);
                }
            }
            try parent_fw.writeByte('\n');

            var parent_key_values = std.ArrayList([]const u8).empty;
            defer {
                for (parent_key_values.items) |v| self.allocator.free(v);
                parent_key_values.deinit(self.allocator);
            }
            for (parent_key_fields.items) |pk_name| {
                if (doc.getField(pk_name) catch null) |val| {
                    const formatted = try formatValueToString(self.allocator, val);
                    try parent_key_values.append(self.allocator, formatted);
                } else {
                    try parent_key_values.append(self.allocator, try self.allocator.dupe(u8, ""));
                }
            }

            for (child_files.items) |*cf| {
                const field_val = doc.getField(cf.name) catch null orelse continue;

                switch (field_val) {
                    .document => |subdoc| {
                        if (!child_headers_written.contains(cf.name)) {
                            try writeChildHeader(self.allocator, &cf.fw, &parent_key_fields, subdoc);
                            try child_headers_written.put(cf.name, true);
                        }
                        try writeChildRow(self.allocator, &cf.fw, key, &parent_key_values, subdoc);
                        child_row_count += 1;
                    },
                    .array => |arr| {
                        const arr_len = arr.len() catch 0;
                        for (0..arr_len) |i| {
                            if (arr.get(i) catch null) |elem| {
                                switch (elem) {
                                    .document => |subdoc| {
                                        if (!child_headers_written.contains(cf.name)) {
                                            try writeChildHeader(self.allocator, &cf.fw, &parent_key_fields, subdoc);
                                            try child_headers_written.put(cf.name, true);
                                        }
                                        try writeChildRow(self.allocator, &cf.fw, key, &parent_key_values, subdoc);
                                        child_row_count += 1;
                                    },
                                    else => {},
                                }
                            }
                        }
                    },
                    else => {},
                }
            }

            doc_count += 1;
        }

        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}_manifest.yaml", .{base_name});
        defer self.allocator.free(manifest_path);
        try self.writeManifest(manifest_path, store_ns, parent_path, &scalar_fields, &parent_key_fields, &child_files);

        const total_files = 1 + child_files.items.len + 1;
        log.info("CSV flatten export: {d} documents, {d} child rows, {d} files", .{ doc_count, child_row_count, total_files });
        return try std.fmt.allocPrint(self.allocator, "exported {d} documents ({d} child rows) to {d} files", .{ doc_count, child_row_count, total_files });
    }

    fn writeManifest(self: *Exporter, manifest_path: []const u8, store_ns: []const u8, parent_path: []const u8, scalar_fields: *std.ArrayList([]const u8), parent_key_fields: *std.ArrayList([]const u8), child_files: *std.ArrayList(ChildFile)) !void {
        var fw = try self.createFile(manifest_path);
        defer fw.close();

        try fw.print("source: {s}\n", .{store_ns});
        try fw.writeAll("format: csv\n");
        try fw.writeAll("files:\n");

        try fw.print("  - name: {s}\n", .{parent_path});
        try fw.writeAll("    role: parent\n");
        try fw.writeAll("    fields: [_id");
        for (scalar_fields.items) |f| {
            try fw.print(", {s}", .{f});
        }
        try fw.writeAll("]\n");

        for (child_files.items) |cf| {
            try fw.print("  - name: {s}\n", .{cf.path});
            try fw.writeAll("    role: child\n");
            try fw.writeAll("    link_field: _parent_id\n");
            try fw.writeAll("    injected_fields: [");
            for (parent_key_fields.items, 0..) |pk, i| {
                if (i > 0) try fw.writeAll(", ");
                try fw.writeAll(pk);
            }
            try fw.writeAll("]\n");
        }
    }

    pub fn exportWithManifest(self: *Exporter, em: *const EximManifest) ![]const u8 {
        const store = self.catalog.findStoreByNamespace(em.store) orelse return error.StoreNotFound;
        const store_id = store.store_id;

        const output_dir = em.output_dir orelse return error.MissingOutputDir;

        switch (em.format) {
            .bson => {
                const root_entity = em.findRoot();
                const file_name = if (root_entity) |r| r.file else "export.bson";
                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ output_dir, file_name });
                defer self.allocator.free(path);
                return try self.exportBson(store_id, path);
            },
            .json => {
                const root_entity = em.findRoot();
                const file_name = if (root_entity) |r| r.file else "export.json";
                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ output_dir, file_name });
                defer self.allocator.free(path);
                return try self.exportJson(store_id, path);
            },
            .csv => {
                if (em.entities.len == 0) {
                    const path = try std.fmt.allocPrint(self.allocator, "{s}/export.csv", .{output_dir});
                    defer self.allocator.free(path);
                    return try self.exportCsv(store_id, em.store, path);
                }
                return try self.exportCsvManifest(store_id, em);
            },
        }
    }

    fn exportCsvManifest(self: *Exporter, store_id: u16, em: *const EximManifest) ![]const u8 {
        const output_dir = em.output_dir orelse return error.MissingOutputDir;
        const root_entity = em.findRoot() orelse return error.MissingParentEntity;

        const parent_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ output_dir, root_entity.file });
        defer self.allocator.free(parent_path);
        var parent_fw = try self.createFile(parent_path);
        defer parent_fw.close();

        try parent_fw.writeAll("_id");
        for (root_entity.fields) |fd| {
            try parent_fw.writeByte(',');
            try writeCsvField(&parent_fw, fd.name);
        }
        try parent_fw.writeByte('\n');

        const children = try em.findChildren(self.allocator, root_entity.name);
        defer self.allocator.free(children);

        var child_files = std.ArrayList(ManifestChildFile).empty;
        defer {
            for (child_files.items) |*cf| {
                cf.fw.close();
                self.allocator.free(cf.path);
            }
            child_files.deinit(self.allocator);
        }

        for (children) |child_entity| {
            const child_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ output_dir, child_entity.file });
            var child_fw = try self.createFile(child_path);

            try child_fw.writeAll("_parent_id");
            if (child_entity.join_key) |jk| {
                try child_fw.writeByte(',');
                try writeCsvField(&child_fw, jk);
            }
            for (child_entity.fields) |fd| {
                try child_fw.writeByte(',');
                try writeCsvField(&child_fw, fd.name);
            }
            try child_fw.writeByte('\n');

            try child_files.append(self.allocator, .{
                .fw = child_fw,
                .entity = child_entity,
                .path = child_path,
            });
        }

        var doc_count: u64 = 0;
        var child_row_count: u64 = 0;
        const range = KeyGen.storeKeyRange(store_id);
        var sk_buf: [16]u8 = undefined;
        var ek_buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &sk_buf, range.min, .big);
        std.mem.writeInt(u128, &ek_buf, range.max, .big);
        var iter = try self.primary_index.tree.rangeScan(&sk_buf, &ek_buf);
        defer iter.deinit();

        while (try iter.next()) |cell| {
            if (cell.key.len < 16 or cell.value.len < 8) continue;

            const key = std.mem.readInt(u128, cell.key[0..16], .big);
            const offset = std.mem.readInt(u64, cell.value[0..8], .little);
            const metadata = KeyGen.extractMetadata(key);
            if (metadata.store_id != store_id) continue;

            const vlog = self.db.vlogs.get(metadata.vlog_id) orelse continue;
            var entry = vlog.get(offset) catch continue;
            defer entry.deinit(self.allocator);
            if (entry.tombstone) continue;
            if (!self.matchesFilter(entry.value)) continue;

            const doc = BsonDocument.init(self.allocator, entry.value, false) catch continue;

            try parent_fw.print("{x}", .{key});
            for (root_entity.fields) |fd| {
                try parent_fw.writeByte(',');
                if (doc.getField(fd.name) catch null) |val| {
                    try writeValueAsCsv(self.allocator, &parent_fw, val);
                }
            }
            try parent_fw.writeByte('\n');

            const join_key_val = blk: {
                for (child_files.items) |cf| {
                    if (cf.entity.join_key) |jk| {
                        if (doc.getField(jk) catch null) |val| {
                            break :blk formatValueToString(self.allocator, val) catch null;
                        }
                    }
                }
                break :blk null;
            };
            defer if (join_key_val) |jkv| self.allocator.free(jkv);

            for (child_files.items) |*cf| {
                const parent_field = cf.entity.parent_field orelse continue;
                const field_val = doc.getField(parent_field) catch null orelse continue;

                switch (field_val) {
                    .array => |arr| {
                        const arr_len = arr.len() catch 0;
                        for (0..arr_len) |i| {
                            if (arr.get(i) catch null) |elem| {
                                switch (elem) {
                                    .document => |subdoc| {
                                        try cf.fw.print("{x}", .{key});
                                        if (join_key_val) |jkv| {
                                            try cf.fw.writeByte(',');
                                            try writeCsvField(&cf.fw, jkv);
                                        }
                                        for (cf.entity.fields) |fd| {
                                            try cf.fw.writeByte(',');
                                            if (subdoc.getField(fd.name) catch null) |sv| {
                                                try writeValueAsCsv(self.allocator, &cf.fw, sv);
                                            }
                                        }
                                        try cf.fw.writeByte('\n');
                                        child_row_count += 1;
                                    },
                                    else => {},
                                }
                            }
                        }
                    },
                    .document => |subdoc| {
                        try cf.fw.print("{x}", .{key});
                        if (join_key_val) |jkv| {
                            try cf.fw.writeByte(',');
                            try writeCsvField(&cf.fw, jkv);
                        }
                        for (cf.entity.fields) |fd| {
                            try cf.fw.writeByte(',');
                            if (subdoc.getField(fd.name) catch null) |sv| {
                                try writeValueAsCsv(self.allocator, &cf.fw, sv);
                            }
                        }
                        try cf.fw.writeByte('\n');
                        child_row_count += 1;
                    },
                    else => {},
                }
            }

            doc_count += 1;
        }

        const total_files = 1 + child_files.items.len;
        log.info("CSV manifest export: {d} documents, {d} child rows, {d} files", .{ doc_count, child_row_count, total_files });
        return try std.fmt.allocPrint(self.allocator, "exported {d} documents ({d} child rows) to {d} files", .{ doc_count, child_row_count, total_files });
    }
};

const ManifestChildFile = struct {
    fw: FileWriter,
    entity: *const manifest.EntityDef,
    path: []const u8,
};

fn writeChildHeader(allocator: Allocator, fw: *FileWriter, parent_key_fields: *std.ArrayList([]const u8), sample_subdoc: BsonDocument) !void {
    try fw.writeAll("_parent_id");
    for (parent_key_fields.items) |pk| {
        try fw.writeByte(',');
        try writeCsvField(fw, pk);
    }

    const child_names = try sample_subdoc.getFieldNames(allocator);
    defer {
        for (child_names) |n| allocator.free(n);
        allocator.free(child_names);
    }
    for (child_names) |cn| {
        try fw.writeByte(',');
        try writeCsvField(fw, cn);
    }
    try fw.writeByte('\n');
}

fn writeChildRow(allocator: Allocator, fw: *FileWriter, parent_key: u128, parent_key_values: *std.ArrayList([]const u8), subdoc: BsonDocument) !void {
    try fw.print("{x}", .{parent_key});

    for (parent_key_values.items) |pkv| {
        try fw.writeByte(',');
        try writeCsvField(fw, pkv);
    }

    const child_names = try subdoc.getFieldNames(allocator);
    defer {
        for (child_names) |n| allocator.free(n);
        allocator.free(child_names);
    }
    for (child_names) |cn| {
        try fw.writeByte(',');
        if (subdoc.getField(cn) catch null) |val| {
            try writeValueAsCsv(allocator, fw, val);
        }
    }
    try fw.writeByte('\n');
}

fn writeValueAsCsv(allocator: Allocator, fw: *FileWriter, val: Value) !void {
    switch (val) {
        .double => |d| try fw.print("{d}", .{d}),
        .string => |s| try writeCsvField(fw, s),
        .int32 => |i| try fw.print("{d}", .{i}),
        .int64 => |i| try fw.print("{d}", .{i}),
        .boolean => |b| try fw.writeAll(if (b) "true" else "false"),
        .datetime => |ms| try fw.print("{d}", .{ms}),
        .null => {},
        .object_id => |oid| {
            for (oid.bytes) |b| {
                try fw.print("{x:0>2}", .{b});
            }
        },
        .document => try fw.writeAll("\"<document>\""),
        .array => |arr| {
            try fw.writeByte('"');
            try fw.writeByte('[');
            const arr_len = arr.len() catch 0;
            for (0..arr_len) |i| {
                if (i > 0) try fw.writeByte(',');
                if (arr.get(i) catch null) |elem| {
                    switch (elem) {
                        .string => |s| {
                            try fw.writeAll("\"\"");
                            try fw.writeAll(s);
                            try fw.writeAll("\"\"");
                        },
                        .int32 => |v| try fw.print("{d}", .{v}),
                        .int64 => |v| try fw.print("{d}", .{v}),
                        .double => |v| try fw.print("{d}", .{v}),
                        .boolean => |v| try fw.writeAll(if (v) "true" else "false"),
                        else => try fw.writeAll("null"),
                    }
                }
            }
            try fw.writeByte(']');
            try fw.writeByte('"');
        },
        else => {},
    }
    _ = allocator;
}

fn writeCsvField(fw: *FileWriter, field: []const u8) !void {
    var needs_quote = false;
    for (field) |c| {
        if (c == ',' or c == '\n' or c == '\r' or c == '"') {
            needs_quote = true;
            break;
        }
    }

    if (needs_quote) {
        try fw.writeByte('"');
        for (field) |c| {
            if (c == '"') {
                try fw.writeAll("\"\"");
            } else {
                try fw.writeByte(c);
            }
        }
        try fw.writeByte('"');
    } else {
        try fw.writeAll(field);
    }
}

fn formatValueToString(allocator: Allocator, val: Value) ![]const u8 {
    return switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        .int32 => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .int64 => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .double => |d| try std.fmt.allocPrint(allocator, "{d}", .{d}),
        .boolean => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .object_id => |oid| blk: {
            var buf: [24]u8 = undefined;
            for (oid.bytes, 0..) |b, i| {
                _ = std.fmt.bufPrint(buf[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
            }
            break :blk try allocator.dupe(u8, &buf);
        },
        else => try allocator.dupe(u8, ""),
    };
}
