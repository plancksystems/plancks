const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Yaml = @import("yaml").Yaml;

pub const AppMeta = struct {
    name: []const u8,
    description: []const u8,
};


const ParsedAppSection = struct {
    name: []const u8 = "",
    description: []const u8 = "",
};

const ParsedConfigForMeta = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    app: ParsedAppSection = .{},
    service: ParsedAppSection = .{},
};

pub fn loadFromCwd(allocator: std.mem.Allocator, io: Io) !AppMeta {
    const config_paths = [_][]const u8{ "app.yaml", "db.yaml", "../../app.yaml" };
    for (config_paths) |path| {
        if (loadConfigAt(allocator, io, path)) |meta| {
            return meta;
        } else |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        }
    }

    std.debug.print("Error: no app.yaml (micro shell) or db.yaml (mono) found. Run from the project root or a service subdirectory.\n", .{});
    return error.NoAppYaml;
}

pub fn loadConfigAt(allocator: std.mem.Allocator, io: Io, path: []const u8) !AppMeta {
    const yaml_str = try Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
    defer allocator.free(yaml_str);

    return parseConfigYaml(allocator, yaml_str, path);
}

pub fn parseConfigYaml(allocator: std.mem.Allocator, yaml_str: []const u8, source_label: []const u8) !AppMeta {
    var yaml: Yaml = .{ .source = yaml_str };
    yaml.load(allocator) catch |err| {
        if (!builtin.is_test) std.debug.print("Error: failed to parse {s}: {s}\n", .{ source_label, @errorName(err) });
        return error.InvalidYaml;
    };
    defer yaml.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = yaml.parse(arena.allocator(), ParsedConfigForMeta) catch |err| {
        if (!builtin.is_test) std.debug.print("Error: invalid {s}: {s}\n", .{ source_label, @errorName(err) });
        return error.InvalidYaml;
    };

    const name = if (parsed.name.len > 0)
        parsed.name
    else if (parsed.app.name.len > 0)
        parsed.app.name
    else if (parsed.service.name.len > 0)
        parsed.service.name
    else {
        if (!builtin.is_test) std.debug.print("Error: 'name' (or 'app.name' / 'service.name') not found in {s}\n", .{source_label});
        return error.InvalidYaml;
    };
    const description = if (parsed.description.len > 0)
        parsed.description
    else if (parsed.app.description.len > 0)
        parsed.app.description
    else
        parsed.service.description;

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
    };
}

