const std = @import("std");
const testing = std.testing;
const meta = std.meta;

const log = std.log.scoped(.wasm_zig);

const c_callconv = std.builtin.CallingConvention.c;

var CALLBACK: usize = undefined;

pub const Error = error{
    ConfigInit,
    EngineInit,
    StoreInit,
    ModuleInit,
    FuncInit,
    InstanceInit,
};

pub const Config = opaque {
    pub fn init() !*Config {
        const config = wasm_config_new() orelse return Error.ConfigInit;
        return config;
    }

    extern "c" fn wasm_config_new() ?*Config;
};

pub const Engine = opaque {
    pub fn init() !*Engine {
        return wasm_engine_new() orelse Error.EngineInit;
    }

    pub fn withConfig(config: *Config) !*Engine {
        return wasm_engine_new_with_config(config) orelse Error.EngineInit;
    }

    pub fn deinit(self: *Engine) void {
        wasm_engine_delete(self);
    }

    extern "c" fn wasm_engine_new() ?*Engine;
    extern "c" fn wasm_engine_new_with_config(*Config) ?*Engine;
    extern "c" fn wasm_engine_delete(*Engine) void;
};

pub const Store = opaque {
    pub fn init(engine: *Engine) !*Store {
        return wasm_store_new(engine) orelse Error.StoreInit;
    }

    pub fn deinit(self: *Store) void {
        wasm_store_delete(self);
    }

    extern "c" fn wasm_store_new(*Engine) ?*Store;
    extern "c" fn wasm_store_delete(*Store) void;
};

pub const Module = opaque {
    pub fn init(store: *Store, bytes: []const u8) !*Module {
        var byte_vec = ByteVec.initWithCapacity(bytes.len);
        defer byte_vec.deinit();

        var ptr = byte_vec.data;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            ptr[i] = bytes[i];
        }

        return wasm_module_new(store, &byte_vec) orelse return Error.ModuleInit;
    }

    pub fn deinit(self: *Module) void {
        wasm_module_delete(self);
    }

    pub fn exports(self: *Module) ExportTypeVec {
        var vec: ExportTypeVec = undefined;
        wasm_module_exports(self, &vec);
        return vec;
    }

    pub fn imports(self: *Module) ImportTypeVec {
        var vec: ImportTypeVec = undefined;
        wasm_module_imports(self, &vec);
        return vec;
    }

    extern "c" fn wasm_module_new(*Store, *const ByteVec) ?*Module;
    extern "c" fn wasm_module_delete(*Module) void;
    extern "c" fn wasm_module_exports(?*const Module, *ExportTypeVec) void;
    extern "c" fn wasm_module_imports(?*const Module, *ImportTypeVec) void;
};

fn cb(params: ?*const Valtype, results: ?*Valtype) callconv(c_callconv) ?*Trap {
    _ = params;
    _ = results;
    const func = @as(*const fn () void, @ptrFromInt(CALLBACK));
    func();
    return null;
}

