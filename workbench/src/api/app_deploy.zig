const std = @import("std");
const schnell = @import("schnell");
const Request = schnell.Request;
const Response = schnell.Response;
const Io = std.Io;
const Dir = Io.Dir;
const Paths = @import("../tasks/paths.zig").Paths;
const AppServices = @import("../tasks/services.zig").AppServices;

const log = std.log.scoped(.api_app_deploy);

var services_ptr: ?*AppServices = null;

pub fn setServices(s: *AppServices) void {
    services_ptr = s;
}

pub fn handle(allocator: std.mem.Allocator, req: *const Request, res: *Response, _: ?*anyopaque) anyerror!void {
    const services = services_ptr orelse {
        res.status = .internal_server_error;
        try res.setHeader("Content-Type", "application/json");
        try res.write("{\"success\":false,\"error\":\"Not initialized\"}");
        return;
    };

    const svc_mgr = services.service_manager orelse {
        try writeError(res, "Service manager not initialized");
        return;
    };

    const action = req.getFormParam("action") orelse {
        try writeError(res, "Action is required");
        return;
    };
    const app_name = req.getFormParam("name") orelse {
        try writeError(res, "App name is required");
        return;
    };

    const p = Paths{ .data_dir = svc_mgr.data_dir };

    if (std.mem.eql(u8, action, "deploy-binary")) {
        const binary_part = req.getMultipartField("binary") orelse {
            try writeError(res, "Binary file is required (field: binary)");
            return;
        };

        if (binary_part.data.len == 0) {
            try writeError(res, "Empty binary file");
            return;
        }

        const mgr = services.app_manager orelse {
            try writeError(res, "App manager not initialized");
            return;
        };

        mgr.deploy(app_name, binary_part.data) catch |err| {
            log.err("deploy-binary failed for app '{s}': {}", .{ app_name, err });
            try writeError(res, "Failed to deploy binary");
            return;
        };

        log.info("deployed binary for app '{s}' ({d} bytes)", .{ app_name, binary_part.data.len });

        if (mgr.takeProxyWarning()) |warn| {
            defer services.allocator.free(warn);
            try writeSuccessWithWarning(res, warn);
        } else {
            try writeSuccess(res);
        }
    } else if (std.mem.eql(u8, action, "deploy-file")) {
        const file_part = req.getMultipartField("file") orelse {
            try writeError(res, "File is required (field: file)");
            return;
        };
        const rel_path = req.getFormParam("path") orelse {
            try writeError(res, "File path is required");
            return;
        };

        if (std.mem.indexOf(u8, rel_path, "..") != null) {
            try writeError(res, "Invalid path");
            return;
        }

        const public_dir = try p.appPublic(allocator, app_name);
        defer allocator.free(public_dir);

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ public_dir, rel_path });
        defer allocator.free(full_path);

        if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |sep| {
            Dir.createDirPath(.cwd(), services.io, full_path[0..sep]) catch {};
        }

        Dir.writeFile(.cwd(), services.io, .{ .sub_path = full_path, .data = file_part.data }) catch |err| {
            log.err("failed to write file '{s}' for app '{s}': {}", .{ rel_path, app_name, err });
            try writeError(res, "Failed to write file");
            return;
        };

        log.info("deployed file '{s}' to app '{s}' ({d} bytes)", .{ rel_path, app_name, file_part.data.len });
        try writeSuccess(res);
    } else if (std.mem.eql(u8, action, "deploy-config")) {
        const file_part = req.getMultipartField("file") orelse {
            try writeError(res, "File is required (field: file)");
            return;
        };
        const rel_path = req.getFormParam("path") orelse {
            try writeError(res, "File path is required");
            return;
        };

        if (std.mem.indexOf(u8, rel_path, "..") != null or std.mem.startsWith(u8, rel_path, "/")) {
            try writeError(res, "Invalid path");
            return;
        }

        const app_dir = try p.appDir(allocator, app_name);
        defer allocator.free(app_dir);

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app_dir, rel_path });
        defer allocator.free(full_path);

        if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |sep| {
            Dir.createDirPath(.cwd(), services.io, full_path[0..sep]) catch {};
        }

        Dir.writeFile(.cwd(), services.io, .{ .sub_path = full_path, .data = file_part.data }) catch |err| {
            log.err("failed to write config '{s}' for app '{s}': {}", .{ rel_path, app_name, err });
            try writeError(res, "Failed to write file");
            return;
        };

        log.info("deployed config '{s}' to app '{s}' ({d} bytes)", .{ rel_path, app_name, file_part.data.len });

        if (std.mem.eql(u8, std.fs.path.basename(rel_path), "Caddyfile")) {
            if (services.app_manager) |mgr| mgr.proxyLifecycle(app_name, .restart);
        }

        try writeSuccess(res);
    } else if (std.mem.eql(u8, action, "restart")) {
        const mgr = services.app_manager orelse {
            try writeError(res, "App manager not initialized");
            return;
        };

        mgr.restart(app_name) catch |err| {
            log.err("failed to restart app '{s}': {}", .{ app_name, err });
            try writeError(res, "Failed to restart app");
            return;
        };

        log.info("restarted app '{s}'", .{app_name});
        try writeSuccess(res);
    } else {
        try writeError(res, "Unknown action. Use: deploy-binary, deploy-file, deploy-config, restart");
    }
}

fn writeSuccess(res: *Response) !void {
    try res.setHeader("Content-Type", "application/json");
    try res.write("{\"success\":true}");
}

fn writeSuccessWithWarning(res: *Response, msg: []const u8) !void {
    try res.setHeader("Content-Type", "application/json");
    var buf: [1024]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{{\"success\":true,\"warning\":\"{s}\"}}", .{msg}) catch "{\"success\":true}";
    try res.write(out);
}

fn writeError(res: *Response, msg: []const u8) !void {
    try res.setHeader("Content-Type", "application/json");
    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch "{\"success\":false}";
    try res.write(out);
}
