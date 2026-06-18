const std = @import("std");
const DocType = @import("proto").DocType;

pub const SYSTEM_CATALOG_STORE_ID: u16 = 1;

pub const SYSTEM_VLOG_FILENAME: []const u8 = "system.vlog";

pub const SYSTEM_INDEX_FILENAME: []const u8 = "system.catalog.idx";

pub const SYSTEM_USERS_STORE_ID: u16 = 2;

pub const SYSTEM_USERS_STORE_NS: []const u8 = "sysusers";

pub const SYSTEM_NS_PREFIX: []const u8 = "sys";

pub const USER_STORE_START_ID: u16 = 101;

pub fn catalogKey(doc_type: DocType, name: []const u8) u128 {
    const h64 = std.hash.Fnv1a_64.hash(name);
    const hi: u32 = @truncate(h64 ^ 0xDEAD_BEEF_CAFE_BABE);
    const rand_part: u128 = @as(u128, h64) | (@as(u128, hi) << 64);
    const rand96: u128 = rand_part & 0x0000_0000_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

    var key: u128 = rand96;
    key |= @as(u128, @intFromEnum(doc_type)) << 104;
    key |= @as(u128, SYSTEM_CATALOG_STORE_ID) << 112;
    return key;
}

test "catalogKey - same inputs produce same key" {
    const k1 = catalogKey(.Store, "orders");
    const k2 = catalogKey(.Store, "orders");
    try std.testing.expectEqual(k1, k2);
}

test "catalogKey - different names produce different keys" {
    const k1 = catalogKey(.Store, "orders");
    const k2 = catalogKey(.Store, "customers");
    try std.testing.expect(k1 != k2);
}

test "catalogKey - different doc_types produce different keys for same name" {
    const k1 = catalogKey(.Store, "orders");
    const k2 = catalogKey(.Index, "orders");
    try std.testing.expect(k1 != k2);
}

test "catalogKey - metadata bits are correctly embedded" {
    const key = catalogKey(.Store, "anything");
    const store_id: u16 = @truncate((key >> 112) & 0xFFFF);
    const doc_type: u8 = @truncate((key >> 104) & 0xFF);
    const reserved: u8 = @truncate((key >> 96) & 0xFF);

    try std.testing.expectEqual(SYSTEM_CATALOG_STORE_ID, store_id);
    try std.testing.expectEqual(@intFromEnum(DocType.Store), doc_type);
    try std.testing.expectEqual(@as(u8, 0), reserved);
}

test "catalogKey - all catalog doc types have correct type bits" {
    const types = [_]DocType{ .Store, .Index, .User, .Backup };
    for (types) |dt| {
        const key = catalogKey(dt, "test");
        const doc_type: u8 = @truncate((key >> 104) & 0xFF);
        try std.testing.expectEqual(@intFromEnum(dt), doc_type);
    }
}
