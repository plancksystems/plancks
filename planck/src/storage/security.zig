const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Now = @import("utils").Now;
const Mutex = @import("utils").Mutex;
const Engine = @import("../engine/engine.zig").Engine;
const proto_mod = @import("proto");
const SYSTEM_USERS_STORE_NS = @import("../common/constants.zig").SYSTEM_USERS_STORE_NS;
const log = std.log.scoped(.security);

pub const Role = enum {
    admin,
    read_write,
    read_only,
    none,
};

pub const Permission = struct {
    can_read: bool = false,
    can_write: bool = false,
    can_delete: bool = false,
    can_admin: bool = false,

    pub fn fromRole(role: Role) Permission {
        return switch (role) {
            .admin => Permission{
                .can_read = true,
                .can_write = true,
                .can_delete = true,
                .can_admin = true,
            },
            .read_write => Permission{
                .can_read = true,
                .can_write = true,
                .can_delete = true,
                .can_admin = false,
            },
            .read_only => Permission{
                .can_read = true,
                .can_write = false,
                .can_delete = false,
                .can_admin = false,
            },
            .none => Permission{},
        };
    }

    pub fn toRoleName(self: Permission) []const u8 {
        if (self.can_admin) return "admin";
        if (self.can_write) return "read_write";
        if (self.can_read) return "read_only";
        return "none";
    }
};

pub const User = struct {
    username: []const u8,
    key_hash: [32]u8,
    key_salt: [32]u8,
    role: Role,
    created_at: i64,
    last_login: i64,
    enabled: bool,
    doc_key: u128 = 0,

    pub fn deinit(self: *User, allocator: Allocator) void {
        allocator.free(self.username);
    }
};

pub const Session = struct {
    token: [32]u8,
    username: []const u8,
    created_at: i64,
    expires_at: i64,
    permissions: Permission,
    now: Now,

    pub fn isValid(self: *const Session) bool {
        return self.now.toMilliSeconds() < self.expires_at;
    }

    pub fn deinit(self: *Session, allocator: Allocator) void {
        allocator.free(self.username);
    }
};

const LoginAttemptInfo = struct {
    failed_count: u32,
    last_failed_at: i64,
    lockout_until: i64,
};

