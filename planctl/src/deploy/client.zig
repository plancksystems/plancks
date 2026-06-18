const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.deploy_client);

pub const DeployClient = struct {
    allocator: std.mem.Allocator,
    io: Io,
    server_url: []const u8,
    dry_run: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: Io, server_url: []const u8) DeployClient {
        return .{ .allocator = allocator, .io = io, .server_url = server_url, .dry_run = false };
    }

    pub fn authenticate(self: *DeployClient, uid: []const u8, key: []const u8) !bool {
        const body = try std.fmt.allocPrint(self.allocator, "uid={s}&key={s}", .{ uid, key });
        defer self.allocator.free(body);

        const resp = try self.post("/api/system-db/connect", body, "application/x-www-form-urlencoded");
        defer self.allocator.free(resp);

        return std.mem.indexOf(u8, resp, "\"success\":true") != null;
    }

    pub fn connectService(self: *DeployClient, service: []const u8) !bool {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"service\":\"{s}\"}}", .{service});
        defer self.allocator.free(body);

        const resp = try self.post("/api/connect", body, "application/json");
        defer self.allocator.free(resp);

        return std.mem.indexOf(u8, resp, "\"success\":true") != null;
    }

    pub fn ensureApp(self: *DeployClient, name: []const u8, description: []const u8) !void {
        const body = try std.fmt.allocPrint(self.allocator, "action=create&name={s}&description={s}", .{ name, description });
        defer self.allocator.free(body);
        const resp = try self.post("/api/apps", body, "application/x-www-form-urlencoded");
        defer self.allocator.free(resp);
    }

    pub fn deployBinary(self: *DeployClient, app_name: []const u8, binary_data: []const u8) !void {
        const boundary = "----PlanctlDeployBoundary";
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        try appendMultipartField(&body, self.allocator, boundary, "action", "deploy-binary");
        try appendMultipartField(&body, self.allocator, boundary, "name", app_name);
        try appendMultipartFile(&body, self.allocator, boundary, "binary", "app.bin", binary_data);
        try body.appendSlice(self.allocator, "--");
        try body.appendSlice(self.allocator, boundary);
        try body.appendSlice(self.allocator, "--\r\n");

        const ct = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer self.allocator.free(ct);

        const resp = try self.post("/api/deploy-app", body.items, ct);
        defer self.allocator.free(resp);

        if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
            log.err("deploy-binary failed: {s}", .{resp});
            return error.DeployFailed;
        }

        if (extractWarning(resp)) |warning| {
            std.debug.print("  Warning: {s}\n", .{warning});
        }
    }

    fn extractWarning(resp: []const u8) ?[]const u8 {
        const marker = "\"warning\":\"";
        const start = std.mem.indexOf(u8, resp, marker) orelse return null;
        const value_start = start + marker.len;
        const value_end = std.mem.indexOfScalarPos(u8, resp, value_start, '"') orelse return null;
        if (value_end <= value_start) return null;
        return resp[value_start..value_end];
    }

    pub fn deployFile(self: *DeployClient, app_name: []const u8, rel_path: []const u8, file_data: []const u8) !void {
        const boundary = "----PlanctlDeployBoundary";
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        try appendMultipartField(&body, self.allocator, boundary, "action", "deploy-file");
        try appendMultipartField(&body, self.allocator, boundary, "name", app_name);
        try appendMultipartField(&body, self.allocator, boundary, "path", rel_path);
        try appendMultipartFile(&body, self.allocator, boundary, "file", rel_path, file_data);
        try body.appendSlice(self.allocator, "--");
        try body.appendSlice(self.allocator, boundary);
        try body.appendSlice(self.allocator, "--\r\n");

        const ct = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer self.allocator.free(ct);

        const resp = try self.post("/api/deploy-app", body.items, ct);
        defer self.allocator.free(resp);
    }

    pub fn deployConfig(self: *DeployClient, app_name: []const u8, rel_path: []const u8, file_data: []const u8) !void {
        const boundary = "----PlanctlDeployBoundary";
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        try appendMultipartField(&body, self.allocator, boundary, "action", "deploy-config");
        try appendMultipartField(&body, self.allocator, boundary, "name", app_name);
        try appendMultipartField(&body, self.allocator, boundary, "path", rel_path);
        try appendMultipartFile(&body, self.allocator, boundary, "file", rel_path, file_data);
        try body.appendSlice(self.allocator, "--");
        try body.appendSlice(self.allocator, boundary);
        try body.appendSlice(self.allocator, "--\r\n");

        const ct = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer self.allocator.free(ct);

        const resp = try self.post("/api/deploy-app", body.items, ct);
        defer self.allocator.free(resp);

        if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
            log.err("deploy-config failed for '{s}': {s}", .{ rel_path, resp });
            return error.DeployFailed;
        }
    }

    pub fn deployService(self: *DeployClient, app_name: []const u8, name: []const u8, service_name: []const u8, db_yaml: []const u8, service_yaml: []const u8, admin_uid: []const u8, admin_key: []const u8) ![]const u8 {
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        try body_buf.appendSlice(self.allocator, "action=deploy&app=");
        try body_buf.appendSlice(self.allocator, app_name);
        try body_buf.appendSlice(self.allocator, "&name=");
        try body_buf.appendSlice(self.allocator, name);
        try body_buf.appendSlice(self.allocator, "&service_name=");
        try body_buf.appendSlice(self.allocator, service_name);
        try body_buf.appendSlice(self.allocator, "&admin_uid=");
        try body_buf.appendSlice(self.allocator, admin_uid);
        try body_buf.appendSlice(self.allocator, "&admin_key=");
        try body_buf.appendSlice(self.allocator, admin_key);
        try body_buf.appendSlice(self.allocator, "&config_yaml=");
        try urlEncodeYaml(&body_buf, self.allocator, db_yaml);
        try body_buf.appendSlice(self.allocator, "&service_yaml=");
        try urlEncodeYaml(&body_buf, self.allocator, service_yaml);

        return try self.post("/api/deploy", body_buf.items, "application/x-www-form-urlencoded");
    }

    pub fn deploySseService(self: *DeployClient, app_name: []const u8, name: []const u8, service_name: []const u8, sse_yaml: []const u8, binary: []const u8) ![]const u8 {
        const encoder = std.base64.standard.Encoder;
        const b64_len = encoder.calcSize(binary.len);
        const b64 = try self.allocator.alloc(u8, b64_len);
        defer self.allocator.free(b64);
        _ = encoder.encode(b64, binary);

        var enc_b64: std.ArrayList(u8) = .empty;
        defer enc_b64.deinit(self.allocator);
        for (b64) |c| {
            switch (c) {
                '+' => try enc_b64.appendSlice(self.allocator, "%2B"),
                '/' => try enc_b64.appendSlice(self.allocator, "%2F"),
                '=' => try enc_b64.appendSlice(self.allocator, "%3D"),
                else => try enc_b64.append(self.allocator, c),
            }
        }

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        try body_buf.appendSlice(self.allocator, "action=deploy&kind=sse_hub&app=");
        try body_buf.appendSlice(self.allocator, app_name);
        try body_buf.appendSlice(self.allocator, "&name=");
        try body_buf.appendSlice(self.allocator, name);
        try body_buf.appendSlice(self.allocator, "&service_name=");
        try body_buf.appendSlice(self.allocator, service_name);
        try body_buf.appendSlice(self.allocator, "&service_yaml=");
        try urlEncodeYaml(&body_buf, self.allocator, sse_yaml);
        try body_buf.appendSlice(self.allocator, "&binary_data=");
        try body_buf.appendSlice(self.allocator, enc_b64.items);

        return try self.post("/api/deploy", body_buf.items, "application/x-www-form-urlencoded");
    }

    fn urlEncodeYaml(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, yaml: []const u8) !void {
        for (yaml) |c| {
            switch (c) {
                '\n' => try buf.appendSlice(allocator, "%0A"),
                '\r' => try buf.appendSlice(allocator, "%0D"),
                ' ' => try buf.appendSlice(allocator, "+"),
                ':' => try buf.appendSlice(allocator, "%3A"),
                '#' => try buf.appendSlice(allocator, "%23"),
                else => try buf.append(allocator, c),
            }
        }
    }

    pub fn deployWasm(self: *DeployClient, service_name: []const u8, app_name: []const u8, wasm_data: []const u8) !void {
        const encoder = std.base64.standard.Encoder;
        const b64_len = encoder.calcSize(wasm_data.len);
        const b64 = try self.allocator.alloc(u8, b64_len);
        defer self.allocator.free(b64);
        _ = encoder.encode(b64, wasm_data);

        const base_name = if (std.mem.indexOf(u8, service_name, ".db.")) |idx| service_name[0..idx] else service_name;
        const wasm_filename = try std.fmt.allocPrint(self.allocator, "planck.{s}.wasm", .{base_name});
        defer self.allocator.free(wasm_filename);

        var encoded_b64: std.ArrayList(u8) = .empty;
        defer encoded_b64.deinit(self.allocator);
        for (b64) |c| {
            switch (c) {
                '+' => try encoded_b64.appendSlice(self.allocator, "%2B"),
                '/' => try encoded_b64.appendSlice(self.allocator, "%2F"),
                '=' => try encoded_b64.appendSlice(self.allocator, "%3D"),
                else => try encoded_b64.append(self.allocator, c),
            }
        }

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "action=update-wasm&name=");
        try body.appendSlice(self.allocator, service_name);
        try body.appendSlice(self.allocator, "&app=");
        try body.appendSlice(self.allocator, app_name);
        try body.appendSlice(self.allocator, "&wasm_filename=");
        try body.appendSlice(self.allocator, wasm_filename);
        try body.appendSlice(self.allocator, "&wasm_data=");
        try body.appendSlice(self.allocator, encoded_b64.items);

        const resp = try self.post("/api/deploy", body.items, "application/x-www-form-urlencoded");
        defer self.allocator.free(resp);

        if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
            log.err("deploy-wasm failed: {s}", .{resp});
            return error.DeployFailed;
        }
    }

    pub fn appLifecycle(self: *DeployClient, app_name: []const u8, action: []const u8) ![]const u8 {
        const body = try std.fmt.allocPrint(self.allocator, "action={s}&app={s}", .{ action, app_name });
        defer self.allocator.free(body);
        return try self.post("/api/app-lifecycle", body, "application/x-www-form-urlencoded");
    }

    pub fn serviceLifecycle(self: *DeployClient, app_name: []const u8, service_name: []const u8, action: []const u8) ![]const u8 {
        const full = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ app_name, service_name });
        defer self.allocator.free(full);
        const body = try std.fmt.allocPrint(self.allocator, "action={s}&app={s}&name={s}", .{ action, app_name, full });
        defer self.allocator.free(body);
        return try self.post("/api/deploy", body, "application/x-www-form-urlencoded");
    }

    pub fn undeployService(self: *DeployClient, app_name: []const u8, service_name: []const u8) ![]const u8 {
        const body = try std.fmt.allocPrint(
            self.allocator,
            "action=undeploy&app={s}&name={s}",
            .{ app_name, service_name },
        );
        defer self.allocator.free(body);
        return try self.post("/api/deploy", body, "application/x-www-form-urlencoded");
    }

    pub fn deleteApp(self: *DeployClient, app_name: []const u8) ![]const u8 {
        const body = try std.fmt.allocPrint(self.allocator, "action=delete&name={s}", .{app_name});
        defer self.allocator.free(body);
        return try self.post("/api/apps", body, "application/x-www-form-urlencoded");
    }

    pub fn listServices(self: *DeployClient) ![]const u8 {
        return try self.get("/api/services");
    }

    pub fn listApps(self: *DeployClient) ![]const u8 {
        return try self.get("/api/apps");
    }

    pub fn listDatabases(self: *DeployClient) ![]const u8 {
        return try self.get("/api/databases");
    }


    pub fn get(self: *DeployClient, path: []const u8) ![]const u8 {
        if (self.dry_run) {
            std.debug.print("  [dry-run] GET {s}{s}\n", .{ self.server_url, path });
            return try self.allocator.dupe(u8, "{\"success\":true,\"dry_run\":true}");
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.server_url, path });
        defer self.allocator.free(url);

        return self.httpRequest(.GET, url, null, null) catch return error.ConnectionFailed;
    }

    pub fn post(self: *DeployClient, path: []const u8, body: []const u8, content_type: []const u8) ![]const u8 {
        if (self.dry_run) {
            std.debug.print("  [dry-run] POST {s}{s} ({d} bytes, {s})\n", .{
                self.server_url, path, body.len, content_type,
            });
            return try self.allocator.dupe(u8, "{\"success\":true,\"dry_run\":true}");
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.server_url, path });
        defer self.allocator.free(url);

        return self.httpRequest(.POST, url, body, content_type) catch return error.ConnectionFailed;
    }

    fn httpRequest(self: *DeployClient, method: std.http.Method, url: []const u8, payload: ?[]const u8, content_type: ?[]const u8) ![]const u8 {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        if (std.mem.startsWith(u8, url, "https://")) {
            const now = std.Io.Clock.real.now(self.io);
            client.ca_bundle.rescan(self.allocator, self.io, now) catch |err| {
                log.warn("CA bundle rescan failed for {s}: {} — continuing with empty trust store", .{ url, err });
            };
        }

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        var header_buf: [2]std.http.Header = undefined;
        var header_count: usize = 0;
        header_buf[header_count] = .{ .name = "Connection", .value = "close" };
        header_count += 1;
        if (content_type) |ct| {
            header_buf[header_count] = .{ .name = "Content-Type", .value = ct };
            header_count += 1;
        }
        const extra_headers: []const std.http.Header = header_buf[0..header_count];

        _ = client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &aw.writer,
            .extra_headers = extra_headers,
        }) catch |err| {
            log.err("http {s} {s} failed: {}", .{ @tagName(method), url, err });
            return err;
        };

        return try aw.toOwnedSlice();
    }


    fn appendMultipartField(body_buf: *std.ArrayList(u8), allocator: std.mem.Allocator, boundary: []const u8, name: []const u8, value: []const u8) !void {
        try body_buf.appendSlice(allocator, "--");
        try body_buf.appendSlice(allocator, boundary);
        try body_buf.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"");
        try body_buf.appendSlice(allocator, name);
        try body_buf.appendSlice(allocator, "\"\r\n\r\n");
        try body_buf.appendSlice(allocator, value);
        try body_buf.appendSlice(allocator, "\r\n");
    }

    fn appendMultipartFile(body_buf: *std.ArrayList(u8), allocator: std.mem.Allocator, boundary: []const u8, field_name: []const u8, filename: []const u8, data: []const u8) !void {
        try body_buf.appendSlice(allocator, "--");
        try body_buf.appendSlice(allocator, boundary);
        try body_buf.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"");
        try body_buf.appendSlice(allocator, field_name);
        try body_buf.appendSlice(allocator, "\"; filename=\"");
        try body_buf.appendSlice(allocator, filename);
        try body_buf.appendSlice(allocator, "\"\r\nContent-Type: application/octet-stream\r\n\r\n");
        try body_buf.appendSlice(allocator, data);
        try body_buf.appendSlice(allocator, "\r\n");
    }
};
