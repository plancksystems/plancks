const std = @import("std");
const builtin = @import("builtin");
pub const wasm = @import("./wasm.zig");

pub const wasi = @import("./wasi.zig");
pub const WasiError = wasi.WasiError;
pub const WasiConfig = wasi.WasiConfig;
pub const WasiEnv = wasi.WasiEnv;
pub const WasiVersion = wasi.WasiVersion;
pub const getWasiVersion = wasi.getWasiVersion;
pub const getImports = wasi.getImports;
pub const getStartFunction = wasi.getStartFunction;

pub const ExternVec = wasm.ExternVec;
pub const ByteVec = wasm.ByteVec;
pub const Engine = wasm.Engine;
pub const Config = wasm.Config;
pub const Middleware = wasm.Middleware;
pub const Metering = wasm.Metering;
pub const Store = wasm.Store;
pub const Module = wasm.Module;
pub const Instance = wasm.Instance;
pub const Extern = wasm.Extern;
pub const Func = wasm.Func;
pub const Memory = wasm.Memory;
pub const MemoryType = wasm.MemoryType;
pub const Limits = wasm.Limits;
pub const LIMITS_MAX_DEFAULT = wasm.LIMITS_MAX_DEFAULT;

pub fn detectWasmerLibDir(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "wasmer", "config", "--libdir" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stderr.len != 0) return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    return try allocator.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\r\n"));
}

pub fn setupTracing(verbosity_level: usize, use_colors: usize) void {
    wasmer_setup_tracing(@as(c_int, @intCast(verbosity_level)), @as(c_int, @intCast(use_colors)));
}

pub extern "c" fn wasmer_setup_tracing(c_int, c_int) void;

pub fn lastError(allocator: std.mem.Allocator) ![:0]u8 {
    const buf_len = @as(usize, @intCast(wasmer_last_error_length()));
    const buf = try allocator.alloc(u8, buf_len);
    _ = wasmer_last_error_message(buf.ptr, @as(c_int, @intCast(buf_len)));
    return buf[0 .. buf_len - 1 :0];
}

pub extern "c" fn wasmer_last_error_length() c_int;
pub extern "c" fn wasmer_last_error_message([*]const u8, c_int) c_int;

pub fn watToWasm(wat: []const u8) !ByteVec {
    var wat_bytes = ByteVec.fromSlice(wat);
    defer wat_bytes.deinit();

    var wasm_bytes: ByteVec = undefined;
    wat2wasm(&wat_bytes, &wasm_bytes);

    if (wasm_bytes.size == 0) return error.WatParse;

    return wasm_bytes;
}

extern "c" fn wat2wasm(*const wasm.ByteVec, *wasm.ByteVec) void;

test "detect wasmer lib directory" {
    const result = try detectWasmerLibDir(std.testing.allocator, std.testing.io) orelse "";
    defer std.testing.allocator.free(result);

    try std.testing.expectStringEndsWith(result, ".wasmer/lib");
}

test "transform WAT to WASM" {
    const wat =
        \\(module
        \\  (type $add_one_t (func (param i32) (result i32)))
        \\  (func $add_one_f (type $add_one_t) (param $value i32) (result i32)
        \\    local.get $value
        \\    i32.const 1
        \\    i32.add)
        \\  (export "add_one" (func $add_one_f)))
    ;

    var wasm_bytes = try watToWasm(wat);

    try std.testing.expectEqual(91, wasm_bytes.size);

    defer wasm_bytes.deinit();
}