pub const SecurityManager = struct {
    allocator: Allocator,
    enabled: bool,
    io: Io,
    now: Now,
    prng: std.Random.DefaultPrng,

    engine: ?*Engine,
    users_store_id: ?u16,

    users: std.StringHashMap(User),
    users_mutex: Mutex,

    sessions: std.AutoHashMap([32]u8, Session),
    sessions_mutex: Mutex,

    login_attempts: std.StringHashMap(LoginAttemptInfo),
    login_attempts_mutex: Mutex,

    session_timeout_ms: i64,

    max_failed_attempts: u32,
    lockout_duration_ms: i64,
    lockout_multiplier: u32,

    has_default_key: bool,

    pub const default_admin_key = "UGxhbmNrX0RlZmF1bHRfQWRtaW5fS2V5XzAwMTA=";

    pub const ThrottleConfig = struct {
        max_failed_attempts: u32 = 5,
        lockout_duration_ms: i64 = 900_000,
        lockout_multiplier: u32 = 2,
    };

    pub fn init(allocator: Allocator, enabled: bool, io: Io, throttle: ThrottleConfig) !*SecurityManager {
        const now = Io.Clock.now(.real, io).toMilliseconds();
        const seed: u64 = @bitCast(now);
        const mgr = try allocator.create(SecurityManager);
        mgr.* = SecurityManager{
            .allocator = allocator,
            .enabled = enabled,
            .io = io,
            .now = Now{ .io = io },
            .prng = std.Random.DefaultPrng.init(seed),
            .engine = null,
            .users_store_id = null,
            .users = std.StringHashMap(User).init(allocator),
            .users_mutex = .{},
            .sessions = std.AutoHashMap([32]u8, Session).init(allocator),
            .sessions_mutex = .{},
            .login_attempts = std.StringHashMap(LoginAttemptInfo).init(allocator),
            .login_attempts_mutex = .{},
            .session_timeout_ms = 3600 * 1000,
            .max_failed_attempts = throttle.max_failed_attempts,
            .lockout_duration_ms = throttle.lockout_duration_ms,
            .lockout_multiplier = throttle.lockout_multiplier,
            .has_default_key = false,
        };

        return mgr;
    }

    pub fn deinit(self: *SecurityManager) void {
        var user_iter = self.users.iterator();
        while (user_iter.next()) |entry| {
            var u = entry.value_ptr.*;
            u.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.users.deinit();

        var session_iter = self.sessions.iterator();
        while (session_iter.next()) |entry| {
            var s = entry.value_ptr.*;
            s.deinit(self.allocator);
        }
        self.sessions.deinit();

        var attempts_iter = self.login_attempts.iterator();
        while (attempts_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.login_attempts.deinit();

        self.allocator.destroy(self);
    }

    fn createDefaultAdmin(self: *SecurityManager) ![]const u8 {
        const result = try self.createUserWithKey("admin", .admin, default_admin_key);
        self.allocator.free(result.password_hash);
        self.has_default_key = true;
        return result.key_b64;
    }

    fn checkDefaultKey(self: *SecurityManager) bool {
        const user = self.users.get("admin") orelse return false;
        const decoder = &std.base64.standard.Decoder;
        var raw_key: [32]u8 = undefined;
        decoder.decode(&raw_key, default_admin_key) catch return false;
        const computed = self.hashKey(&raw_key, user.key_salt) catch return false;
        return std.crypto.timing_safe.eql([32]u8, computed, user.key_hash);
    }

    pub fn hasDefaultKey(self: *SecurityManager) bool {
        return self.has_default_key;
    }

    pub fn createUserWithKey(self: *SecurityManager, username: []const u8, role: Role, key_b64: []const u8) !CreateUserResult {
        self.users_mutex.lock(self.io);
        defer self.users_mutex.unlock(self.io);

        if (self.users.contains(username)) {
            return error.UserAlreadyExists;
        }

        const decoder = &std.base64.standard.Decoder;
        var raw_key: [32]u8 = undefined;
        decoder.decode(&raw_key, key_b64) catch return error.InvalidCredentials;

        const random = self.prng.random();
        var salt: [32]u8 = undefined;
        random.bytes(&salt);
        const hash = try self.hashKey(&raw_key, salt);

        const key_result = try self.allocator.dupe(u8, key_b64);

        const hex_hash = try self.hexEncode(&hash);
        defer self.allocator.free(hex_hash);
        const hex_salt = try self.hexEncode(&salt);
        defer self.allocator.free(hex_salt);
        const password_hash = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ hex_hash, hex_salt });

        const user = User{
            .username = try self.allocator.dupe(u8, username),
            .key_hash = hash,
            .key_salt = salt,
            .role = role,
            .created_at = self.now.toMilliSeconds(),
            .last_login = 0,
            .enabled = true,
        };

        try self.users.put(try self.allocator.dupe(u8, username), user);

        return .{ .key_b64 = key_result, .password_hash = password_hash };
    }

    pub const CreateUserResult = struct {
        key_b64: []const u8,
        password_hash: []const u8,
    };

    pub fn createUser(self: *SecurityManager, username: []const u8, role: Role) !CreateUserResult {
        self.users_mutex.lock(self.io);
        defer self.users_mutex.unlock(self.io);

        if (self.users.contains(username)) {
            return error.UserAlreadyExists;
        }

        var raw_key: [32]u8 = undefined;
        const random = self.prng.random();
        random.bytes(&raw_key);

        var salt: [32]u8 = undefined;
        random.bytes(&salt);
        const hash = try self.hashKey(&raw_key, salt);

        const encoder = &std.base64.standard.Encoder;
        var b64_buf: [44]u8 = undefined;
        const key_b64 = encoder.encode(&b64_buf, &raw_key);
        const key_result = try self.allocator.dupe(u8, key_b64);

        const hex_hash = try self.hexEncode(&hash);
        defer self.allocator.free(hex_hash);
        const hex_salt = try self.hexEncode(&salt);
        defer self.allocator.free(hex_salt);
        const password_hash = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ hex_hash, hex_salt });

        const user = User{
            .username = try self.allocator.dupe(u8, username),
            .key_hash = hash,
            .key_salt = salt,
            .role = role,
            .created_at = self.now.toMilliSeconds(),
            .last_login = 0,
            .enabled = true,
        };

        try self.users.put(try self.allocator.dupe(u8, username), user);


        return .{ .key_b64 = key_result, .password_hash = password_hash };
    }

    pub fn authenticate(self: *SecurityManager, uid: []const u8, key_b64: []const u8) !Session {
        if (!self.enabled) {
            return Session{
                .token = [_]u8{0} ** 32,
                .now = self.now,
                .username = try self.allocator.dupe(u8, "anonymous"),
                .created_at = self.now.toMilliSeconds(),
                .expires_at = std.math.maxInt(i64),
                .permissions = Permission.fromRole(.admin),
            };
        }

        const now = self.now.toMilliSeconds();

        {
            self.login_attempts_mutex.lock(self.io);
            defer self.login_attempts_mutex.unlock(self.io);
            if (self.login_attempts.get(uid)) |info| {
                if (now < info.lockout_until) {
                    const remaining_s = @divTrunc(info.lockout_until - now, 1000);
                    log.info("Login attempt for locked-out user '{s}' (locked for {d}s more)", .{ uid, remaining_s });
                    return error.AccountLockedOut;
                }
                if (info.lockout_until > 0 and now >= info.lockout_until) {
                    log.info("Lockout window expired for '{s}' — clearing failed-attempt counter", .{uid});
                    self.clearFailedAttemptsLocked(uid);
                }
            }
        }

        const decoder = &std.base64.standard.Decoder;
        var raw_key: [32]u8 = undefined;
        decoder.decode(&raw_key, key_b64) catch {
            self.recordFailedAttempt(uid, now);
            return error.InvalidCredentials;
        };

        self.users_mutex.lock(self.io);
        defer self.users_mutex.unlock(self.io);

        const user = self.users.get(uid) orelse {
            self.recordFailedAttempt(uid, now);
            return error.InvalidCredentials;
        };

        if (!user.enabled) {
            return error.UserDisabled;
        }

        const computed = try self.hashKey(&raw_key, user.key_salt);
        if (!std.crypto.timing_safe.eql([32]u8, computed, user.key_hash)) {
            self.recordFailedAttempt(uid, now);
            return error.InvalidCredentials;
        }

        self.clearFailedAttempts(uid);

        var token: [32]u8 = undefined;
        const random = self.prng.random();
        random.bytes(&token);

        const session = Session{
            .token = token,
            .now = self.now,
            .username = try self.allocator.dupe(u8, uid),
            .created_at = self.now.toMilliSeconds(),
            .expires_at = self.now.toMilliSeconds() + self.session_timeout_ms,
            .permissions = Permission.fromRole(user.role),
        };

        self.sessions_mutex.lock(self.io);
        defer self.sessions_mutex.unlock(self.io);
        try self.sessions.put(token, session);

        return session;
    }

    fn recordFailedAttempt(self: *SecurityManager, uid: []const u8, now: i64) void {
        self.login_attempts_mutex.lock(self.io);
        defer self.login_attempts_mutex.unlock(self.io);
        const result = self.login_attempts.getOrPut(uid) catch return;
        if (!result.found_existing) {
            result.key_ptr.* = self.allocator.dupe(u8, uid) catch return;
            result.value_ptr.* = LoginAttemptInfo{
                .failed_count = 1,
                .last_failed_at = now,
                .lockout_until = 0,
            };
        } else {
            result.value_ptr.failed_count += 1;
            result.value_ptr.last_failed_at = now;
        }

        const count = result.value_ptr.failed_count;
        if (count >= self.max_failed_attempts) {
            const excess = count - self.max_failed_attempts;
            var multiplied_duration = self.lockout_duration_ms;
            for (0..excess) |_| {
                multiplied_duration = @min(
                    multiplied_duration * self.lockout_multiplier,
                    3600_000,
                );
            }
            result.value_ptr.lockout_until = now + multiplied_duration;
            log.info("User '{s}' locked out for {d}ms after {d} failed attempts", .{
                uid, multiplied_duration, count,
            });
        }
    }

    fn clearFailedAttempts(self: *SecurityManager, uid: []const u8) void {
        self.login_attempts_mutex.lock(self.io);
        defer self.login_attempts_mutex.unlock(self.io);
        self.clearFailedAttemptsLocked(uid);
    }

    fn clearFailedAttemptsLocked(self: *SecurityManager, uid: []const u8) void {
        if (self.login_attempts.fetchRemove(uid)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    pub fn validateSession(self: *SecurityManager, token: [32]u8) !Session {
        if (!self.enabled) {
            return Session{
                .token = [_]u8{0} ** 32,
                .now = self.now,
                .username = try self.allocator.dupe(u8, "anonymous"),
                .created_at = self.now.toMilliSeconds(),
                .expires_at = std.math.maxInt(i64),
                .permissions = Permission.fromRole(.admin),
            };
        }

        self.sessions_mutex.lock(self.io);
        defer self.sessions_mutex.unlock(self.io);

        const session = self.sessions.get(token) orelse return error.InvalidSession;

        if (!session.isValid()) {
            return error.SessionExpired;
        }

        return session;
    }

    pub fn checkPermission(self: *SecurityManager, session: *const Session, permission_type: PermissionType) !void {
        _ = self;
        const has_permission = switch (permission_type) {
            .read => session.permissions.can_read,
            .write => session.permissions.can_write,
            .delete => session.permissions.can_delete,
            .admin => session.permissions.can_admin,
        };

        if (!has_permission) {
            return error.PermissionDenied;
        }
    }

    pub fn revokeSession(self: *SecurityManager, token: [32]u8) !void {
        self.sessions_mutex.lock(self.io);
        defer self.sessions_mutex.unlock(self.io);

        if (self.sessions.fetchRemove(token)) |kv| {
            var session = kv.value;
            session.deinit(self.allocator);
        }
    }

    pub fn regenerateKey(self: *SecurityManager, username: []const u8) !CreateUserResult {
        self.users_mutex.lock(self.io);
        defer self.users_mutex.unlock(self.io);

        const user_ptr = self.users.getPtr(username) orelse return error.UserNotFound;

        var raw_key: [32]u8 = undefined;
        const random = self.prng.random();
        random.bytes(&raw_key);

        var new_salt: [32]u8 = undefined;
        random.bytes(&new_salt);
        user_ptr.key_hash = try self.hashKey(&raw_key, new_salt);
        user_ptr.key_salt = new_salt;

        const encoder = &std.base64.standard.Encoder;
        var b64_buf: [44]u8 = undefined;
        const key_b64 = encoder.encode(&b64_buf, &raw_key);
        const key_result = try self.allocator.dupe(u8, key_b64);

        const hex_hash = try self.hexEncode(&user_ptr.key_hash);
        defer self.allocator.free(hex_hash);
        const hex_salt = try self.hexEncode(&new_salt);
        defer self.allocator.free(hex_salt);
        const password_hash = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ hex_hash, hex_salt });

        if (std.mem.eql(u8, username, "admin")) {
            self.has_default_key = false;
        }

        return CreateUserResult{
            .key_b64 = key_result,
            .password_hash = password_hash,
        };
    }

    pub fn updateUserRole(self: *SecurityManager, username: []const u8, role: Role) !void {
        self.users_mutex.lock(self.io);
        defer self.users_mutex.unlock(self.io);

        const user_ptr = self.users.getPtr(username) orelse return error.UserNotFound;
        user_ptr.role = role;
    }

    pub fn deleteUser(self: *SecurityManager, username: []const u8) !void {
        self.users_mutex.lock(self.io);
        defer self.users_mutex.unlock(self.io);

        if (self.users.fetchRemove(username)) |kv| {
            var user = kv.value;
            user.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
    }

    fn hashKey(self: *SecurityManager, key: []const u8, salt: [32]u8) ![32]u8 {
        var hash: [32]u8 = undefined;
        try std.crypto.pwhash.argon2.kdf(
            self.allocator,
            &hash,
            key,
            &salt,
            .{ .t = 2, .m = 65536, .p = 1 },
            .argon2id,
            self.io,
        );
        return hash;
    }

    pub fn attachEngine(self: *SecurityManager, engine: *Engine) !void {
        self.engine = engine;

        if (!self.enabled) {
            return;
        }

        try self.ensureUsersStore();

        try self.loadUsersFromCatalog();

        self.users_mutex.lock(self.io);
        const user_count = self.users.count();
        self.users_mutex.unlock(self.io);

        std.debug.print("attachEngine: user_count={d}\n", .{user_count});
        if (user_count == 0) {
            const eng = self.engine orelse return error.EngineNotAttached;

            const result = try self.createUserWithKey("admin", .admin, default_admin_key);
            defer self.allocator.free(result.key_b64);
            defer self.allocator.free(result.password_hash);
            self.has_default_key = true;
            std.debug.print("attachEngine: admin created with default key\n", .{});
            _ = eng.catalog.createUser("admin", result.password_hash, 0) catch |err| {
                log.err("Failed to persist default admin in catalog: {}", .{err});
            };
            log.info("First startup: admin user created with default key. Regenerate key before use.", .{});
        } else {
            self.has_default_key = self.checkDefaultKey();
        }
    }

    fn ensureUsersStore(self: *SecurityManager) !void {
        const engine = self.engine orelse return error.EngineNotAttached;

        const store = engine.catalog.findStoreByNamespace(SYSTEM_USERS_STORE_NS) orelse
            return error.SystemUsersStoreNotFound;
        self.users_store_id = store.id;
    }

    fn loadUsersFromCatalog(self: *SecurityManager) !void {
        const engine = self.engine orelse return error.EngineNotAttached;

        var iter = engine.catalog.users.valueIterator();
        while (iter.next()) |user_ptr| {
            const cat_user: *const proto_mod.User = user_ptr.*;
            if (self.users.contains(cat_user.username)) continue;

            const ph = cat_user.password_hash;
            if (std.mem.indexOfScalar(u8, ph, ':')) |colon_pos| {
                const hex_hash_str = ph[0..colon_pos];
                const hex_salt_str = ph[colon_pos + 1 ..];

                const hash_bytes = self.hexDecode(hex_hash_str) catch {
                    log.warn("loadUsersFromCatalog: invalid key_hash hex for user {s}", .{cat_user.username});
                    continue;
                };
                defer self.allocator.free(hash_bytes);
                if (hash_bytes.len != 32) continue;

                const salt_bytes = self.hexDecode(hex_salt_str) catch {
                    log.warn("loadUsersFromCatalog: invalid key_salt hex for user {s}", .{cat_user.username});
                    continue;
                };
                defer self.allocator.free(salt_bytes);
                if (salt_bytes.len != 32) continue;

                const role: Role = switch (cat_user.role) {
                    0 => .admin,
                    1 => .read_write,
                    2 => .read_only,
                    else => .none,
                };

                const user = User{
                    .username = try self.allocator.dupe(u8, cat_user.username),
                    .key_hash = hash_bytes[0..32].*,
                    .key_salt = salt_bytes[0..32].*,
                    .role = role,
                    .created_at = cat_user.created_at,
                    .last_login = 0,
                    .enabled = true,
                };

                self.users_mutex.lock(self.io);
                defer self.users_mutex.unlock(self.io);
                try self.users.put(try self.allocator.dupe(u8, cat_user.username), user);
            } else {
                log.warn("loadUsersFromCatalog: no hash:salt separator for user {s}, trying legacy store", .{cat_user.username});
            }
        }

        self.loadUsersFromStore() catch |err| {
            log.warn("loadUsersFromCatalog: legacy store load failed (may not exist): {}", .{err});
        };
    }

    fn loadUsersFromStore(self: *SecurityManager) !void {
        const engine = self.engine orelse return error.EngineNotAttached;
        if (self.users_store_id == null) return;

        const entries = engine.listDocs(SYSTEM_USERS_STORE_NS, null, null) catch |err| {
            if (err == error.StoreNotFound) return;
            return err;
        };
        defer self.allocator.free(entries);

        for (entries) |entry| {
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, entry.value, .{}) catch |err| {
                std.log.warn("Failed to parse user JSON: {}", .{err});
                continue;
            };
            defer parsed.deinit();

            if (parsed.value != .object) continue;

            self.parseAndAddUser(parsed.value.object, entry.key) catch |err| {
                std.log.warn("Failed to parse user: {}", .{err});
                continue;
            };
        }
    }

    fn parseAndAddUser(self: *SecurityManager, obj: std.json.ObjectMap, doc_key: u128) !void {
        const username_val = obj.get("username") orelse return error.MissingField;
        const password_hash_hex = obj.get("key_hash") orelse return error.MissingField;
        const password_salt_hex = obj.get("key_salt") orelse return error.MissingField;
        const role_str = obj.get("role") orelse return error.MissingField;
        const created_at_val = obj.get("created_at") orelse return error.MissingField;
        const enabled_val = obj.get("enabled") orelse return error.MissingField;

        if (username_val != .string or password_hash_hex != .string or
            password_salt_hex != .string or role_str != .string)
        {
            return error.InvalidFieldType;
        }

        const hash_bytes = try self.hexDecode(password_hash_hex.string);
        defer self.allocator.free(hash_bytes);
        if (hash_bytes.len != 32) return error.InvalidFieldType;
        const key_hash: [32]u8 = hash_bytes[0..32].*;

        const salt_bytes = try self.hexDecode(password_salt_hex.string);
        defer self.allocator.free(salt_bytes);
        if (salt_bytes.len != 32) return error.InvalidFieldType;
        const key_salt: [32]u8 = salt_bytes[0..32].*;

        const role: Role = if (std.mem.eql(u8, role_str.string, "admin"))
            .admin
        else if (std.mem.eql(u8, role_str.string, "read_write"))
            .read_write
        else if (std.mem.eql(u8, role_str.string, "read_only"))
            .read_only
        else
            .none;

        const created_at: i64 = switch (created_at_val) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => 0,
        };

        const last_login_val = obj.get("last_login");
        const last_login: i64 = if (last_login_val) |v| switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => 0,
        } else 0;

        const enabled = enabled_val == .bool and enabled_val.bool;

        const user = User{
            .username = try self.allocator.dupe(u8, username_val.string),
            .key_hash = key_hash,
            .key_salt = key_salt,
            .role = role,
            .created_at = created_at,
            .last_login = last_login,
            .enabled = enabled,
            .doc_key = doc_key,
        };

        self.users_mutex.lock(self.io);
        defer self.users_mutex.unlock(self.io);

        const username_key = try self.allocator.dupe(u8, username_val.string);
        try self.users.put(username_key, user);
    }

    fn persistUser(self: *SecurityManager, user: *const User) !u128 {
        const engine = self.engine orelse return 0;
        if (self.users_store_id == null) return 0;

        const json = try self.serializeUserToJson(user);
        defer self.allocator.free(json);

        const key = engine.post(SYSTEM_USERS_STORE_NS, json, true) catch |err| {
            std.log.err("Failed to persist user {s}: {}", .{ user.username, err });
            return err;
        };
        return key;
    }

    fn serializeUserToJson(self: *SecurityManager, user: *const User) ![]u8 {
        const hex_hash = try self.hexEncode(&user.key_hash);
        defer self.allocator.free(hex_hash);
        const hex_salt = try self.hexEncode(&user.key_salt);
        defer self.allocator.free(hex_salt);

        const role_str = switch (user.role) {
            .admin => "admin",
            .read_write => "read_write",
            .read_only => "read_only",
            .none => "none",
        };

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.print(self.allocator,
            \\{{"username":"{s}","key_hash":"{s}","key_salt":"{s}","role":"{s}","created_at":{d},"last_login":{d},"enabled":{s}}}
        , .{
            user.username,
            hex_hash,
            hex_salt,
            role_str,
            user.created_at,
            user.last_login,
            if (user.enabled) "true" else "false",
        });

        return try buf.toOwnedSlice(self.allocator);
    }

    fn hexEncode(self: *SecurityManager, data: []const u8) ![]u8 {
        const hex_chars = "0123456789abcdef";
        const result = try self.allocator.alloc(u8, data.len * 2);

        for (data, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0f];
        }

        return result;
    }

    fn hexDecode(self: *SecurityManager, hex: []const u8) ![]u8 {
        if (hex.len % 2 != 0) return error.InvalidHexLength;

        const result = try self.allocator.alloc(u8, hex.len / 2);
        errdefer self.allocator.free(result);

        for (0..hex.len / 2) |i| {
            const high = hexCharToValue(hex[i * 2]) orelse return error.InvalidHexChar;
            const low = hexCharToValue(hex[i * 2 + 1]) orelse return error.InvalidHexChar;
            result[i] = (high << 4) | low;
        }

        return result;
    }

    fn hexCharToValue(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }
};

