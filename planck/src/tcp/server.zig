const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const Config = @import("../common/config.zig").Config;
const Engine = @import("../engine/engine.zig").Engine;
const SessionPool = @import("session_pool.zig").SessionPool;
const MessageBufferPool = @import("message_buffer_pool.zig").MessageBufferPool;
const common = @import("../common/common.zig");
const Now = @import("utils").Now;
const proto = @import("proto");
const Packet = proto.Packet;
const Operation = proto.Operation;
const AdminOperation = proto.Operation;
const AdminPacket = proto.Packet;
const Status = proto.Status;
const ErrorCode = proto.ErrorCode;
const Buffer = @import("utils").Buffer;
const SecurityManager = @import("../storage/security.zig").SecurityManager;
const Session_Security = @import("../storage/security.zig").Session;
const PermissionType = @import("../storage/security.zig").PermissionType;
const bson = @import("bson");
const tls = @import("tls");
const ReplicationManager = @import("replication.zig").ReplicationManager;
const constants = @import("../common/constants.zig");
const dispatchOp = @import("../engine/dispatch.zig").dispatch;
const Role = @import("../storage/security.zig").Role;
const manifest_codec = @import("../exim/manifest_yaml.zig");

const Entry = @import("../common/common.zig").Entry;

const log = std.log.scoped(.server);

pub const OperationMode = enum(u8) {
    online = 0,
    offline = 1,
};

pub const Server = struct {
    allocator: Allocator,
    config: *const Config,
    config_dir: Io.Dir,
    address: net.IpAddress,
    io: Io,
    engine: *Engine,
    message_buffer_pool: MessageBufferPool,
    session_pool: SessionPool,
    security_manager: *SecurityManager,
    security_enabled: bool,
    active_connections: std.atomic.Value(u64),
    shutdown_requested: std.atomic.Value(bool),
    mode: std.atomic.Value(u8),
    listener: ?*net.Server,
    group: Io.Group,
    tls_auth: ?*tls.config.CertKeyPair,

    pub fn init(allocator: Allocator, config: *const Config, io: Io, engine: *Engine, security_enabled: bool, config_dir: Io.Dir) !Server {
        const address = try net.IpAddress.parseIp4(config.address, config.port);

        const security_manager = try SecurityManager.init(allocator, security_enabled, io, .{
            .max_failed_attempts = config.security.max_failed_attempts,
            .lockout_duration_ms = config.security.lockout_duration_ms,
            .lockout_multiplier = config.security.lockout_multiplier,
        });
        errdefer security_manager.deinit();

        try security_manager.attachEngine(engine);

        var message_buffer_pool = try MessageBufferPool.init(
            allocator,
            io,
            256 * 1024,
            config.max_sessions,
        );
        errdefer message_buffer_pool.deinit();

        var session_pool = try SessionPool.init(
            allocator,
            io,
            engine,
            config.max_sessions,
            config.session.idle_timeout_ms,
            security_manager,
        );
        errdefer session_pool.deinit();

        if (security_enabled) {
            log.info("Security enabled with authentication and authorization", .{});
        } else {
            log.warn("Security DISABLED - all connections have admin access", .{});
        }

        var tls_auth: ?*tls.config.CertKeyPair = null;
        if (config.tls.enabled) {
            const auth = try allocator.create(tls.config.CertKeyPair);
            auth.* = tls.config.CertKeyPair.fromFilePathAbsolute(
                allocator,
                io,
                config.tls.cert_file,
                config.tls.key_file,
            ) catch |err| {
                log.err("Failed to load TLS certificate/key: {}", .{err});
                allocator.destroy(auth);
                return err;
            };
            tls_auth = auth;
            log.info("TLS 1.3 enabled with cert={s} key={s}", .{ config.tls.cert_file, config.tls.key_file });
        }

        return Server{
            .allocator = allocator,
            .config = config,
            .config_dir = config_dir,
            .address = address,
            .io = io,
            .engine = engine,
            .message_buffer_pool = message_buffer_pool,
            .session_pool = session_pool,
            .security_manager = security_manager,
            .security_enabled = security_enabled,
            .active_connections = std.atomic.Value(u64).init(0),
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .mode = std.atomic.Value(u8).init(@intFromEnum(OperationMode.online)),
            .listener = null,
            .group = .init,
            .tls_auth = tls_auth,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.tls_auth) |auth| {
            auth.deinit(self.allocator);
            self.allocator.destroy(auth);
        }
        self.session_pool.deinit();
        self.message_buffer_pool.deinit();
        self.security_manager.deinit();
    }

    pub fn getActiveConnections(self: *const Server) u64 {
        return self.active_connections.load(.monotonic);
    }

    pub fn run(self: *Server) !void {
        var listening = try self.address.listen(self.io, .{ .reuse_address = true });
        self.listener = &listening;
        defer {
            self.listener = null;
            if (!self.shutdown_requested.load(.acquire)) {
                listening.deinit(self.io);
            }
        }

        log.info("Server listening on {s}:{d} (Io.Group thread pool)", .{
            self.config.address,
            self.config.port,
        });

        while (!self.shutdown_requested.load(.acquire)) {
            const connection = listening.accept(self.io) catch |err| {
                if (self.shutdown_requested.load(.acquire)) break;
                log.err("Accept error: {}", .{err});
                continue;
            };

            const prev = self.active_connections.fetchAdd(1, .monotonic);
            if (prev >= self.config.max_sessions) {
                _ = self.active_connections.fetchSub(1, .monotonic);
                log.warn("Max connections reached ({}), rejecting new connection", .{prev});
                connection.close(self.io);
                continue;
            }

            self.group.async(self.io, handleConnection, .{ self, connection });
        }

        log.info("Server accept loop exited, canceling active connections...", .{});

        self.group.cancel(self.io);

        log.info("Server stopped ({} connections were active)", .{self.active_connections.load(.monotonic)});
    }

    pub fn stop(self: *Server) void {
        log.info("Server stop requested", .{});

        self.shutdown_requested.store(true, .release);

        if (self.listener) |l| {
            l.socket.close(self.io);
        }
    }

    pub fn getMode(self: *const Server) OperationMode {
        return @enumFromInt(self.mode.load(.acquire));
    }

    pub fn setMode(self: *Server, new_mode: OperationMode) OperationMode {
        const prev = self.mode.swap(@intFromEnum(new_mode), .acq_rel);
        log.info("Operation mode changed: {} → {}", .{ @as(OperationMode, @enumFromInt(prev)), new_mode });
        return @enumFromInt(prev);
    }

    fn setTcpNoDelay(fd: std.posix.fd_t) void {
        if(comptime builtin.os.tag != .windows) {
            const value: c_int = 1;
            const opt: [*]const u8 = @ptrCast(&value);
            _ = std.posix.system.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, opt, @sizeOf(c_int));
        }
    }

    fn handleConnection(self: *Server, connection: net.Stream) Io.Cancelable!void {
        defer connection.close(self.io);

        setTcpNoDelay(connection.socket.handle);

        defer _ = self.active_connections.fetchSub(1, .monotonic);

        var session = self.session_pool.acquire(connection, &self.message_buffer_pool, self) catch |err| {
            log.err("Failed to acquire session: {}", .{err});
            return;
        };
        defer self.session_pool.release(session);

        if (self.tls_auth) |auth| {
            const rng_impl: std.Random.IoSource = .{ .io = self.io };
            var tls_conn = tls.serverFromStream(self.io, connection, .{
                .auth = auth,
                .now = Io.Clock.real.now(self.io),
                .rng = rng_impl.interface(),
            }) catch |err| {
                log.err("TLS handshake failed: {}", .{err});
                return;
            };
            defer tls_conn.close() catch {};
            var tls_reader = tls_conn.reader(&session.read_buffer);
            var tls_writer = tls_conn.writer(&session.write_buffer);
            session.run(&tls_reader.interface, &tls_writer.interface) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                log.err("Session error: {}", .{err});
            };
        } else {
            var reader = connection.reader(self.io, &session.read_buffer);
            var writer = connection.writer(self.io, &session.write_buffer);
            session.run(&reader.interface, &writer.interface) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                log.err("Session error: {}", .{err});
            };
        }
    }
};

