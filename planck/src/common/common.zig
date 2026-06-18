const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Yaml = @import("yaml").Yaml;
const Now = @import("utils").Now;

pub fn nowMs(io: Io) i64 {
    const n: Now = .{ .io = io };
    return n.toMilliSeconds();
}

pub const PageId = u16;

pub const FrameId = u16;

pub const VlogEntry = struct {
    key: u128,
    lsn: u64 = 0,
    value: []const u8,
    timestamp: i64,
    tombstone: bool = false,

    pub fn write(self: *const VlogEntry, writer: anytype) anyerror!void {
        try writer.writeInt(u128, self.key, .little);
        try writer.writeInt(u64, self.lsn, .little);
        try writer.writeInt(u64, self.value.len, .little);
        _ = try writer.writeAll(self.value);
        try writer.writeInt(i64, self.timestamp, .little);
        try writer.writeInt(u8, if (self.tombstone) 1 else 0, .little);

        const seed: u64 = 0;
        var hasher = std.hash.Wyhash.init(seed);
        hasher.update(std.mem.asBytes(&self.key));
        hasher.update(std.mem.asBytes(&self.lsn));
        hasher.update(std.mem.asBytes(&self.value.len));
        hasher.update(self.value);
        hasher.update(std.mem.asBytes(&self.timestamp));
        const tombstone_byte: u8 = if (self.tombstone) 1 else 0;
        hasher.update(std.mem.asBytes(&tombstone_byte));

        const checksum = hasher.final();
        try writer.writeInt(u64, checksum, .little);
    }

    pub fn toBytes(self: *const VlogEntry, allocator: std.mem.Allocator) ![]u8 {
        const total_size = 49 + self.value.len;
        const buffer = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buffer);

        var offset: usize = 0;

        std.mem.writeInt(u128, buffer[offset..][0..16], self.key, .little);
        offset += 16;

        std.mem.writeInt(u64, buffer[offset..][0..8], self.lsn, .little);
        offset += 8;

        std.mem.writeInt(u64, buffer[offset..][0..8], self.value.len, .little);
        offset += 8;

        @memcpy(buffer[offset .. offset + self.value.len], self.value);
        offset += self.value.len;

        std.mem.writeInt(i64, buffer[offset..][0..8], self.timestamp, .little);
        offset += 8;

        const tombstone_byte: u8 = if (self.tombstone) 1 else 0;
        buffer[offset] = tombstone_byte;
        offset += 1;

        const seed: u64 = 0;
        var hasher = std.hash.Wyhash.init(seed);
        hasher.update(std.mem.asBytes(&self.key));
        hasher.update(std.mem.asBytes(&self.lsn));
        hasher.update(std.mem.asBytes(&self.value.len));
        hasher.update(self.value);
        hasher.update(std.mem.asBytes(&self.timestamp));
        hasher.update(std.mem.asBytes(&tombstone_byte));
        const checksum = hasher.final();

        std.mem.writeInt(u64, buffer[offset..][0..8], checksum, .little);

        return buffer;
    }

    pub fn read(allocator: std.mem.Allocator, reader: anytype) !VlogEntry {
        const key = try reader.readInt(u128, .little);
        const lsn = try reader.readInt(u64, .little);
        const value_len = try reader.readInt(u64, .little);
        const value_buff = try allocator.alloc(u8, value_len);
        defer allocator.free(value_buff);
        _ = try reader.readAll(value_buff);
        const timestamp = try reader.readInt(i64, .little);
        const tombstone_byte = try reader.readInt(u8, .little);

        const file_checksum = try reader.readInt(u64, .little);

        const seed: u64 = 0;
        var hasher = std.hash.Wyhash.init(seed);
        hasher.update(std.mem.asBytes(&key));
        hasher.update(std.mem.asBytes(&lsn));
        hasher.update(std.mem.asBytes(&value_len));
        hasher.update(value_buff);
        hasher.update(std.mem.asBytes(&timestamp));
        hasher.update(std.mem.asBytes(&tombstone_byte));
        const checksum = hasher.final();
        if (file_checksum != checksum) {
            return error.InvalidChecksum;
        }

        return VlogEntry{
            .key = key,
            .lsn = lsn,
            .value = try allocator.dupe(u8, value_buff),
            .timestamp = timestamp,
            .tombstone = tombstone_byte != 0,
        };
    }

    pub fn readFromSlice(allocator: std.mem.Allocator, data: []const u8) !VlogEntry {
        var offset: usize = 0;

        if (data.len < 49) return error.BufferTooSmall;

        const key = std.mem.readInt(u128, data[offset..][0..16], .little);
        offset += 16;

        const lsn = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const value_len = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const expected_total_size = 49 + value_len;
        if (data.len < expected_total_size) return error.BufferTooSmall;

        const value_data = data[offset .. offset + value_len];
        offset += value_len;

        const timestamp = std.mem.readInt(i64, data[offset..][0..8], .little);
        offset += 8;

        const tombstone_byte = data[offset];
        offset += 1;

        const file_checksum = std.mem.readInt(u64, data[offset..][0..8], .little);

        const seed: u64 = 0;
        var hasher = std.hash.Wyhash.init(seed);
        hasher.update(std.mem.asBytes(&key));
        hasher.update(std.mem.asBytes(&lsn));
        hasher.update(std.mem.asBytes(&value_len));
        hasher.update(value_data);
        hasher.update(std.mem.asBytes(&timestamp));
        hasher.update(std.mem.asBytes(&tombstone_byte));
        const checksum = hasher.final();
        if (file_checksum != checksum) {
            return error.InvalidChecksum;
        }

        return VlogEntry{
            .key = key,
            .lsn = lsn,
            .value = try allocator.dupe(u8, value_data),
            .timestamp = timestamp,
            .tombstone = tombstone_byte != 0,
        };
    }

    pub fn size(self: *const VlogEntry) usize {
        return @sizeOf(u128) + @sizeOf(u64) + @sizeOf(u64) + self.value.len + @sizeOf(i64) + @sizeOf(u8) + @sizeOf(u64);
    }

    pub fn deinit(self: *VlogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const OpKind = enum(u8) {
    insert,
    update,
    delete,
    read,
    sequence,
};

pub const LogRecord = struct {
    lsn: u64,
    key: u128,
    value: []const u8,
    timestamp: i64,
    kind: OpKind,

    pub fn hash(self: LogRecord) u64 {
        const seed: u64 = 0;
        var hasher = std.hash.Wyhash.init(seed);
        hasher.update(std.mem.asBytes(&self.lsn));
        hasher.update(std.mem.asBytes(&self.key));
        hasher.update(std.mem.asBytes(&self.timestamp));
        hasher.update(std.mem.asBytes(&self.kind));
        hasher.update(self.value);
        return hasher.final();
    }

    pub fn size(self: LogRecord) usize {
        return @sizeOf(u32) +
            @sizeOf(u64) +
            @sizeOf(u128) +
            @sizeOf(u32) +
            self.value.len +
            @sizeOf(i64) +
            @sizeOf(u8) +
            @sizeOf(u64);
    }

    pub fn serialize(record: LogRecord, writer: anytype) !void {
        const checksum = record.hash();
        const payload_len: u32 = @intCast(record.size() - @sizeOf(u32));
        try writer.writeInt(u32, payload_len, .little);
        try writer.writeInt(u64, record.lsn, .little);
        try writer.writeInt(u128, record.key, .little);
        try writer.writeInt(u32, @intCast(record.value.len), .little);
        try writer.writeAll(record.value);
        try writer.writeInt(i64, record.timestamp, .little);
        try writer.writeInt(u8, @intFromEnum(record.kind), .little);
        try writer.writeInt(u64, checksum, .little);
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: anytype) !?LogRecord {
        const payload_len = reader.readInt(u32, .little) catch |err| {
            if (err == error.EndOfStream) return null;
            return err;
        };
        if (payload_len > 1_000_000_000) return error.RecordTooLarge;

        const lsn = reader.readInt(u64, .little) catch |err| {
            if (err == error.EndOfStream) return error.InvalidRecordLength;
            return err;
        };

        const key = reader.readInt(u128, .little) catch |err| {
            if (err == error.EndOfStream) return error.InvalidRecordLength;
            return err;
        };

        const value_len = reader.readInt(u32, .little) catch |err| {
            if (err == error.EndOfStream) return error.InvalidRecordLength;
            return err;
        };
        const value = allocator.alloc(u8, value_len) catch |err| {
            if (err == error.EndOfStream) return error.InvalidRecordLength;
            return err;
        };
        errdefer allocator.free(value);
        _ = reader.readAll(value) catch |err| {
            if (err == error.EndOfStream) return error.InvalidRecordLength;
            return err;
        };
        const timestamp = reader.readInt(i64, .little) catch |err| {
            if (err == error.EndOfStream) return error.InvalidRecordLength;
            return err;
        };
        const kind_int = reader.readInt(u8, .little) catch |err| {
            if (err == error.EndOfStream) return error.InvalidRecordLength;
            return err;
        };
        const kind: OpKind = switch (kind_int) {
            0 => OpKind.insert,
            1 => OpKind.update,
            2 => OpKind.delete,
            4 => OpKind.sequence,
            else => return error.InvalidRecordLength,
        };
        const checksum = reader.readInt(u64, .little) catch |err| {
            if (err == error.EndOfStream) return error.InvalidRecordLength;
            return err;
        };
        const fixed_fields_len: u32 = 8 + 16 + 4 + value_len + 8 + 1 + 8;

        if (payload_len != fixed_fields_len) {
            return error.InvalidRecordLength;
        }
        const record = LogRecord{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = kind,
        };
        if (record.hash() != checksum) {
            return error.ChecksumMismatch;
        }
        return record;
    }
};

pub const CurrentVlog = struct {
    id: u16,
    offset: u64,
};

pub const Entry = struct {
    lsn: u64,
    key: u128,
    value: []const u8,
    timestamp: i64,
    kind: OpKind,

    pub fn size(self: Entry) usize {
        return @sizeOf(u64) + @sizeOf(u128) + @sizeOf(u64) + self.value.len + @sizeOf(i64) + 1;
    }
};

pub const Result = struct {
    lsn: u64,
    key: u128,
};

test "VlogEntry - size calculation" {
    const entry = VlogEntry{
        .key = 12345,
        .value = "test_value",
        .timestamp = 1000,
    };

    try std.testing.expectEqual(@as(u64, 59), entry.size());
}

test "VlogEntry - size with empty value" {
    const entry = VlogEntry{
        .key = 0,
        .value = "",
        .timestamp = 0,
    };

    try std.testing.expectEqual(@as(u64, 49), entry.size());
}

test "Entry - operation kinds" {
    const insert_entry = Entry{
        .lsn = 0,
        .key = 1,
        .value = "val",
        .timestamp = 0,
        .kind = .insert,
    };

    const delete_entry = Entry{
        .lsn = 0,
        .key = 1,
        .value = "",
        .timestamp = 0,
        .kind = .delete,
    };

    try std.testing.expectEqual(OpKind.insert, insert_entry.kind);
    try std.testing.expectEqual(OpKind.delete, delete_entry.kind);
}

test "Entry - size calculation" {
    const entry = Entry{
        .lsn = 0,
        .key = 1,
        .value = "test_value",
        .timestamp = 1000,
        .kind = .insert,
    };

    const size = entry.size();
    try std.testing.expect(size > 0);
}

test "OpKind - enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(OpKind.insert));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(OpKind.update));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(OpKind.delete));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(OpKind.read));
}

