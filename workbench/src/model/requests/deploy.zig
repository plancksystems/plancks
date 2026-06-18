pub const DeployRequest = struct {
    action: []const u8 = "",
    app: []const u8 = "",
    name: []const u8 = "",
    config_yaml: []const u8 = "",
    service_yaml: []const u8 = "",
    admin_uid: []const u8 = "admin",
    admin_key: []const u8 = "",
    description: []const u8 = "",
    wasm_filename: []const u8 = "",
    wasm_data: []const u8 = "",
    kind: []const u8 = "wasm",
    binary_data: []const u8 = "",
    service_name: []const u8 = "",
};

pub const DeployReplicaRequest = struct {
    action: []const u8 = "deploy",
    name: []const u8 = "",
    app: []const u8 = "",
    config_yaml: []const u8 = "",
    admin_uid: []const u8 = "admin",
    admin_key: []const u8 = "",
    description: []const u8 = "",
    primary_host: []const u8 = "127.0.0.1",
    primary_port: []const u8 = "0",
};