pub const Session = struct {
    allocator: Allocator,
    io: Io,
    now: Now,
    connection: net.Stream,
    engine: *Engine,
    server: *Server,
    read_buffer: [64 * 1024]u8,
    write_buffer: [64 * 1024]u8,
    idle_timeout_ms: u64,
    last_activity_ms: i64 = 0,
    message_buffer_pool: ?*MessageBufferPool,
    security_manager: *SecurityManager,
    security_session: ?Session_Security,
    authenticated: bool,
    shutdown_after_reply: bool,
    response_writer: Buffer,

    pub fn init(allocator: Allocator, io: Io, connection: net.Stream, engine: *Engine, server: *Server, idle_timeout_ms: u64, message_buffer_pool: ?*MessageBufferPool, security_manager: *SecurityManager) !Session {
        var session = Session{
            .allocator = allocator,
            .io = io,
            .now = Now{ .io = io },
            .connection = connection,
            .engine = engine,
            .server = server,
            .read_buffer = undefined,
            .write_buffer = undefined,
            .idle_timeout_ms = idle_timeout_ms,
            .message_buffer_pool = message_buffer_pool,
            .security_manager = security_manager,
            .security_session = null,
            .authenticated = !security_manager.enabled,
            .shutdown_after_reply = false,
            .response_writer = try Buffer.init(allocator, 16 * 1024 * 1024),
        };
        session.last_activity_ms = session.now.toMilliSeconds();
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.response_writer.deinit();
        if (self.security_session) |*session| {
            session.deinit(self.allocator);
        }
    }

    pub fn reset(self: *Session, connection: net.Stream, server: *Server) void {
        self.connection = connection;
        self.server = server;
        self.last_activity_ms = self.now.toMilliSeconds();
        self.authenticated = !self.security_manager.enabled;
        self.shutdown_after_reply = false;
        self.security_session = null;
    }

    pub fn isIdle(self: *const Session) bool {
        if (self.idle_timeout_ms == 0) return false;
        const now = self.now.toMilliSeconds();
        const elapsed: u64 = @intCast(@max(0, now - self.last_activity_ms));
        return elapsed > self.idle_timeout_ms;
    }

    fn updateActivity(self: *Session) void {
        self.last_activity_ms = self.now.toMilliSeconds();
    }

    pub fn run(self: *Session, reader: *Io.Reader, writer: *Io.Writer) !void {
        while (true) {
            var length_buf: [4]u8 = undefined;
            reader.readSliceAll(&length_buf) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                if (err == error.EndOfStream) {
                    break;
                }
                if (self.isIdle()) {
                    return error.IdleTimeout;
                }
                log.err("Failed to read message length: {}", .{err});
                break;
            };
            self.updateActivity();

            const msg_len = std.mem.readInt(u32, &length_buf, .little);
            if (msg_len > self.server.config.limits.max_message_size) {
                log.err("Message too large: {} bytes (max {})", .{ msg_len, self.server.config.limits.max_message_size });
                break;
            }

            const msg_buf_full = if (self.message_buffer_pool) |pool| blk: {
                break :blk try pool.acquire(msg_len);
            } else blk: {
                break :blk try self.allocator.alloc(u8, msg_len);
            };

            defer {
                if (self.message_buffer_pool) |pool| {
                    pool.release(msg_buf_full);
                } else {
                    self.allocator.free(msg_buf_full);
                }
            }

            const msg_buf = msg_buf_full[0..msg_len];

            reader.readSliceAll(msg_buf) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                log.err("Failed to read complete message: {}", .{err});
                break;
            };
            self.updateActivity();

            const response_len = try self.processMessage(msg_buf);
            self.updateActivity();

            if (response_len > 0) {
                try writer.writeAll(self.response_writer.buf[0..response_len]);
                try writer.flush();
            }

            if (self.shutdown_after_reply) {
                self.server.stop();
                break;
            }
        }
    }

    const HEADER_SIZE: usize = @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u32) + @sizeOf(i64);

    fn isAdminOnlyTag(tag: u8) bool {
        return switch (tag) {
            101, 103...118, 200...202 => true,
            else => false,
        };
    }

    fn processMessage(self: *Session, payload: []const u8) !usize {
        if (payload.len > HEADER_SIZE and isAdminOnlyTag(payload[HEADER_SIZE])) {
            return self.processAdminMessage(payload);
        }

        const request = try Packet.deserialize(self.allocator, payload);
        defer Packet.free(self.allocator, request);

        const response_op = self.handleOperation(&request.op) catch |err| {
            if (err != error.ServerOffline) {
                log.err("Error handling operation: {}", .{err});
            }
            const error_code: ErrorCode = switch (err) {
                error.NotFound => .not_found,
                error.StoreNotFound => .store_not_found,
                error.StoreDeleteInProgress => .store_delete_in_progress,
                error.InvalidRequest => .invalid_request,
                error.ServerOffline => .server_offline,
                error.NoIndexOnField => .no_index_on_field,
                error.InvalidFieldType => .invalid_field_type,
                error.DocumentSizeExceedsAllowedLength => .document_too_large,
                error.PermissionDenied => .permission_denied,
                error.Unauthenticated, error.NoSecuritySession => .unauthorized,
                else => .internal_error,
            };
            const error_msg = try error_code.formatError(self.allocator, error_code.toName());
            defer self.allocator.free(error_msg);

            const status = error_code.toStatus();

            const error_op = Operation{ .Reply = .{ .status = status, .data = error_msg } };

            const response = Packet{
                .checksum = 0,
                .packet_length = 0,
                .packet_id = request.packet_id,
                .timestamp = self.now.toMilliSeconds(),
                .op = error_op,
            };

            self.response_writer.reset();
            _ = try self.response_writer.write(&[_]u8{ 0, 0, 0, 0 });
            const serialized = try response.serialize(&self.response_writer);
            const packet_len = serialized.len - 4;
            std.mem.writeInt(u32, serialized[12..16], @intCast(packet_len), .little);
            std.mem.writeInt(u32, serialized[0..4], @intCast(packet_len), .little);
            return serialized.len;
        };
        defer {
            if (response_op == .Reply) {
                if (response_op.Reply.data) |data| {
                    self.allocator.free(data);
                }
            }
        }

        const response = Packet{
            .checksum = 0,
            .packet_length = 0,
            .packet_id = request.packet_id,
            .timestamp = self.now.toMilliSeconds(),
            .op = response_op,
        };

        self.response_writer.reset();
        _ = try self.response_writer.write(&[_]u8{ 0, 0, 0, 0 });
        const serialized = try response.serialize(&self.response_writer);
        const packet_len = serialized.len - 4;
        std.mem.writeInt(u32, serialized[12..16], @intCast(packet_len), .little);
        std.mem.writeInt(u32, serialized[0..4], @intCast(packet_len), .little);

        const is_watch = switch (response_op) {
            .WatchReply => true,
            else => false,
        };
        if (is_watch) {
            const dump_n = @min(serialized.len, 64);
            var sbuf: [200]u8 = undefined;
            var p: usize = 0;
            for (serialized[0..dump_n]) |b| {
                if (p + 3 > sbuf.len) break;
                _ = std.fmt.bufPrint(sbuf[p..][0..3], "{x:0>2} ", .{b}) catch break;
                p += 3;
            }
        }

        return serialized.len;
    }

    fn checkPermission(self: *Session, op: *const Operation) !void {
        switch (op.*) {
            .Authenticate => return,
            else => {},
        }

        if (!self.authenticated) {
            return error.Unauthenticated;
        }

        if (op.* == .Logout) return;

        const required_permission: PermissionType = switch (op.*) {
            .Create => .write,
            .Drop => .write,
            .Flush => .write,
            .List => .read,

            .Insert, .BatchInsert => .write,
            .Read => .read,
            .Update => .write,
            .Delete => .delete,

            .Range, .Query, .Aggregate, .Scan => .read,
            .NextSequence => .write,
            .Watch => .read,

            .Authenticate, .Logout => return error.PermissionDenied,

            .Reply, .BatchReply, .WatchReply => return error.InvalidOperation,

            .Shutdown, .SetMode, .RegenerateKey, .UpdateUser, .Backup, .Restore, .Export, .Import => .write,
            .Stats, .GetConfig, .Vlogs => .read,
            .SetConfig, .Collect, .Ping, .Truncate, .SaveStats => .write,
            .SaveToken, .RevokeToken, .RefreshToken, .AuditLog => .write,
            .ShipWal, .Demote, .Promote => .write,
        };

        if (self.security_session) |*session| {
            try self.security_manager.checkPermission(session, required_permission);
        } else if (!self.authenticated) {
            return error.NoSecuritySession;
        }
    }

    fn handleOperation(self: *Session, op: *const Operation) !Operation {
        if (self.server.getMode() != .online) {
            switch (op.*) {
                .Authenticate, .Logout, .Flush => {},
                else => return error.ServerOffline,
            }
        }

        try self.checkPermission(op);

        const maybe_ns: ?[]const u8 = switch (op.*) {
            .Insert => |d| d.store_ns,
            .BatchInsert => |d| d.store_ns,
            .Read => |d| d.store_ns,
            .Update => |d| d.store_ns,
            .Delete => |d| d.store_ns,
            .Range => |d| d.store_ns,
            .Query => |d| d.store_ns,
            .Aggregate => |d| d.store_ns,
            .Scan => |d| d.store_ns,
            else => null,
        };
        if (maybe_ns) |ns| {
            if (std.mem.startsWith(u8, ns, constants.SYSTEM_NS_PREFIX)) {
                const is_admin = if (self.security_session) |*s| s.permissions.can_admin else false;
                if (!is_admin) {
                    const msg = try ErrorCode.permission_denied.formatError(self.allocator, "namespace is reserved for system use");
                    return Operation{ .Reply = .{ .status = .invalid_request, .data = msg } };
                }
            }
        }

        return switch (op.*) {
            .Create => |data| blk: {
                const needs_catalog_lock = switch (data.doc_type) {
                    .Store, .Index => true,
                    .User, .Backup, .Schedule, .Document, .Service, .Sequence => false,
                };

                if (needs_catalog_lock) {
                    self.engine.catalog_mutex.lock(self.io);
                    defer self.engine.catalog_mutex.unlock(self.io);
                }

                switch (data.doc_type) {
                    .Store => {
                        const already = self.engine.catalog.findStoreByNamespace(data.ns) != null;
                        const store = try self.engine.catalog.createStore(data.ns, data.metadata);
                        if (!already) {
                            if (self.engine.replication) |repl| {
                                log.info("shipping create_store '{s}' store_id={d} to replica", .{ data.ns, store.store_id });
                                repl.ship(.{
                                    .op_kind = 4,
                                    .store_ns = data.ns,
                                    .lsn = 0,
                                    .doc_id = @as(u128, store.store_id),
                                    .timestamp = self.now.toMilliSeconds(),
                                    .data = if (data.metadata) |m| m else &[_]u8{},
                                });
                            } else {
                                log.info("create_store '{s}': replication not enabled", .{data.ns});
                            }
                        }
                        const status: proto.Status = if (already) .already_exists else .ok;
                        break :blk Operation{ .Reply = .{ .status = status, .data = null } };
                    },
                    .Index => {
                        var decoder = bson.Decoder.init(self.allocator, data.payload);
                        const index = try decoder.decode(proto.Index);
                        defer self.allocator.free(index.field);

                        const field = index.field;
                        const field_type = index.field_type;

                        var parts = try proto.parseNamespace(self.allocator, data.ns);
                        defer parts.deinit(self.allocator);

                        const store_ns = parts.store orelse return error.InvalidIndexNamespace;

                        const store = self.engine.catalog.findStoreByNamespace(store_ns) orelse return error.StoreNotFound;
                        const store_id = store.store_id;

                        self.engine.db_mutex.lock(self.io);
                        defer self.engine.db_mutex.unlock(self.io);
                        const already = self.engine.db.secondary_indexes.contains(data.ns);
                        try self.engine.db.createSecondaryIndex(store_id, data.ns, field, field_type);
                        if (!already) {
                            if (self.engine.replication) |repl| {
                                repl.ship(.{
                                    .op_kind = 5,
                                    .store_ns = data.ns,
                                    .lsn = 0,
                                    .doc_id = @as(u128, store_id),
                                    .timestamp = self.now.toMilliSeconds(),
                                    .data = data.payload,
                                });
                            }
                        }
                        const status: proto.Status = if (already) .already_exists else .ok;
                        break :blk Operation{ .Reply = .{ .status = status, .data = null } };
                    },
                    .User => {
                        var decoder = bson.Decoder.init(self.allocator, data.payload);
                        const user_data = try decoder.decode(proto.User);
                        defer {
                            self.allocator.free(user_data.username);
                            self.allocator.free(user_data.password_hash);
                        }

                        const role: Role = switch (user_data.role) {
                            0 => .admin,
                            1 => .read_write,
                            2 => .read_only,
                            else => .none,
                        };

                        const result = if (user_data.password_hash.len > 0)
                            self.security_manager.createUserWithKey(user_data.username, role, user_data.password_hash) catch {
                                const msg = ErrorCode.user_already_exists.formatError(self.allocator, "failed to create user") catch break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                                break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                            }
                        else
                            self.security_manager.createUser(user_data.username, role) catch {
                                const msg = ErrorCode.user_already_exists.formatError(self.allocator, "failed to create user") catch break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                                break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                            };
                        defer self.allocator.free(result.password_hash);

                        const role_u8: u8 = switch (role) {
                            .admin => 0,
                            .read_write => 1,
                            .read_only => 2,
                            .none => 3,
                        };
                        _ = self.engine.catalog.createUser(user_data.username, result.password_hash, role_u8) catch |err| {
                            log.err("Failed to persist user in catalog: {}", .{err});
                        };

                        if (self.engine.replication) |repl| {
                            const replica_role: u8 = if (role == .read_write) 2 else role_u8;
                            var enc = bson.Encoder.init(self.allocator);
                            const replica_payload = enc.encode(proto.User{
                                .id = user_data.id,
                                .username = user_data.username,
                                .password_hash = result.key_b64,
                                .role = replica_role,
                                .created_at = user_data.created_at,
                            }) catch data.payload;

                            repl.ship(.{
                                .op_kind = 3,
                                .store_ns = user_data.username,
                                .lsn = 0,
                                .doc_id = 0,
                                .timestamp = self.now.toMilliSeconds(),
                                .data = replica_payload,
                            });
                        }

                        break :blk Operation{ .Reply = .{ .status = .ok, .data = result.key_b64 } };
                    },
                    .Backup => {
                        return error.InvalidDocType;
                    },
                    .Service => {
                        const key = try self.engine.postLocal(data.ns, data.payload, true);
                        const key_json = try std.fmt.allocPrint(self.allocator, "{{\"key\":\"{x:0>32}\"}}", .{key});
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = key_json } };
                    },
                    .Schedule, .Document, .Sequence => {
                        return error.InvalidDocType;
                    },
                }
            },
            .Drop => |data| blk: {
                self.engine.catalog_mutex.lock(self.io);
                defer self.engine.catalog_mutex.unlock(self.io);

                switch (data.doc_type) {
                    .Store => {
                        self.engine.dropStore(data.name) catch |err| {
                            const msg = try ErrorCode.not_found.formatError(self.allocator, @errorName(err));
                            break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                        };
                        if (self.engine.replication) |repl| {
                            repl.ship(.{
                                .op_kind = 7,
                                .store_ns = data.name,
                                .lsn = 0,
                                .doc_id = 0,
                                .timestamp = self.now.toMilliSeconds(),
                                .data = &[_]u8{},
                            });
                        }
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                    },
                    .Index => {
                        self.engine.dropIndex(data.name) catch |err| {
                            const msg = try ErrorCode.not_found.formatError(self.allocator, @errorName(err));
                            break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                        };
                        if (self.engine.replication) |repl| {
                            repl.ship(.{
                                .op_kind = 8,
                                .store_ns = data.name,
                                .lsn = 0,
                                .doc_id = 0,
                                .timestamp = self.now.toMilliSeconds(),
                                .data = &[_]u8{},
                            });
                        }
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                    },
                    .User => {
                        self.engine.catalog.dropUser(data.name) catch |err| {
                            const msg = try ErrorCode.not_found.formatError(self.allocator, @errorName(err));
                            break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                        };
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                    },
                    .Backup => {
                        self.engine.catalog.dropBackup(data.name) catch |err| {
                            const msg = try ErrorCode.not_found.formatError(self.allocator, @errorName(err));
                            break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                        };
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                    },
                    .Service, .Schedule, .Document, .Sequence => {
                        return error.InvalidDocType;
                    },
                }
            },
            .List => |data| blk: {
                self.engine.catalog_mutex.lock(self.io);
                defer self.engine.catalog_mutex.unlock(self.io);

                switch (data.doc_type) {
                    .Store => {
                        const bson_data = try self.engine.catalog.listStoresBson(self.allocator, data.ns);
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
                    },
                    .Index => {
                        const bson_data = try self.engine.catalog.listIndexesBson(self.allocator, data.ns);
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
                    },
                    .User => {
                        const bson_data = try self.engine.catalog.listUsersBson(self.allocator);
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
                    },
                    .Backup => {
                        const bson_data = try self.engine.catalog.listBackupsBson(self.allocator);
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
                    },
                    .Service, .Schedule, .Document, .Sequence => {
                        return error.InvalidDocType;
                    },
                }
            },

            .Insert, .Read, .Update, .Delete, .Range, .Query, .Aggregate, .Scan, .NextSequence => {
                return try dispatchOp(self.engine, self.allocator, self.io, op);
            },

            .Watch => |data| blk: {
                const cs = self.engine.change_streamer orelse {
                    const msg = try ErrorCode.invalid_request.formatError(self.allocator, "change_streams not configured on this engine");
                    break :blk Operation{ .Reply = .{ .status = .invalid_request, .data = msg } };
                };
                const outcome = cs.watch(
                    self.allocator,
                    data.stores,
                    data.since_lsn,
                    if (data.max_wait_ms == 0) 30_000 else data.max_wait_ms,
                    data.max_records,
                ) catch |err| switch (err) {
                    error.CursorBehindRetention => {
                        const empty = try self.allocator.alloc([]const u8, 0);
                        break :blk Operation{ .WatchReply = .{
                            .status = .not_found,
                            .high_lsn = cs.high_lsn.load(.acquire),
                            .records = empty,
                        } };
                    },
                    else => {
                        const msg = try ErrorCode.internal_error.formatError(self.allocator, @errorName(err));
                        break :blk Operation{ .Reply = .{ .status = .server_error, .data = msg } };
                    },
                };
                const records = try self.allocator.alloc([]const u8, outcome.frames.len);
                for (outcome.frames, 0..) |f, i| records[i] = f;
                self.allocator.free(outcome.frames);
                break :blk Operation{ .WatchReply = .{
                    .status = .ok,
                    .high_lsn = outcome.high_lsn,
                    .records = records,
                } };
            },
            .BatchInsert => |data| blk: {
                if (data.values.len > self.server.config.limits.max_batch_size) {
                    const detail = try std.fmt.allocPrint(self.allocator, "batch too large ({d} docs, max {d})", .{ data.values.len, self.server.config.limits.max_batch_size });
                    defer self.allocator.free(detail);
                    const err_msg = try ErrorCode.batch_too_large.formatError(self.allocator, detail);
                    break :blk Operation{ .Reply = .{ .status = .invalid_request, .data = err_msg } };
                }
                break :blk try dispatchOp(self.engine, self.allocator, self.io, op);
            },

            .Authenticate => |data| blk: {
                std.debug.print("Auth request: uid={s} key_len={d}\n", .{ data.uid, data.key.len });
                const session = self.security_manager.authenticate(data.uid, data.key) catch |err| {
                    std.debug.print("Auth FAILED: {}\n", .{err});
                    const code: ErrorCode = switch (err) {
                        error.InvalidCredentials => .invalid_credentials,
                        error.AccountLockedOut => .account_locked,
                        error.UserDisabled => .user_disabled,
                        else => .unauthorized,
                    };
                    const msg = code.formatError(self.allocator, code.toName()) catch break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                    break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                };
                self.security_session = session;
                self.authenticated = true;

                const token_copy = try self.allocator.dupe(u8, &session.token);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = token_copy } };
            },
            .Logout => blk: {
                if (self.security_session) |session| {
                    self.security_manager.revokeSession(session.token) catch {};
                    self.security_session = null;
                    self.authenticated = false;
                }
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },

            .Reply => return error.InvalidOperation,
            .BatchReply => return error.InvalidOperation,
            .WatchReply => return error.InvalidOperation,
            .Flush => {
                return try dispatchOp(self.engine, self.allocator, self.io, op);
            },
            else => return error.InvalidOperation,
        };
    }

    fn processAdminMessage(self: *Session, payload: []const u8) !usize {
        const request = try AdminPacket.deserialize(self.allocator, payload);
        defer AdminPacket.free(self.allocator, request);

        const response_op = self.handleAdminOperation(&request.op) catch |err| {
            if (err != error.ServerOffline) {
                log.err("Error handling admin operation: {}", .{err});
            }
            const error_code: ErrorCode = switch (err) {
                error.NotFound => .not_found,
                error.StoreNotFound => .store_not_found,
                error.StoreDeleteInProgress => .store_delete_in_progress,
                error.InvalidRequest => .invalid_request,
                error.ServerOffline => .server_offline,
                error.PermissionDenied => .permission_denied,
                error.Unauthenticated, error.NoSecuritySession => .unauthorized,
                else => .internal_error,
            };
            const error_msg = try error_code.formatError(self.allocator, error_code.toName());
            defer self.allocator.free(error_msg);
            const status = error_code.toStatus();
            const error_op = Operation{ .Reply = .{ .status = status, .data = error_msg } };
            const response = Packet{
                .checksum = 0,
                .packet_length = 0,
                .packet_id = request.packet_id,
                .timestamp = self.now.toMilliSeconds(),
                .op = error_op,
            };
            self.response_writer.reset();
            _ = try self.response_writer.write(&[_]u8{ 0, 0, 0, 0 });
            const serialized = try response.serialize(&self.response_writer);
            const packet_len = serialized.len - 4;
            std.mem.writeInt(u32, serialized[12..16], @intCast(packet_len), .little);
            std.mem.writeInt(u32, serialized[0..4], @intCast(packet_len), .little);
            return serialized.len;
        };
        defer {
            if (response_op == .Reply) {
                if (response_op.Reply.data) |data| {
                    self.allocator.free(data);
                }
            }
        }

        const response = Packet{
            .checksum = 0,
            .packet_length = 0,
            .packet_id = request.packet_id,
            .timestamp = self.now.toMilliSeconds(),
            .op = response_op,
        };
        self.response_writer.reset();
        _ = try self.response_writer.write(&[_]u8{ 0, 0, 0, 0 });
        const serialized = try response.serialize(&self.response_writer);
        const packet_len = serialized.len - 4;
        std.mem.writeInt(u32, serialized[12..16], @intCast(packet_len), .little);
        std.mem.writeInt(u32, serialized[0..4], @intCast(packet_len), .little);
        return serialized.len;
    }

    fn checkAdminPermission(self: *Session, op: *const AdminOperation) !void {
        switch (op.*) {
            .Authenticate, .ShipWal => return,
            else => {},
        }
        if (!self.authenticated) return error.Unauthenticated;
        if (op.* == .Logout) return;

        const required_permission: PermissionType = switch (op.*) {
            .Drop => .admin,
            .Shutdown, .SetMode, .Truncate, .SaveStats => .admin,
            .RegenerateKey, .UpdateUser => .admin,
            .Restore, .Backup, .Stats, .Collect, .Vlogs => .admin,
            .SetConfig, .Import, .Demote, .Promote => .admin,
            .SaveToken, .RevokeToken, .RefreshToken, .AuditLog => .admin,
            .GetConfig, .Export, .Ping => .read,
            .Authenticate, .Logout, .ShipWal => return error.PermissionDenied,
            .Reply, .BatchReply => return error.InvalidOperation,
            .Create, .Flush => .admin,
            else => return error.InvalidOperation,
        };

        if (self.security_session) |*session| {
            try self.security_manager.checkPermission(session, required_permission);
        } else if (!self.authenticated) {
            return error.NoSecuritySession;
        }
    }

    fn handleAdminOperation(self: *Session, op: *const AdminOperation) !Operation {
        if (self.server.getMode() != .online) {
            switch (op.*) {
                .Authenticate, .Logout, .Flush, .Shutdown, .Collect, .SetMode, .Restore, .Stats, .Vlogs, .GetConfig, .SetConfig, .Ping, .Truncate, .SaveStats, .ShipWal, .Demote, .Promote, .SaveToken, .RevokeToken, .RefreshToken, .AuditLog => {},
                else => return error.ServerOffline,
            }
        }

        try self.checkAdminPermission(op);

        return switch (op.*) {
            .Drop => |data| blk: {
                self.engine.catalog_mutex.lock(self.io);
                self.engine.db_mutex.lock(self.io);
                defer self.engine.db_mutex.unlock(self.io);
                defer self.engine.catalog_mutex.unlock(self.io);

                switch (data.doc_type) {
                    .Store => {
                        try self.engine.dropStore(data.name);
                        if (self.engine.replication) |repl| {
                            repl.ship(.{
                                .op_kind = 7,
                                .store_ns = data.name,
                                .lsn = 0,
                                .doc_id = 0,
                                .timestamp = self.now.toMilliSeconds(),
                                .data = &[_]u8{},
                            });
                        }
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                    },
                    .Index => {
                        try self.engine.dropIndex(data.name);
                        if (self.engine.replication) |repl| {
                            repl.ship(.{
                                .op_kind = 8,
                                .store_ns = data.name,
                                .lsn = 0,
                                .doc_id = 0,
                                .timestamp = self.now.toMilliSeconds(),
                                .data = &[_]u8{},
                            });
                        }
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                    },
                    .User => {
                        self.security_manager.deleteUser(data.name) catch {
                            break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                        };
                        self.engine.catalog.dropUser(data.name) catch |err| {
                            log.err("Failed to drop user from catalog: {}", .{err});
                        };

                        if (self.engine.replication) |repl| {
                            repl.ship(.{
                                .op_kind = 6,
                                .store_ns = data.name,
                                .lsn = 0,
                                .doc_id = 0,
                                .timestamp = self.now.toMilliSeconds(),
                                .data = &[_]u8{},
                            });
                        }

                        break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                    },
                    .Backup => {
                        self.engine.catalog.dropBackup(data.name) catch |err| {
                            log.err("Failed to drop backup: {}", .{err});
                            break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                        };
                        break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                    },
                    .Service, .Schedule, .Document, .Sequence => {
                        return error.InvalidDocType;
                    },
                }
            },
            .RegenerateKey => |data| blk: {
                const result = self.security_manager.regenerateKey(data.uid) catch {
                    break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                };
                defer self.allocator.free(result.password_hash);
                self.engine.catalog.updateUserPassword(data.uid, result.password_hash) catch |err| {
                    log.err("Failed to update user hash in catalog: {}", .{err});
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result.key_b64 } };
            },
            .UpdateUser => |data| blk: {
                const role: Role = switch (data.role) {
                    0 => .admin,
                    1 => .read_write,
                    2 => .read_only,
                    else => .none,
                };
                self.security_manager.updateUserRole(data.uid, role) catch {
                    break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                };
                self.engine.catalog.updateUserRole(data.uid, data.role) catch |err| {
                    log.err("Failed to update user role in catalog: {}", .{err});
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .Restore => |data| blk: {
                if (self.server.getMode() != .offline) {
                    const msg = try ErrorCode.invalid_request.formatError(self.allocator, "restore can only run in offline mode - run .offline first, then retry .restore");
                    break :blk Operation{ .Reply = .{ .status = .invalid_request, .data = msg } };
                }
                const result = try self.engine.restoreFromBackup(data.backup_path, data.target_path);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            },
            .Backup => |data| blk: {
                const result = self.engine.createBackup(data.path) catch |err| {
                    std.log.err("backup to '{s}' failed: {}", .{ data.path, err });
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "{{\"code\":1500,\"error\":\"internal_error\",\"message\":\"backup failed: {s}\"}}",
                        .{@errorName(err)},
                    );
                    break :blk Operation{ .Reply = .{ .status = .server_error, .data = msg } };
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            },
            .Stats => |data| blk: {
                const result = try self.engine.getStats(data.stat);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            },
            .Collect => |data| blk: {
                if (self.server.getMode() != .offline) {
                    const msg = try ErrorCode.invalid_request.formatError(self.allocator, "garbage collection can only run in offline mode - run .offline first, then retry .collect");
                    break :blk Operation{ .Reply = .{ .status = .invalid_request, .data = msg } };
                }

                if (data.vlogs.len == 0) {
                    const result = try self.engine.garbageCollectAuto();
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
                }

                const vlog_ids = try self.allocator.alloc(u16, data.vlogs.len);
                defer self.allocator.free(vlog_ids);
                for (data.vlogs, 0..) |v, i| {
                    vlog_ids[i] = @as(u16, v);
                }
                const result = try self.engine.garbageCollect(vlog_ids);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            },
            .Vlogs => blk: {
                const result = try self.engine.getVlogHeaders();
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            },
            .GetConfig => blk: {
                const config = self.server.config;
                const bson_data = try config.toBson(self.allocator);
                break :blk Operation{ .Reply = .{ .status = .ok, .data = bson_data } };
            },
            .SetConfig => |data| blk: {
                const config = @constCast(self.server.config);
                config.applyBson(self.allocator, data.data) catch {
                    const msg = try ErrorCode.invalid_request.formatError(self.allocator, "failed to apply configuration");
                    break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                };
                config.save(self.allocator, self.io, self.server.config_dir) catch {
                    const msg = try ErrorCode.invalid_request.formatError(self.allocator, "failed to save configuration");
                    break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .SetMode => |data| blk: {
                const new_mode: OperationMode = if (data.online) .online else .offline;
                const prev = self.server.setMode(new_mode);
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"mode\":\"{s}\",\"previous\":\"{s}\"}}",
                    .{ @tagName(new_mode), @tagName(prev) },
                );
                break :blk Operation{ .Reply = .{ .status = .ok, .data = msg } };
            },
            .Shutdown => blk: {
                self.shutdown_after_reply = true;
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .Export => |data| blk: {
                const result = self.handleExport(data.data) catch |err| {
                    const msg = try ErrorCode.invalid_request.formatError(self.allocator, @errorName(err));
                    break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            },
            .Import => |data| blk: {
                const result = self.handleImport(data.data) catch |err| {
                    const msg = try ErrorCode.invalid_request.formatError(self.allocator, @errorName(err));
                    break :blk Operation{ .Reply = .{ .status = .err, .data = msg } };
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = result } };
            },
            .Ping => Operation{ .Reply = .{ .status = .ok, .data = null } },
            .Truncate => blk: {
                try self.engine.truncateWal();
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .Authenticate, .Logout => return error.InvalidOperation,
            .Reply, .BatchReply => return error.InvalidOperation,
            .Create, .Flush => return error.InvalidOperation,
            .SaveStats => |data| blk: {
                const key = try self.engine.postLocal(data.store_ns, data.data, true);
                const key_json = try std.fmt.allocPrint(self.allocator, "{{\"key\":\"{x:0>32}\"}}", .{key});
                break :blk Operation{ .Reply = .{ .status = .ok, .data = key_json } };
            },
            .ShipWal => |data| blk: {
                if (data.op_kind >= 3) {
                    log.info("ShipWal received: op_kind={d} store_ns='{s}' doc_id={d}", .{ data.op_kind, data.store_ns, data.doc_id });
                }

                if (data.op_kind == 3) {
                    var decoder = bson.Decoder.init(self.allocator, data.data);
                    const user_data = decoder.decode(proto.User) catch |err| {
                        log.err("ShipWal create_user: failed to decode user: {}", .{err});
                        break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                    };
                    defer {
                        self.allocator.free(user_data.username);
                        self.allocator.free(user_data.password_hash);
                    }

                    const role: Role = switch (user_data.role) {
                        0 => .admin,
                        1 => .read_write,
                        2 => .read_only,
                        else => .none,
                    };

                    const create_result = if (user_data.password_hash.len > 0)
                        self.security_manager.createUserWithKey(user_data.username, role, user_data.password_hash) catch |err| {
                            log.warn("ShipWal create_user: {s} - {}", .{ user_data.username, err });
                            break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                        }
                    else
                        self.security_manager.createUser(user_data.username, role) catch |err| {
                            log.warn("ShipWal create_user: {s} - {}", .{ user_data.username, err });
                            break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                        };
                    defer self.allocator.free(create_result.key_b64);
                    defer self.allocator.free(create_result.password_hash);

                    const role_u8: u8 = switch (role) {
                        .admin => 0,
                        .read_write => 1,
                        .read_only => 2,
                        .none => 3,
                    };
                    _ = self.engine.catalog.createUser(user_data.username, create_result.password_hash, role_u8) catch |err| {
                        log.warn("ShipWal create_user catalog: {s} - {}", .{ user_data.username, err });
                    };

                    log.info("ShipWal: replicated user '{s}'", .{user_data.username});
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                }

                if (data.op_kind == 6) {
                    self.security_manager.deleteUser(data.store_ns) catch |err| {
                        log.warn("ShipWal drop_user: {s} - {}", .{ data.store_ns, err });
                    };
                    self.engine.catalog.dropUser(data.store_ns) catch |err| {
                        log.warn("ShipWal drop_user catalog: {s} - {}", .{ data.store_ns, err });
                    };

                    log.info("ShipWal: dropped user '{s}'", .{data.store_ns});
                    break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
                }

                self.engine.applyLogRecord(data.store_ns, data.lsn, data.doc_id, data.timestamp, data.op_kind, data.data) catch |err| {
                    log.err("applyLogRecord failed: op_kind={d} store_ns='{s}' err={}", .{ data.op_kind, data.store_ns, err });
                    break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .SaveToken => |data| blk: {
                const max_sessions: usize = 10;
                const uid_query = std.fmt.allocPrint(
                    self.allocator,
                    "{{\"app\":{{\"$eq\":\"{s}\"}},\"uid\":{{\"$eq\":\"{s}\"}}}}",
                    .{ data.app, data.uid },
                ) catch break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                defer self.allocator.free(uid_query);

                const user_tokens = self.engine.queryDocs("system.tokens", uid_query) catch &[_]Entry{};

                if (user_tokens.len >= max_sessions) {
                    self.engine.del("system.tokens", user_tokens[0].key) catch {};
                }

                var doc = bson.BsonDocument.empty(self.allocator);
                defer doc.deinit();
                try doc.putString("app", data.app);
                try doc.putString("uid", data.uid);
                try doc.putString("provider", data.provider);
                try doc.putString("token", data.token);
                try doc.putInt64("expires_at", data.expires_at);
                if (data.claims) |c| try doc.putString("claims", c);
                try doc.putString("role", data.role);
                if (data.client_ip) |ip| try doc.putString("client_ip", ip);
                try doc.putInt64("created_at", self.now.toMilliSeconds());

                const payload = doc.toBytes();
                _ = self.engine.postLocal("system.tokens", payload, true) catch |err| {
                    log.err("SaveToken: failed to store token: {}", .{err});
                    break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .RevokeToken => |data| blk: {
                const query_json = std.fmt.allocPrint(
                    self.allocator,
                    "{{\"app\":{{\"$eq\":\"{s}\"}},\"token\":{{\"$eq\":\"{s}\"}}}}",
                    .{ data.app, data.token },
                ) catch break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                defer self.allocator.free(query_json);

                const docs = self.engine.queryDocs("system.tokens", query_json) catch |err| {
                    log.err("RevokeToken: failed to query token: {}", .{err});
                    break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                };

                for (docs) |doc| {
                    self.engine.del("system.tokens", doc.key) catch |err| {
                        log.err("RevokeToken: failed to delete token key={x:0>32}: {}", .{ doc.key, err });
                    };
                }
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .RefreshToken => blk: {
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .AuditLog => |data| blk: {
                var doc = bson.BsonDocument.empty(self.allocator);
                defer doc.deinit();
                try doc.putString("event", data.event);
                if (data.uid) |u| try doc.putString("uid", u);
                if (data.provider) |p| try doc.putString("provider", p);
                if (data.client_ip) |ip| try doc.putString("client_ip", ip);
                if (data.reason) |r| try doc.putString("reason", r);
                try doc.putInt64("timestamp", data.timestamp);
                try doc.putString("app", data.app);

                const payload = doc.toBytes();
                _ = self.engine.postLocal("system.auth_log", payload, true) catch |err| {
                    log.err("AuditLog: failed to store audit entry: {}", .{err});
                };
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .Demote => blk: {
                const config = @constCast(self.server.config);
                config.primary = false;
                config.replica.enabled = false;
                config.save(self.allocator, self.io, self.server.config_dir) catch {
                    break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                };
                log.info("node demoted: primary=false, replica.enabled=false", .{});
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            .Promote => blk: {
                const config = @constCast(self.server.config);
                config.primary = true;
                config.save(self.allocator, self.io, self.server.config_dir) catch {
                    break :blk Operation{ .Reply = .{ .status = .err, .data = null } };
                };
                log.info("node promoted: primary=true", .{});
                break :blk Operation{ .Reply = .{ .status = .ok, .data = null } };
            },
            else => return error.InvalidOperation,
        };
    }

    fn handleExport(self: *Session, data: []const u8) ![]const u8 {
        const doc = try bson.BsonDocument.init(self.allocator, data, false);
        const manifest_yaml = (try doc.getString("manifest")) orelse return error.MissingManifest;
        const query_json = try doc.getString("query_json");

        var em = try manifest_codec.parse(self.allocator, manifest_yaml);
        defer em.deinit(self.allocator);

        return try self.engine.exportWithManifest(&em, query_json);
    }

    fn handleImport(self: *Session, data: []const u8) ![]const u8 {
        const doc = try bson.BsonDocument.init(self.allocator, data, false);
        const manifest_yaml = (try doc.getString("manifest")) orelse return error.MissingManifest;

        var em = try manifest_codec.parse(self.allocator, manifest_yaml);
        defer em.deinit(self.allocator);

        return try self.engine.importWithManifest(&em);
    }

    fn matchesCriterion(self: *const Session, json_value: std.json.Value, criterion: proto.Attribute) bool {
        _ = self;

        const field_name = switch (criterion) {
            .U64 => |attr| attr.name,
            .I64 => |attr| attr.name,
            .U32 => |attr| attr.name,
            .I32 => |attr| attr.name,
            .Pointer => |attr| attr.name,
            .F64 => |attr| attr.name,
            .F32 => |attr| attr.name,
            else => return false,
        };

        if (json_value != .object) return false;
        const field_value = json_value.object.get(field_name) orelse return false;

        return switch (criterion) {
            .U64 => |attr| switch (field_value) {
                .integer => |i| i >= 0 and @as(u64, @intCast(i)) == attr.value,
                else => false,
            },
            .I64 => |attr| switch (field_value) {
                .integer => |i| i == attr.value,
                else => false,
            },
            .U32 => |attr| switch (field_value) {
                .integer => |i| i >= 0 and i <= std.math.maxInt(u32) and @as(u32, @intCast(i)) == attr.value,
                else => false,
            },
            .I32 => |attr| switch (field_value) {
                .integer => |i| i >= std.math.minInt(i32) and i <= std.math.maxInt(i32) and @as(i32, @intCast(i)) == attr.value,
                else => false,
            },
            .F64 => |attr| switch (field_value) {
                .float => |f| f == attr.value,
                .integer => |i| @as(f64, @floatFromInt(i)) == attr.value,
                else => false,
            },
            .F32 => |attr| switch (field_value) {
                .float => |f| @as(f32, @floatCast(f)) == attr.value,
                .integer => |i| @as(f32, @floatFromInt(i)) == attr.value,
                else => false,
            },
            .Pointer => |attr| switch (field_value) {
                .string => |s| std.mem.eql(u8, s, attr.value),
                else => false,
            },
            else => false,
        };
    }
};

