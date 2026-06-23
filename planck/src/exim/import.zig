const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const bson = @import("bson");
const BsonDocument = bson.BsonDocument;
const BsonArray = bson.BsonArray;
const manifest = @import("utils").manifest;
const datetime_mod = @import("utils").datetime;
const ImportSpec = manifest.ImportSpec;
const ImportSourceEntry = manifest.ImportSourceEntry;
const FieldDescriptor = manifest.FieldDescriptor;
const FieldType = manifest.FieldType;
const FileRole = manifest.FileRole;
const ExportFormat = manifest.ExportFormat;
const EximManifest = manifest.EximManifest;

const log = std.log.scoped(.exim_import);

pub const Importer = struct {
    allocator: Allocator,
    io: Io,

    post_fn: *const fn (ctx: *anyopaque, store_ns: []const u8, value: []const u8) anyerror!u128,
    post_ctx: *anyopaque,

    pub fn init(allocator: Allocator, io: Io, post_fn: *const fn (ctx: *anyopaque, store_ns: []const u8, value: []const u8) anyerror!u128, post_ctx: *anyopaque) Importer {
        return .{
            .allocator = allocator,
            .io = io,
            .post_fn = post_fn,
            .post_ctx = post_ctx,
        };
    }

    fn postDocument(self: *Importer, store_ns: []const u8, value: []const u8) !u128 {
        return self.post_fn(self.post_ctx, store_ns, value);
    }

    pub fn importData(self: *Importer, payload: []const u8) ![]const u8 {
        var spec = try self.parseImportSpec(payload);
        defer spec.deinit(self.allocator);

        return switch (spec.format) {
            .bson => try self.importBson(&spec),
            .json => try self.importJson(&spec),
            .csv => try self.importCsv(&spec),
        };
    }

    pub fn importWithManifest(self: *Importer, em: *const EximManifest) ![]const u8 {
        var spec = try em.toImportSpec(self.allocator);
        defer spec.deinit(self.allocator);

        return switch (spec.format) {
            .bson => try self.importBson(&spec),
            .json => try self.importJson(&spec),
            .csv => try self.importCsv(&spec),
        };
    }

    fn parseImportSpec(self: *Importer, payload: []const u8) !ImportSpec {
        const doc = try BsonDocument.init(self.allocator, payload, false);

        const target = try self.allocator.dupe(u8, (try doc.getString("target")) orelse return error.MissingTarget);
        errdefer self.allocator.free(target);

        const format_str = (try doc.getString("format")) orelse return error.MissingFormat;
        const format = ExportFormat.fromString(format_str) orelse return error.UnsupportedFormat;

        var spec = ImportSpec{
            .target = target,
            .format = format,
        };

        if (try doc.getString("file_path")) |fp| {
            spec.file_path = try self.allocator.dupe(u8, fp);
        }

        if (format == .json) {
            if (try doc.getArray("fields")) |fields_arr| {
                const flen = try fields_arr.len();
                var fields = try self.allocator.alloc(FieldDescriptor, flen);
                var fcount: usize = 0;
                errdefer {
                    for (fields[0..fcount]) |fd| self.allocator.free(fd.name);
                    self.allocator.free(fields);
                }

                for (0..flen) |i| {
                    if (try fields_arr.get(i)) |felem| {
                        switch (felem) {
                            .document => |fdoc| {
                                const fname = (try fdoc.getString("name")) orelse continue;
                                const ftype_str = (try fdoc.getString("type")) orelse "string";
                                fields[fcount] = .{
                                    .name = try self.allocator.dupe(u8, fname),
                                    .field_type = FieldType.fromString(ftype_str) orelse .string,
                                };
                                fcount += 1;
                            },
                            else => {},
                        }
                    }
                }

                if (fcount < flen) {
                    fields = try self.allocator.realloc(fields, fcount);
                }
                spec.fields = fields;
            }
        }

        if (try doc.getArray("sources")) |sources_arr| {
            const arr_len = try sources_arr.len();
            var entries = try self.allocator.alloc(ImportSourceEntry, arr_len);
            var count: usize = 0;
            errdefer {
                for (entries[0..count]) |*e| self.freeSourceEntry(e);
                self.allocator.free(entries);
            }

            for (0..arr_len) |i| {
                if (try sources_arr.get(i)) |elem| {
                    switch (elem) {
                        .document => |src_doc| {
                            entries[count] = try self.parseSourceEntry(src_doc);
                            count += 1;
                        },
                        else => {},
                    }
                }
            }

            if (count < arr_len) {
                entries = try self.allocator.realloc(entries, count);
            }
            spec.sources = entries;
        }

        return spec;
    }

    fn parseSourceEntry(self: *Importer, doc: BsonDocument) !ImportSourceEntry {
        const file = try self.allocator.dupe(u8, (try doc.getString("file")) orelse return error.MissingFile);
        errdefer self.allocator.free(file);

        const role_str = (try doc.getString("role")) orelse return error.MissingRole;
        const role = FileRole.fromString(role_str) orelse return error.InvalidRole;

        var entry = ImportSourceEntry{
            .file = file,
            .role = role,
            .fields = &[_]FieldDescriptor{},
        };

        if (try doc.getString("parent")) |p| {
            entry.parent = try self.allocator.dupe(u8, p);
        }
        if (try doc.getString("embed_as")) |ea| {
            entry.embed_as = try self.allocator.dupe(u8, ea);
        }
        if (try doc.getString("join_key")) |jk| {
            entry.join_key = try self.allocator.dupe(u8, jk);
        }

        if (try doc.getArray("fields")) |fields_arr| {
            const flen = try fields_arr.len();
            var fields = try self.allocator.alloc(FieldDescriptor, flen);
            var fcount: usize = 0;
            errdefer {
                for (fields[0..fcount]) |fd| self.allocator.free(fd.name);
                self.allocator.free(fields);
            }

            for (0..flen) |i| {
                if (try fields_arr.get(i)) |felem| {
                    switch (felem) {
                        .document => |fdoc| {
                            const fname = (try fdoc.getString("name")) orelse continue;
                            const ftype_str = (try fdoc.getString("type")) orelse "string";
                            fields[fcount] = .{
                                .name = try self.allocator.dupe(u8, fname),
                                .field_type = FieldType.fromString(ftype_str) orelse .string,
                            };
                            fcount += 1;
                        },
                        else => {},
                    }
                }
            }

            if (fcount < flen) {
                fields = try self.allocator.realloc(fields, fcount);
            }
            entry.fields = fields;
        }

        return entry;
    }

    fn freeSourceEntry(self: *Importer, entry: *ImportSourceEntry) void {
        self.allocator.free(entry.file);
        if (entry.parent) |p| self.allocator.free(p);
        if (entry.embed_as) |ea| self.allocator.free(ea);
        if (entry.join_key) |jk| self.allocator.free(jk);
        for (entry.fields) |fd| self.allocator.free(fd.name);
        self.allocator.free(entry.fields);
    }

    fn importBson(self: *Importer, spec: *ImportSpec) ![]const u8 {
        const file_path = spec.file_path orelse return error.MissingFilePath;

        const file = try Dir.openFile(.cwd(), self.io, file_path, .{ .mode = .read_only });
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const file_size = stat.size;

        var doc_count: u64 = 0;
        var err_count: u64 = 0;
        var file_pos: u64 = 0;
        var last_err: ?[]const u8 = null;

        var buf_cap: usize = 16 * 1024;
        var doc_buf = try self.allocator.alloc(u8, buf_cap);
        defer self.allocator.free(doc_buf);

        var size_buf: [4]u8 = undefined;

        while (file_pos + 4 <= file_size) {
            _ = file.readPositionalAll(self.io, &size_buf, file_pos) catch break;

            const doc_size: usize = @intCast(std.mem.readInt(i32, &size_buf, .little));
            if (doc_size < 5 or file_pos + doc_size > file_size) break;

            if (doc_size > buf_cap) {
                self.allocator.free(doc_buf);
                buf_cap = doc_size;
                doc_buf = try self.allocator.alloc(u8, buf_cap);
            }

            const doc_bytes = doc_buf[0..doc_size];
            _ = file.readPositionalAll(self.io, doc_bytes, file_pos) catch break;

            _ = self.postDocument(spec.target, doc_bytes) catch |e| {
                err_count += 1;
                last_err = @errorName(e);
                file_pos += doc_size;
                continue;
            };
            doc_count += 1;
            file_pos += doc_size;
        }

        log.info("BSON import: {d} documents, {d} errors into {s}", .{ doc_count, err_count, spec.target });
        if (err_count > 0) {
            return try std.fmt.allocPrint(self.allocator, "imported {d} documents into {s} ({d} failed, last error: {s})", .{ doc_count, spec.target, err_count, last_err orelse "unknown" });
        }
        return try std.fmt.allocPrint(self.allocator, "imported {d} documents into {s}", .{ doc_count, spec.target });
    }

    fn importJson(self: *Importer, spec: *ImportSpec) ![]const u8 {
        const file_path = spec.file_path orelse return error.MissingFilePath;
        const data = try self.readFile(file_path);
        defer self.allocator.free(data);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return error.InvalidJsonFormat;
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.InvalidJsonFormat,
        };

        var doc_count: u64 = 0;
        for (arr.items) |elem| {
            const obj = switch (elem) {
                .object => |o| o,
                else => continue,
            };

            const bson_bytes = try self.jsonValueToBson(obj, spec.fields);
            defer self.allocator.free(bson_bytes);

            _ = try self.postDocument(spec.target, bson_bytes);
            doc_count += 1;
        }

        log.info("JSON import: {d} documents into {s}", .{ doc_count, spec.target });
        return try std.fmt.allocPrint(self.allocator, "imported {d} documents into {s}", .{ doc_count, spec.target });
    }

    fn importCsv(self: *Importer, spec: *ImportSpec) ![]const u8 {
        const sources = spec.sources orelse return error.MissingSources;

        var parent_src: ?*const ImportSourceEntry = null;
        for (sources) |*src| {
            if (src.role == .parent) {
                parent_src = src;
                break;
            }
        }
        const parent = parent_src orelse return error.MissingParentSource;

        var has_children = false;
        for (sources) |*src| {
            if (src.role == .child) {
                has_children = true;
                break;
            }
        }

        if (has_children) {
            return try self.importCsvHierarchical(spec, parent, sources);
        } else {
            return try self.importCsvFlat(spec.target, parent);
        }
    }

    fn importCsvFlat(self: *Importer, target: []const u8, source: *const ImportSourceEntry) ![]const u8 {
        const data = try self.readFile(source.file);
        defer self.allocator.free(data);

        var lines = CsvLineIterator.init(data);

        const header_line = lines.next() orelse return error.EmptyCsv;
        const fields = if (source.fields.len > 0)
            source.fields
        else
            try self.fieldsFromHeader(header_line);
        defer if (source.fields.len == 0) self.freeAutoFields(fields);

        var doc_count: u64 = 0;

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var doc = BsonDocument.empty(self.allocator);
            defer doc.deinit();

            var col_idx: usize = 0;
            var field_iter = CsvFieldIterator.init(line);

            while (field_iter.next()) |field_value| {
                if (col_idx < fields.len) {
                    const fd = &fields[col_idx];
                    try self.putTypedField(&doc, fd.name, field_value, fd.field_type);
                }
                col_idx += 1;
            }

            const bson_bytes = try self.allocator.dupe(u8, doc.toBytes());
            defer self.allocator.free(bson_bytes);

            _ = try self.postDocument(target, bson_bytes);
            doc_count += 1;
        }

        log.info("CSV flat import: {d} documents into {s}", .{ doc_count, target });
        return try std.fmt.allocPrint(self.allocator, "imported {d} documents into {s}", .{ doc_count, target });
    }

    fn importCsvHierarchical(self: *Importer, spec: *ImportSpec, parent: *const ImportSourceEntry, sources: []const ImportSourceEntry) ![]const u8 {
        _ = sources;

        const GroupedRows = std.StringHashMap(std.ArrayList([]const u8));

        const ChildInfo = struct {
            rows: GroupedRows,
            embed_as: []const u8,
            join_key: []const u8,
        };

        var entity_data = std.StringHashMap(ChildInfo).init(self.allocator);
        defer {
            var eit = entity_data.iterator();
            while (eit.next()) |kv| {
                var info = kv.value_ptr.*;
                var rit = info.rows.iterator();
                while (rit.next()) |rkv| {
                    for (rkv.value_ptr.items) |bytes| self.allocator.free(bytes);
                    rkv.value_ptr.deinit(self.allocator);
                }
                info.rows.deinit();
            }
            entity_data.deinit();
        }

        const order = try spec.buildOrder(self.allocator);
        defer self.allocator.free(order);

        log.info("Hierarchical import: {d} entities in build order", .{order.len});
        for (order) |o| {
            log.info("  entity: {s} role={s} join_key={s}", .{
                o.name orelse "(unnamed)",
                if (o.role == .parent) "parent" else "child",
                o.join_key orelse "(none)",
            });
        }

        for (order) |entry| {
            const entry_name = entry.name orelse continue;

            const data = try self.readFile(entry.file);
            defer self.allocator.free(data);

            var lines = CsvLineIterator.init(data);
            const header_line = lines.next() orelse continue;
            const fields = if (entry.fields.len > 0)
                entry.fields
            else
                try self.fieldsFromHeader(header_line);
            defer if (entry.fields.len == 0) self.freeAutoFields(fields);

            var join_col_idx: ?usize = null;
            if (entry.join_key) |jk| {
                for (fields, 0..) |fd, idx| {
                    if (std.mem.eql(u8, fd.name, jk)) {
                        join_col_idx = idx;
                        break;
                    }
                }
                if (join_col_idx == null) {
                    var hdr_idx: usize = 0;
                    var hdr_iter = CsvFieldIterator.init(header_line);
                    while (hdr_iter.next()) |col_name| {
                        if (std.mem.eql(u8, col_name, jk)) {
                            join_col_idx = hdr_idx;
                            break;
                        }
                        hdr_idx += 1;
                    }
                }
            }

            var header_cols = std.ArrayList([]const u8).empty;
            defer header_cols.deinit(self.allocator);
            {
                var hdr_iter2 = CsvFieldIterator.init(header_line);
                while (hdr_iter2.next()) |col| {
                    try header_cols.append(self.allocator, col);
                }
            }

            const children = try spec.findChildren(self.allocator, entry_name);
            defer self.allocator.free(children);

            log.info("Processing entity '{s}': join_col_idx={?d}, {d} children to embed", .{
                entry_name,
                join_col_idx,
                children.len,
            });

            var rows = GroupedRows.init(self.allocator);

            while (lines.next()) |line| {
                if (line.len == 0) continue;

                var field_values = std.ArrayList([]const u8).empty;
                defer field_values.deinit(self.allocator);
                var fiter = CsvFieldIterator.init(line);
                while (fiter.next()) |fv| {
                    try field_values.append(self.allocator, fv);
                }

                var doc = BsonDocument.empty(self.allocator);
                defer doc.deinit();

                for (fields, 0..) |fd, idx| {
                    if (idx < field_values.items.len) {
                        if (!std.mem.eql(u8, fd.name, "_parent_id")) {
                            try self.putTypedField(&doc, fd.name, field_values.items[idx], fd.field_type);
                        }
                    }
                }

                for (children) |child_entry| {
                    const child_name = child_entry.name orelse continue;
                    const child_embed_as = child_entry.embed_as orelse continue;
                    const child_join_key = child_entry.join_key orelse continue;

                    var jk_val: ?[]const u8 = null;
                    for (header_cols.items, 0..) |col_name, idx| {
                        if (std.mem.eql(u8, col_name, child_join_key)) {
                            if (idx < field_values.items.len) {
                                jk_val = field_values.items[idx];
                            }
                            break;
                        }
                    }

                    if (jk_val) |jkv| {
                        if (entity_data.get(child_name)) |child_info| {
                            if (child_info.rows.get(jkv)) |child_list| {
                                log.info("  Embedding {d} '{s}' rows as '{s}' (join_key={s} val={s})", .{
                                    child_list.items.len, child_name, child_embed_as, child_join_key, jkv,
                                });
                                var arr_doc = BsonDocument.empty(self.allocator);
                                defer arr_doc.deinit();

                                for (child_list.items, 0..) |child_bytes, arr_idx| {
                                    var idx_buf: [16]u8 = undefined;
                                    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{arr_idx}) catch "0";
                                    const child_bson = BsonDocument.init(self.allocator, child_bytes, false) catch continue;
                                    try arr_doc.put(idx_str, .{ .document = child_bson });
                                }

                                try doc.putArray(child_embed_as, BsonArray.init(self.allocator, arr_doc.toBytes()));
                            } else {
                                log.info("  No rows found for child '{s}' with key '{s}'", .{ child_name, jkv });
                            }
                        } else {
                            log.info("  entity_data missing for child '{s}'", .{child_name});
                        }
                    } else {
                        log.info("  join_key '{s}' not found in fields of '{s}'", .{ child_join_key, entry_name });
                    }
                }

                const doc_bytes = try self.allocator.dupe(u8, doc.toBytes());

                if (join_col_idx) |jci| {
                    if (jci < field_values.items.len) {
                        const jk_owned = try self.allocator.dupe(u8, field_values.items[jci]);
                        const gop = try rows.getOrPut(jk_owned);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = std.ArrayList([]const u8).empty;
                        } else {
                            self.allocator.free(jk_owned);
                        }
                        try gop.value_ptr.append(self.allocator, doc_bytes);
                    } else {
                        self.allocator.free(doc_bytes);
                    }
                } else {
                    self.allocator.free(doc_bytes);
                }
            }

            if (entry.role == .child) {
                log.info("Storing entity_data['{s}']: {d} groups", .{ entry_name, rows.count() });
                const name_owned = try self.allocator.dupe(u8, entry_name);
                try entity_data.put(name_owned, .{
                    .rows = rows,
                    .embed_as = entry.embed_as orelse "",
                    .join_key = entry.join_key orelse "",
                });
            } else {
                var rit = rows.iterator();
                while (rit.next()) |rkv| {
                    for (rkv.value_ptr.items) |bytes| self.allocator.free(bytes);
                    rkv.value_ptr.deinit(self.allocator);
                }
                rows.deinit();
            }
        }

        const parent_data = try self.readFile(parent.file);
        defer self.allocator.free(parent_data);

        var lines = CsvLineIterator.init(parent_data);
        const parent_header = lines.next() orelse return error.EmptyCsv;
        const parent_fields = if (parent.fields.len > 0)
            parent.fields
        else
            try self.fieldsFromHeader(parent_header);
        defer if (parent.fields.len == 0) self.freeAutoFields(parent_fields);

        const parent_name = parent.name orelse "parent";

        var parent_hdr_cols = std.ArrayList([]const u8).empty;
        defer parent_hdr_cols.deinit(self.allocator);
        {
            var phdr = CsvFieldIterator.init(parent_header);
            while (phdr.next()) |col| {
                try parent_hdr_cols.append(self.allocator, col);
            }
        }

        const parent_children = try spec.findChildren(self.allocator, parent_name);
        defer self.allocator.free(parent_children);

        var doc_count: u64 = 0;

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var doc = BsonDocument.empty(self.allocator);
            defer doc.deinit();

            var field_values = std.ArrayList([]const u8).empty;
            defer field_values.deinit(self.allocator);
            var fiter = CsvFieldIterator.init(line);
            while (fiter.next()) |fv| {
                try field_values.append(self.allocator, fv);
            }

            for (parent_fields, 0..) |fd, idx| {
                if (idx < field_values.items.len) {
                    try self.putTypedField(&doc, fd.name, field_values.items[idx], fd.field_type);
                }
            }

            for (parent_children) |child_entry| {
                const child_name = child_entry.name orelse continue;
                const child_embed_as = child_entry.embed_as orelse continue;
                const child_join_key = child_entry.join_key orelse continue;

                var jk_val: ?[]const u8 = null;
                for (parent_hdr_cols.items, 0..) |col_name, idx| {
                    if (std.mem.eql(u8, col_name, child_join_key)) {
                        if (idx < field_values.items.len) {
                            jk_val = field_values.items[idx];
                        }
                        break;
                    }
                }

                if (jk_val) |jkv| {
                    if (entity_data.get(child_name)) |child_info| {
                        if (child_info.rows.get(jkv)) |child_list| {
                            var arr_doc = BsonDocument.empty(self.allocator);
                            defer arr_doc.deinit();

                            for (child_list.items, 0..) |child_bytes, arr_idx| {
                                var idx_buf: [16]u8 = undefined;
                                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{arr_idx}) catch "0";
                                const child_bson = BsonDocument.init(self.allocator, child_bytes, false) catch continue;
                                try arr_doc.put(idx_str, .{ .document = child_bson });
                            }

                            try doc.putArray(child_embed_as, BsonArray.init(self.allocator, arr_doc.toBytes()));
                        }
                    }
                }
            }

            const bson_bytes = try self.allocator.dupe(u8, doc.toBytes());
            defer self.allocator.free(bson_bytes);

            _ = try self.postDocument(spec.target, bson_bytes);
            doc_count += 1;
        }

        log.info("CSV hierarchical import: {d} documents into {s}", .{ doc_count, spec.target });
        return try std.fmt.allocPrint(self.allocator, "imported {d} documents into {s}", .{ doc_count, spec.target });
    }

    fn readFile(self: *Importer, path: []const u8) ![]const u8 {
        const file = try Dir.openFile(.cwd(), self.io, path, .{ .mode = .read_only });
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const size = stat.size;
        if (size == 0) return try self.allocator.alloc(u8, 0);

        const data = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(data);

        _ = try file.readPositionalAll(self.io, data, 0);
        return data;
    }

    fn fieldsFromHeader(self: *Importer, header: []const u8) ![]FieldDescriptor {
        var count: usize = 0;
        var counter = CsvFieldIterator.init(header);
        while (counter.next()) |_| count += 1;

        var fields = try self.allocator.alloc(FieldDescriptor, count);
        var idx: usize = 0;
        var iter = CsvFieldIterator.init(header);
        while (iter.next()) |col_name| {
            fields[idx] = .{
                .name = try self.allocator.dupe(u8, col_name),
                .field_type = .string,
            };
            idx += 1;
        }
        return fields;
    }

    fn freeAutoFields(self: *Importer, fields: []const FieldDescriptor) void {
        for (fields) |fd| self.allocator.free(fd.name);
        self.allocator.free(fields);
    }

    fn putTypedField(self: *Importer, doc: *BsonDocument, name: []const u8, value: []const u8, field_type: FieldType) !void {
        _ = self;
        if (value.len == 0) {
            try doc.putNull(name);
            return;
        }

        switch (field_type) {
            .string => try doc.putString(name, value),
            .int => {
                const v = std.fmt.parseInt(i64, value, 10) catch {
                    try doc.putString(name, value);
                    return;
                };
                try doc.putInt64(name, v);
            },
            .double => {
                const v = std.fmt.parseFloat(f64, value) catch {
                    try doc.putString(name, value);
                    return;
                };
                try doc.putDouble(name, v);
            },
            .bool => {
                const b = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
                try doc.putBool(name, b);
            },
            .datetime => {
                const ms = std.fmt.parseInt(i64, value, 10) catch {
                    try doc.putString(name, value);
                    return;
                };
                try doc.put(name, .{ .datetime = ms });
            },
            .objectid => {
                if (value.len == 24) {
                    var bytes: [12]u8 = undefined;
                    for (0..12) |i| {
                        bytes[i] = std.fmt.parseInt(u8, value[i * 2 ..][0..2], 16) catch 0;
                    }
                    try doc.put(name, .{ .object_id = bson.ObjectId.fromBytes(bytes) });
                } else {
                    try doc.putString(name, value);
                }
            },
        }
    }

    fn jsonValueToBson(self: *Importer, obj: std.json.ObjectMap, fields: ?[]const FieldDescriptor) ![]const u8 {
        var doc = BsonDocument.empty(self.allocator);
        defer doc.deinit();

        var it = obj.iterator();
        while (it.next()) |entry| {
            try self.putJsonField(&doc, entry.key_ptr.*, entry.value_ptr.*, fields);
        }

        return try self.allocator.dupe(u8, doc.toBytes());
    }

    fn putJsonField(self: *Importer, doc: *BsonDocument, key: []const u8, value: std.json.Value, fields: ?[]const FieldDescriptor) anyerror!void {
        const field_type: ?FieldType = if (fields) |fds| blk: {
            for (fds) |fd| {
                if (std.mem.eql(u8, fd.name, key)) break :blk fd.field_type;
            }
            break :blk null;
        } else null;

        switch (value) {
            .string => |s| try self.putJsonString(doc, key, s, field_type),
            .integer => |i| {
                if (field_type) |ft| switch (ft) {
                    .bool => try doc.putBool(key, i != 0),
                    .double => try doc.putDouble(key, @floatFromInt(i)),
                    .int => try doc.putInt32(key, @intCast(i)),
                    else => try doc.putInt64(key, i),
                } else try doc.putInt64(key, i);
            },
            .float => |f| {
                if (field_type) |ft| switch (ft) {
                    .bool => try doc.putBool(key, f != 0),
                    .double => try doc.putDouble(key, f),
                    .int => try doc.putInt32(key, @intFromFloat(f)),
                    else => try doc.putDouble(key, f),
                } else try doc.putDouble(key, f);
            },
            .number_string => |s| {
                if (tryParseJsonNumber(s)) |num| switch (num) {
                    .int => |v| try doc.putInt64(key, v),
                    .float => |v| try doc.putDouble(key, v),
                } else {
                    try doc.putString(key, s);
                }
            },
            .bool => |b| try doc.putBool(key, b),
            .null => try doc.putNull(key),
            .object => |o| {
                const nested = try self.jsonValueToBson(o, fields);
                defer self.allocator.free(nested);
                const nested_doc = try BsonDocument.init(self.allocator, nested, false);
                try doc.putDocument(key, nested_doc);
            },
            .array => |a| {
                var arr_doc = BsonDocument.empty(self.allocator);
                defer arr_doc.deinit();
                for (a.items, 0..) |item, idx| {
                    var idx_buf: [16]u8 = undefined;
                    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch "0";
                    try self.putJsonField(&arr_doc, idx_str, item, fields);
                }
                try doc.putArray(key, BsonArray.init(self.allocator, arr_doc.toBytes()));
            },
        }
    }

    fn putJsonString(self: *Importer, doc: *BsonDocument, key: []const u8, s: []const u8, field_type: ?FieldType) !void {
        _ = self;
        const ft = field_type orelse {
            try doc.putString(key, s);
            return;
        };
        switch (ft) {
            .int => {
                if (std.fmt.parseInt(i64, s, 10)) |v| {
                    try doc.putInt64(key, v);
                } else |_| {
                    try doc.putString(key, s);
                }
            },
            .double => {
                if (std.fmt.parseFloat(f64, s)) |v| {
                    try doc.putDouble(key, v);
                } else |_| {
                    try doc.putString(key, s);
                }
            },
            .bool => {
                const is_true = std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "yes");
                try doc.putBool(key, is_true);
            },
            .datetime => {
                if (datetime_mod.parseIso(s)) |epoch_ms| {
                    try doc.putInt64(key, epoch_ms);
                } else |_| {
                    try doc.putString(key, s);
                }
            },
            .string => try doc.putString(key, s),
            .objectid => try doc.putString(key, s),
        }
    }
};

