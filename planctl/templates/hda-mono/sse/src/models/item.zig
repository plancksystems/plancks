const std_ = @import("std");

pub const Item = struct {
    ItemID: []const u8 = "",
    Name: []const u8 = "",
    Status: []const u8 = "",

    pub fn statusColor(self: Item) []const u8 {
        if (std_.mem.eql(u8, self.Status, "active")) return "border-blue-500";
        if (std_.mem.eql(u8, self.Status, "done")) return "border-emerald-500";
        if (std_.mem.eql(u8, self.Status, "error")) return "border-red-500";
        return "border-slate-300";
    }
};