pub const Func = opaque {
    pub const CallError = error{
        InnerError,
        InvalidResultType,
        InvalidParamCount,
        InvalidResultCount,
        Trap,
    };
    pub fn init(store: *Store, callback: anytype) !*Func {
        const cb_meta = @typeInfo(@TypeOf(callback));
        switch (cb_meta) {
            .@"fn" => {
                if (cb_meta.@"fn".params.len > 0 or cb_meta.@"fn".return_type.? != void) {
                    @compileError("only callbacks with no input args and no results are currently supported");
                }
            },
            else => @compileError("only functions can be used as callbacks into Wasm"),
        }

        const func_ptr: *const fn () void = @ptrCast(&callback);

        CALLBACK = @intFromPtr(func_ptr);

        var args = ValtypeVec.empty();
        var results = ValtypeVec.empty();

        const functype = wasm_functype_new(&args, &results) orelse return Error.FuncInit;
        defer wasm_functype_delete(functype);

        return wasm_func_new(store, functype, cb) orelse Error.FuncInit;
    }

    pub fn asExtern(self: *Func) *Extern {
        return wasm_func_as_extern(self).?;
    }

    pub fn fromExtern(extern_func: *Extern) ?*Func {
        return extern_func.asFunc();
    }

    pub fn copy(self: *Func) *Func {
        return self.wasm_func_copy().?;
    }











    pub fn call(self: *Func, comptime ResultType: type, args: anytype) CallError!ResultType {
        if (!comptime @typeInfo(@TypeOf(args)).@"struct".is_tuple)
            @compileError("Expected 'args' to be a tuple, but found type '" ++ @typeName(@TypeOf(args)) ++ "'");

        const args_len = args.len;
        var wasm_args: [args_len]Value = undefined;

        inline for (&wasm_args, 0..) |*arg, i| {
            arg.* = switch (@TypeOf(args[i])) {
                i32, u32 => .{ .kind = .i32, .of = .{ .i32 = @as(i32, @bitCast(args[i])) } },
                i64, u64 => .{ .kind = .i64, .of = .{ .i64 = @as(i64, @bitCast(args[i])) } },
                f32 => .{ .kind = .f32, .of = .{ .f32 = args[i] } },
                f64 => .{ .kind = .f64, .of = .{ .f64 = args[i] } },
                *Func => .{ .kind = .funcref, .of = .{ .ref = args[i] } },
                *Extern => .{ .kind = .anyref, .of = .{ .ref = args[i] } },
                else => |ty| @compileError("Unsupported argument type '" ++ @typeName(ty) ++ "'"),
            };
        }

        const result_len: usize = if (ResultType == void) 0 else 1;
        if (result_len != wasm_func_result_arity(self)) return CallError.InvalidResultCount;
        if (args_len != wasm_func_param_arity(self)) return CallError.InvalidParamCount;

        const final_args = ValVec{
            .size = args_len,
            .data = if (args_len == 0) undefined else &wasm_args,
        };

        var result_list = ValVec.initWithCapacity(result_len);
        defer result_list.deinit();

        const trap = wasm_func_call(self, &final_args, &result_list);

        if (trap) |t| {
            t.deinit();
            log.err("code unexpectedly trapped", .{});
            return CallError.Trap;
        }

        if (ResultType == void) return;

        const result_ty = result_list.data[0];
        if (!matchesKind(ResultType, result_ty.kind)) return CallError.InvalidResultType;

        return switch (ResultType) {
            i32, u32 => @as(ResultType, @intCast(result_ty.of.i32)),
            i64, u64 => @as(ResultType, @intCast(result_ty.of.i64)),
            f32 => result_ty.of.f32,
            f64 => result_ty.of.f64,
            *Func => @as(?*Func, @ptrCast(result_ty.of.ref)).?,
            *Extern => @as(?*Extern, @ptrCast(result_ty.of.ref)).?,
            else => |ty| @compileError("Unsupported result type '" ++ @typeName(ty) ++ "'"),
        };
    }

    pub fn deinit(self: *Func) void {
        wasm_func_delete(self);
    }

    pub fn matchesKind(comptime T: type, kind: Valkind) bool {
        return switch (T) {
            i32, u32 => kind == .i32,
            i64, u64 => kind == .i64,
            f32 => kind == .f32,
            f64 => kind == .f64,
            *Func => kind == .funcref,
            *Extern => kind == .ref,
            else => false,
        };
    }

    extern "c" fn wasm_func_new(*Store, ?*anyopaque, *const Callback) ?*Func;
    extern "c" fn wasm_func_delete(*Func) void;
    extern "c" fn wasm_func_as_extern(*Func) ?*Extern;
    extern "c" fn wasm_func_copy(*const Func) ?*Func;
    extern "c" fn wasm_func_call(*Func, *const ValVec, *ValVec) ?*Trap;
    extern "c" fn wasm_func_result_arity(*Func) usize;
    extern "c" fn wasm_func_param_arity(*Func) usize;
};

