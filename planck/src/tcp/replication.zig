const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;

const Config = @import("../common/config.zig").Config;
const proto = @import("proto");
const Packet = proto.Packet;
const Operation = proto.Operation;
const Buffer = @import("utils").Buffer;

const ReplWal = @import("../durability/repl_wal.zig").ReplWal;

const log = std.log.scoped(.replication);

const QUEUE_DEPTH = 32768;

const RETENTION_COUNT: u64 = 12;

pub const ShipRecord = struct {
    op_kind: u8,
    store_ns: []const u8,
    lsn: u64,
    doc_id: u128,
    timestamp: i64,
    data: []const u8,
};

pub const ReplicationManager = struct {
    allocator: Allocator,
    io: Io,
    group: Io.Group,
    config: *Config,

    address: []const u8,
    port: u16,

    queue: std.Io.Queue([]u8),
    queue_buf: [][]u8,

    notify_queue: std.Io.Queue(u64),
    notify_buf: []u64,

    repl_wal: *ReplWal,
    wal_mutex: Io.Mutex,

    ship_bw: Buffer,
    repl_client: ReplClient,

    pub fn init(allocator: Allocator, io: Io, config: *Config) !*ReplicationManager {
        const self = try allocator.create(ReplicationManager);
        errdefer allocator.destroy(self);

        const queue_buf = try allocator.alloc([]u8, QUEUE_DEPTH);
        errdefer allocator.free(queue_buf);

        const notify_buf = try allocator.alloc(u64, 256);
        errdefer allocator.free(notify_buf);

        const repl_wal_path = try fmt.allocPrint(allocator, "{s}/repl", .{config.paths.wal});
        defer allocator.free(repl_wal_path);

        const repl_wal = try ReplWal.init(allocator, .{
            .dir_path = repl_wal_path,
            .max_file_size = 16 * 1024 * 1024,
            .sync_interval_ms = config.replica.sync_interval_ms,
            .buffer_size = 256 * 1024,
            .io = io,
        });
        errdefer repl_wal.deinit();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .group = Io.Group.init,
            .config = config,
            .address = config.replica.address,
            .port = config.replica.port,
            .queue = std.Io.Queue([]u8).init(queue_buf),
            .queue_buf = queue_buf,
            .notify_queue = std.Io.Queue(u64).init(notify_buf),
            .notify_buf = notify_buf,
            .repl_wal = repl_wal,
            .wal_mutex = Io.Mutex.init,
            .ship_bw = try Buffer.init(allocator, config.buffers.wal),
            .repl_client = try ReplClient.init(allocator, io, config.buffers.wal),
        };

        return self;
    }

    pub fn deinit(self: *ReplicationManager) void {
        self.queue.close(self.io);
        self.notify_queue.close(self.io);
        self.group.cancel(self.io);

        self.repl_wal.deinit();
        self.ship_bw.deinit();
        self.repl_client.deinit();
        self.allocator.free(self.queue_buf);
        self.allocator.free(self.notify_buf);
        self.allocator.destroy(self);
    }

    pub fn ship(self: *ReplicationManager, record: ShipRecord) void {
        if (!self.config.primary) return;

        const pck = Packet{
            .checksum = 0,
            .packet_length = 0,
            .packet_id = 0,
            .timestamp = 0,
            .op = Operation{ .ShipWal = .{
                .op_kind = record.op_kind,
                .store_ns = record.store_ns,
                .lsn = record.lsn,
                .doc_id = record.doc_id,
                .timestamp = record.timestamp,
                .data = record.data,
            } },
        };

        self.ship_bw.reset();

        const serialized = pck.serialize(&self.ship_bw) catch |err| {
            log.err("ship: serialize failed: {}", .{err});
            return;
        };
        std.mem.writeInt(u32, serialized[8..12], @intCast(serialized.len), .little);

        const copy = self.allocator.dupe(u8, serialized) catch |err| {
            log.err("ship: OOM: {}", .{err});
            return;
        };

        self.queue.putOneUncancelable(self.io, copy) catch {
            self.allocator.free(copy);
        };
    }

    pub fn shipFlush(self: *ReplicationManager) void {
        self.ship(.{ .op_kind = 254, .store_ns = &.{}, .lsn = 0, .doc_id = 0, .timestamp = 0, .data = &.{} });
    }

    pub fn startTasks(self: *ReplicationManager) void {
        self.group.async(self.io, runFlushTask, .{self});
        self.group.async(self.io, runSyncTask, .{self});
    }

    fn runFlushTask(self: *ReplicationManager) Io.Cancelable!void {
        while (true) {
            const frame = self.queue.getOne(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => return,
            };
            defer self.allocator.free(frame);

            const op_kind = frame[25];

            self.wal_mutex.lockUncancelable(self.io);
            defer self.wal_mutex.unlock(self.io);

            if (op_kind == 254 or op_kind == 4 or op_kind == 5 or op_kind == 7 or op_kind == 8) {
                self.repl_wal.append(frame) catch |err| {
                    log.err("flush: WAL append failed: {}", .{err});
                    continue;
                };
                if (self.repl_wal.file_size > 0) {
                    const seq = self.repl_wal.rotate() catch |err| {
                        log.err("flush: WAL rotate failed: {}", .{err});
                        continue;
                    };
                    self.notify_queue.putOneUncancelable(self.io, seq) catch {};
                }
                continue;
            }

            const ns_len = std.mem.readInt(u32, frame[26..30], .little);
            const lsn = std.mem.readInt(u64, frame[30 + ns_len ..][0..8], .little);

            self.repl_wal.append(frame) catch |err| {
                log.err("flush: WAL append failed: {}", .{err});
                continue;
            };
            self.repl_wal.last_lsn = lsn;

            if (self.repl_wal.shouldRotate()) {
                const seq = self.repl_wal.rotate() catch |err| {
                    log.err("flush: WAL rotate failed: {}", .{err});
                    continue;
                };
                self.notify_queue.putOneUncancelable(self.io, seq) catch {};
            }
        }
    }

    fn runSyncTask(self: *ReplicationManager) Io.Cancelable!void {
        self.syncPendingFiles();

        while (true) {
            const seq = self.notify_queue.getOne(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => return,
            };
            _ = seq;

            self.syncPendingFiles();
        }
    }

    fn syncPendingFiles(self: *ReplicationManager) void {
        const cp = self.repl_wal.loadCheckpoint() catch return;

        const dir = Io.Dir.openDir(.cwd(), self.io, self.repl_wal.dir_path, .{ .iterate = true }) catch return;
        var wal_dir = dir;
        defer wal_dir.close(self.io);

        var pending: std.ArrayList(u64) = .empty;
        defer pending.deinit(self.allocator);

        var dir_iter = wal_dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".rwal")) {
                const seq_str = entry.name[0 .. entry.name.len - 5];
                const seq = fmt.parseUnsigned(u64, seq_str, 10) catch continue;
                if (seq < self.repl_wal.current_seq) {
                    pending.append(self.allocator, seq) catch continue;
                }
            }
        }

        if (pending.items.len == 0) return;

        std.mem.sort(u64, pending.items, {}, std.sort.asc(u64));

        for (pending.items) |seq| {
            if (seq <= cp.file_seq) continue;

            const frames = self.repl_wal.readFile(seq, self.allocator) catch |err| {
                log.err("sync: failed to read WAL seq={d}: {}", .{ seq, err });
                return;
            };
            defer {
                for (frames) |frame| self.allocator.free(frame);
                self.allocator.free(frames);
            }

            if (frames.len == 0) {
                self.repl_wal.deleteFile(seq) catch {};
                continue;
            }

            self.sendWalFile(frames) catch |err| {
                log.warn("sync to {s}:{d} failed (seq={d}): {} - will retry", .{
                    self.address, self.port, seq, err,
                });
                return;
            };

            self.repl_wal.checkpoint(seq) catch |err| {
                log.err("sync: checkpoint failed for seq={d}: {}", .{ seq, err });
                return;
            };
        }

        const updated_cp = self.repl_wal.loadCheckpoint() catch return;
        for (pending.items) |seq| {
            if (seq <= updated_cp.file_seq) {
                self.repl_wal.deleteFile(seq) catch {};
            }
        }
    }

    fn sendWalFile(self: *ReplicationManager, frames: [][]u8) !void {
        try self.repl_client.connect(self.config);
        defer self.repl_client.disconnect();
        try self.repl_client.ship(frames);

        log.info("synced {d} frames to {s}:{d}", .{ frames.len, self.address, self.port });
    }
};

 
const ReplClient = struct {
    const FRAME_OVERHEAD = 64;

    allocator: Allocator,
    io: Io,
    auth_bw: Buffer,
    read_buf: []u8,
    write_buf: []u8,
    stream: ?net.Stream = null,
    reader: ?net.Stream.Reader = null,
    writer: ?net.Stream.Writer = null,

    fn init(allocator: Allocator, io: Io, wal_buf_size: usize) !ReplClient {
        const cap = wal_buf_size + FRAME_OVERHEAD;
        var auth_bw = try Buffer.init(allocator, cap);
        errdefer auth_bw.deinit();
        const read_buf = try allocator.alloc(u8, cap);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, cap);
        return .{
            .allocator = allocator,
            .io = io,
            .auth_bw = auth_bw,
            .read_buf = read_buf,
            .write_buf = write_buf,
        };
    }

    fn deinit(self: *ReplClient) void {
        self.disconnect();
        self.auth_bw.deinit();
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
    }

    fn connect(self: *ReplClient, config: *const Config) !void {
        if (config.replica.uid.len == 0 or config.replica.key.len == 0) {
            log.err("repl: replica.uid/replica.key not configured; refusing to ship unauthenticated", .{});
            return error.NoReplicationCredentials;
        }
        const address = try net.IpAddress.parseIp4(config.replica.address, config.replica.port);
        const stream = address.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
            log.err("repl: connection failed to {s}:{d}: {}", .{ config.replica.address, config.replica.port, err });
            return err;
        };
        errdefer stream.close(self.io);
        self.stream = stream;
        self.reader = net.Stream.Reader.init(stream, self.io, self.read_buf);
        self.writer = net.Stream.Writer.init(stream, self.io, self.write_buf);

        try self.authenticate(config);
    }

    fn disconnect(self: *ReplClient) void {
        self.reader = null;
        self.writer = null;
        if (self.stream) |*s| {
            s.close(self.io);
            self.stream = null;
        }
    }

    fn ship(self: *ReplClient, frames: [][]u8) !void {
        for (frames) |frame| {
            try self.writeFramed(frame);
            try self.readReply();
        }
    }

    fn authenticate(self: *ReplClient, config: *const Config) !void {
        const auth = Packet{
            .checksum = 0,
            .packet_length = 0,
            .packet_id = 0,
            .timestamp = 0,
            .op = Operation{ .Authenticate = .{
                .uid = config.replica.uid,
                .key = config.replica.key,
            } },
        };

        self.auth_bw.reset();
        const serialized = try auth.serialize(&self.auth_bw);
        std.mem.writeInt(u32, serialized[8..12], @intCast(serialized.len), .little);

        try self.writeFramed(serialized);
        self.readReply() catch |err| {
            log.err("repl: authentication rejected by {s}:{d}", .{ config.replica.address, config.replica.port });
            return err;
        };
    }

    fn writeFramed(self: *ReplClient, payload: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);
        const w = &self.writer.?;
        try w.interface.writeAll(&len_buf);
        try w.interface.writeAll(payload);
        try w.interface.flush();
    }

    fn readReply(self: *ReplClient) !void {
        var resp_len_buf: [4]u8 = undefined;
        try self.reader.?.interface.readSliceAll(&resp_len_buf);
        const resp_len = std.mem.readInt(u32, &resp_len_buf, .little);
        if (resp_len == 0) return error.ReplicationProtocolError;

        const resp = try self.allocator.alloc(u8, resp_len);
        defer self.allocator.free(resp);
        try self.reader.?.interface.readSliceAll(resp);

        const reply = try Packet.deserialize(self.allocator, resp);
        defer Packet.free(self.allocator, reply);

        switch (reply.op) {
            .Reply => |r| if (r.status != .ok) return error.ReplicationRejected,
            else => return error.ReplicationProtocolError,
        }
    }
};