const CsvLineIterator = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) CsvLineIterator {
        return .{ .data = data, .pos = 0 };
    }

    fn next(self: *CsvLineIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;

        const start = self.pos;

        var in_quote = false;
        while (self.pos < self.data.len) {
            if (self.data[self.pos] == '"') {
                in_quote = !in_quote;
            } else if (!in_quote and (self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) {
                break;
            }
            self.pos += 1;
        }

        const line = self.data[start..self.pos];

        if (self.pos < self.data.len and self.data[self.pos] == '\r') self.pos += 1;
        if (self.pos < self.data.len and self.data[self.pos] == '\n') self.pos += 1;

        return line;
    }
};

const CsvFieldIterator = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) CsvFieldIterator {
        return .{ .data = data, .pos = 0 };
    }

    fn next(self: *CsvFieldIterator) ?[]const u8 {
        if (self.pos > self.data.len) return null;
        if (self.pos == self.data.len) {
            self.pos += 1;
            return "";
        }

        if (self.data[self.pos] == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.data.len) {
                if (self.data[self.pos] == '"') {
                    if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '"') {
                        self.pos += 2;
                    } else {
                        const field = self.data[start..self.pos];
                        self.pos += 1;
                        if (self.pos < self.data.len and self.data[self.pos] == ',') self.pos += 1;
                        return field;
                    }
                } else {
                    self.pos += 1;
                }
            }
            return self.data[start..self.pos];
        } else {
            const start = self.pos;
            while (self.pos < self.data.len and self.data[self.pos] != ',') self.pos += 1;
            const field = self.data[start..self.pos];
            if (self.pos < self.data.len) self.pos += 1;
            return field;
        }
    }
};


