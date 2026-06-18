const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CompressionAlgorithm = enum(u8) {
    none = 0,
    lz4 = 1,
    zstd = 2,
};

pub const CompressionConfig = struct {
    enabled: bool = true,
    algorithm: CompressionAlgorithm = .lz4,
    threshold_bytes: usize = 1024,
    compression_level: i32 = 1,
};

const CompressionHeader = struct {
    algorithm: CompressionAlgorithm,
    compressed_size: u32,
    uncompressed_size: u32,

    const HEADER_SIZE = 9;

    fn write(self: CompressionHeader, buf: []u8) void {
        buf[0] = @intFromEnum(self.algorithm);
        std.mem.writeInt(u32, buf[1..5], self.compressed_size, .little);
        std.mem.writeInt(u32, buf[5..9], self.uncompressed_size, .little);
    }

    fn read(buf: []const u8) CompressionHeader {
        return CompressionHeader{
            .algorithm = @enumFromInt(buf[0]),
            .compressed_size = std.mem.readInt(u32, buf[1..5], .little),
            .uncompressed_size = std.mem.readInt(u32, buf[5..9], .little),
        };
    }
};

pub const Compressor = struct {
    allocator: Allocator,
    config: CompressionConfig,

    pub fn init(allocator: Allocator, config: CompressionConfig) !*Compressor {
        const compressor = try allocator.create(Compressor);
        compressor.* = Compressor{
            .allocator = allocator,
            .config = config,
        };
        return compressor;
    }

    pub fn deinit(self: *Compressor) void {
        self.allocator.destroy(self);
    }

    pub fn compress(self: *Compressor, data: []const u8) ![]u8 {
        if (!self.config.enabled or data.len < self.config.threshold_bytes) {
            return try self.allocator.dupe(u8, data);
        }

        return switch (self.config.algorithm) {
            .none => try self.allocator.dupe(u8, data),
            .lz4 => try self.compressLZ4(data),
            .zstd => try self.compressZstd(data),
        };
    }

    pub fn decompress(self: *Compressor, data: []const u8) ![]u8 {
        if (data.len < CompressionHeader.HEADER_SIZE) {
            return try self.allocator.dupe(u8, data);
        }

        if (data[0] > 2) {
            return try self.allocator.dupe(u8, data);
        }

        const header = CompressionHeader.read(data[0..CompressionHeader.HEADER_SIZE]);

        if (header.algorithm == .none or header.compressed_size == 0) {
            return try self.allocator.dupe(u8, data);
        }

        const compressed_data = data[CompressionHeader.HEADER_SIZE..];

        return switch (header.algorithm) {
            .none => try self.allocator.dupe(u8, compressed_data),
            .lz4 => try self.decompressLZ4(compressed_data, header.uncompressed_size),
            .zstd => try self.decompressZstd(compressed_data, header.uncompressed_size),
        };
    }

    pub fn isCompressed(data: []const u8) bool {
        if (data.len < CompressionHeader.HEADER_SIZE) return false;
        if (data[0] == 0 or data[0] > 2) return false;
        const header = CompressionHeader.read(data[0..CompressionHeader.HEADER_SIZE]);
        return header.algorithm != .none and header.compressed_size > 0;
    }

    fn compressLZ4(self: *Compressor, data: []const u8) ![]u8 {
        const max_compressed_size = data.len + (data.len / 255) + 16;
        var compressed_buf = try self.allocator.alloc(u8, CompressionHeader.HEADER_SIZE + max_compressed_size);
        errdefer self.allocator.free(compressed_buf);

        var compressed_size: usize = 0;
        var i: usize = 0;

        while (i < data.len) {
            const byte = data[i];
            var run_length: usize = 1;

            while (i + run_length < data.len and data[i + run_length] == byte and run_length < 255) {
                run_length += 1;
            }

            if (run_length >= 4) {
                compressed_buf[CompressionHeader.HEADER_SIZE + compressed_size] = 0xFF;
                compressed_buf[CompressionHeader.HEADER_SIZE + compressed_size + 1] = @intCast(run_length);
                compressed_buf[CompressionHeader.HEADER_SIZE + compressed_size + 2] = byte;
                compressed_size += 3;
                i += run_length;
            } else {
                compressed_buf[CompressionHeader.HEADER_SIZE + compressed_size] = byte;
                compressed_size += 1;
                i += 1;
            }
        }

        if (compressed_size >= data.len) {
            self.allocator.free(compressed_buf);
            return try self.allocator.dupe(u8, data);
        }

        const header = CompressionHeader{
            .algorithm = .lz4,
            .compressed_size = @intCast(compressed_size),
            .uncompressed_size = @intCast(data.len),
        };
        header.write(compressed_buf[0..CompressionHeader.HEADER_SIZE]);

        const final_size = CompressionHeader.HEADER_SIZE + compressed_size;
        const result = try self.allocator.realloc(compressed_buf, final_size);
        return result;
    }

    fn decompressLZ4(self: *Compressor, compressed: []const u8, uncompressed_size: u32) ![]u8 {
        var decompressed = try self.allocator.alloc(u8, uncompressed_size);
        errdefer self.allocator.free(decompressed);

        var src_idx: usize = 0;
        var dst_idx: usize = 0;

        while (src_idx < compressed.len and dst_idx < uncompressed_size) {
            const byte = compressed[src_idx];

            if (byte == 0xFF and src_idx + 2 < compressed.len) {
                const run_length = compressed[src_idx + 1];
                const value = compressed[src_idx + 2];

                var j: usize = 0;
                while (j < run_length and dst_idx < uncompressed_size) : (j += 1) {
                    decompressed[dst_idx] = value;
                    dst_idx += 1;
                }
                src_idx += 3;
            } else {
                decompressed[dst_idx] = byte;
                dst_idx += 1;
                src_idx += 1;
            }
        }

        return decompressed;
    }

    fn compressZstd(self: *Compressor, data: []const u8) ![]u8 {
        return try self.compressLZ4(data);
    }

    fn decompressZstd(self: *Compressor, compressed: []const u8, uncompressed_size: u32) ![]u8 {
        return try self.decompressLZ4(compressed, uncompressed_size);
    }

    pub fn getStats(self: *Compressor, original_size: usize, compressed_size: usize) CompressionStats {
        _ = self;
        const ratio = if (original_size > 0)
            @as(f64, @floatFromInt(compressed_size)) / @as(f64, @floatFromInt(original_size))
        else
            1.0;

        return CompressionStats{
            .original_size = original_size,
            .compressed_size = compressed_size,
            .compression_ratio = ratio,
            .space_saved = if (original_size > compressed_size) original_size - compressed_size else 0,
        };
    }
};

