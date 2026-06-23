const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml_pkg = @import("yaml");
const Yaml = yaml_pkg.Yaml;

const manifest = @import("utils").manifest;
const EximManifest = manifest.EximManifest;
const EntityDef = manifest.EntityDef;
const FieldDescriptor = manifest.FieldDescriptor;
const FieldType = manifest.FieldType;
const FileRole = manifest.FileRole;
const ExportFormat = manifest.ExportFormat;
const ManifestParseError = manifest.ManifestParseError;


const FieldWire = struct {
    name: []const u8 = "",
    type: []const u8 = "string",
};

const EntityWire = struct {
    name: []const u8 = "",
    role: []const u8 = "",
    file: []const u8 = "",
    parent: []const u8 = "",
    parent_field: []const u8 = "",
    join_key: []const u8 = "",
    fields: []const FieldWire = &.{},
};

const ManifestWire = struct {
    store: []const u8 = "",
    format: []const u8 = "",
    output_dir: []const u8 = "",
    query: []const u8 = "",
    entities: []const EntityWire = &.{},
};

pub fn parse(allocator: Allocator, yaml_str: []const u8) ManifestParseError!EximManifest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var y: Yaml = .{ .source = yaml_str };
    y.load(allocator) catch return ManifestParseError.OutOfMemory;
    defer y.deinit(allocator);

    const wire = y.parse(arena.allocator(), ManifestWire) catch return ManifestParseError.OutOfMemory;

    return convert(allocator, wire);
}

fn convert(allocator: Allocator, wire: ManifestWire) ManifestParseError!EximManifest {
    if (wire.store.len == 0) return ManifestParseError.MissingStore;
    if (wire.format.len == 0) return ManifestParseError.MissingFormat;
    const format = ExportFormat.fromString(wire.format) orelse return ManifestParseError.InvalidFormat;

    const store_owned = allocator.dupe(u8, wire.store) catch return ManifestParseError.OutOfMemory;
    errdefer allocator.free(store_owned);

    var output_dir_owned: ?[]const u8 = null;
    errdefer if (output_dir_owned) |s| allocator.free(s);
    if (wire.output_dir.len > 0) {
        output_dir_owned = allocator.dupe(u8, wire.output_dir) catch return ManifestParseError.OutOfMemory;
    }

    var query_owned: ?[]const u8 = null;
    errdefer if (query_owned) |s| allocator.free(s);
    if (wire.query.len > 0) {
        query_owned = allocator.dupe(u8, wire.query) catch return ManifestParseError.OutOfMemory;
    }

    var entities = allocator.alloc(EntityDef, wire.entities.len) catch return ManifestParseError.OutOfMemory;
    var built: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < built) : (i += 1) {
            freeEntity(allocator, entities[i]);
        }
        allocator.free(entities);
    }

    for (wire.entities) |we| {
        entities[built] = try convertEntity(allocator, we);
        built += 1;
    }

    return EximManifest{
        .store = store_owned,
        .format = format,
        .output_dir = output_dir_owned,
        .query = query_owned,
        .entities = entities,
    };
}

fn convertEntity(allocator: Allocator, we: EntityWire) ManifestParseError!EntityDef {
    if (we.name.len == 0) return ManifestParseError.MissingEntityName;
    if (we.role.len == 0) return ManifestParseError.MissingEntityRole;
    if (we.file.len == 0) return ManifestParseError.MissingEntityFile;

    const role = FileRole.fromString(we.role) orelse return ManifestParseError.InvalidRole;

    const name = allocator.dupe(u8, we.name) catch return ManifestParseError.OutOfMemory;
    errdefer allocator.free(name);

    const file = allocator.dupe(u8, we.file) catch return ManifestParseError.OutOfMemory;
    errdefer allocator.free(file);

    var parent: ?[]const u8 = null;
    errdefer if (parent) |s| allocator.free(s);
    if (we.parent.len > 0) {
        parent = allocator.dupe(u8, we.parent) catch return ManifestParseError.OutOfMemory;
    }

    var parent_field: ?[]const u8 = null;
    errdefer if (parent_field) |s| allocator.free(s);
    if (we.parent_field.len > 0) {
        parent_field = allocator.dupe(u8, we.parent_field) catch return ManifestParseError.OutOfMemory;
    }

    var join_key: ?[]const u8 = null;
    errdefer if (join_key) |s| allocator.free(s);
    if (we.join_key.len > 0) {
        join_key = allocator.dupe(u8, we.join_key) catch return ManifestParseError.OutOfMemory;
    }

    var fields = allocator.alloc(FieldDescriptor, we.fields.len) catch return ManifestParseError.OutOfMemory;
    var built: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < built) : (i += 1) {
            allocator.free(fields[i].name);
        }
        allocator.free(fields);
    }

    for (we.fields) |fw| {
        const fname = allocator.dupe(u8, fw.name) catch return ManifestParseError.OutOfMemory;
        const ftype = FieldType.fromString(fw.type) orelse {
            allocator.free(fname);
            return ManifestParseError.InvalidFieldType;
        };
        fields[built] = .{ .name = fname, .field_type = ftype };
        built += 1;
    }

    return EntityDef{
        .name = name,
        .role = role,
        .file = file,
        .parent = parent,
        .parent_field = parent_field,
        .join_key = join_key,
        .fields = fields,
    };
}

