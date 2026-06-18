
const planck = @import("planck");
const m = @import("models/task.zig");
const Task = m.Task;

pub const TaskModel = planck.Model(Task, .{
    .store = "tasks",
    .primary_key = "TaskID",
    .timestamps = true,
    .schema = &.{
        .{ "Title", .{ .field_type = .string, .required = true, .min_length = 1, .max_length = 200 } },
    },
});