const testing = std.testing;

fn testBoundPort(fd: std.posix.fd_t) u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    if (std.posix.system.getsockname(fd, @ptrCast(&storage), &len) != 0) return 0;
    const sin: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&storage));
    return std.mem.bigToNative(u16, sin.port);
}

const MockReplica = struct {
    listener: *net.Server,
    io: Io,
    allocator: Allocator,
    err: ?anyerror = null,

    fn run(self: *MockReplica) void {
        var stream = self.listener.accept(self.io) catch |e| {
            self.err = e;
            return;
        };
        defer stream.close(self.io);

        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var reader = net.Stream.Reader.init(stream, self.io, &rbuf);
        var writer = net.Stream.Writer.init(stream, self.io, &wbuf);

        while (true) {
            var len_buf: [4]u8 = undefined;
            reader.interface.readSliceAll(&len_buf) catch break;
            const frame_len = std.mem.readInt(u32, &len_buf, .little);
            const payload = self.allocator.alloc(u8, frame_len) catch return;
            defer self.allocator.free(payload);
            reader.interface.readSliceAll(payload) catch break;

            var bw = Buffer.init(self.allocator, 1024) catch return;
            defer bw.deinit();
            const reply = Packet{
                .checksum = 0,
                .packet_length = 0,
                .packet_id = 0,
                .timestamp = 0,
                .op = Operation{ .Reply = .{ .status = .ok, .data = null } },
            };
            const bytes = reply.serialize(&bw) catch return;
            var reply_len: [4]u8 = undefined;
            std.mem.writeInt(u32, &reply_len, @intCast(bytes.len), .little);
            writer.interface.writeAll(&reply_len) catch break;
            writer.interface.writeAll(bytes) catch break;
            writer.interface.flush() catch break;
        }
    }
};

test "ReplClient ships frames to a replica" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    const listen_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try net.IpAddress.listen(&listen_addr, io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const port = testBoundPort(listener.socket.handle);
    try testing.expect(port != 0);

    var mock = MockReplica{ .listener = &listener, .io = io, .allocator = allocator };
    const thread = try std.Thread.spawn(.{}, MockReplica.run, .{&mock});

    var config: Config = undefined;
    config.replica = .{
        .enabled = true,
        .sync_interval_ms = 5000,
        .address = "127.0.0.1",
        .port = port,
        .uid = "replica-uid",
        .key = "replica-key",
    };

    var client = try ReplClient.init(allocator, io, 262144);
    defer client.deinit();

    const frame = try allocator.dupe(u8, "hello-replicated-wal-frame");
    defer allocator.free(frame);
    var frames = [_][]u8{frame};

    client.connect(&config) catch |e| {
        thread.join();
        if (mock.err) |me| return me;
        return e;
    };
    const ship_result = client.ship(&frames);
    client.disconnect();
    thread.join();

    if (mock.err) |e| return e;
    try ship_result;
}