const JsonNumber = union(enum) {
    int: i64,
    float: f64,
};

fn tryParseJsonNumber(s: []const u8) ?JsonNumber {
    for (s) |c| {
        if (c == '.' or c == 'e' or c == 'E') {
            const f = std.fmt.parseFloat(f64, s) catch return null;
            return .{ .float = f };
        }
    }
    const i = std.fmt.parseInt(i64, s, 10) catch return null;
    return .{ .int = i };
}

fn dummyPost(_: *anyopaque, _: []const u8, _: []const u8) anyerror!u128 {
    return 0;
}

test "jsonValueToBson: std.json parse + typed coercion round-trip" {
    const allocator = std.testing.allocator;
    var ctx: u8 = 0;
    var imp = Importer.init(allocator, undefined, dummyPost, &ctx);

    const json =
        "{\"age\":\"30\",\"score\":4.5,\"active\":true,\"name\":\"bob\"," ++
        "\"tags\":[\"a\",\"b\"],\"addr\":{\"city\":\"NYC\"}}";

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    // "age" is declared int but arrives as a JSON string -> coerced to int64.
    const fields = [_]FieldDescriptor{
        .{ .name = "age", .field_type = .int },
    };

    const bytes = try imp.jsonValueToBson(parsed.value.object, &fields);
    defer allocator.free(bytes);

    var doc = try BsonDocument.init(allocator, bytes, false);
    defer doc.deinit();

    try std.testing.expectEqual(@as(?i64, 30), try doc.getInt64("age"));
    try std.testing.expectEqual(@as(?f64, 4.5), try doc.getDouble("score"));
    try std.testing.expectEqual(@as(?bool, true), try doc.getBool("active"));

    const name = (try doc.getString("name")).?;
    defer allocator.free(name);
    try std.testing.expectEqualStrings("bob", name);

    var arr = (try doc.getArray("tags")).?;
    defer arr.deinit();
    try std.testing.expectEqual(@as(usize, 2), try arr.len());

    var addr = (try doc.getDocument("addr")).?;
    defer addr.deinit();
    const city = (try addr.getString("city")).?;
    defer allocator.free(city);
    try std.testing.expectEqualStrings("NYC", city);
}

test "import: malformed json is rejected by the standard parser (no OOB walk)" {
    const allocator = std.testing.allocator;
    // Truncated / hostile input errors cleanly in std.json instead of walking out of bounds.
    try std.testing.expectError(error.UnexpectedEndOfInput, std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":", .{}));
}