pub const PermissionType = enum {
    read,
    write,
    delete,
    admin,
};

test "Role - enum values" {
    const admin = Role.admin;
    const read_write = Role.read_write;
    const read_only = Role.read_only;
    const none = Role.none;

    try std.testing.expect(admin != read_write);
    try std.testing.expect(read_write != read_only);
    try std.testing.expect(read_only != none);
}

test "Permission - fromRole admin" {
    const perm = Permission.fromRole(.admin);

    try std.testing.expectEqual(true, perm.can_read);
    try std.testing.expectEqual(true, perm.can_write);
    try std.testing.expectEqual(true, perm.can_delete);
    try std.testing.expectEqual(true, perm.can_admin);
}

test "Permission - fromRole read_write" {
    const perm = Permission.fromRole(.read_write);

    try std.testing.expectEqual(true, perm.can_read);
    try std.testing.expectEqual(true, perm.can_write);
    try std.testing.expectEqual(true, perm.can_delete);
    try std.testing.expectEqual(false, perm.can_admin);
}

test "Permission - fromRole read_only" {
    const perm = Permission.fromRole(.read_only);

    try std.testing.expectEqual(true, perm.can_read);
    try std.testing.expectEqual(false, perm.can_write);
    try std.testing.expectEqual(false, perm.can_delete);
    try std.testing.expectEqual(false, perm.can_admin);
}

