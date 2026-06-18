pub const model = struct {
    pub const types = @import("model/types.zig");
};

pub const tasks = struct {
    pub const config = @import("tasks/config.zig");
    pub const compat = @import("tasks/compat.zig");
    pub const service_manager = @import("tasks/service_manager.zig");
};

