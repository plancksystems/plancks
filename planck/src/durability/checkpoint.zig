const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const Dir = Io.Dir;

pub const CheckpointRecord = struct {
    file_seq: u64,
    last_flushed_lsn: u64 = 0,
    const CHECKPOINT_FILENAME = "CHECKPOINT";

    pub fn load(allocator: mem.Allocator, io: Io, dir_path: []const u8) !CheckpointRecord {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const checkpoint_path = fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, CHECKPOINT_FILENAME }) catch return CheckpointRecord{ .file_seq = 0, .last_flushed_lsn = 0 };
        const data = Dir.readFileAlloc(.cwd(), io, checkpoint_path, allocator, @enumFromInt(100)) catch |err| {
            if (err == error.FileNotFound) return CheckpointRecord{ .file_seq = 0, .last_flushed_lsn = 0 };
            return err;
        };
        defer allocator.free(data);
        const gpa = std.heap.page_allocator;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const parsed = try std.json.parseFromSlice(CheckpointRecord, arena.allocator(), data, .{});
        return parsed.value;
    }

    pub fn save(self: CheckpointRecord, io: Io, dir_path: []const u8) !void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try fmt.bufPrint(&path_buf, "{s}/CHECKPOINT.tmp", .{dir_path});

        var buf: [128]u8 = undefined;
        const data = try fmt.bufPrint(&buf, "{{\"file_seq\":{}, \"last_flushed_lsn\":{}}}", .{ self.file_seq, self.last_flushed_lsn });

        var file = try Dir.createFile(.cwd(), io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, data);
        try file.sync(io);

        var final_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const final_path = try fmt.bufPrint(&final_path_buf, "{s}/{s}", .{ dir_path, CHECKPOINT_FILENAME });
        try Dir.rename(.cwd(), tmp_path, .cwd(), final_path, io);
    }
};