fn freeEntity(allocator: Allocator, e: EntityDef) void {
    allocator.free(e.name);
    allocator.free(e.file);
    if (e.parent) |p| allocator.free(p);
    if (e.parent_field) |pf| allocator.free(pf);
    if (e.join_key) |jk| allocator.free(jk);
    for (e.fields) |fd| allocator.free(fd.name);
    allocator.free(e.fields);
}


const ImportSourceEntry = manifest.ImportSourceEntry;

test "parse - minimal JSON manifest" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: json
        \\output_dir: /data/exports
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    try std.testing.expectEqualStrings("stores.orders", m.store);
    try std.testing.expectEqual(ExportFormat.json, m.format);
    try std.testing.expectEqualStrings("/data/exports", m.output_dir.?);
    try std.testing.expectEqual(@as(?[]const u8, null), m.query);
    try std.testing.expectEqual(@as(usize, 0), m.entities.len);
}

test "parse - with query (standard YAML unescaping)" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: csv
        \\output_dir: /data/exports
        \\query: "orders.filter(status = \"shipped\")"
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    try std.testing.expectEqualStrings("orders.filter(status = \"shipped\")", m.query.?);
}

test "parse - parent only" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: csv
        \\output_dir: /data/exports
        \\entities:
        \\  - name: orders
        \\    role: parent
        \\    file: orders.csv
        \\    fields:
        \\      - name: order_id
        \\        type: int
        \\      - name: customer_name
        \\        type: string
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), m.entities.len);
    const e = m.entities[0];
    try std.testing.expectEqualStrings("orders", e.name);
    try std.testing.expectEqual(FileRole.parent, e.role);
    try std.testing.expectEqualStrings("orders.csv", e.file);
    try std.testing.expectEqual(@as(usize, 2), e.fields.len);
    try std.testing.expectEqualStrings("order_id", e.fields[0].name);
    try std.testing.expectEqual(FieldType.int, e.fields[0].field_type);
    try std.testing.expectEqualStrings("customer_name", e.fields[1].name);
    try std.testing.expectEqual(FieldType.string, e.fields[1].field_type);
}

test "parse - parent + children + grandchildren" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: csv
        \\output_dir: /data/exports/orders
        \\entities:
        \\  - name: orders
        \\    role: parent
        \\    file: orders.csv
        \\    fields:
        \\      - name: order_id
        \\        type: int
        \\      - name: total
        \\        type: double
        \\  - name: items
        \\    role: child
        \\    parent_field: items
        \\    join_key: order_id
        \\    file: order_items.csv
        \\    fields:
        \\      - name: item_id
        \\        type: int
        \\      - name: price
        \\        type: double
        \\  - name: attributes
        \\    role: child
        \\    parent: items
        \\    parent_field: attributes
        \\    join_key: item_id
        \\    file: item_attributes.csv
        \\    fields:
        \\      - name: attr_name
        \\        type: string
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), m.entities.len);

    try std.testing.expectEqualStrings("orders", m.entities[0].name);
    try std.testing.expectEqual(FileRole.parent, m.entities[0].role);
    try std.testing.expectEqual(@as(usize, 2), m.entities[0].fields.len);

    try std.testing.expectEqualStrings("items", m.entities[1].name);
    try std.testing.expectEqual(FileRole.child, m.entities[1].role);
    try std.testing.expectEqualStrings("items", m.entities[1].parent_field.?);
    try std.testing.expectEqualStrings("order_id", m.entities[1].join_key.?);
    try std.testing.expectEqual(@as(?[]const u8, null), m.entities[1].parent);
    try std.testing.expectEqual(@as(usize, 2), m.entities[1].fields.len);

    try std.testing.expectEqualStrings("attributes", m.entities[2].name);
    try std.testing.expectEqualStrings("items", m.entities[2].parent.?);
    try std.testing.expectEqualStrings("attributes", m.entities[2].parent_field.?);
    try std.testing.expectEqualStrings("item_id", m.entities[2].join_key.?);
    try std.testing.expectEqual(@as(usize, 1), m.entities[2].fields.len);
}

test "parse - inline field flow-maps are rejected (block syntax required)" {
    const allocator = std.testing.allocator;
    // The zig_yaml lib has no flow-map support, so inline `{ name:, type: }` field
    // entries don't parse. Real manifests and the exporter use block syntax (see the
    // block-style tests above). This documents the limitation instead of pretending
    // inline syntax works. parse() surfaces the lib's parse failure as OutOfMemory.
    const src =
        \\store: stores.sales
        \\format: csv
        \\output_dir: /data/exports
        \\entities:
        \\  - name: sales
        \\    role: parent
        \\    file: sales.csv
        \\    fields:
        \\      - { name: sale_id, type: int }
    ;

    try std.testing.expectError(ManifestParseError.OutOfMemory, parse(allocator, src));
}

