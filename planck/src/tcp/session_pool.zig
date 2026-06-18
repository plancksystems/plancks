const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const Mutex = @import("utils").Mutex;
const Engine = @import("../engine/engine.zig").Engine;
const Session = @import("server.zig").Session;
const SecurityManager = @import("../storage/security.zig").SecurityManager;
const common = @import("../common/common.zig");
const MessageBufferPool = @import("message_buffer_pool.zig").MessageBufferPool;

const log = std.log.scoped(.session_pool);

pub const SessionPool = struct {
    allocator: Allocator,
    pool: std.ArrayList(*Session),
    mutex: Mutex,
    io: Io,
    engine: *Engine,
    max_size: usize,
    idle_timeout_ms: u64,
    security_manager: *SecurityManager,

    pub fn init(allocator: Allocator, io: Io, engine: *Engine, pool_size: usize, idle_timeout_ms: u64, security_manager: *SecurityManager) !SessionPool {
        var pool: std.ArrayList(*Session) = .empty;
        errdefer pool.deinit(allocator);

        try pool.ensureTotalCapacity(allocator, pool_size);

        return SessionPool{
            .allocator = allocator,
            .pool = pool,
            .mutex = .{},
            .io = io,
            .engine = engine,
            .max_size = pool_size,
            .idle_timeout_ms = idle_timeout_ms,
            .security_manager = security_manager,
        };
    }

    pub fn deinit(self: *SessionPool) void {
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        for (self.pool.items) |session| {
            session.deinit();
            self.allocator.destroy(session);
        }
        self.pool.deinit(self.allocator);
    }

    pub fn acquire(self: *SessionPool, connection: net.Stream, message_buffer_pool: *MessageBufferPool, server: anytype) !*Session {
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pool.items.len > 0) {
            const session = self.pool.pop().?;
            session.reset(connection, server);
            return session;
        }

        const session = try self.allocator.create(Session);
        session.* = try Session.init(self.allocator, self.io, connection, self.engine, server, self.idle_timeout_ms, message_buffer_pool, self.security_manager);
        return session;
    }

    pub fn release(self: *SessionPool, session: *Session) void {
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pool.items.len < self.max_size) {
            self.pool.append(self.allocator, session) catch {
                session.deinit();
                self.allocator.destroy(session);
            };
        } else {
            session.deinit();
            self.allocator.destroy(session);
        }
    }
};
