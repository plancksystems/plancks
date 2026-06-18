const std = @import("std");
const Io = std.Io;
const yaml_pkg = @import("yaml");
const Yaml = yaml_pkg.Yaml;
const bson = @import("bson");
const schnell = @import("schnell");

pub const MAX_KEY_SIZE: usize = 256;

pub const NodeType = enum { system, user };

pub const Config = struct {
    node_type: NodeType = .user,
    address: []const u8,
    port: u16,
    tls: struct {
        enabled: bool = false,
        cert_file: []const u8 = "",
        key_file: []const u8 = "",
    },
    primary: bool = true,
    max_sessions: u31,
    base_dir: []const u8 = ".",
    backup_dir: []const u8 = "",
    exim_dir: []const u8 = "",
    session: struct {
        idle_timeout_ms: u64,
    },
    buffers: struct {
        memtable: usize,
        vlog: usize,
        wal: usize,
    },
    durability: struct {
        enabled: bool,
        flush_interval_in_ms: i64,
        log_archive: struct {
            enabled: bool,
            dest_path: []const u8,
            retain_logs_days: u32,
        },
    },
    file_sizes: struct {
        vlog: usize,
        wal: usize,
    },
    paths: struct {
        vlog: []const u8 = "",
        wal: []const u8 = "",
        index: []const u8 = "",
    } = .{},
    index: struct {
        primary: struct {
            pool_size: u32,
        },
        secondary: struct {
            pool_size: u32,
        },
    },
    cache: struct {
        enabled: bool = true,
        capacity: usize = 10000,
    } = .{},

    logging: struct {
        path: []const u8 = "",
        level: []const u8 = "info",
        max_size_mb: u32 = 10,
        max_files: u32 = 5,
    } = .{},
    gc: struct {
        dead_ratio: u16,
    },
    security: struct {
        max_failed_attempts: u32 = 5,
        lockout_duration_ms: i64 = 900_000,
        lockout_multiplier: u32 = 2,
    } = .{},

    limits: struct {
        max_batch_size: u32 = 10_000,
        max_message_size: usize = 16 * 1024 * 1024,
    } = .{},

    replica: struct {
        enabled: bool = false,
        sync_interval_ms: u64 = 5000,
        address: []const u8 = "",
        port: u16 = 0,
    } = .{},

    change_streams: struct {
        stores: []const struct {
            ns: []const u8 = "",
            operations: []const []const u8 = &.{},
        } = &.{},
        ring_capacity: usize = 16 * 1024,
    } = .{},

    pub fn toYaml(self: *const Config, allocator: std.mem.Allocator) ![]const u8 {
        var w = Io.Writer.Allocating.init(allocator);
        errdefer w.deinit();
        const wr = &w.writer;

        try wr.print("node_type: {s}\n", .{@tagName(self.node_type)});
        try wr.print("address: \"{s}\"\n", .{self.address});
        try wr.print("port: {d}\n", .{self.port});
        try wr.print("primary: {s}\n", .{if (self.primary) "true" else "false"});
        try wr.print("max_sessions: {d}\n", .{self.max_sessions});
        try wr.writeAll("tls:\n");
        try wr.print("  enabled: {s}\n", .{if (self.tls.enabled) "true" else "false"});
        try wr.print("  cert_file: \"{s}\"\n", .{self.tls.cert_file});
        try wr.print("  key_file: \"{s}\"\n", .{self.tls.key_file});
        try wr.writeAll("session:\n");
        try wr.print("  idle_timeout_ms: {d}\n", .{self.session.idle_timeout_ms});
        try wr.writeAll("buffers:\n");
        try wr.print("  memtable: {d}\n", .{self.buffers.memtable});
        try wr.print("  vlog: {d}\n", .{self.buffers.vlog});
        try wr.print("  wal: {d}\n", .{self.buffers.wal});
        try wr.writeAll("durability:\n");
        try wr.print("  enabled: {s}\n", .{if (self.durability.enabled) "true" else "false"});
        try wr.print("  flush_interval_in_ms: {d}\n", .{self.durability.flush_interval_in_ms});
        try wr.writeAll("  log_archive:\n");
        try wr.print("    enabled: {s}\n", .{if (self.durability.log_archive.enabled) "true" else "false"});
        try wr.print("    dest_path: \"{s}\"\n", .{self.durability.log_archive.dest_path});
        try wr.print("    retain_logs_days: {d}\n", .{self.durability.log_archive.retain_logs_days});
        try wr.writeAll("file_sizes:\n");
        try wr.print("  vlog: {d}\n", .{self.file_sizes.vlog});
        try wr.print("  wal: {d}\n", .{self.file_sizes.wal});
        try wr.writeAll("index:\n");
        try wr.writeAll("  primary:\n");
        try wr.print("    pool_size: {d}\n", .{self.index.primary.pool_size});
        try wr.writeAll("  secondary:\n");
        try wr.print("    pool_size: {d}\n", .{self.index.secondary.pool_size});
        try wr.writeAll("cache:\n");
        try wr.print("  enabled: {s}\n", .{if (self.cache.enabled) "true" else "false"});
        try wr.print("  capacity: {d}\n", .{self.cache.capacity});
        try wr.writeAll("logging:\n");
        try wr.print("  path: \"{s}\"\n", .{self.logging.path});
        try wr.print("  level: {s}\n", .{self.logging.level});
        try wr.print("  max_size_mb: {d}\n", .{self.logging.max_size_mb});
        try wr.print("  max_files: {d}\n", .{self.logging.max_files});
        try wr.writeAll("gc:\n");
        try wr.print("  dead_ratio: {d}\n", .{self.gc.dead_ratio});
        try wr.writeAll("limits:\n");
        try wr.print("  max_batch_size: {d}\n", .{self.limits.max_batch_size});
        try wr.print("  max_message_size: {d}\n", .{self.limits.max_message_size});
        try wr.writeAll("security:\n");
        try wr.print("  max_failed_attempts: {d}\n", .{self.security.max_failed_attempts});
        try wr.print("  lockout_duration_ms: {d}\n", .{self.security.lockout_duration_ms});
        try wr.print("  lockout_multiplier: {d}\n", .{self.security.lockout_multiplier});
        try wr.writeAll("replica:\n");
        try wr.print("  enabled: {s}\n", .{if (self.replica.enabled) "true" else "false"});
        try wr.print("  sync_interval_ms: {d}\n", .{self.replica.sync_interval_ms});
        try wr.print("  address: \"{s}\"\n", .{self.replica.address});
        try wr.print("  port: {d}\n", .{self.replica.port});
        try wr.print("base_dir: \"{s}\"\n", .{self.base_dir});
        if (self.backup_dir.len > 0) {
            try wr.print("backup_dir: \"{s}\"\n", .{self.backup_dir});
        }
        if (self.exim_dir.len > 0) {
            try wr.print("exim_dir: \"{s}\"\n", .{self.exim_dir});
        }
        try wr.writeAll("paths:\n");
        try wr.print("  vlog: \"{s}\"\n", .{self.paths.vlog});
        try wr.print("  wal: \"{s}\"\n", .{self.paths.wal});
        try wr.print("  index: \"{s}\"\n", .{self.paths.index});

        return try w.toOwnedSlice();
    }

    pub fn save(self: *const Config, allocator: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
        const yaml_data = try self.toYaml(allocator);
        defer allocator.free(yaml_data);
        try Io.Dir.writeFile(dir, io, .{ .sub_path = "db.yaml", .data = yaml_data });
    }

    pub fn toBson(self: *const Config, allocator: std.mem.Allocator) ![]const u8 {
        var doc = bson.BsonDocument.empty(allocator);
        defer doc.deinit();

        try doc.putString("address", self.address);
        try doc.putInt32("port", @as(i32, @intCast(self.port)));
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putBool("enabled", self.tls.enabled);
            try sub.putString("cert_file", self.tls.cert_file);
            try sub.putString("key_file", self.tls.key_file);
            try doc.putDocument("tls", sub);
        }
        try doc.putBool("primary", self.primary);
        try doc.putInt32("max_sessions", @as(i32, @intCast(self.max_sessions)));
        try doc.putString("base_dir", self.base_dir);
        try doc.putString("backup_dir", self.backup_dir);
        try doc.putString("exim_dir", self.exim_dir);
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putInt64("idle_timeout_ms", @as(i64, @intCast(self.session.idle_timeout_ms)));
            try doc.putDocument("session", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putInt64("memtable", @as(i64, @intCast(self.buffers.memtable)));
            try sub.putInt64("vlog", @as(i64, @intCast(self.buffers.vlog)));
            try sub.putInt64("wal", @as(i64, @intCast(self.buffers.wal)));
            try doc.putDocument("buffers", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putBool("enabled", self.durability.enabled);
            try sub.putInt64("flush_interval_in_ms", @as(i64, @intCast(self.durability.flush_interval_in_ms)));
            {
                var la = bson.BsonDocument.empty(allocator);
                defer la.deinit();
                try la.putBool("enabled", self.durability.log_archive.enabled);
                try la.putString("dest_path", self.durability.log_archive.dest_path);
                try la.putInt32("retain_logs_days", @as(i32, @intCast(self.durability.log_archive.retain_logs_days)));
                try sub.putDocument("log_archive", la);
            }
            try doc.putDocument("durability", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putInt64("vlog", @as(i64, @intCast(self.file_sizes.vlog)));
            try sub.putInt64("wal", @as(i64, @intCast(self.file_sizes.wal)));
            try doc.putDocument("file_sizes", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            {
                var p = bson.BsonDocument.empty(allocator);
                defer p.deinit();
                try p.putInt32("pool_size", @as(i32, @intCast(self.index.primary.pool_size)));
                try sub.putDocument("primary", p);
            }
            {
                var s = bson.BsonDocument.empty(allocator);
                defer s.deinit();
                try s.putInt32("pool_size", @as(i32, @intCast(self.index.secondary.pool_size)));
                try sub.putDocument("secondary", s);
            }
            try doc.putDocument("index", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putBool("enabled", self.cache.enabled);
            try sub.putInt64("capacity", @as(i64, @intCast(self.cache.capacity)));
            try doc.putDocument("cache", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putString("path", self.logging.path);
            try sub.putString("level", self.logging.level);
            try sub.putInt32("max_size_mb", @as(i32, @intCast(self.logging.max_size_mb)));
            try sub.putInt32("max_files", @as(i32, @intCast(self.logging.max_files)));
            try doc.putDocument("logging", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putInt32("dead_ratio", @as(i32, @intCast(self.gc.dead_ratio)));
            try doc.putDocument("gc", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putInt32("max_failed_attempts", @as(i32, @intCast(self.security.max_failed_attempts)));
            try sub.putInt64("lockout_duration_ms", self.security.lockout_duration_ms);
            try sub.putInt32("lockout_multiplier", @as(i32, @intCast(self.security.lockout_multiplier)));
            try doc.putDocument("security", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putInt32("max_batch_size", @as(i32, @intCast(self.limits.max_batch_size)));
            try sub.putInt64("max_message_size", @as(i64, @intCast(self.limits.max_message_size)));
            try doc.putDocument("limits", sub);
        }
        {
            var sub = bson.BsonDocument.empty(allocator);
            defer sub.deinit();
            try sub.putBool("enabled", self.replica.enabled);
            try sub.putInt64("sync_interval_ms", @as(i64, @intCast(self.replica.sync_interval_ms)));
            try sub.putString("address", self.replica.address);
            try sub.putInt32("port", @as(i32, @intCast(self.replica.port)));
            try doc.putDocument("replica", sub);
        }
        return try allocator.dupe(u8, doc.toBytes());
    }

    pub fn applyBson(self: *Config, allocator: std.mem.Allocator, data: []const u8) !void {
        var doc = try bson.BsonDocument.init(allocator, data, false);
        defer doc.deinit();

        if (try doc.getString("backup_dir")) |v| {
            if (!std.mem.eql(u8, self.backup_dir, v)) {
                if (self.backup_dir.len > 0) allocator.free(self.backup_dir);
                self.backup_dir = if (v.len > 0) try allocator.dupe(u8, v) else "";
            }
        }

        if (try doc.getString("exim_dir")) |v| {
            if (!std.mem.eql(u8, self.exim_dir, v)) {
                if (self.exim_dir.len > 0) allocator.free(self.exim_dir);
                self.exim_dir = if (v.len > 0) try allocator.dupe(u8, v) else "";
            }
        }

        if (try doc.getInt32("max_sessions")) |v| {
            self.max_sessions = @intCast(v);
        }

        if (try doc.getDocument("session")) |sub| {
            if (try sub.getInt64("idle_timeout_ms")) |v| {
                self.session.idle_timeout_ms = @intCast(v);
            }
        }

        if (try doc.getDocument("buffers")) |sub| {
            if (try sub.getInt64("memtable")) |v| self.buffers.memtable = @intCast(v);
            if (try sub.getInt64("vlog")) |v| self.buffers.vlog = @intCast(v);
            if (try sub.getInt64("wal")) |v| self.buffers.wal = @intCast(v);
        }

        if (try doc.getDocument("durability")) |sub| {
            if (try sub.getBool("enabled")) |v| self.durability.enabled = v;
            if (try sub.getInt64("flush_interval_in_ms")) |v| {
                self.durability.flush_interval_in_ms = @intCast(v);
            }
            if (try sub.getDocument("log_archive")) |la| {
                if (try la.getBool("enabled")) |v| self.durability.log_archive.enabled = v;
                if (try la.getString("dest_path")) |v| {
                    if (!std.mem.eql(u8, self.durability.log_archive.dest_path, v)) {
                        if (self.durability.log_archive.dest_path.len > 0) allocator.free(self.durability.log_archive.dest_path);
                        self.durability.log_archive.dest_path = try allocator.dupe(u8, v);
                    }
                }
                if (try la.getInt32("retain_logs_days")) |v| {
                    self.durability.log_archive.retain_logs_days = @intCast(v);
                }
            }
        }

        if (try doc.getDocument("file_sizes")) |sub| {
            if (try sub.getInt64("vlog")) |v| self.file_sizes.vlog = @intCast(v);
            if (try sub.getInt64("wal")) |v| self.file_sizes.wal = @intCast(v);
        }

        if (try doc.getDocument("index")) |sub| {
            if (try sub.getDocument("primary")) |p| {
                if (try p.getInt32("pool_size")) |v| self.index.primary.pool_size = @intCast(v);
            }
            if (try sub.getDocument("secondary")) |s| {
                if (try s.getInt32("pool_size")) |v| self.index.secondary.pool_size = @intCast(v);
            }
        }

        if (try doc.getDocument("cache")) |sub| {
            if (try sub.getBool("enabled")) |v| self.cache.enabled = v;
            if (try sub.getInt64("capacity")) |v| self.cache.capacity = @intCast(v);
        }

        if (try doc.getDocument("logging")) |sub| {
            if (try sub.getString("path")) |v| {
                if (!std.mem.eql(u8, self.logging.path, v)) {
                    if (self.logging.path.len > 0) allocator.free(self.logging.path);
                    self.logging.path = if (v.len > 0) try allocator.dupe(u8, v) else "";
                }
            }
            if (try sub.getString("level")) |v| {
                if (!std.mem.eql(u8, self.logging.level, v)) {
                    if (self.logging.level.len > 0) allocator.free(self.logging.level);
                    self.logging.level = if (v.len > 0) try allocator.dupe(u8, v) else "";
                }
            }
            if (try sub.getInt32("max_size_mb")) |v| self.logging.max_size_mb = @intCast(v);
            if (try sub.getInt32("max_files")) |v| self.logging.max_files = @intCast(v);
        }

        if (try doc.getDocument("gc")) |sub| {
            if (try sub.getInt32("dead_ratio")) |v| self.gc.dead_ratio = @intCast(v);
        }

        if (try doc.getDocument("security")) |sub| {
            if (try sub.getInt32("max_failed_attempts")) |v| self.security.max_failed_attempts = @intCast(v);
            if (try sub.getInt64("lockout_duration_ms")) |v| self.security.lockout_duration_ms = v;
            if (try sub.getInt32("lockout_multiplier")) |v| self.security.lockout_multiplier = @intCast(v);
        }

        if (try doc.getDocument("limits")) |sub| {
            if (try sub.getInt32("max_batch_size")) |v| self.limits.max_batch_size = @intCast(v);
            if (try sub.getInt64("max_message_size")) |v| self.limits.max_message_size = @intCast(v);
        }

        if (try doc.getDocument("replica")) |sub| {
            if (try sub.getBool("enabled")) |v| self.replica.enabled = v;
            if (try sub.getInt64("sync_interval_ms")) |v| {
                self.replica.sync_interval_ms = @intCast(v);
            }
            if (try sub.getString("address")) |v| {
                if (!std.mem.eql(u8, self.replica.address, v)) {
                    if (self.replica.address.len > 0) allocator.free(self.replica.address);
                    self.replica.address = if (v.len > 0) try allocator.dupe(u8, v) else "";
                }
            }
            if (try sub.getInt32("port")) |v| self.replica.port = @intCast(v);
        }
    }

    pub fn applyYaml(self: *Config, allocator: std.mem.Allocator, yaml_str: []const u8) !void {
        var yaml: Yaml = .{ .source = yaml_str };
        try yaml.load(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = try yaml.parse(arena.allocator(), Config);
        yaml.deinit(allocator);

        if (!std.mem.eql(u8, self.backup_dir, parsed.backup_dir)) {
            if (self.backup_dir.len > 0) allocator.free(self.backup_dir);
            self.backup_dir = if (parsed.backup_dir.len > 0)
                try allocator.dupe(u8, parsed.backup_dir)
            else
                "";
        }

        self.max_sessions = parsed.max_sessions;

        self.session.idle_timeout_ms = parsed.session.idle_timeout_ms;

        self.buffers.memtable = parsed.buffers.memtable;
        self.buffers.vlog = parsed.buffers.vlog;
        self.buffers.wal = parsed.buffers.wal;

        self.durability.enabled = parsed.durability.enabled;
        self.durability.flush_interval_in_ms = parsed.durability.flush_interval_in_ms;
        self.durability.log_archive.enabled = parsed.durability.log_archive.enabled;
        if (!std.mem.eql(u8, self.durability.log_archive.dest_path, parsed.durability.log_archive.dest_path)) {
            if (self.durability.log_archive.dest_path.len > 0) allocator.free(self.durability.log_archive.dest_path);
            self.durability.log_archive.dest_path = try allocator.dupe(u8, parsed.durability.log_archive.dest_path);
        }
        self.durability.log_archive.retain_logs_days = parsed.durability.log_archive.retain_logs_days;

        self.file_sizes.vlog = parsed.file_sizes.vlog;
        self.file_sizes.wal = parsed.file_sizes.wal;

        self.index.primary.pool_size = parsed.index.primary.pool_size;
        self.index.secondary.pool_size = parsed.index.secondary.pool_size;

        self.cache.enabled = parsed.cache.enabled;
        self.cache.capacity = parsed.cache.capacity;

        if (!std.mem.eql(u8, self.logging.path, parsed.logging.path)) {
            if (self.logging.path.len > 0) allocator.free(self.logging.path);
            self.logging.path = if (parsed.logging.path.len > 0)
                try allocator.dupe(u8, parsed.logging.path)
            else
                "";
        }
        if (!std.mem.eql(u8, self.logging.level, parsed.logging.level)) {
            if (self.logging.level.len > 0) allocator.free(self.logging.level);
            self.logging.level = if (parsed.logging.level.len > 0)
                try allocator.dupe(u8, parsed.logging.level)
            else
                "";
        }
        self.logging.max_size_mb = parsed.logging.max_size_mb;
        self.logging.max_files = parsed.logging.max_files;

        self.gc.dead_ratio = parsed.gc.dead_ratio;

        self.security.max_failed_attempts = parsed.security.max_failed_attempts;
        self.security.lockout_duration_ms = parsed.security.lockout_duration_ms;
        self.security.lockout_multiplier = parsed.security.lockout_multiplier;

        self.limits.max_batch_size = parsed.limits.max_batch_size;
        self.limits.max_message_size = parsed.limits.max_message_size;

        self.replica.enabled = parsed.replica.enabled;
        self.replica.sync_interval_ms = parsed.replica.sync_interval_ms;
        if (!std.mem.eql(u8, self.replica.address, parsed.replica.address)) {
            if (self.replica.address.len > 0) allocator.free(self.replica.address);
            self.replica.address = if (parsed.replica.address.len > 0)
                try allocator.dupe(u8, parsed.replica.address)
            else
                "";
        }
        self.replica.port = parsed.replica.port;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
        allocator.free(self.base_dir);
        if (self.backup_dir.len > 0) allocator.free(self.backup_dir);
        allocator.free(self.paths.vlog);
        allocator.free(self.paths.wal);
        allocator.free(self.paths.index);
        if (self.tls.enabled) {
            allocator.free(self.tls.cert_file);
            allocator.free(self.tls.key_file);
        }
        if (self.replica.address.len > 0) allocator.free(self.replica.address);
        if (self.durability.log_archive.dest_path.len > 0) allocator.free(self.durability.log_archive.dest_path);
        if (self.logging.path.len > 0) allocator.free(self.logging.path);
        if (self.logging.level.len > 0) allocator.free(self.logging.level);
        allocator.destroy(self);
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: Io.Dir) !*Config {
        const content = try Io.Dir.readFileAlloc(dir, io, "db.yaml", allocator, .unlimited);
        defer allocator.free(content);

        var yaml: Yaml = .{ .source = content };
        try yaml.load(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = try yaml.parse(arena.allocator(), Config);
        yaml.deinit(allocator);

        const cfg = try allocator.create(Config);
        cfg.* = parsed;
        cfg.node_type = parsed.node_type;
        cfg.address = try allocator.dupe(u8, parsed.address);
        cfg.primary = parsed.primary;
        cfg.base_dir = try allocator.dupe(u8, parsed.base_dir);
        if (parsed.backup_dir.len > 0) {
            cfg.backup_dir = try allocator.dupe(u8, parsed.backup_dir);
        } else {
            cfg.backup_dir = "";
        }
        cfg.paths.vlog = try std.fmt.allocPrint(allocator, "{s}/logs", .{cfg.base_dir});
        cfg.paths.wal = try std.fmt.allocPrint(allocator, "{s}/wals", .{cfg.base_dir});
        cfg.paths.index = try std.fmt.allocPrint(allocator, "{s}/indexes", .{cfg.base_dir});

        if (parsed.tls.enabled) {
            cfg.tls.enabled = true;
            cfg.tls.cert_file = try allocator.dupe(u8, parsed.tls.cert_file);
            cfg.tls.key_file = try allocator.dupe(u8, parsed.tls.key_file);
        }
        if (parsed.replica.address.len > 0) {
            cfg.replica.address = try allocator.dupe(u8, parsed.replica.address);
        }
        cfg.durability.log_archive.dest_path = try allocator.dupe(u8, parsed.durability.log_archive.dest_path);
        cfg.logging.path = try std.fmt.allocPrint(allocator, "{s}/planck.log", .{cfg.base_dir});
        if (parsed.logging.level.len > 0) {
            cfg.logging.level = try allocator.dupe(u8, parsed.logging.level);
        }

        cfg.change_streams.ring_capacity = parsed.change_streams.ring_capacity;
        if (parsed.change_streams.stores.len > 0) {
            const StoreEntry = @TypeOf(parsed.change_streams.stores[0]);
            const out = try allocator.alloc(StoreEntry, parsed.change_streams.stores.len);
            for (parsed.change_streams.stores, 0..) |s, i| {
                const ops = try allocator.alloc([]const u8, s.operations.len);
                for (s.operations, 0..) |op, j| ops[j] = try allocator.dupe(u8, op);
                out[i] = .{
                    .ns = try allocator.dupe(u8, s.ns),
                    .operations = ops,
                };
            }
            cfg.change_streams.stores = out;
        } else {
            cfg.change_streams.stores = &.{};
        }
        return cfg;
    }
};

test "Config - cache defaults" {
    const cache: @TypeOf(@as(Config, undefined).cache) = .{};
    try std.testing.expect(cache.enabled);
    try std.testing.expectEqual(@as(usize, 10000), cache.capacity);
}

test "Config - struct field types" {
    try std.testing.expectEqual(@as(usize, @sizeOf(u16)), @sizeOf(@TypeOf(@as(Config, undefined).port)));
    try std.testing.expectEqual(@as(usize, @sizeOf(u31)), @sizeOf(@TypeOf(@as(Config, undefined).max_sessions)));
}

test "Config - nested struct access" {
    var cfg: Config = undefined;
    cfg.cache = .{};
    try std.testing.expect(cfg.cache.enabled);
}

test "Config - parse pizzaqsr-hda-mono db.yaml verbatim" {
    const yaml_str =
        \\address: "0.0.0.0"
        \\primary: true
        \\max_sessions: 128
        \\# planck TCP wire port - clients connect here to query the DB.
        \\# Unique per app on the same host.
        \\port: 24010
        \\tls:
        \\  enabled: false
        \\  cert_file: ""
        \\  key_file: ""
        \\session:
        \\  idle_timeout_ms: 604800000
        \\buffers:
        \\  memtable: 16777216
        \\  vlog: 4194304
        \\  wal: 262144
        \\durability:
        \\  enabled: true
        \\  flush_interval_in_ms: 1000
        \\  log_archive:
        \\    enabled: false
        \\    dest_path: ""
        \\    retain_logs_days: 15
        \\file_sizes:
        \\  vlog: 1073741824
        \\  wal: 16777216
        \\index:
        \\  primary:
        \\    pool_size: 64
        \\  secondary:
        \\    pool_size: 64
        \\cache:
        \\  enabled: false
        \\  capacity: 10000
        \\logging:
        \\  path: ""
        \\  level: info
        \\  max_size_mb: 10
        \\  max_files: 5
        \\gc:
        \\  dead_ratio: 30
        \\limits:
        \\  max_batch_size: 10000
        \\  max_message_size: 16777216
        \\security:
        \\  max_failed_attempts: 5
        \\  lockout_duration_ms: 900000
        \\  lockout_multiplier: 2
        \\replica:
        \\  enabled: false
        \\  sync_interval_ms: 5000
        \\  address: "127.0.0.1"
        \\  port: 0
        \\
        \\change_streams:
        \\  stores:
        \\    - ns: orders
        \\      operations: [insert, update, delete]
        \\  ring_capacity: 16384
        \\
    ;

    const allocator = std.testing.allocator;

    var yaml: Yaml = .{ .source = yaml_str };
    try yaml.load(allocator);
    defer yaml.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try yaml.parse(arena.allocator(), Config);

    try std.testing.expectEqual(@as(u16, 24010), parsed.port);
    try std.testing.expectEqual(@as(usize, 1), parsed.change_streams.stores.len);
    try std.testing.expectEqualStrings("orders", parsed.change_streams.stores[0].ns);
    try std.testing.expectEqual(@as(usize, 16384), parsed.change_streams.ring_capacity);
}

test "Config - DbCfgSubset parse of pizzaqsr-hda-mono db.yaml" {
    const yaml_str =
        \\address: "0.0.0.0"
        \\primary: true
        \\max_sessions: 128
        \\port: 24010
        \\tls:
        \\  enabled: false
        \\  cert_file: ""
        \\  key_file: ""
        \\session:
        \\  idle_timeout_ms: 604800000
        \\buffers:
        \\  memtable: 16777216
        \\  vlog: 4194304
        \\  wal: 262144
        \\durability:
        \\  enabled: true
        \\  flush_interval_in_ms: 1000
        \\  log_archive:
        \\    enabled: false
        \\    dest_path: ""
        \\    retain_logs_days: 15
        \\file_sizes:
        \\  vlog: 1073741824
        \\  wal: 16777216
        \\index:
        \\  primary:
        \\    pool_size: 64
        \\  secondary:
        \\    pool_size: 64
        \\cache:
        \\  enabled: false
        \\  capacity: 10000
        \\logging:
        \\  path: ""
        \\  level: info
        \\  max_size_mb: 10
        \\  max_files: 5
        \\gc:
        \\  dead_ratio: 30
        \\limits:
        \\  max_batch_size: 10000
        \\  max_message_size: 16777216
        \\security:
        \\  max_failed_attempts: 5
        \\  lockout_duration_ms: 900000
        \\  lockout_multiplier: 2
        \\replica:
        \\  enabled: false
        \\  sync_interval_ms: 5000
        \\  address: "127.0.0.1"
        \\  port: 0
        \\
        \\change_streams:
        \\  stores:
        \\    - ns: orders
        \\      operations: [insert, update, delete]
        \\  ring_capacity: 16384
        \\
    ;

    const DbCfgSubset = struct {
        port: u16 = 0,
    };

    const allocator = std.testing.allocator;

    var yaml: Yaml = .{ .source = yaml_str };
    try yaml.load(allocator);
    defer yaml.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try yaml.parse(arena.allocator(), DbCfgSubset);

    try std.testing.expectEqual(@as(u16, 24010), parsed.port);
}

test "Config - flow array followed by comment inside mapping (zig_yaml regression)" {
    const yaml_str =
        \\port: 24010
        \\change_streams:
        \\  stores:
        \\    - ns: orders
        \\      operations: [insert, update, delete]
        \\  # comment after flow array trips zig_yaml v0.3.0
        \\  ring_capacity: 16384
        \\
    ;

    const DbCfgSubset = struct {
        port: u16 = 0,
    };

    const allocator = std.testing.allocator;
    var yaml: Yaml = .{ .source = yaml_str };
    defer yaml.deinit(allocator);
    if (yaml.load(allocator)) |_| {
        std.debug.print("note: yaml.load now succeeds — zig_yaml regression fixed; flip this test\n", .{});
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try yaml.parse(arena.allocator(), DbCfgSubset);
    } else |err| {
        try std.testing.expectEqual(error.ParseFailure, err);
    }
}
