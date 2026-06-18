
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Yaml = @import("yaml").Yaml;

const Profile = @import("config.zig").Profile;
const DeployClient = @import("client.zig").DeployClient;

pub const Arch = enum { mono, micro };

pub const Error = error{
    PortIsZero,
    MonoNameMismatch,
    PortDuplicateLocal,
    PortCollidesAcrossApps,
    InvalidConfig,
} || Allocator.Error || Io.Dir.OpenError || Io.Dir.ReadFileError;

const PortInfo = struct {
    location: []const u8,
    value: u16,
};


const DbCfgSubset = struct {
    port: u16 = 0,
};

const ServiceCfgSubset = struct {
    name: []const u8 = "",
    wasm: struct {
        http: struct {
            port: u16 = 0,
        } = .{},
    } = .{},
};

const AppCfgSubset = struct {
    app: struct {
        name: []const u8 = "",
        port: u16 = 0,
    } = .{},
};

pub fn validate(allocator: Allocator, io: Io, arch: Arch, profile: *const Profile) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ports: std.ArrayList(PortInfo) = .empty;
    var project_name: []const u8 = "";

    switch (arch) {
        .mono => try collectMonoPorts(a, io, &ports, &project_name),
        .micro => try collectMicroPorts(a, io, &ports, &project_name),
    }

    try checkZero(ports.items);
    try checkLocalDuplicates(ports.items);
    try checkCrossAppCollisions(a, io, ports.items, project_name, profile);
    if (arch == .mono) try checkMonoNameAgreement(a, io);
}

fn checkMonoNameAgreement(a: Allocator, io: Io) !void {
    const app_cfg = readAppYaml(a, io, "./app.yaml") catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const svc_cfg = readServiceYaml(a, io, "./app/service.yaml") catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const app_name = app_cfg.app.name;
    const svc_name = svc_cfg.name;
    if (app_name.len == 0 or svc_name.len == 0) return;
    if (!std.mem.eql(u8, app_name, svc_name)) {
        std.debug.print(
            "Error: ./app.yaml:name ('{s}') and ./app/service.yaml:name ('{s}') disagree. " ++
                "Mono apps need both to match (planctl uses app.yaml, planck/db reads service.yaml). " ++
                "Update one to match the other and retry.\n",
            .{ app_name, svc_name },
        );
        return error.MonoNameMismatch;
    }
}


fn collectMonoPorts(a: Allocator, io: Io, ports: *std.ArrayList(PortInfo), project_name: *[]const u8) !void {
    const db = readDbYaml(a, io, "./app/db.yaml") catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Error: ./app/db.yaml not found. Run `planctl deploy` from the project root.\n", .{});
            return error.InvalidConfig;
        },
        else => return err,
    };
    const svc = readServiceYaml(a, io, "./app/service.yaml") catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Error: ./app/service.yaml not found. Run `planctl deploy` from the project root.\n", .{});
            return error.InvalidConfig;
        },
        else => return err,
    };
    project_name.* = svc.name;
    try ports.append(a, .{ .location = "./app/db.yaml:port", .value = db.port });
    try ports.append(a, .{ .location = "./app/service.yaml:wasm.http.port", .value = svc.wasm.http.port });
}

