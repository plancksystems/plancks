pub const DeployResponse = struct {
    success: bool = true,
    @"error": ?[]const u8 = null,
    port: ?i32 = null,
    query_node_undeployed: ?bool = null,
};

pub const DeployReplicaResponse = struct {
    success: bool = true,
    port: i32 = 0,
    @"error": ?[]const u8 = null,
};