pub const Instance = opaque {
    pub fn init(store: *Store, module: *Module, import: []const *Func) !*Instance {
        var trap: ?*Trap = null;
        var imports = ExternVec.initWithCapacity(import.len);
        defer imports.deinit();

        var ptr = imports.data;
        var i: usize = 0;
        while (i < import.len) : (i += 1) {
            ptr[i] = import[i].asExtern();
        }

        const instance = wasm_instance_new(store, module, &imports, &trap);

        if (trap) |t| {
            defer t.deinit();
            log.err("code unexpectedly trapped", .{});
            return Error.InstanceInit;
        }

        return instance orelse Error.InstanceInit;
    }

    pub fn initFromImports(store: *Store, module: *Module, imports: *ExternVec) !*Instance {
        var trap: ?*Trap = null;

        const instance = wasm_instance_new(store, module, imports, &trap);

        if (trap) |t| {
            defer t.deinit();
            log.err("code unexpectedly trapped", .{});
            return Error.InstanceInit;
        }

        return instance orelse Error.InstanceInit;
    }

    pub fn getExportFunc(self: *Instance, module: *Module, name: []const u8) ?*Func {
        return if (self.getExport(module, name)) |exp| {
            defer exp.deinit();
            return exp.asFunc().copy();
        } else null;
    }

    pub fn getExport(self: *Instance, module: *Module, name: []const u8) ?*Extern {
        var externs: ExternVec = undefined;
        wasm_instance_exports(self, &externs);
        defer externs.deinit();

        var exports = module.exports();
        defer exports.deinit();

        return for (exports.toSlice(), 0..) |export_type, index| {
            const ty = export_type orelse continue;
            const type_name = ty.name();
            defer type_name.deinit();

            if (std.mem.eql(u8, name, type_name.toSlice())) {
                if (externs.data[index]) |ext| {
                    break ext.copy();
                }
            }
        } else null;
    }

    pub fn getExportByIndex(self: *Instance, index: u32) ?*Extern {
        var externs: ExternVec = undefined;
        wasm_instance_exports(self, &externs);
        defer externs.deinit();

        if (index > externs.size) return null;
        return externs.data[index].?;
    }

    pub fn getExportMem(self: *Instance, module: *Module, name: []const u8) ?*Memory {
        return if (self.getExport(module, name)) |exp| {
            defer exp.deinit();
            return exp.asMemory().copy();
        } else null;
    }

    pub fn deinit(self: *Instance) void {
        wasm_instance_delete(self);
    }

    extern "c" fn wasm_instance_new(*Store, *const Module, *const ExternVec, *?*Trap) ?*Instance;
    extern "c" fn wasm_instance_delete(*Instance) void;
    extern "c" fn wasm_instance_exports(*Instance, *ExternVec) void;
};

pub const Trap = opaque {
    pub fn deinit(self: *Trap) void {
        wasm_trap_delete(self);
    }

    pub fn message(self: *Trap) *ByteVec {
        var bytes: ?*ByteVec = null;
        wasm_trap_message(self, &bytes);
        return bytes.?;
    }

    extern "c" fn wasm_trap_delete(*Trap) void;
    extern "c" fn wasm_trap_message(*const Trap, out: *?*ByteVec) void;
};

pub const Extern = opaque {
    pub fn asFunc(self: *Extern) *Func {
        return wasm_extern_as_func(self).?;
    }

    pub fn asMemory(self: *Extern) *Memory {
        return wasm_extern_as_memory(self).?;
    }

    pub fn asGlobal(self: *Extern) *Global {
        return wasm_extern_as_global(self).?;
    }

    pub fn asTable(self: *Extern) *Table {
        return wasm_extern_as_table(self).?;
    }

    pub fn deinit(self: *Extern) void {
        wasm_extern_delete(self);
    }

    pub fn copy(self: *Extern) *Extern {
        return wasm_extern_copy(self).?;
    }

    pub fn eql(self: *const Extern, other: *const Extern) bool {
        return wasm_extern_same(self, other);
    }

    pub fn toType(self: *const Extern) *ExternType {
        return wasm_extern_type(self).?;
    }

    pub fn kind(self: *const Extern) ExternKind {
        return wasm_extern_kind(self);
    }

    extern "c" fn wasm_extern_as_func(*Extern) ?*Func;
    extern "c" fn wasm_extern_as_memory(*Extern) ?*Memory;
    extern "c" fn wasm_extern_as_global(*Extern) ?*Global;
    extern "c" fn wasm_extern_as_table(*Extern) ?*Table;
    extern "c" fn wasm_extern_delete(*Extern) void;
    extern "c" fn wasm_extern_copy(*Extern) ?*Extern;
    extern "c" fn wasm_extern_same(*const Extern, *const Extern) bool;
    extern "c" fn wasm_extern_type(?*const Extern) ?*ExternType;
    extern "c" fn wasm_extern_kind(?*const Extern) ExternKind;
};

pub const ExternKind = std.wasm.ExternalKind;