test "Permission - fromRole none" {
    const perm = Permission.fromRole(.none);

    try std.testing.expectEqual(false, perm.can_read);
    try std.testing.expectEqual(false, perm.can_write);
    try std.testing.expectEqual(false, perm.can_delete);
    try std.testing.expectEqual(false, perm.can_admin);
}

test "Permission - default values" {
    const perm = Permission{};

    try std.testing.expectEqual(false, perm.can_read);
    try std.testing.expectEqual(false, perm.can_write);
    try std.testing.expectEqual(false, perm.can_delete);
    try std.testing.expectEqual(false, perm.can_admin);
}

test "User - structure" {
    const user = User{
        .username = "testuser",
        .key_hash = [_]u8{0} ** 32,
        .key_salt = [_]u8{0} ** 32,
        .role = .read_write,
        .created_at = 1000,
        .last_login = 2000,
        .enabled = true,
    };

    try std.testing.expectEqualStrings("testuser", user.username);
    try std.testing.expectEqual(Role.read_write, user.role);
    try std.testing.expectEqual(true, user.enabled);
}

test "User - disabled" {
    const user = User{
        .username = "disabled_user",
        .key_hash = [_]u8{0} ** 32,
        .key_salt = [_]u8{0} ** 32,
        .role = .none,
        .created_at = 0,
        .last_login = 0,
        .enabled = false,
    };

    try std.testing.expectEqual(false, user.enabled);
    try std.testing.expectEqual(Role.none, user.role);
}

