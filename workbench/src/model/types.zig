
pub const ServiceInfo = struct {
    name: []const u8 = "",
    service_name: []const u8 = "",
    description: []const u8 = "",
    admin_uid: []const u8 = "",
    admin_key: []const u8 = "",
    kind: []const u8 = "wasm",
    status: []const u8 = "unknown",
    port: i32 = 0,
    wasm_port: i32 = 0,
};

pub const ServiceStatus = struct {
    name: []const u8 = "",
    service_name: []const u8 = "",
    description: []const u8 = "",
    admin_uid: []const u8 = "",
    admin_key: []const u8 = "",
    service_type: []const u8 = "standalone",
    kind: []const u8 = "wasm",
    status: []const u8 = "unknown",
    port: i32 = 0,
    pid: i32 = 0,
    cpu_percent: f64 = 0,
    rss_mb: f64 = 0,
    app: []const u8 = "",
    replica: ?ReplicaStatus = null,
};

pub const ReplicaStatus = struct {
    status: []const u8 = "unknown",
    port: i32 = 0,
};

pub const AppInfo = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    path: []const u8 = "",
    port: i32 = 0,
    status: []const u8 = "unknown",
    services: []ServiceInfo = &.{},
    kind: []const u8 = "shell",
    shell_status: []const u8 = "not_deployed",
    shell_port: u16 = 0,
    shell_pid: i32 = 0,
};

pub const StoreInfo = struct {
    ns: []const u8 = "",
    status: []const u8 = "ok",
    short: []const u8 = "",
    description: ?[]const u8 = null,
    indexes: []IndexInfo = &.{},
};

pub const IndexInfo = struct {
    ns: []const u8 = "",
    field: []const u8 = "",
    field_type: []const u8 = "String",
    unique: bool = false,
    short: []const u8 = "",
    description: ?[]const u8 = null,
};

pub const DbStatus = struct {
    name: []const u8 = "",
    label: []const u8 = "",
    connected: bool = false,
    role: []const u8 = "",
    uid: []const u8 = "",
    wasm_port: i32 = 0,
};

pub const Schedule = struct {
    name: []const u8 = "",

    app: []const u8 = "",
    service: []const u8 = "",

    task_type: []const u8 = "",
    cron_expr: []const u8 = "",
    enabled: bool = true,
    backup_path: []const u8 = "",
    description: []const u8 = "",
    manifest: []const u8 = "",
    created_at: i64 = 0,
    last_run_at: i64 = 0,
    next_run_at: i64 = 0,
};

pub const UserInfo = struct {
    username: []const u8 = "",
    role: []const u8 = "",
    created_at: i64 = 0,
};

pub const StatsSnapshot = struct {
    ts: i64 = 0,
    data: []const u8 = "",
};

pub const ApiError = struct {
    success: bool = false,
    @"error": []const u8 = "",
};
