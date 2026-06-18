
const std = @import("std");
const builtin = @import("builtin");

const win = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const DWORD = windows.DWORD;
    const BOOL = windows.BOOL;
    const HANDLE = windows.HANDLE;

    const PROCESS_TERMINATE: DWORD = 0x0001;
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: DWORD,
        bInheritHandle: BOOL,
        dwProcessId: DWORD
    ) callconv(.winapi) ?HANDLE;

    extern "kernel32" fn TerminateProcess(
        hProcess: HANDLE,
        uExitCode: u32
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn GetProcessId(
        Process: HANDLE
    ) callconv(.winapi) DWORD;

    const CloseHandle = windows.CloseHandle;
} else void;

pub fn killByPid(pid: i32) void {
    if (comptime builtin.os.tag == .windows) {
        const handle = win.OpenProcess(win.PROCESS_TERMINATE, .FALSE, @intCast(pid)) orelse return;
        defer win.CloseHandle(handle);
        _ = win.TerminateProcess(handle, 1);
    } else {
        std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch {};
    }
}

pub fn pidFromChild(child_id_opt: anytype) ?i32 {
    const child_id = child_id_opt orelse return null;
    if (comptime builtin.os.tag == .windows) {
        const dword = win.GetProcessId(child_id);
        if (dword == 0) return null;
        return @intCast(dword);
    } else {
        return @intCast(child_id);
    }
}

pub fn isAliveByPid(pid: i32) bool {
    if (comptime builtin.os.tag == .windows) {
        const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, @intCast(pid)) orelse return false;
        defer win.CloseHandle(handle);
        return true;
    } else {
        std.posix.kill(@intCast(pid), @enumFromInt(0)) catch return false;
        return true;
    }
}