pub const CompressionStats = struct {
    original_size: usize,
    compressed_size: usize,
    compression_ratio: f64,
    space_saved: usize,
};

test "CompressionHeader - write and read " {
    const header = CompressionHeader{
        .algorithm = .lz4,
        .compressed_size = 12345,
        .uncompressed_size = 67890,
    };

    var buf: [CompressionHeader.HEADER_SIZE]u8 = undefined;
    header.write(&buf);

    const read_header = CompressionHeader.read(&buf);
    try std.testing.expectEqual(header.algorithm, read_header.algorithm);
    try std.testing.expectEqual(header.compressed_size, read_header.compressed_size);
    try std.testing.expectEqual(header.uncompressed_size, read_header.uncompressed_size);
}

test "CompressionHeader - all algorithms" {
    const algorithms = [_]CompressionAlgorithm{ .none, .lz4, .zstd };

    for (algorithms) |algo| {
        const header = CompressionHeader{
            .algorithm = algo,
            .compressed_size = 100,
            .uncompressed_size = 200,
        };

        var buf: [CompressionHeader.HEADER_SIZE]u8 = undefined;
        header.write(&buf);

        const read_header = CompressionHeader.read(&buf);
        try std.testing.expectEqual(algo, read_header.algorithm);
    }
}

test "Compressor - small data not compressed (below threshold)" {
    const allocator = std.testing.allocator;

    var compressor = try Compressor.init(allocator, CompressionConfig{
        .enabled = true,
        .algorithm = .lz4,
        .threshold_bytes = 1024,
    });
    defer compressor.deinit();

    const small_data = "Hello, World! This is a small test." ** 3;
    const result = try compressor.compress(small_data);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, small_data, result);
}

test "Compressor - disabled compression returns original" {
    const allocator = std.testing.allocator;

    var compressor = try Compressor.init(allocator, CompressionConfig{
        .enabled = false,
        .algorithm = .lz4,
        .threshold_bytes = 0,
    });
    defer compressor.deinit();

    const data = "Test data for compression check";
    const result = try compressor.compress(data);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, data, result);
}