test "Session - isValid when not expired" {
    const session = Session{
        .now = .{ .io = std.testing.io },
        .token = [_]u8{0} ** 32,
        .username = "testuser",
        .created_at = 1000,
        .expires_at = std.math.maxInt(i64),
        .permissions = Permission.fromRole(.admin),
    };

    try std.testing.expectEqual(true, session.isValid());
}

test "Session - isValid when expired" {
    const session = Session{
        .now = .{ .io = std.testing.io },
        .token = [_]u8{0} ** 32,
        .username = "testuser",
        .created_at = 0,
        .expires_at = 0,
        .permissions = Permission.fromRole(.read_only),
    };

    try std.testing.expectEqual(false, session.isValid());
}

test "PermissionType - enum values" {
    const read = PermissionType.read;
    const write = PermissionType.write;
    const delete = PermissionType.delete;
    const admin = PermissionType.admin;

    try std.testing.expect(read != write);
    try std.testing.expect(write != delete);
    try std.testing.expect(delete != admin);
}

test "SecurityManager - init disabled" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    try std.testing.expectEqual(false, mgr.enabled);
    try std.testing.expectEqual(@as(i64, 3600 * 1000), mgr.session_timeout_ms);
}

test "SecurityManager - init enabled no auto admin" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    try std.testing.expectEqual(true, mgr.enabled);

    mgr.users_mutex.lock(mgr.io);
    defer mgr.users_mutex.unlock(mgr.io);
    try std.testing.expect(!mgr.users.contains("admin"));
}

