
pub const Task = struct {
    TaskID: i64 = 0,
    Title: []const u8 = "",
    Done: bool = false,
    CreatedAt: i64 = 0,
    UpdatedAt: i64 = 0,

    pub fn boxClass(self: Task) []const u8 {
        return if (self.Done) "border-emerald-500 bg-emerald-500 text-white" else "border-slate-300";
    }
    pub fn titleClass(self: Task) []const u8 {
        return if (self.Done) "text-slate-400 line-through" else "text-slate-800";
    }
    pub fn toggleTo(self: Task) []const u8 {
        return if (self.Done) "false" else "true";
    }
    pub fn checkMark(self: Task) []const u8 {
        return if (self.Done) "✓" else "";
    }
};

pub const CreateTaskBody = struct {
    Title: []const u8,
};

pub const ToggleTaskBody = struct {
    Done: bool,
};