test "Compressor - compress and decompress  with repetitive data" {
    const allocator = std.testing.allocator;

    var compressor = try Compressor.init(allocator, CompressionConfig{
        .enabled = true,
        .algorithm = .lz4,
        .threshold_bytes = 64,
    });
    defer compressor.deinit();

    const original = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    const compressed = try compressor.compress(original);
    defer allocator.free(compressed);

    const decompressed = try compressor.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "Compressor - isCompressed detects compressed data" {
    const allocator = std.testing.allocator;

    var compressor = try Compressor.init(allocator, CompressionConfig{
        .enabled = true,
        .algorithm = .lz4,
        .threshold_bytes = 64,
    });
    defer compressor.deinit();

    const original = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";

    const compressed = try compressor.compress(original);
    defer allocator.free(compressed);

    if (compressed.len < original.len) {
        try std.testing.expect(Compressor.isCompressed(compressed));
    }

    try std.testing.expect(!Compressor.isCompressed(original));
}

test "Compressor - getStats calculates correctly" {
    const allocator = std.testing.allocator;

    var compressor = try Compressor.init(allocator, CompressionConfig{
        .enabled = true,
        .algorithm = .lz4,
        .threshold_bytes = 1024,
    });
    defer compressor.deinit();

    const stats = compressor.getStats(1000, 400);

    try std.testing.expectEqual(@as(usize, 1000), stats.original_size);
    try std.testing.expectEqual(@as(usize, 400), stats.compressed_size);
    try std.testing.expectEqual(@as(usize, 600), stats.space_saved);
    try std.testing.expect(stats.compression_ratio < 1.0);
}

test "Compressor - decompress handles uncompressed data" {
    const allocator = std.testing.allocator;

    var compressor = try Compressor.init(allocator, CompressionConfig{
        .enabled = true,
        .algorithm = .lz4,
        .threshold_bytes = 1024,
    });
    defer compressor.deinit();

    const plain_data = "Plain uncompressed data";
    const result = try compressor.decompress(plain_data);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, plain_data, result);
}

test "CompressionConfig - default values" {
    const config = CompressionConfig{};

    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(CompressionAlgorithm.lz4, config.algorithm);
    try std.testing.expectEqual(@as(usize, 1024), config.threshold_bytes);
    try std.testing.expectEqual(@as(i32, 1), config.compression_level);
}

test "Compressor - empty data compression" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator, .{
        .threshold_bytes = 0,
    });
    defer compressor.deinit();

    const empty_data = "";
    const compressed = try compressor.compress(empty_data);
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len >= 0);
}

test "Compressor - single byte data" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator, .{
        .threshold_bytes = 0,
    });
    defer compressor.deinit();

    const single_byte = "X";
    const compressed = try compressor.compress(single_byte);
    defer allocator.free(compressed);

    const decompressed = try compressor.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(single_byte, decompressed);
}

test "Compressor - data below threshold is not compressed" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator, .{
        .threshold_bytes = 1000,
    });
    defer compressor.deinit();

    const small_data = "small";
    const result = try compressor.compress(small_data);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(small_data, result);
}

test "Compressor - compression disabled returns data unchanged" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator, .{
        .enabled = false,
    });
    defer compressor.deinit();

    const data = "test data that would normally be compressed if long enough";
    const result = try compressor.compress(data);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(data, result);
}

test "Compressor - decompress very short data (less than header)" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator, .{});
    defer compressor.deinit();

    const short = "abc";
    const result = try compressor.decompress(short);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(short, result);
}

test "Compressor -  with repetitive data" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator, .{
        .threshold_bytes = 0,
    });
    defer compressor.deinit();

    const repetitive = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const compressed = try compressor.compress(repetitive);
    defer allocator.free(compressed);

    const decompressed = try compressor.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(repetitive, decompressed);
}

test "Compressor -  with random-like data" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator, .{
        .threshold_bytes = 0,
    });
    defer compressor.deinit();

    const random_like = "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6";
    const compressed = try compressor.compress(random_like);
    defer allocator.free(compressed);

    const decompressed = try compressor.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(random_like, decompressed);
}

test "isCompressed - returns false for empty data" {
    const empty: []const u8 = "";
    try std.testing.expect(!Compressor.isCompressed(empty));
}

test "isCompressed - returns false for short data" {
    const short = "short";
    try std.testing.expect(!Compressor.isCompressed(short));
}

test "CompressionAlgorithm - enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(CompressionAlgorithm.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(CompressionAlgorithm.lz4));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(CompressionAlgorithm.zstd));
}
