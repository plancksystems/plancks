const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

var last_nanos: u80 = 0;
var counter: u16 = 0;
var time_mutex: Io.Mutex = Io.Mutex.init;

fn nextTimeKey(io: Io) u96 {
    time_mutex.lockUncancelable(io);
    defer time_mutex.unlock(io);

    const ts = Io.Clock.now(.real, io);
    const ns: u80 = @intCast(@as(u96, @bitCast(ts.toNanoseconds())));
    if (ns == last_nanos) {
        counter +%= 1;
    } else {
        last_nanos = ns;
        counter = 0;
    }
    return (@as(u96, ns) << 16) | @as(u96, counter);
}

pub const KeyGen = struct {
    pub fn init() KeyGen {
        return KeyGen{};
    }

    pub fn Gen(self: *KeyGen, store_id: u16, vlog_id: u8, doc_type: u8, io: Io) !u128 {
        _ = self;

        const time_part: u128 = nextTimeKey(io);

        var key: u128 = time_part;
        key |= (@as(u128, vlog_id) << 96);
        key |= (@as(u128, doc_type) << 104);
        key |= (@as(u128, store_id) << 112);

        return key;
    }

    pub const KeyMetaData = struct {
        store_id: u16,
        vlog_id: u8,
        doc_type: u8,
    };

    pub const KeyRange = struct {
        min: u128,
        max: u128,
    };

    pub fn storeKeyRange(store_id: u16) KeyRange {
        const min = @as(u128, store_id) << 112;
        const max = min | ((@as(u128, 1) << 112) - 1);
        return .{ .min = min, .max = max };
    }

    pub fn extractMetadata(key: u128) KeyMetaData {
        const store_id: u16 = @truncate((key >> 112) & 0xFFFF);
        const doc_type: u8 = @truncate((key >> 104) & 0xFF);
        const vlog_id: u8 = @truncate((key >> 96) & 0xFF);

        return KeyMetaData{
            .store_id = store_id,
            .vlog_id = vlog_id,
            .doc_type = doc_type,
        };
    }
};

test "KeyGen - generates unique keys" {
    var keygen = KeyGen.init();
    const key1 = try keygen.Gen(1, 0, 4, std.testing.io);
    const key2 = try keygen.Gen(1, 0, 4, std.testing.io);
    const key3 = try keygen.Gen(1, 0, 4, std.testing.io);

    try std.testing.expect(key1 != key2);
    try std.testing.expect(key2 != key3);
    try std.testing.expect(key1 != key3);
}

test "KeyGen - metadata encoding and decoding" {
    var keygen = KeyGen.init();

    const test_cases = [_]struct { store_id: u16, vlog_id: u8, doc_type: u8 }{
        .{ .store_id = 0, .vlog_id = 0, .doc_type = 0 },
        .{ .store_id = 1, .vlog_id = 1, .doc_type = 4 },
        .{ .store_id = 100, .vlog_id = 50, .doc_type = 3 },
        .{ .store_id = 65535, .vlog_id = 255, .doc_type = 255 },
        .{ .store_id = 12345, .vlog_id = 128, .doc_type = 1 },
    };

    for (test_cases) |tc| {
        const key = try keygen.Gen(tc.store_id, tc.vlog_id, tc.doc_type, std.testing.io);
        const meta = KeyGen.extractMetadata(key);

        try std.testing.expectEqual(tc.store_id, meta.store_id);
        try std.testing.expectEqual(tc.vlog_id, meta.vlog_id);
        try std.testing.expectEqual(tc.doc_type, meta.doc_type);
    }
}

test "KeyGen - store_id is most significant (keys sort by store)" {
    var keygen = KeyGen.init();

    const key_store_1 = try keygen.Gen(1, 0, 4, std.testing.io);
    const key_store_2 = try keygen.Gen(2, 0, 4, std.testing.io);
    const key_store_10 = try keygen.Gen(10, 0, 4, std.testing.io);
    const key_store_100 = try keygen.Gen(100, 0, 4, std.testing.io);

    try std.testing.expect(key_store_1 < key_store_2);
    try std.testing.expect(key_store_2 < key_store_10);
    try std.testing.expect(key_store_10 < key_store_100);
}