test "parse - missing store returns error" {
    const allocator = std.testing.allocator;
    const src =
        \\format: csv
        \\output_dir: /data/exports
    ;

    const result = parse(allocator, src);
    try std.testing.expectError(ManifestParseError.MissingStore, result);
}

test "parse - missing format returns error" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
    ;

    const result = parse(allocator, src);
    try std.testing.expectError(ManifestParseError.MissingFormat, result);
}

test "parse - findRoot and findChildren" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: csv
        \\output_dir: /data
        \\entities:
        \\  - name: orders
        \\    role: parent
        \\    file: orders.csv
        \\    fields:
        \\      - name: id
        \\        type: int
        \\  - name: items
        \\    role: child
        \\    parent_field: items
        \\    join_key: id
        \\    file: items.csv
        \\    fields:
        \\      - name: sku
        \\        type: string
        \\  - name: attrs
        \\    role: child
        \\    parent: items
        \\    parent_field: attrs
        \\    join_key: sku
        \\    file: attrs.csv
        \\    fields:
        \\      - name: key
        \\        type: string
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    const root = m.findRoot().?;
    try std.testing.expectEqualStrings("orders", root.name);

    const children = try m.findChildren(allocator, "orders");
    defer allocator.free(children);
    try std.testing.expectEqual(@as(usize, 1), children.len);
    try std.testing.expectEqualStrings("items", children[0].name);

    const grandchildren = try m.findChildren(allocator, "items");
    defer allocator.free(grandchildren);
    try std.testing.expectEqual(@as(usize, 1), grandchildren.len);
    try std.testing.expectEqualStrings("attrs", grandchildren[0].name);
}

test "parse - toImportSpec" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: csv
        \\output_dir: /data
        \\entities:
        \\  - name: orders
        \\    role: parent
        \\    file: orders.csv
        \\    fields:
        \\      - name: id
        \\        type: int
        \\  - name: items
        \\    role: child
        \\    parent_field: items
        \\    join_key: id
        \\    file: items.csv
        \\    fields:
        \\      - name: sku
        \\        type: string
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    var spec = try m.toImportSpec(allocator);
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("stores.orders", spec.target);
    try std.testing.expectEqual(ExportFormat.csv, spec.format);
    try std.testing.expect(spec.sources != null);
    const sources = spec.sources.?;
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("/data/orders.csv", sources[0].file);
    try std.testing.expectEqual(FileRole.parent, sources[0].role);
    try std.testing.expectEqualStrings("/data/items.csv", sources[1].file);
    try std.testing.expectEqual(FileRole.child, sources[1].role);
    try std.testing.expectEqualStrings("items", sources[1].embed_as.?);
    try std.testing.expectEqualStrings("id", sources[1].join_key.?);
}

test "toImportSpec - BSON format uses file_path not sources" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: bson
        \\output_dir: /data/exports
        \\entities:
        \\  - name: orders
        \\    role: parent
        \\    file: orders.bson
        \\    fields:
        \\      - name: id
        \\        type: int
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    var spec = try m.toImportSpec(allocator);
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("stores.orders", spec.target);
    try std.testing.expectEqual(ExportFormat.bson, spec.format);
    try std.testing.expectEqualStrings("/data/exports/orders.bson", spec.file_path.?);
    try std.testing.expectEqual(@as(?[]const ImportSourceEntry, null), spec.sources);
}

test "toImportSpec - JSON format without entities uses default file name" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: json
        \\output_dir: /data/exports
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    var spec = try m.toImportSpec(allocator);
    defer spec.deinit(allocator);

    try std.testing.expectEqual(ExportFormat.json, spec.format);
    try std.testing.expectEqualStrings("/data/exports/export.json", spec.file_path.?);
}

test "toImportSpec - JSON with root entity" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: json
        \\output_dir: /tmp/out
        \\entities:
        \\  - name: orders
        \\    role: parent
        \\    file: my_export.json
        \\    fields:
        \\      - name: id
        \\        type: int
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    var spec = try m.toImportSpec(allocator);
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/out/my_export.json", spec.file_path.?);
}

test "toImportSpec - BSON without output_dir uses bare file name" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: bson
        \\entities:
        \\  - name: orders
        \\    role: parent
        \\    file: orders.bson
        \\    fields:
        \\      - name: id
        \\        type: int
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    var spec = try m.toImportSpec(allocator);
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("orders.bson", spec.file_path.?);
}

test "parse - invalid format returns error" {
    const allocator = std.testing.allocator;
    const src =
        \\store: stores.orders
        \\format: xml
    ;

    const result = parse(allocator, src);
    try std.testing.expectError(ManifestParseError.InvalidFormat, result);
}

test "parse - comment lines are skipped" {
    const allocator = std.testing.allocator;
    const src =
        \\# This is a comment
        \\store: stores.orders
        \\# Another comment
        \\format: json
        \\output_dir: /data
    ;

    var m = try parse(allocator, src);
    defer m.deinit(allocator);

    try std.testing.expectEqualStrings("stores.orders", m.store);
    try std.testing.expectEqual(ExportFormat.json, m.format);
}