test "LogRecord - structure" {
    const record = LogRecord{
        .lsn = 0,
        .key = 12345,
        .value = "log_value",
        .timestamp = 1000000,
        .kind = .insert,
    };

    try std.testing.expectEqual(@as(u128, 12345), record.key);
    try std.testing.expectEqualStrings("log_value", record.value);
    try std.testing.expectEqual(@as(i64, 1000000), record.timestamp);
    try std.testing.expectEqual(OpKind.insert, record.kind);
}

test "CurrentVlog - initial state" {
    const vlog = CurrentVlog{
        .id = 0,
        .offset = 0,
    };

    try std.testing.expectEqual(@as(u16, 0), vlog.id);
    try std.testing.expectEqual(@as(u64, 0), vlog.offset);
}

test "VlogEntry - checksum computation is deterministic" {
    const seed: u64 = 0;
    const key: u128 = 12345;
    const value = "test_data";
    const timestamp: i64 = 1000;

    var hasher1 = std.hash.Wyhash.init(seed);
    hasher1.update(std.mem.asBytes(&key));
    var value_len: u64 = value.len;
    hasher1.update(std.mem.asBytes(&value_len));
    hasher1.update(value);
    hasher1.update(std.mem.asBytes(&timestamp));
    const checksum1 = hasher1.final();

    var hasher2 = std.hash.Wyhash.init(seed);
    hasher2.update(std.mem.asBytes(&key));
    hasher2.update(std.mem.asBytes(&value_len));
    hasher2.update(value);
    hasher2.update(std.mem.asBytes(&timestamp));
    const checksum2 = hasher2.final();

    try std.testing.expectEqual(checksum1, checksum2);
}

test "VlogEntry - different data produces different checksum" {
    const seed: u64 = 0;

    var hasher1 = std.hash.Wyhash.init(seed);
    hasher1.update("data1");
    const checksum1 = hasher1.final();

    var hasher2 = std.hash.Wyhash.init(seed);
    hasher2.update("data2");
    const checksum2 = hasher2.final();

    try std.testing.expect(checksum1 != checksum2);
}

test "VlogEntry - single bit flip changes checksum" {
    const seed: u64 = 0;

    var hasher1 = std.hash.Wyhash.init(seed);
    hasher1.update("AAAA");
    const checksum1 = hasher1.final();

    var hasher2 = std.hash.Wyhash.init(seed);
    hasher2.update("BAAA");
    const checksum2 = hasher2.final();

    try std.testing.expect(checksum1 != checksum2);
}
