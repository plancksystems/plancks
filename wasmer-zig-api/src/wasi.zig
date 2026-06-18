const std = @import("std");
const wasm = @import("./wasm.zig");

pub const WasiError = error{
    ConfigInit,
    PreopenDirFailed,
    MapDirFailed,
    EnvInit,
    ReadStdoutFailed,
    ReadStderrFailed,
    InitializeInstanceFailed,
    GetImportsFailed,
    StartFunctionNotFound,
};

pub const WasiConfig = opaque {
    const InheritOptions = struct {
        argv: bool = true,
        env: bool = true,
        std_in: bool = true,
        std_out: bool = true,
        std_err: bool = true,
    };

    pub fn init(program_name: [:0]const u8) !*WasiConfig {
        return wasi_config_new(program_name.ptr) orelse WasiError.ConfigInit;
    }

    pub fn deinit(self: *WasiConfig) void {
        _ = self;
        @compileError("not implemented in wasmer");
    }

    pub fn inherit(self: *WasiConfig, options: InheritOptions) void {
        if (options.argv) self.inheritArgv();
        if (options.env) self.inheritEnv();
        if (options.std_in) self.inheritStdIn();
        if (options.std_out) self.inheritStdOut();
        if (options.std_err) self.inheritStdErr();
    }

    pub fn inheritArgv(self: *WasiConfig) void {
        wasi_config_inherit_argv(self);
    }

    pub fn inheritEnv(self: *WasiConfig) void {
        wasi_config_inherit_env(self);
    }

    pub fn inheritStdIn(self: *WasiConfig) void {
        wasi_config_inherit_stdin(self);
    }

    pub fn inheritStdOut(self: *WasiConfig) void {
        wasi_config_inherit_stdout(self);
    }

    pub fn inheritStdErr(self: *WasiConfig) void {
        wasi_config_inherit_stderr(self);
    }

    pub fn setArg(self: *WasiConfig, arg: []const u8) void {
        wasi_config_arg(self, arg.ptr);
    }

    pub fn setEnv(self: *WasiConfig, key: []const u8, value: []const u8) void {
        wasi_config_env(self, key.ptr, value.ptr);
    }

    pub fn preopenDir(self: *WasiConfig, dir: []const u8) !void {
        if (!wasi_config_preopen_dir(self, dir.ptr)) {
            return WasiError.PreopenDirFailed;
        }
    }

    pub fn mapDir(self: *WasiConfig, alias: []const u8, dir: []const u8) !void {
        if (!wasi_config_mapdir(self, alias.ptr, dir.ptr)) {
            return WasiError.MapDirFailed;
        }
    }

    pub fn captureStdout(self: *WasiConfig) void {
        wasi_config_capture_stdout(self);
    }

    pub fn captureStderr(self: *WasiConfig) void {
        wasi_config_capture_stderr(self);
    }

    extern "c" fn wasi_config_new([*:0]const u8) ?*WasiConfig;
    extern "c" fn wasi_config_delete(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_argv(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_env(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_stdin(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_stdout(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_stderr(?*WasiConfig) void;
    extern "c" fn wasi_config_arg(?*WasiConfig, [*]const u8) void;
    extern "c" fn wasi_config_env(?*WasiConfig, [*]const u8, [*]const u8) void;
    extern "c" fn wasi_config_preopen_dir(?*WasiConfig, [*]const u8) bool;
    extern "c" fn wasi_config_mapdir(?*WasiConfig, [*]const u8, [*]const u8) bool;
    extern "c" fn wasi_config_capture_stdout(?*WasiConfig) void;
    extern "c" fn wasi_config_capture_stderr(?*WasiConfig) void;
};

pub const WasiEnv = opaque {
    pub fn init(store: *wasm.Store, config: *WasiConfig) !*WasiEnv {
        return wasi_env_new(store, config) orelse WasiError.EnvInit;
    }

    pub fn deinit(self: *WasiEnv) void {
        wasi_env_delete(self);
    }

    pub fn readStdout(self: *WasiEnv, buffer: []u8) !usize {
        const result = wasi_env_read_stdout(self, buffer.ptr, buffer.len);
        return if (result >= 0) @as(usize, @intCast(result)) else WasiError.ReadStdoutFailed;
    }

    pub fn readStderr(self: *WasiEnv, buffer: []u8) !usize {
        const result = wasi_env_read_stderr(self, buffer.ptr, buffer.len);
        return if (result >= 0) @as(usize, @intCast(result)) else WasiError.ReadStderrFailed;
    }

    pub fn initializeInstance(self: *WasiEnv, store: *wasm.Store, instance: *wasm.Instance) !void {
        if (!wasi_env_initialize_instance(self, store, instance)) {
            return WasiError.InitializeInstanceFailed;
        }
    }

    extern "c" fn wasi_env_new(?*wasm.Store, ?*WasiConfig) ?*WasiEnv;
    extern "c" fn wasi_env_delete(?*WasiEnv) void;
    extern "c" fn wasi_env_read_stdout(?*WasiEnv, [*]u8, usize) isize;
    extern "c" fn wasi_env_read_stderr(?*WasiEnv, [*]u8, usize) isize;
    extern "c" fn wasi_env_initialize_instance(?*WasiEnv, ?*wasm.Store, ?*wasm.Instance) bool;
};

pub const WasiVersion = enum(c_int) {
    InvalidVersion = -1,
    Latest = 0,
    Snapshot0 = 1,
    Snapshot1 = 2,
    Wasix32v1 = 3,
    Wasix64v1 = 4,
};

pub fn getWasiVersion(module: *wasm.Module) WasiVersion {
    return @enumFromInt(wasi_get_wasi_version(module));
}

pub fn getImports(store: *wasm.Store, wasi_env: *WasiEnv, module: *wasm.Module) !wasm.ExternVec {
    var imports = wasm.ExternVec.empty();
    if (!wasi_get_imports(store, wasi_env, module, &imports)) {
        return WasiError.GetImportsFailed;
    }
    return imports;
}

pub fn getStartFunction(instance: *wasm.Instance) !*wasm.Func {
    return wasi_get_start_function(instance) orelse WasiError.StartFunctionNotFound;
}

extern "c" fn wasi_get_wasi_version(?*wasm.Module) c_int;
extern "c" fn wasi_get_imports(?*wasm.Store, ?*WasiEnv, ?*wasm.Module, ?*wasm.ExternVec) bool;
extern "c" fn wasi_get_start_function(?*wasm.Instance) ?*wasm.Func;
