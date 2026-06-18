
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Forms = struct {
    snake_plural: []const u8,
    snake_singular: []const u8,
    title_plural: []const u8,
    title_singular: []const u8,

    pub fn deinit(self: Forms, allocator: Allocator) void {
        allocator.free(self.snake_singular);
        allocator.free(self.title_plural);
        allocator.free(self.title_singular);
    }
};

pub fn forms(allocator: Allocator, snake_plural: []const u8) !Forms {
    const snake_singular = try singularize(allocator, snake_plural);
    errdefer allocator.free(snake_singular);
    const title_plural = try toTitleCase(allocator, snake_plural);
    errdefer allocator.free(title_plural);
    const title_singular = try toTitleCase(allocator, snake_singular);
    return .{
        .snake_plural = snake_plural,
        .snake_singular = snake_singular,
        .title_plural = title_plural,
        .title_singular = title_singular,
    };
}

pub fn substitute(allocator: Allocator, bytes: []const u8, f: Forms) ![]u8 {
    const step1 = try replaceAll(allocator, bytes, "Tasks", f.title_plural);
    errdefer allocator.free(step1);
    const step2 = try replaceAll(allocator, step1, "Task", f.title_singular);
    allocator.free(step1);
    errdefer allocator.free(step2);
    const step3 = try replaceAll(allocator, step2, "tasks", f.snake_plural);
    allocator.free(step2);
    errdefer allocator.free(step3);
    const step4 = try replaceAll(allocator, step3, "task", f.snake_singular);
    allocator.free(step3);
    return step4;
}


fn singularize(allocator: Allocator, name: []const u8) ![]u8 {
    if (name.len > 1 and name[name.len - 1] == 's') {
        return allocator.dupe(u8, name[0 .. name.len - 1]);
    }
    return allocator.dupe(u8, name);
}

pub fn toTitleCase(allocator: Allocator, snake: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var capitalize = true;
    for (snake) |c| {
        if (c == '_') {
            capitalize = true;
            continue;
        }
        const ch = if (capitalize) std.ascii.toUpper(c) else c;
        try out.append(allocator, ch);
        capitalize = false;
    }
    return out.toOwnedSlice(allocator);
}

pub fn replaceAll(allocator: Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            try out.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try out.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}


test "forms: plural input" {
    const a = std.testing.allocator;
    const f = try forms(a, "notes");
    defer f.deinit(a);
    try std.testing.expectEqualStrings("notes", f.snake_plural);
    try std.testing.expectEqualStrings("note", f.snake_singular);
    try std.testing.expectEqualStrings("Notes", f.title_plural);
    try std.testing.expectEqualStrings("Note", f.title_singular);
}

test "forms: non-pluralizable input (mail)" {
    const a = std.testing.allocator;
    const f = try forms(a, "mail");
    defer f.deinit(a);
    try std.testing.expectEqualStrings("mail", f.snake_plural);
    try std.testing.expectEqualStrings("mail", f.snake_singular);
    try std.testing.expectEqualStrings("Mail", f.title_plural);
    try std.testing.expectEqualStrings("Mail", f.title_singular);
}

test "substitute: tasks → notes" {
    const a = std.testing.allocator;
    const f = try forms(a, "notes");
    defer f.deinit(a);
    const out = try substitute(a, "Task: const TaskModel = planck.Model(Task, .{ .store = \"tasks\" });", f);
    defer a.free(out);
    try std.testing.expectEqualStrings("Note: const NoteModel = planck.Model(Note, .{ .store = \"notes\" });", out);
}

test "substitute: TaskID survives Task→Note" {
    const a = std.testing.allocator;
    const f = try forms(a, "notes");
    defer f.deinit(a);
    const out = try substitute(a, "TaskID: i64, Tasks.len, tasks list, task var", f);
    defer a.free(out);
    try std.testing.expectEqualStrings("NoteID: i64, Notes.len, notes list, note var", out);
}

test "toTitleCase" {
    const a = std.testing.allocator;
    {
        const out = try toTitleCase(a, "tasks");
        defer a.free(out);
        try std.testing.expectEqualStrings("Tasks", out);
    }
    {
        const out = try toTitleCase(a, "notes_app");
        defer a.free(out);
        try std.testing.expectEqualStrings("NotesApp", out);
    }
    {
        const out = try toTitleCase(a, "task_tracker_v2");
        defer a.free(out);
        try std.testing.expectEqualStrings("TaskTrackerV2", out);
    }
}
