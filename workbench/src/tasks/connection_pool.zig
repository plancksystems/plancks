const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const planck = @import("planck");
const PlanckClient = planck.PlanckClient;
const TimeoutConfig = planck.TimeoutConfig;

const log = std.log.scoped(.connection_pool);

pub const ServiceConn = struct {
    client: *PlanckClient,
};

pub const ConnectionPool = struct {
    allocator: Allocator,
    io: Io,
    entries: std.StringHashMap(*ServiceEntry),

    const wb_timeout: TimeoutConfig = .{
        .connect_timeout_ms = 5000,
        .read_timeout_ms = 120000,
        .write_timeout_ms = 10000,
        .operation_timeout_ms = 120000,
    };

    const ServiceEntry = struct {
        host: []const u8,
        port: u16,
        uid: []const u8,
        key: []const u8,
        tls: bool,
        conn: ?ServiceConn,
        mutex: Io.Mutex,
        role: []const u8,
        allocator: Allocator,
        io: Io,

        fn closeConn(self: *ServiceEntry) void {
            if (self.conn) |conn| {
                log.warn("closeConn: closing connection to {s}:{d}", .{ self.host, self.port });
                conn.client.disconnect();
                conn.client.deinit();
                self.conn = null;
            }
        }

        fn freeStrings(self: *ServiceEntry, allocator: Allocator) void {
            allocator.free(self.host);
            allocator.free(self.uid);
            allocator.free(self.key);
            if (self.role.len > 0) allocator.free(self.role);
        }
    };

    pub fn init(allocator: Allocator, io: Io) !*ConnectionPool {
        const self = try allocator.create(ConnectionPool);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .entries = std.StringHashMap(*ServiceEntry).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *ConnectionPool) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            entry.closeConn();
            entry.freeStrings(self.allocator);
            self.allocator.free(kv.key_ptr.*);
            self.allocator.destroy(entry);
        }
        self.entries.deinit();
        self.allocator.destroy(self);
    }

    pub fn register(self: *ConnectionPool, name: []const u8, host: []const u8, port: u16, uid: []const u8, key: []const u8, tls: bool) !void {
        if (self.entries.get(name)) |existing| {
            existing.closeConn();
            existing.freeStrings(self.allocator);
            existing.host = try self.allocator.dupe(u8, host);
            existing.port = port;
            existing.uid = try self.allocator.dupe(u8, uid);
            existing.key = try self.allocator.dupe(u8, key);
            existing.tls = tls;
            existing.role = "";
            return;
        }

        const entry = try self.allocator.create(ServiceEntry);
        entry.* = .{
            .host = try self.allocator.dupe(u8, host),
            .port = port,
            .uid = try self.allocator.dupe(u8, uid),
            .key = try self.allocator.dupe(u8, key),
            .tls = tls,
            .conn = null,
            .mutex = Io.Mutex.init,
            .role = "",
            .allocator = self.allocator,
            .io = self.io,
        };

        const name_dupe = try self.allocator.dupe(u8, name);
        try self.entries.put(name_dupe, entry);
    }

    pub fn unregister(self: *ConnectionPool, name: []const u8) void {
        log.warn("unregister: removing '{s}' from pool", .{name});
        const kv = self.entries.fetchRemove(name) orelse return;
        const entry = kv.value;
        entry.closeConn();
        entry.freeStrings(self.allocator);
        self.allocator.free(kv.key);
        self.allocator.destroy(entry);
    }

    pub fn disconnect(self: *ConnectionPool, name: []const u8) void {
        log.warn("disconnect: closing connection for '{s}' (keeping entry)", .{name});
        const entry = self.entries.get(name) orelse return;
        entry.mutex.lockUncancelable(self.io);
        entry.closeConn();
        entry.mutex.unlock(self.io);
    }

    pub fn acquire(self: *ConnectionPool, name: []const u8) !*ServiceConn {
        const entry = self.entries.get(name) orelse return error.ServiceNotRegistered;

        entry.mutex.lockUncancelable(self.io);

        if (entry.conn == null) {
            self.createConn(entry) catch |err| {
                entry.mutex.unlock(self.io);
                return err;
            };
        }

        return &entry.conn.?;
    }

    pub fn tryAcquire(self: *ConnectionPool, name: []const u8) ?*ServiceConn {
        const entry = self.entries.get(name) orelse return null;

        if (!entry.mutex.tryLock()) return null;

        if (entry.conn == null) {
            entry.mutex.unlock(self.io);
            return null;
        }

        return &entry.conn.?;
    }

    pub fn release(self: *ConnectionPool, name: []const u8, broken: bool) void {
        const entry = self.entries.get(name) orelse return;
        if (broken) {
            entry.closeConn();
        }
        entry.mutex.unlock(self.io);
    }

    pub fn isConnected(self: *ConnectionPool, name: []const u8) bool {
        const entry = self.entries.get(name) orelse return false;
        return entry.conn != null;
    }

    pub fn isRegistered(self: *ConnectionPool, name: []const u8) bool {
        return self.entries.contains(name);
    }

    pub fn getRole(self: *ConnectionPool, name: []const u8) []const u8 {
        const entry = self.entries.get(name) orelse return "";
        return entry.role;
    }

    pub fn getUid(self: *ConnectionPool, name: []const u8) []const u8 {
        const entry = self.entries.get(name) orelse return "";
        return entry.uid;
    }

    pub fn getKey(self: *ConnectionPool, name: []const u8) []const u8 {
        const entry = self.entries.get(name) orelse return "";
        return entry.key;
    }

    pub fn getPort(self: *ConnectionPool, name: []const u8) u16 {
        const entry = self.entries.get(name) orelse return 0;
        return entry.port;
    }

    pub fn setRole(self: *ConnectionPool, name: []const u8, role: []const u8) void {
        const entry = self.entries.get(name) orelse return;
        const new_role = self.allocator.dupe(u8, role) catch return;
        if (entry.role.len > 0) self.allocator.free(entry.role);
        entry.role = new_role;
    }

    fn createConn(self: *ConnectionPool, entry: *ServiceEntry) !void {
        const client = try PlanckClient.init(self.allocator, self.io);
        errdefer client.deinit();

        client.setTimeoutConfig(wb_timeout);

        const conn_str = try std.fmt.allocPrint(self.allocator, "{s}:{d};uid={s};key={s};tls={s}", .{
            entry.host, entry.port, entry.uid, entry.key,
            if (entry.tls) "true" else "false",
        });
        defer self.allocator.free(conn_str);

        var auth = client.connect(conn_str) catch |err| {
            log.err("connect to {s}:{d} failed: {}", .{ entry.host, entry.port, err });
            return err;
        };
        auth.deinit();

        entry.conn = .{ .client = client };

        log.info("connected to {s}:{d}", .{ entry.host, entry.port });
    }

    pub fn resolveServiceName(_: *ConnectionPool, request: anytype, databases: anytype) ?[]const u8 {
        if (request.getFormParam("service")) |name| {
            for (databases) |entry| {
                if (std.mem.eql(u8, entry.name, name)) return entry.name;
            }
        }
        if (request.query.get("service")) |name| {
            for (databases) |entry| {
                if (std.mem.eql(u8, entry.name, name)) return entry.name;
            }
        }
        const db_str = request.getFormParam("db") orelse request.query.get("db") orelse return null;
        const idx = std.fmt.parseInt(usize, db_str, 10) catch return null;
        if (idx < databases.len) return databases[idx].name;
        return null;
    }
};