pub const ExternType = opaque {
    pub fn fromExtern(extern_object: *const Extern) *ExternType {
        return Extern.wasm_extern_type(extern_object).?;
    }

    pub fn deinit(self: *ExternType) void {
        wasm_externtype_delete(self);
    }

    pub fn copy(self: *ExportType) *ExportType {
        return wasm_externtype_copy(self).?;
    }

    pub fn kind(self: *const ExportType) ExternKind {
        return wasm_externtype_kind(self);
    }

    extern "c" fn wasm_externtype_delete(?*ExportType) void;
    extern "c" fn wasm_externtype_copy(?*ExportType) ?*ExportType;
    extern "c" fn wasm_externtype_kind(?*const ExternType) ExternKind;
};

pub const Memory = opaque {
    pub fn init(store: *Store, mem_type: *const MemoryType) !*Memory {
        return wasm_memory_new(store, mem_type) orelse error.MemoryInit;
    }

    pub fn getType(self: *const Memory) *MemoryType {
        return wasm_memory_type(self).?;
    }

    pub fn deinit(self: *Memory) void {
        wasm_memory_delete(self);
    }

    pub fn copy(self: *const Memory) ?*Memory {
        return wasm_memory_copy(self);
    }

    pub fn eql(self: *const Memory, other: *const Memory) bool {
        return wasm_memory_same(self, other);
    }

    pub fn data(self: *Memory) [*]u8 {
        return wasm_memory_data(self);
    }

    pub fn size(self: *const Memory) usize {
        return wasm_memory_data_size(self);
    }

    pub fn pages(self: *const Memory) u32 {
        return wasm_memory_size(self);
    }

    pub fn toSlice(self: *Memory) []const u8 {
        var slice: []const u8 = undefined;
        slice.ptr = self.data();
        slice.len = self.size();
        return slice;
    }

    pub fn grow(self: *Memory, page_count: u32) error{OutOfMemory}!void {
        if (!wasm_memory_grow(self, page_count)) return error.OutOfMemory;
    }

    extern "c" fn wasm_memory_delete(*Memory) void;
    extern "c" fn wasm_memory_copy(*const Memory) ?*Memory;
    extern "c" fn wasm_memory_same(*const Memory, *const Memory) bool;
    extern "c" fn wasm_memory_new(*Store, *const MemoryType) ?*Memory;
    extern "c" fn wasm_memory_type(*const Memory) *MemoryType;
    extern "c" fn wasm_memory_data(*Memory) [*]u8;
    extern "c" fn wasm_memory_data_size(*const Memory) usize;
    extern "c" fn wasm_memory_grow(*Memory, delta: u32) bool;
    extern "c" fn wasm_memory_size(*const Memory) u32;
};

pub const Limits = extern struct {
    min: u32,
    max: u32,
};

pub const MemoryType = opaque {
    pub fn init(limits: Limits) !*MemoryType {
        return wasm_memorytype_new(&limits) orelse return error.InitMemoryType;
    }

    pub fn deinit(self: *MemoryType) void {
        wasm_memorytype_delete(self);
    }

    extern "c" fn wasm_memorytype_new(*const Limits) ?*MemoryType;
    extern "c" fn wasm_memorytype_delete(*MemoryType) void;
};

pub const Table = opaque {};
pub const Global = opaque {};

pub const ExportType = opaque {
    pub fn name(self: *ExportType) *ByteVec {
        return self.wasm_exporttype_name().?;
    }

    extern "c" fn wasm_exporttype_name(*ExportType) ?*ByteVec;
};

pub const ExportTypeVec = extern struct {
    size: usize,
    data: [*]?*ExportType,

    pub fn toSlice(self: *const ExportTypeVec) []const ?*ExportType {
        return self.data[0..self.size];
    }

    pub fn deinit(self: *ExportTypeVec) void {
        self.wasm_exporttype_vec_delete();
    }

    extern "c" fn wasm_exporttype_vec_delete(*ExportTypeVec) void;
};

pub const ImportType = opaque {
    pub fn name(self: *ImportType) *ByteVec {
        return wasm_importtype_name(self).?;
    }

    extern "c" fn wasm_importtype_name(*ImportType) ?*ByteVec;
};