test "SecurityManager - createDefaultAdmin" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const admin_key = try mgr.createDefaultAdmin();
    defer allocator.free(admin_key);

    try std.testing.expect(admin_key.len == 40);

    mgr.users_mutex.lock(mgr.io);
    defer mgr.users_mutex.unlock(mgr.io);
    try std.testing.expect(mgr.users.contains("admin"));
}

test "SecurityManager - authenticate when disabled" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    var session = try mgr.authenticate("anyone", "anything");
    defer session.deinit(allocator);

    try std.testing.expectEqualStrings("anonymous", session.username);
    try std.testing.expectEqual(true, session.permissions.can_admin);
}

test "SecurityManager - createUser duplicate error" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const admin_key = try mgr.createDefaultAdmin();
    defer allocator.free(admin_key);

    const result = mgr.createUser("admin", .admin);
    try std.testing.expectError(error.UserAlreadyExists, result);
}

test "SecurityManager - authenticate invalid credentials" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const admin_key = try mgr.createDefaultAdmin();
    defer allocator.free(admin_key);

    const result = mgr.authenticate("admin", "dGhpcyBpcyBhIGJhZCBrZXkgdGhhdCB3b250IHdvcms=");
    try std.testing.expectError(error.InvalidCredentials, result);
}

test "SecurityManager - authenticate valid credentials" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const admin_key = try mgr.createDefaultAdmin();
    defer allocator.free(admin_key);

    const session = try mgr.authenticate("admin", admin_key);

    try std.testing.expectEqualStrings("admin", session.username);
    try std.testing.expectEqual(true, session.permissions.can_admin);
}