test "KeyGen - doc_type affects sorting within store" {
    var keygen = KeyGen.init();

    const key_type_1 = try keygen.Gen(5, 0, 1, std.testing.io);
    const key_type_4 = try keygen.Gen(5, 0, 4, std.testing.io);

    const meta1 = KeyGen.extractMetadata(key_type_1);
    const meta4 = KeyGen.extractMetadata(key_type_4);

    try std.testing.expectEqual(@as(u8, 1), meta1.doc_type);
    try std.testing.expectEqual(@as(u8, 4), meta4.doc_type);

    try std.testing.expectEqual(meta1.store_id, meta4.store_id);
}

test "KeyGen - extract metadata from known key" {
    const store_id: u128 = 0x1234;
    const doc_type: u128 = 0x56;
    const vlog_id: u128 = 0x78;
    const random_part: u128 = 0x123456789ABC;

    const key: u128 = random_part |
        (vlog_id << 96) |
        (doc_type << 104) |
        (store_id << 112);

    const meta = KeyGen.extractMetadata(key);

    try std.testing.expectEqual(@as(u16, 0x1234), meta.store_id);
    try std.testing.expectEqual(@as(u8, 0x56), meta.doc_type);
    try std.testing.expectEqual(@as(u8, 0x78), meta.vlog_id);
}

test "KeyGen - zero values for all metadata fields" {
    var keygen = KeyGen.init();
    const key = try keygen.Gen(0, 0, 0, std.testing.io);
    const meta = KeyGen.extractMetadata(key);

    try std.testing.expectEqual(@as(u16, 0), meta.store_id);
    try std.testing.expectEqual(@as(u8, 0), meta.vlog_id);
    try std.testing.expectEqual(@as(u8, 0), meta.doc_type);
}

test "KeyGen - max values for all metadata fields" {
    var keygen = KeyGen.init();
    const key = try keygen.Gen(65535, 255, 255, std.testing.io);
    const meta = KeyGen.extractMetadata(key);

    try std.testing.expectEqual(@as(u16, 65535), meta.store_id);
    try std.testing.expectEqual(@as(u8, 255), meta.vlog_id);
    try std.testing.expectEqual(@as(u8, 255), meta.doc_type);
}

test "KeyGen - extract metadata from zero key" {
    const meta = KeyGen.extractMetadata(0);

    try std.testing.expectEqual(@as(u16, 0), meta.store_id);
    try std.testing.expectEqual(@as(u8, 0), meta.vlog_id);
    try std.testing.expectEqual(@as(u8, 0), meta.doc_type);
}

test "KeyGen - extract metadata from max key" {
    const max_key: u128 = std.math.maxInt(u128);
    const meta = KeyGen.extractMetadata(max_key);

    try std.testing.expectEqual(@as(u16, 65535), meta.store_id);
    try std.testing.expectEqual(@as(u8, 255), meta.vlog_id);
    try std.testing.expectEqual(@as(u8, 255), meta.doc_type);
}

test "KeyGen - many sequential keys are unique" {
    var keygen = KeyGen.init();
    var keys: [100]u128 = undefined;

    for (&keys) |*k| {
        k.* = try keygen.Gen(1, 0, 4, std.testing.io);
    }

    for (keys, 0..) |key1, i| {
        for (keys[i + 1 ..]) |key2| {
            try std.testing.expect(key1 != key2);
        }
    }
}

test "KeyGen - keys with same store cluster together" {
    var keygen = KeyGen.init();

    var store1_keys: [10]u128 = undefined;
    var store2_keys: [10]u128 = undefined;

    for (&store1_keys) |*k| {
        k.* = try keygen.Gen(1, 0, 4, std.testing.io);
    }
    for (&store2_keys) |*k| {
        k.* = try keygen.Gen(2, 0, 4, std.testing.io);
    }

    for (store1_keys) |k1| {
        for (store2_keys) |k2| {
            try std.testing.expect(k1 < k2);
        }
    }
}