pub const ImportTypeVec = extern struct {
    size: usize,
    data: [*]?*ImportType,

    pub fn toSlice(self: *const ImportTypeVec) []const ?*ImportType {
        return self.data[0..self.size];
    }

    pub fn deinit(self: *ImportTypeVec) void {
        self.wasm_importtype_vec_delete();
    }

    extern "c" fn wasm_importtype_vec_delete(*ImportTypeVec) void;
};

pub const Callback = fn (?*const Valtype, ?*Valtype) callconv(c_callconv) ?*Trap;

pub const ByteVec = extern struct {
    size: usize,
    data: [*]u8,

    pub fn initWithCapacity(size: usize) ByteVec {
        var bytes: ByteVec = undefined;
        wasm_byte_vec_new_uninitialized(&bytes, size);
        return bytes;
    }

    pub fn fromSlice(slice: []const u8) ByteVec {
        var bytes: ByteVec = undefined;
        wasm_byte_vec_new(&bytes, slice.len, slice.ptr);
        return bytes;
    }

    pub fn toSlice(self: ByteVec) []const u8 {
        return self.data[0..self.size];
    }

    pub fn deinit(self: *ByteVec) void {
        wasm_byte_vec_delete(self);
    }

    extern "c" fn wasm_byte_vec_new(*ByteVec, usize, [*]const u8) void;
    extern "c" fn wasm_byte_vec_new_uninitialized(*ByteVec, usize) void;
    extern "c" fn wasm_byte_vec_delete(*ByteVec) void;
};

pub const NameVec = extern struct {
    size: usize,
    data: [*]const u8,

    pub fn fromSlice(slice: []const u8) NameVec {
        return .{ .size = slice.len, .data = slice.ptr };
    }
};

pub const ExternVec = extern struct {
    size: usize,
    data: [*]?*Extern,

    pub fn empty() ExternVec {
        return .{ .size = 0, .data = undefined };
    }

    pub fn deinit(self: *ExternVec) void {
        wasm_extern_vec_delete(self);
    }

    pub fn initWithCapacity(size: usize) ExternVec {
        var externs: ExternVec = undefined;
        wasm_extern_vec_new_uninitialized(&externs, size);
        return externs;
    }

    extern "c" fn wasm_extern_vec_new_empty(*ExternVec) void;
    extern "c" fn wasm_extern_vec_new_uninitialized(*ExternVec, usize) void;
    extern "c" fn wasm_extern_vec_delete(*ExternVec) void;
};

pub const Valkind = enum(u8) {
    i32 = 0,
    i64 = 1,
    f32 = 2,
    f64 = 3,
    anyref = 128,
    funcref = 129,
};

pub const Value = extern struct {
    kind: Valkind,
    of: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        ref: ?*anyopaque,
    },
};

pub const Valtype = opaque {
    pub fn init(valKind: Valkind) *Valtype {
        return wasm_valtype_new(@intFromEnum(valKind));
    }

    pub fn deinit(self: *Valtype) void {
        wasm_valtype_delete(self);
    }

    pub fn kind(self: *Valtype) Valkind {
        return @as(Valkind, @enumFromInt(wasm_valtype_kind(self)));
    }

    extern "c" fn wasm_valtype_new(kind: u8) *Valtype;
    extern "c" fn wasm_valtype_delete(*Valkind) void;
    extern "c" fn wasm_valtype_kind(*Valkind) u8;
};

pub const ValtypeVec = extern struct {
    size: usize,
    data: [*]?*Valtype,

    pub fn empty() ValtypeVec {
        return .{ .size = 0, .data = undefined };
    }
};

pub const ValVec = extern struct {
    size: usize,
    data: [*]Value,

    pub fn initWithCapacity(size: usize) ValVec {
        var bytes: ValVec = undefined;
        wasm_val_vec_new_uninitialized(&bytes, size);
        return bytes;
    }

    pub fn deinit(self: *ValVec) void {
        self.wasm_val_vec_delete();
    }

    extern "c" fn wasm_val_vec_new_uninitialized(*ValVec, usize) void;
    extern "c" fn wasm_val_vec_delete(*ValVec) void;
};

pub extern "c" fn wasm_functype_new(args: *ValtypeVec, results: *ValtypeVec) ?*anyopaque;
pub extern "c" fn wasm_functype_delete(functype: *anyopaque) void;

test "run_tests" {
    testing.refAllDecls(@This());
}