test "SecurityManager - validateSession invalid" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const result = mgr.validateSession([_]u8{0} ** 32);
    try std.testing.expectError(error.InvalidSession, result);
}

test "SecurityManager - checkPermission admin has all" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    const session = Session{
        .now = .{ .io = std.testing.io },
        .token = [_]u8{0} ** 32,
        .username = "admin",
        .created_at = 0,
        .expires_at = std.math.maxInt(i64),
        .permissions = Permission.fromRole(.admin),
    };

    try mgr.checkPermission(&session, .read);
    try mgr.checkPermission(&session, .write);
    try mgr.checkPermission(&session, .delete);
    try mgr.checkPermission(&session, .admin);
}

test "SecurityManager - checkPermission read_only denied write" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    const session = Session{
        .now = .{ .io = std.testing.io },
        .token = [_]u8{0} ** 32,
        .username = "reader",
        .created_at = 0,
        .expires_at = std.math.maxInt(i64),
        .permissions = Permission.fromRole(.read_only),
    };

    try mgr.checkPermission(&session, .read);

    const write_result = mgr.checkPermission(&session, .write);
    try std.testing.expectError(error.PermissionDenied, write_result);

    const admin_result = mgr.checkPermission(&session, .admin);
    try std.testing.expectError(error.PermissionDenied, admin_result);
}

test "SecurityManager - checkPermission none denied all" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    const session = Session{
        .now = .{ .io = std.testing.io },
        .token = [_]u8{0} ** 32,
        .username = "nobody",
        .created_at = 0,
        .expires_at = std.math.maxInt(i64),
        .permissions = Permission.fromRole(.none),
    };

    try std.testing.expectError(error.PermissionDenied, mgr.checkPermission(&session, .read));
    try std.testing.expectError(error.PermissionDenied, mgr.checkPermission(&session, .write));
    try std.testing.expectError(error.PermissionDenied, mgr.checkPermission(&session, .delete));
    try std.testing.expectError(error.PermissionDenied, mgr.checkPermission(&session, .admin));
}