fn collectMicroPorts(a: Allocator, io: Io, ports: *std.ArrayList(PortInfo), project_name: *[]const u8) !void {
    const app_cfg = readAppYaml(a, io, "./app.yaml") catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Error: ./app.yaml not found. Run `planctl deploy` from the project root.\n", .{});
            return error.InvalidConfig;
        },
        else => return err,
    };
    project_name.* = app_cfg.app.name;
    try ports.append(a, .{ .location = "./app.yaml:app.port", .value = app_cfg.app.port });

    var svc_dir = Io.Dir.openDir(.cwd(), io, "app/services", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer svc_dir.close(io);

    var iter = svc_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const db_path = try std.fmt.allocPrint(a, "./app/services/{s}/db.yaml", .{entry.name});
        const db_cfg = readDbYaml(a, io, db_path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const db_port_loc = try std.fmt.allocPrint(a, "{s}:port", .{db_path});
        try ports.append(a, .{ .location = db_port_loc, .value = db_cfg.port });

        const svc_path = try std.fmt.allocPrint(a, "./app/services/{s}/service.yaml", .{entry.name});
        const svc_cfg = readServiceYaml(a, io, svc_path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const wasm_loc = try std.fmt.allocPrint(a, "{s}:wasm.http.port", .{svc_path});
        try ports.append(a, .{ .location = wasm_loc, .value = svc_cfg.wasm.http.port });
    }
}

fn readDbYaml(a: Allocator, io: Io, path: []const u8) !DbCfgSubset {
    const content = try Io.Dir.readFileAlloc(.cwd(), io, path, a, .unlimited);
    var yaml: Yaml = .{ .source = content };
    try yaml.load(a);
    return try yaml.parse(a, DbCfgSubset);
}

fn readServiceYaml(a: Allocator, io: Io, path: []const u8) !ServiceCfgSubset {
    const content = try Io.Dir.readFileAlloc(.cwd(), io, path, a, .unlimited);
    var yaml: Yaml = .{ .source = content };
    try yaml.load(a);
    return try yaml.parse(a, ServiceCfgSubset);
}

fn readAppYaml(a: Allocator, io: Io, path: []const u8) !AppCfgSubset {
    const content = try Io.Dir.readFileAlloc(.cwd(), io, path, a, .unlimited);
    var yaml: Yaml = .{ .source = content };
    try yaml.load(a);
    return try yaml.parse(a, AppCfgSubset);
}


fn checkZero(ports: []const PortInfo) !void {
    for (ports) |p| {
        if (p.value == 0) {
            std.debug.print(
                "Error: {s} is 0. The template ships with port: 0 — set a real port before deploy.\n",
                .{p.location},
            );
            return error.PortIsZero;
        }
    }
}

fn checkLocalDuplicates(ports: []const PortInfo) !void {
    var i: usize = 0;
    while (i < ports.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < ports.len) : (j += 1) {
            if (ports[i].value == ports[j].value) {
                std.debug.print(
                    "Error: port {d} is used by both {s} and {s}. Each port in this project must be unique.\n",
                    .{ ports[i].value, ports[i].location, ports[j].location },
                );
                return error.PortDuplicateLocal;
            }
        }
    }
}

fn checkCrossAppCollisions(
    a: Allocator,
    io: Io,
    local_ports: []const PortInfo,
    project_name: []const u8,
    profile: *const Profile
) !void {
    const remote = fetchRemotePorts(a, io, project_name, profile) catch |err| {
        std.debug.print(
            "  Warning: could not reach workbench to check port collisions ({s}) — skipping cross-app check.\n",
            .{@errorName(err)},
        );
        return;
    };
    for (local_ports) |lp| {
        for (remote) |rp| {
            if (lp.value == rp.value) {
                std.debug.print(
                    "Error: port {d} ({s}) is already used by {s}. Pick a different port.\n",
                    .{ lp.value, lp.location, rp.location },
                );
                return error.PortCollidesAcrossApps;
            }
        }
    }
}


const ApiAppEntry = struct {
    name: []const u8 = "",
    shell_port: u16 = 0,
    services: []const ApiServiceEntry = &.{},
};

const ApiServiceEntry = struct {
    name: []const u8 = "",
    port: u16 = 0,
    wasm_port: u16 = 0,
};

const ApiAppsResponse = struct {
    success: bool = false,
    apps: []const ApiAppEntry = &.{},
};

fn fetchRemotePorts(
    a: Allocator,
    io: Io,
    project_name: []const u8,
    profile: *const Profile
) ![]const PortInfo {
    if (profile.nodes.len == 0) return error.NoNode;
    const node = profile.nodes[0];
    var client = DeployClient.init(a, io, node.server);

    _ = client.authenticate(node.uid, node.key) catch return error.AuthFailed;

    const body = try client.get("/api/apps");
    defer a.free(body);

    const parsed = std.json.parseFromSliceLeaky(ApiAppsResponse, a, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.ParseFailed;

    if (!parsed.success) return error.WorkbenchError;

    var out: std.ArrayList(PortInfo) = .empty;
    for (parsed.apps) |app| {
        if (std.mem.eql(u8, app.name, project_name)) continue;
        if (app.shell_port > 0) {
            const loc = try std.fmt.allocPrint(a, "app '{s}' shell port", .{app.name});
            try out.append(a, .{ .location = loc, .value = app.shell_port });
        }
        for (app.services) |svc| {
            if (svc.port > 0) {
                const loc = try std.fmt.allocPrint(a, "app '{s}' / service '{s}' (planck port)", .{ app.name, svc.name });
                try out.append(a, .{ .location = loc, .value = svc.port });
            }
            if (svc.wasm_port > 0) {
                const loc = try std.fmt.allocPrint(a, "app '{s}' / service '{s}' (wasm port)", .{ app.name, svc.name });
                try out.append(a, .{ .location = loc, .value = svc.wasm_port });
            }
        }
    }
    return try out.toOwnedSlice(a);
}