test "SecurityManager - deleteUser" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const result = try mgr.createUser("testuser", .read_only);
    defer allocator.free(result.key_b64);
    defer allocator.free(result.password_hash);

    try mgr.deleteUser("testuser");

    mgr.users_mutex.lock(mgr.io);
    defer mgr.users_mutex.unlock(mgr.io);
    try std.testing.expect(!mgr.users.contains("testuser"));
}

test "SecurityManager - regenerateKey" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const admin_key = try mgr.createDefaultAdmin();
    defer allocator.free(admin_key);

    const result = try mgr.regenerateKey("admin");
    defer allocator.free(result.key_b64);
    defer allocator.free(result.password_hash);

    const old_auth = mgr.authenticate("admin", admin_key);
    try std.testing.expectError(error.InvalidCredentials, old_auth);

    const session = try mgr.authenticate("admin", result.key_b64);
    try std.testing.expectEqualStrings("admin", session.username);
}

test "SecurityManager - regenerateKey user not found" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const result = mgr.regenerateKey("nonexistent");
    try std.testing.expectError(error.UserNotFound, result);
}

test "SecurityManager - revokeSession" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{});
    defer mgr.deinit();

    const admin_key = try mgr.createDefaultAdmin();
    defer allocator.free(admin_key);

    const session = try mgr.authenticate("admin", admin_key);
    const token = session.token;

    _ = try mgr.validateSession(token);

    try mgr.revokeSession(token);

    const result = mgr.validateSession(token);
    try std.testing.expectError(error.InvalidSession, result);
}

test "SecurityManager - hexEncode" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    const data = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    const hex = try mgr.hexEncode(&data);
    defer allocator.free(hex);

    try std.testing.expectEqualStrings("48656c6c6f", hex);
}

test "SecurityManager - hexDecode" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    const decoded = try mgr.hexDecode("48656c6c6f");
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("Hello", decoded);
}

test "SecurityManager - hexEncode/hexDecode " {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    const original = [_]u8{ 0x5e, 0x88, 0x48, 0x98, 0xda, 0x28, 0x04, 0x71 } ** 4;
    const hex = try mgr.hexEncode(&original);
    defer allocator.free(hex);

    const decoded = try mgr.hexDecode(hex);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &original, decoded);
}

test "SecurityManager - serializeUserToJson" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, false, std.testing.io, .{});
    defer mgr.deinit();

    const user = User{
        .username = "testuser",
        .key_hash = .{ 0x61, 0x62, 0x63 } ++ .{0} ** 29,
        .key_salt = [_]u8{0} ** 32,
        .role = .read_write,
        .created_at = 1000,
        .last_login = 2000,
        .enabled = true,
    };

    const json = try mgr.serializeUserToJson(&user);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"username\":\"testuser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"key_hash\":\"616263") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"read_write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":true") != null);
}

test "SecurityManager - brute-force lockout after max attempts" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{
        .max_failed_attempts = 3,
        .lockout_duration_ms = 60_000,
        .lockout_multiplier = 2,
    });
    defer mgr.deinit();

    const admin_key = try mgr.createDefaultAdmin();
    defer allocator.free(admin_key);

    const bad_key = "dGhpcyBpcyBhIGJhZCBrZXkgdGhhdCB3b250IHdvcms=";

    for (0..3) |_| {
        const result = mgr.authenticate("admin", bad_key);
        try std.testing.expectError(error.InvalidCredentials, result);
    }

    const result = mgr.authenticate("admin", bad_key);
    try std.testing.expectError(error.AccountLockedOut, result);

    const result2 = mgr.authenticate("admin", admin_key);
    try std.testing.expectError(error.AccountLockedOut, result2);
}

test "SecurityManager - successful login clears failed attempts" {
    const allocator = std.testing.allocator;
    const mgr = try SecurityManager.init(allocator, true, std.testing.io, .{
        .max_failed_attempts = 5,
        .lockout_duration_ms = 60_000,
        .lockout_multiplier = 2,
    });
    defer mgr.deinit();

    const admin_key = try mgr.createDefaultAdmin();
    defer allocator.free(admin_key);

    const bad_key = "dGhpcyBpcyBhIGJhZCBrZXkgdGhhdCB3b250IHdvcms=";

    for (0..3) |_| {
        const result = mgr.authenticate("admin", bad_key);
        try std.testing.expectError(error.InvalidCredentials, result);
    }

    _ = try mgr.authenticate("admin", admin_key);

    for (0..3) |_| {
        const result = mgr.authenticate("admin", bad_key);
        try std.testing.expectError(error.InvalidCredentials, result);
    }
}
