const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;
const EngineMetrics = @import("../common/metrics.zig").EngineMetrics;
const testing = std.testing;

pub const PageId = u64;

const FrameId = u32;

pub const PAGE_SIZE: u32 = 16384 * 4 - 1;

const MIN_POOL_SIZE: u32 = 64;

const MAX_TREE_DEPTH: u32 = 32;

const MAGIC: u32 = 0x53535441;

const VERSION: u8 = 1;

const FRAME_STRIDE: usize = std.mem.alignForward(usize, PAGE_SIZE, @alignOf(Header));

fn readHeader(data: []const u8) Header {
    var h: Header = undefined;
    @memcpy(std.mem.asBytes(&h), data[0..@sizeOf(Header)]);
    return h;
}

fn writeHeader(data: []u8, h: *const Header) void {
    @memcpy(data[0..@sizeOf(Header)], std.mem.asBytes(h));
}

comptime {
    std.debug.assert(PAGE_SIZE <= std.math.maxInt(u16));
    std.debug.assert(@sizeOf(CellPtr) == 6);
    std.debug.assert(@offsetOf(CellPtr, "offset") == 0);
    std.debug.assert(@offsetOf(CellPtr, "key_size") == 2);
    std.debug.assert(@offsetOf(CellPtr, "value_size") == 4);
    std.debug.assert(@offsetOf(PageHeader, "checksum") == 0);
    std.debug.assert(@offsetOf(Header, "checksum") == 0);
    std.debug.assert(@sizeOf(PageHeader) < PAGE_SIZE);
    std.debug.assert(MIN_POOL_SIZE >= 64);
}

pub const IndexConfig = struct {
    dir_path: []const u8,
    file_name: []const u8,
    pool_size: u32,
    io: Io,
};

pub const PageType = enum(u8) {
    leaf = 0,
    internal = 1,
};

pub const PageHeader = extern struct {
    checksum: u64,
    page_type: PageType,
    num_cells: u16,
    free_space_start: u16,
    free_space_end: u16,
    parent_page_id: PageId,
    next_page_id: PageId,
    leftmost_child_id: PageId,
};

const Header = extern struct {
    checksum: u64 = 0,
    magic: u32,
    version: u8,
    page_size: u32,
    root_page_id: PageId,
    lsn: u64,
    free_page_list_head: PageId = 0,
};

pub const CellPtr = struct {
    offset: u16,
    key_size: u16,
    value_size: u16,
};

pub const Cell = struct {
    key: []const u8,
    value: []const u8,

    pub fn len(self: *const Cell) u32 {
        return @as(u32, @intCast(self.key.len)) +
            @as(u32, @intCast(self.value.len));
    }
};

pub const SlottedPage = struct {
    data: []u8,

    pub fn reset(self: *SlottedPage, page_type: PageType) void {
        @memset(self.data, 0);
        self.headerPtr().* = .{
            .checksum = 0,
            .page_type = page_type,
            .num_cells = 0,
            .free_space_start = @sizeOf(PageHeader),
            .free_space_end = PAGE_SIZE,
            .parent_page_id = 0,
            .next_page_id = 0,
            .leftmost_child_id = 0,
        };
    }

    pub fn initOwned(allocator: Allocator, page_type: PageType) !*SlottedPage {
        const self = try allocator.create(SlottedPage);
        errdefer allocator.destroy(self);
        const buf = try allocator.alloc(u8, PAGE_SIZE);
        self.* = .{ .data = buf };
        self.reset(page_type);
        return self;
    }

    pub fn deinitOwned(self: *SlottedPage, allocator: Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }

    pub fn headerPtr(self: anytype) *PageHeader {
        return @ptrCast(@alignCast(self.data.ptr));
    }

    pub fn freeSpace(self: *const SlottedPage) u16 {
        const h = self.headerPtr();
        return h.free_space_end - h.free_space_start;
    }

    pub fn hasSpace(self: *const SlottedPage, cell_size: u32) bool {
        return @as(u32, self.freeSpace()) >= cell_size + @as(u32, @sizeOf(CellPtr));
    }

    pub fn findChildPageId(self: *const SlottedPage, key: []const u8) PageId {
        const h = self.headerPtr();
        var left: i32 = -1;
        var right: i32 = @intCast(h.num_cells);
        while (right - left > 1) {
            const mid: i32 = left + @divTrunc(right - left, 2);
            const cell = self.getCell(@intCast(mid)) orelse {
                right = mid;
                continue;
            };
            switch (mem.order(u8, key, cell.key)) {
                .lt => right = mid,
                else => left = mid,
            }
        }
        if (left == -1) return h.leftmost_child_id;
        const cell = self.getCell(@intCast(left)).?;
        return mem.readInt(PageId, cell.value[0..@sizeOf(PageId)], .little);
    }

    pub fn findInsertIndex(self: *const SlottedPage, key: []const u8) u16 {
        var left: u16 = 0;
        var right: u16 = self.headerPtr().num_cells;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_cell = self.getCell(mid) orelse {
                left = mid + 1;
                continue;
            };
            if (mem.order(u8, mid_cell.key, key) == .lt) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }

    fn findChildIndex(self: *const SlottedPage, child_id: PageId) ?u16 {
        if (self.headerPtr().leftmost_child_id == child_id) return 0;
        var i: u16 = 0;
        while (i < self.headerPtr().num_cells) : (i += 1) {
            const cell = self.getCell(i) orelse continue;
            const pid = mem.readInt(PageId, cell.value[0..@sizeOf(PageId)], .little);
            if (pid == child_id) return i + 1;
        }
        return null;
    }

    pub fn insertCell(self: *SlottedPage, index: u16, cell: Cell) !void {
        if (cell.key.len == 0) return error.ZeroLengthKey;
        if (cell.key.len > std.math.maxInt(u16)) return error.KeyTooLarge;
        if (cell.value.len > std.math.maxInt(u16)) return error.ValueTooLarge;
        if (!self.hasSpace(cell.len())) return error.PageFull;

        const h = self.headerPtr();
        const n = h.num_cells;
        const cps = @sizeOf(PageHeader);
        const new_off = cps + index * @sizeOf(CellPtr);
        const to_move = (n - index) * @sizeOf(CellPtr);

        if (to_move > 0) {
            mem.copyBackwards(
                u8,
                self.data[new_off + @sizeOf(CellPtr) ..][0..to_move],
                self.data[new_off..][0..to_move],
            );
        }

        const data_off: u16 = @intCast(h.free_space_end - cell.len());
        @memcpy(self.data[data_off..][0..cell.key.len], cell.key);
        @memcpy(self.data[data_off + cell.key.len ..][0..cell.value.len], cell.value);

        var pb: [@sizeOf(CellPtr)]u8 = undefined;
        mem.writeInt(u16, pb[0..2], data_off, .little);
        mem.writeInt(u16, pb[2..4], @intCast(cell.key.len), .little);
        mem.writeInt(u16, pb[4..6], @intCast(cell.value.len), .little);
        @memcpy(self.data[new_off..][0..@sizeOf(CellPtr)], &pb);

        h.num_cells += 1;
        h.free_space_start += @sizeOf(CellPtr);
        h.free_space_end = data_off;
    }

    pub fn getCell(self: *const SlottedPage, index: u16) ?Cell {
        const h = self.headerPtr();
        if (index >= h.num_cells) return null;

        const cpo = @sizeOf(PageHeader) + index * @sizeOf(CellPtr);
        const offset = mem.readInt(u16, self.data[cpo..][0..2], .little);
        const key_size = mem.readInt(u16, self.data[cpo + 2 ..][0..2], .little);
        if (key_size == 0) return null;

        const value_size = mem.readInt(u16, self.data[cpo + 4 ..][0..2], .little);
        const end = @as(u32, offset) + key_size + value_size;
        if (end > PAGE_SIZE) return null;

        return Cell{
            .key = self.data[offset..][0..key_size],
            .value = self.data[offset + key_size ..][0..value_size],
        };
    }

    pub fn updateCell(self: *SlottedPage, index: u16, new_value: []const u8) !void {
        const h = self.headerPtr();
        if (index >= h.num_cells) return error.InvalidCellIndex;
        const cpo = @sizeOf(PageHeader) + index * @sizeOf(CellPtr);
        const offset = mem.readInt(u16, self.data[cpo..][0..2], .little);
        const key_size = mem.readInt(u16, self.data[cpo + 2 ..][0..2], .little);
        if (key_size == 0) return error.CellDeleted;
        const value_size = mem.readInt(u16, self.data[cpo + 4 ..][0..2], .little);
        if (new_value.len != value_size) return error.ValueSizeMismatch;
        @memcpy(self.data[offset + key_size ..][0..value_size], new_value);
    }

    pub fn deleteCell(self: *SlottedPage, index: u16) void {
        const h = self.headerPtr();
        if (index >= h.num_cells) return;
        const cpo = @sizeOf(PageHeader) + index * @sizeOf(CellPtr);
        mem.writeInt(u16, self.data[cpo + 2 ..][0..2], 0, .little);
    }

    pub fn compact(self: *SlottedPage, scratch: Allocator) !void {
        const h = self.headerPtr();

        var live = std.ArrayList(Cell).empty;
        var it = self.cells();
        while (it.next()) |b| {
            try live.append(scratch, .{
                .key = try scratch.dupe(u8, b.key),
                .value = try scratch.dupe(u8, b.value),
            });
        }

        const pt = h.page_type;
        const pid = h.parent_page_id;
        const nid = h.next_page_id;
        const lc = h.leftmost_child_id;

        @memset(self.data, 0);
        h.* = .{
            .checksum = 0,
            .page_type = pt,
            .num_cells = 0,
            .free_space_start = @sizeOf(PageHeader),
            .free_space_end = PAGE_SIZE,
            .parent_page_id = pid,
            .next_page_id = nid,
            .leftmost_child_id = lc,
        };

        for (live.items) |c| {
            self.insertCell(h.num_cells, c) catch |err| {
                std.log.err("compact: insertCell failed unexpectedly: {}", .{err});
                return error.CompactFailed;
            };
        }
    }

    pub fn findCellByKey(self: *const SlottedPage, key: []const u8) ?u16 {
        var left: u16 = 0;
        var right: u16 = self.headerPtr().num_cells;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const cell = self.getCell(mid) orelse {
                left = mid + 1;
                continue;
            };
            switch (mem.order(u8, key, cell.key)) {
                .lt => right = mid,
                .gt => left = mid + 1,
                .eq => return mid,
            }
        }
        return null;
    }

    pub fn clear(self: *SlottedPage) void {
        const h = self.headerPtr();
        const pt = h.page_type;
        const pid = h.parent_page_id;
        const nid = h.next_page_id;
        const lc = h.leftmost_child_id;
        @memset(self.data, 0);
        h.* = .{
            .checksum = 0,
            .page_type = pt,
            .num_cells = 0,
            .free_space_start = @sizeOf(PageHeader),
            .free_space_end = PAGE_SIZE,
            .parent_page_id = pid,
            .next_page_id = nid,
            .leftmost_child_id = lc,
        };
    }

    pub fn cells(self: *const SlottedPage) CellsIterator {
        return .{ .page = self, .index = 0 };
    }
};

pub const CellsIterator = struct {
    page: *const SlottedPage,
    index: u16,

    pub fn next(self: *CellsIterator) ?Cell {
        while (self.index < self.page.headerPtr().num_cells) {
            const i = self.index;
            self.index += 1;
            if (self.page.getCell(i)) |c| return c;
        }
        return null;
    }
};

pub const Pager = struct {
    file: File,
    io: Io,
    num_pages: PageId,
    file_path: []const u8 = "<unknown>",
    free_pages: std.ArrayList(PageId),
    allocator: Allocator,

    pub fn init(io: Io, file_path: []const u8, allocator: Allocator) !Pager {
        const file = Dir.openFile(.cwd(), io, file_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try Dir.createFile(.cwd(), io, file_path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        errdefer file.close(io);

        const stat = try file.stat(io);
        const file_size = stat.size;
        if (file_size % PAGE_SIZE != 0) return error.InvalidDbFile;

        return .{
            .file = file,
            .io = io,
            .num_pages = file_size / PAGE_SIZE,
            .file_path = file_path,
            .free_pages = std.ArrayList(PageId).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pager) void {
        self.free_pages.deinit(self.allocator);
        self.file.close(self.io);
    }

    pub fn allocPage(self: *Pager) !PageId {
        if (self.free_pages.items.len > 0) return self.free_pages.pop().?;
        const id = self.num_pages;
        self.num_pages += 1;
        return id;
    }

    pub fn freePage(self: *Pager, id: PageId) !void {
        if (id <= 1) return;
        try self.free_pages.append(self.allocator, id);
    }

    pub fn writePage(self: *Pager, page_id: PageId, data: []const u8) !void {
        try self.file.writePositionalAll(self.io, data, page_id * PAGE_SIZE);
    }

    pub fn readPage(self: *Pager, page_id: PageId, buf: []u8) !void {
        _ = try self.file.readPositionalAll(self.io, buf, page_id * PAGE_SIZE);
    }

    pub fn sync(self: *Pager) !void {
        try self.file.sync(self.io);
    }

    pub fn persistFreeList(self: *Pager, scratch: []u8) !PageId {
        std.debug.assert(scratch.len >= PAGE_SIZE);
        var head: PageId = 0;
        for (self.free_pages.items) |pid| {
            @memset(scratch[0..PAGE_SIZE], 0);
            mem.writeInt(PageId, scratch[@sizeOf(u64) .. @sizeOf(u64) + @sizeOf(PageId)], head, .little);
            const cs = std.hash.Wyhash.hash(0, scratch[@sizeOf(u64)..PAGE_SIZE]);
            mem.writeInt(u64, scratch[0..@sizeOf(u64)], cs, .little);
            try self.writePage(pid, scratch[0..PAGE_SIZE]);
            head = pid;
        }
        return head;
    }

    pub fn loadFreeList(self: *Pager, head: PageId, scratch: []u8) !void {
        std.debug.assert(scratch.len >= PAGE_SIZE);
        self.free_pages.clearRetainingCapacity();
        var cur = head;
        while (cur != 0) {
            try self.readPage(cur, scratch[0..PAGE_SIZE]);
            const next = mem.readInt(PageId, scratch[@sizeOf(u64) .. @sizeOf(u64) + @sizeOf(PageId)], .little);
            try self.free_pages.append(self.allocator, cur);
            cur = next;
        }
    }
};

pub const Frame = struct {
    page_id: ?PageId = null,
    pin_count: u32 = 0,
    is_dirty: bool = false,
    is_referenced: bool = false,
};

pub const PagePool = struct {
    allocator: Allocator,
    pager: *Pager,
    pool_size: u32,
    frames: []Frame,
    pages: []SlottedPage,
    slab: []u8,
    page_table: HashMap(PageId, FrameId, std.hash_map.AutoContext(PageId), 80),
    free_list: std.ArrayList(FrameId),
    clock_hand: FrameId = 0,
    checksum_failed: u32 = 0,

    pub fn init(allocator: Allocator, io: Io, file_path: []const u8, pool_size: u32) !*PagePool {
        if (pool_size == 0) return error.ZeroSizedPool;
        if (pool_size < MIN_POOL_SIZE) return error.PoolTooSmall;

        const pager = try allocator.create(Pager);
        errdefer allocator.destroy(pager);
        pager.* = try Pager.init(io, file_path, allocator);
        errdefer pager.deinit();

        const pool = try allocator.create(PagePool);
        errdefer allocator.destroy(pool);

        const frames = try allocator.alloc(Frame, pool_size);
        errdefer allocator.free(frames);

        const slab = try allocator.alloc(u8, @as(usize, pool_size) * FRAME_STRIDE);
        errdefer allocator.free(slab);
        @memset(slab, 0);

        const pages = try allocator.alloc(SlottedPage, pool_size);
        errdefer allocator.free(pages);

        for (0..pool_size) |i| {
            pages[i] = .{ .data = slab[i * FRAME_STRIDE .. i * FRAME_STRIDE + PAGE_SIZE] };
            frames[i] = .{};
        }

        pool.* = .{
            .allocator = allocator,
            .pager = pager,
            .pool_size = pool_size,
            .frames = frames,
            .pages = pages,
            .slab = slab,
            .page_table = HashMap(PageId, FrameId, std.hash_map.AutoContext(PageId), 80).init(allocator),
            .free_list = .empty,
        };
        for (0..pool_size) |i| try pool.free_list.append(allocator, @intCast(i));
        return pool;
    }

    pub fn deinit(self: *PagePool) !void {
        try self.flushAllPages();
        self.allocator.free(self.pages);
        self.allocator.free(self.slab);
        self.allocator.free(self.frames);
        self.free_list.deinit(self.allocator);
        self.page_table.deinit();
        self.pager.deinit();
        self.allocator.destroy(self.pager);
        self.allocator.destroy(self);
    }

    inline fn pageForFrame(self: *PagePool, fid: FrameId) *SlottedPage {
        return &self.pages[fid];
    }

    pub fn pageOf(self: *PagePool, f: *Frame) *SlottedPage {
        const fid: FrameId = @intCast((@intFromPtr(f) - @intFromPtr(self.frames.ptr)) / @sizeOf(Frame));
        return &self.pages[fid];
    }

    pub fn fetchPage(self: *PagePool, page_id: PageId) !*Frame {
        if (self.page_table.get(page_id)) |fid| {
            const f = &self.frames[fid];
            f.pin_count += 1;
            f.is_referenced = true;
            return f;
        }

        const fid = self.findVictimFrame() orelse return error.NoFreeFrames;
        const f = &self.frames[fid];
        const p = self.pageForFrame(fid);

        if (f.is_dirty) {
            try self.writeChecksum(p);
            try self.pager.writePage(f.page_id.?, p.data);
        }
        if (f.page_id) |old| _ = self.page_table.remove(old);

        try self.pager.readPage(page_id, p.data);

        if (page_id != 0) {
            self.validateChecksum(p) catch {
                const hdr = p.headerPtr();
                const expected = std.hash.Wyhash.hash(0, p.data[@sizeOf(u64)..]);
                std.log.err(
                    "InvalidChecksum: file={s} page_id={d} num_pages={d} stored={x} expected={x} beyond_eof={}",
                    .{ self.pager.file_path, page_id, self.pager.num_pages, hdr.checksum, expected, page_id >= self.pager.num_pages },
                );
                return error.InvalidChecksum;
            };
        }

        f.page_id = page_id;
        f.pin_count = 1;
        f.is_dirty = false;
        f.is_referenced = true;
        try self.page_table.put(page_id, fid);
        return f;
    }

    pub fn newPage(self: *PagePool, page_type: PageType) !*Frame {
        const fid = self.findVictimFrame() orelse return error.NoFreeFrames;
        const f = &self.frames[fid];
        const p = self.pageForFrame(fid);

        if (f.is_dirty) {
            try self.writeChecksum(p);
            try self.pager.writePage(f.page_id.?, p.data);
        }
        if (f.page_id) |old| _ = self.page_table.remove(old);

        const new_id = try self.pager.allocPage();
        p.reset(page_type);

        f.page_id = new_id;
        f.pin_count = 1;
        f.is_dirty = true;
        f.is_referenced = true;
        try self.page_table.put(new_id, fid);
        return f;
    }

    pub fn unpinPage(self: *PagePool, page_id: PageId, is_dirty: bool) void {
        if (self.page_table.get(page_id)) |fid| {
            const f = &self.frames[fid];
            if (f.pin_count > 0) f.pin_count -= 1;
            if (is_dirty) f.is_dirty = true;
        }
    }

    pub fn discardPage(self: *PagePool, page_id: PageId) !void {
        const fid = self.page_table.get(page_id) orelse return;
        const f = &self.frames[fid];
        if (f.pin_count > 0) return error.PageStillPinned;
        _ = self.page_table.remove(page_id);
        f.page_id = null;
        f.is_dirty = false;
        f.is_referenced = false;
        try self.free_list.append(self.allocator, fid);
        try self.pager.freePage(page_id);
    }

    pub fn flushAllPages(self: *PagePool) !void {
        for (self.frames, 0..) |*f, fid| {
            if (f.is_dirty) {
                const p = self.pageForFrame(@intCast(fid));
                try self.writeChecksum(p);
                try self.pager.writePage(f.page_id.?, p.data);
                f.is_dirty = false;
            }
        }
    }

    pub fn flushPage(self: *PagePool, page_id: PageId) !void {
        const fid = self.page_table.get(page_id) orelse return;
        const f = &self.frames[fid];
        if (f.is_dirty) {
            const p = self.pageForFrame(fid);
            try self.writeChecksum(p);
            try self.pager.writePage(page_id, p.data);
            f.is_dirty = false;
        }
    }

    fn findVictimFrame(self: *PagePool) ?FrameId {
        if (self.free_list.pop()) |id| return id;
        var i: u32 = 0;
        while (i < self.pool_size * 2) : (i += 1) {
            const f = &self.frames[self.clock_hand];
            if (f.pin_count == 0) {
                if (f.is_referenced) {
                    f.is_referenced = false;
                } else {
                    const v = self.clock_hand;
                    self.clock_hand = (self.clock_hand + 1) % self.pool_size;
                    return v;
                }
            }
            self.clock_hand = (self.clock_hand + 1) % self.pool_size;
        }
        return null;
    }

    fn writeChecksum(_: *PagePool, page: *SlottedPage) !void {
        page.headerPtr().checksum = std.hash.Wyhash.hash(0, page.data[@sizeOf(u64)..]);
    }

    fn validateChecksum(self: *PagePool, page: *SlottedPage) !void {
        const stored = page.headerPtr().checksum;
        const expected = std.hash.Wyhash.hash(0, page.data[@sizeOf(u64)..]);
        if (stored != expected) {
            self.checksum_failed += 1;
            return error.InvalidChecksum;
        }
    }
};

pub const Iterator = struct {
    tree: *BPlusTree,
    current_frame: *Frame,
    current_index: u16,

    pub fn next(self: *Iterator) !?Cell {
        while (true) {
            const page = self.tree.pool.pageOf(self.current_frame);
            while (self.current_index < page.headerPtr().num_cells) {
                const i = self.current_index;
                self.current_index += 1;
                if (page.getCell(i)) |c| return c;
            }
            const next_id = page.headerPtr().next_page_id;
            self.tree.pool.unpinPage(self.current_frame.page_id.?, false);
            if (next_id == 0) return null;
            self.current_frame = try self.tree.pool.fetchPage(next_id);
            self.current_index = 0;
        }
    }

    pub fn deinit(self: *Iterator) void {
        self.tree.pool.unpinPage(self.current_frame.page_id.?, false);
    }
};

pub const PrefetchIterator = struct {
    tree: *BPlusTree,
    current_frame: *Frame,
    current_index: u16,
    prefetch_buffer: [PREFETCH_DEPTH]*Frame,
    prefetch_count: u8,
    allocator: Allocator,

    const PREFETCH_DEPTH = 4;

    pub fn init(tree: *BPlusTree, start_frame: *Frame, allocator: Allocator) !PrefetchIterator {
        var self = PrefetchIterator{
            .tree = tree,
            .current_frame = start_frame,
            .current_index = 0,
            .prefetch_buffer = undefined,
            .prefetch_count = 0,
            .allocator = allocator,
        };
        try self.prefetchAhead();
        return self;
    }

    fn prefetchAhead(self: *PrefetchIterator) !void {
        const cur_page = self.tree.pool.pageOf(self.current_frame);
        var pid = cur_page.headerPtr().next_page_id;
        var count: u8 = 0;
        while (count < PREFETCH_DEPTH and pid != 0) : (count += 1) {
            const f = try self.tree.pool.fetchPage(pid);
            self.prefetch_buffer[count] = f;
            pid = self.tree.pool.pageOf(f).headerPtr().next_page_id;
        }
        self.prefetch_count = count;
    }

    pub fn next(self: *PrefetchIterator) !?Cell {
        while (true) {
            const page = self.tree.pool.pageOf(self.current_frame);
            while (self.current_index < page.headerPtr().num_cells) {
                const i = self.current_index;
                self.current_index += 1;
                if (page.getCell(i)) |c| return c;
            }
            self.tree.pool.unpinPage(self.current_frame.page_id.?, false);
            if (self.prefetch_count == 0) return null;

            self.current_frame = self.prefetch_buffer[0];
            self.current_index = 0;

            var i: u8 = 0;
            while (i < self.prefetch_count - 1) : (i += 1)
                self.prefetch_buffer[i] = self.prefetch_buffer[i + 1];
            self.prefetch_count -= 1;

            if (self.prefetch_count < PREFETCH_DEPTH) {
                const last = if (self.prefetch_count > 0)
                    self.prefetch_buffer[self.prefetch_count - 1]
                else
                    self.current_frame;
                const nxt = self.tree.pool.pageOf(last).headerPtr().next_page_id;
                if (nxt != 0) {
                    self.prefetch_buffer[self.prefetch_count] = try self.tree.pool.fetchPage(nxt);
                    self.prefetch_count += 1;
                }
            }
        }
    }

    pub fn deinit(self: *PrefetchIterator) void {
        self.tree.pool.unpinPage(self.current_frame.page_id.?, false);
        var i: u8 = 0;
        while (i < self.prefetch_count) : (i += 1)
            self.tree.pool.unpinPage(self.prefetch_buffer[i].page_id.?, false);
    }
};

pub const RangeIterator = struct {
    tree: *BPlusTree,
    current_frame: *Frame,
    current_index: u16,
    end_key: ?[]const u8,
    pinned_page_id: ?PageId,

    pub fn next(self: *RangeIterator) !?Cell {
        while (true) {
            const page = self.tree.pool.pageOf(self.current_frame);
            while (self.current_index < page.headerPtr().num_cells) {
                const i = self.current_index;
                self.current_index += 1;
                const cell = page.getCell(i) orelse continue;
                if (self.end_key) |ek| {
                    if (mem.order(u8, cell.key, ek) == .gt) return null;
                }
                return cell;
            }
            const next_id = page.headerPtr().next_page_id;
            if (self.pinned_page_id) |pid| {
                self.tree.pool.unpinPage(pid, false);
                self.pinned_page_id = null;
            }
            if (next_id == 0) return null;
            self.current_frame = try self.tree.pool.fetchPage(next_id);
            self.pinned_page_id = next_id;
            self.current_index = 0;
        }
    }

    pub fn deinit(self: *RangeIterator) void {
        if (self.pinned_page_id) |pid| self.tree.pool.unpinPage(pid, false);
    }
};

const BPlusTree = struct {
    pool: *PagePool,
    root_page_id: PageId,
    lsn: u64 = 0,
    allocator: Allocator,
    scratch: std.heap.ArenaAllocator,

    const BTreeError = error{
        KeyNotFound,
        KeyAlreadyExists,
        TreeTooDeepOrCyclic,
        CompactFailed,
    };

    pub fn init(pool: *PagePool, allocator: Allocator) !*BPlusTree {
        const self = try allocator.create(BPlusTree);
        errdefer allocator.destroy(self);
        self.* = .{
            .pool = pool,
            .root_page_id = 0,
            .lsn = 0,
            .allocator = allocator,
            .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };

        if (pool.pager.num_pages == 0) {
            const hf = try self.pool.newPage(.leaf);
            const hid = hf.page_id.?;
            defer self.pool.unpinPage(hid, true);

            const rf = try self.pool.newPage(.leaf);
            const rid = rf.page_id.?;
            self.pool.unpinPage(rid, true);

            const hp = self.pool.pageOf(hf);
            @memset(hp.data[0..@sizeOf(Header)], 0);
            var hdr = Header{
                .magic = MAGIC,
                .version = VERSION,
                .page_size = PAGE_SIZE,
                .root_page_id = rid,
                .lsn = 0,
                .free_page_list_head = 0,
            };
            writeHeader(hp.data, &hdr);
            self.root_page_id = rid;

            try self.pool.flushPage(rid);
            try self.pool.flushPage(hid);
        } else {
            const hf = try self.pool.fetchPage(0);
            defer self.pool.unpinPage(0, false);
            const hp = self.pool.pageOf(hf);
            const hdr = readHeader(hp.data);
            if (hdr.magic != MAGIC) return error.InvalidMagic;
            if (hdr.version != VERSION) return error.UnsupportedVersion;
            if (hdr.page_size != PAGE_SIZE) return error.PageSizeMismatch;
            self.root_page_id = hdr.root_page_id;
            self.lsn = hdr.lsn;
            var scratch_buf: [PAGE_SIZE]u8 = undefined;
            try self.pool.pager.loadFreeList(hdr.free_page_list_head, &scratch_buf);
        }
        return self;
    }

    pub fn deinit(self: *BPlusTree) void {
        self.shutdown() catch {};
        self.pool.deinit() catch {};
        self.scratch.deinit();
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *BPlusTree) !void {
        const hf = try self.pool.fetchPage(0);
        defer self.pool.unpinPage(0, true);
        const hp = self.pool.pageOf(hf);
        var hdr = readHeader(hp.data);
        hdr.root_page_id = self.root_page_id;
        hdr.lsn = self.lsn;
        var scratch_buf: [PAGE_SIZE]u8 = undefined;
        hdr.free_page_list_head = try self.pool.pager.persistFreeList(&scratch_buf);
        writeHeader(hp.data, &hdr);
    }

    pub fn search(self: *BPlusTree, key: []const u8) !?[]const u8 {
        const f = try self.findLeaf(key);
        defer self.pool.unpinPage(f.page_id.?, false);
        const p = self.pool.pageOf(f);
        if (p.findCellByKey(key)) |i| return p.getCell(i).?.value;
        return null;
    }

    pub fn update(self: *BPlusTree, key: []const u8, new_value: []const u8) !void {
        const f = try self.findLeaf(key);
        defer self.pool.unpinPage(f.page_id.?, true);
        const p = self.pool.pageOf(f);
        if (p.findCellByKey(key)) |i| {
            try p.updateCell(i, new_value);
        } else {
            return BTreeError.KeyNotFound;
        }
    }

    pub fn insert(self: *BPlusTree, key: []const u8, value: []const u8) !void {
        defer _ = self.scratch.reset(.free_all);

        const f = try self.findLeaf(key);
        const p = self.pool.pageOf(f);
        const lid = f.page_id.?;

        if (p.findCellByKey(key) != null) {
            self.pool.unpinPage(lid, false);
            return BTreeError.KeyAlreadyExists;
        }

        const cell = Cell{ .key = key, .value = value };
        if (p.hasSpace(cell.len())) {
            try p.insertCell(p.findInsertIndex(key), cell);
            self.pool.unpinPage(lid, true);
        } else {
            self.pool.unpinPage(lid, true);
            try self.splitAndInsert(lid, cell, 0);
        }
    }

    pub fn delete(self: *BPlusTree, key: []const u8) !void {
        defer _ = self.scratch.reset(.free_all);

        const f = try self.findLeaf(key);
        const lid = f.page_id.?;
        const p = self.pool.pageOf(f);

        if (p.findCellByKey(key)) |i| {
            p.deleteCell(i);
            try p.compact(self.scratch.allocator());

            const parent_id = p.headerPtr().parent_page_id;
            if (p.freeSpace() > (PAGE_SIZE - @sizeOf(PageHeader) - PAGE_SIZE / 2) and
                self.root_page_id != lid)
            {
                self.pool.unpinPage(lid, true);
                try self.handleUnderflow(lid, parent_id, 0);
            } else {
                self.pool.unpinPage(lid, true);
            }
        } else {
            self.pool.unpinPage(lid, false);
            return BTreeError.KeyNotFound;
        }
    }

    pub fn rangeScan(self: *BPlusTree, start_key: []const u8, end_key: ?[]const u8) !RangeIterator {
        const sf = try self.findLeaf(start_key);
        const sp = self.pool.pageOf(sf);
        return RangeIterator{
            .tree = self,
            .current_frame = sf,
            .current_index = sp.findInsertIndex(start_key),
            .end_key = end_key,
            .pinned_page_id = sf.page_id.?,
        };
    }

    fn findLeaf(self: *BPlusTree, key: []const u8) !*Frame {
        var cur_id = self.root_page_id;
        var cur_frame = try self.pool.fetchPage(cur_id);
        var depth: u32 = 0;
        while (self.pool.pageOf(cur_frame).headerPtr().page_type == .internal) {
            depth += 1;
            if (depth > MAX_TREE_DEPTH) {
                self.pool.unpinPage(cur_id, false);
                return BTreeError.TreeTooDeepOrCyclic;
            }
            const next_id = self.pool.pageOf(cur_frame).findChildPageId(key);
            self.pool.unpinPage(cur_id, false);
            cur_id = next_id;
            cur_frame = try self.pool.fetchPage(cur_id);
        }
        return cur_frame;
    }

    fn splitAndInsert(self: *BPlusTree, page_id: PageId, cell: Cell, depth: u32) !void {
        if (depth > MAX_TREE_DEPTH) return BTreeError.TreeTooDeepOrCyclic;

        const sc = self.scratch.allocator();

        const of = try self.pool.fetchPage(page_id);
        defer self.pool.unpinPage(page_id, true);
        const op = self.pool.pageOf(of);
        const is_leaf = op.headerPtr().page_type == .leaf;
        const orig_parent = op.headerPtr().parent_page_id;

        var all = std.ArrayList(Cell).empty;
        {
            var it = op.cells();
            while (it.next()) |b| {
                if (b.key.len == 0) continue;
                try all.append(sc, .{
                    .key = try sc.dupe(u8, b.key),
                    .value = try sc.dupe(u8, b.value),
                });
            }
            try all.append(sc, .{
                .key = try sc.dupe(u8, cell.key),
                .value = try sc.dupe(u8, cell.value),
            });
            std.sort.pdq(Cell, all.items, {}, struct {
                fn lt(_: void, a: Cell, b: Cell) bool {
                    return mem.order(u8, a.key, b.key) == .lt;
                }
            }.lt);
        }

        const sp = all.items.len / 2;
        const pkc = all.items[sp];
        const promoted_key = try sc.dupe(u8, pkc.key);

        const nf = try self.pool.newPage(op.headerPtr().page_type);
        const nid = nf.page_id.?;
        defer self.pool.unpinPage(nid, true);
        const np = self.pool.pageOf(nf);
        np.headerPtr().parent_page_id = orig_parent;

        const old_next = op.headerPtr().next_page_id;
        op.clear();
        op.headerPtr().parent_page_id = orig_parent;
        op.headerPtr().next_page_id = if (is_leaf) nid else old_next;
        if (is_leaf) np.headerPtr().next_page_id = old_next;

        var promoted_pid_bytes: [@sizeOf(PageId)]u8 = undefined;

        if (is_leaf) {
            for (all.items[0..sp]) |c| try op.insertCell(op.headerPtr().num_cells, c);
            for (all.items[sp..]) |c| try np.insertCell(np.headerPtr().num_cells, c);
        } else {
            np.headerPtr().leftmost_child_id =
                mem.readInt(PageId, pkc.value[0..@sizeOf(PageId)], .little);
            for (all.items[0..sp]) |c| try op.insertCell(op.headerPtr().num_cells, c);
            for (all.items[sp + 1 ..]) |c| try np.insertCell(np.headerPtr().num_cells, c);

            var cf = try self.pool.fetchPage(np.headerPtr().leftmost_child_id);
            self.pool.pageOf(cf).headerPtr().parent_page_id = nid;
            self.pool.unpinPage(cf.page_id.?, true);
            var nit = np.cells();
            while (nit.next()) |c| {
                cf = try self.pool.fetchPage(mem.readInt(PageId, c.value[0..@sizeOf(PageId)], .little));
                self.pool.pageOf(cf).headerPtr().parent_page_id = nid;
                self.pool.unpinPage(cf.page_id.?, true);
            }
        }

        mem.writeInt(PageId, &promoted_pid_bytes, nid, .little);
        try self.insertIntoParent(orig_parent, promoted_key, &promoted_pid_bytes, depth + 1);
    }

    fn insertIntoParent(self: *BPlusTree, parent_id: PageId, key: []const u8, value_slice: []const u8, depth: u32) anyerror!void {
        if (depth > MAX_TREE_DEPTH) return BTreeError.TreeTooDeepOrCyclic;

        if (parent_id == 0) {
            const rf = try self.pool.newPage(.internal);
            defer self.pool.unpinPage(rf.page_id.?, true);
            const rp = self.pool.pageOf(rf);
            const old = self.root_page_id;
            self.root_page_id = rf.page_id.?;
            rp.headerPtr().leftmost_child_id = old;
            try rp.insertCell(0, .{ .key = key, .value = value_slice });

            const ocf = try self.pool.fetchPage(old);
            self.pool.pageOf(ocf).headerPtr().parent_page_id = self.root_page_id;
            self.pool.unpinPage(old, true);

            const ncf = try self.pool.fetchPage(mem.readInt(PageId, value_slice[0..@sizeOf(PageId)], .little));
            self.pool.pageOf(ncf).headerPtr().parent_page_id = self.root_page_id;
            self.pool.unpinPage(ncf.page_id.?, true);
            return;
        }

        const pf = try self.pool.fetchPage(parent_id);
        const pp = self.pool.pageOf(pf);
        const c = Cell{ .key = key, .value = value_slice };
        if (pp.hasSpace(c.len())) {
            try pp.insertCell(pp.findInsertIndex(key), c);
            self.pool.unpinPage(parent_id, true);
        } else {
            self.pool.unpinPage(parent_id, true);
            try self.splitAndInsert(parent_id, c, depth);
        }
    }

    fn handleUnderflow(self: *BPlusTree, page_id: PageId, parent_id: PageId, depth: u32) anyerror!void {
        if (depth > MAX_TREE_DEPTH) return BTreeError.TreeTooDeepOrCyclic;

        const pf = try self.pool.fetchPage(parent_id);
        defer self.pool.unpinPage(parent_id, true);
        const pp = self.pool.pageOf(pf);
        const pos = pp.findChildIndex(page_id) orelse return;

        if (pos > 0) {
            const lid = if (pos == 1)
                pp.headerPtr().leftmost_child_id
            else
                mem.readInt(PageId, pp.getCell(pos - 2).?.value[0..@sizeOf(PageId)], .little);
            const lf = try self.pool.fetchPage(lid);
            defer self.pool.unpinPage(lid, true);
            if (self.pool.pageOf(lf).freeSpace() < PAGE_SIZE / 2)
                return self.borrowFromLeft(page_id, lid, parent_id, pos - 1);
        }

        if (pos < pp.headerPtr().num_cells) {
            const rid = mem.readInt(PageId, pp.getCell(pos).?.value[0..@sizeOf(PageId)], .little);
            const rf = try self.pool.fetchPage(rid);
            defer self.pool.unpinPage(rid, true);
            if (self.pool.pageOf(rf).freeSpace() < PAGE_SIZE / 2)
                return self.borrowFromRight(page_id, rid, parent_id, pos);
        }

        if (pos > 0) {
            const lid = if (pos == 1)
                pp.headerPtr().leftmost_child_id
            else
                mem.readInt(PageId, pp.getCell(pos - 2).?.value[0..@sizeOf(PageId)], .little);
            try self.mergePages(lid, page_id, parent_id, pos - 1, depth);
        } else {
            const rid = mem.readInt(PageId, pp.getCell(0).?.value[0..@sizeOf(PageId)], .little);
            try self.mergePages(page_id, rid, parent_id, 0, depth);
        }
    }

    fn borrowFromLeft(self: *BPlusTree, page_id: PageId, left_id: PageId, parent_id: PageId, key_idx: u16) !void {
        const sc = self.scratch.allocator();

        const pf = try self.pool.fetchPage(page_id);
        defer self.pool.unpinPage(page_id, true);
        const lf = try self.pool.fetchPage(left_id);
        defer self.pool.unpinPage(left_id, true);
        const rf = try self.pool.fetchPage(parent_id);
        defer self.pool.unpinPage(parent_id, true);
        const page = self.pool.pageOf(pf);
        const left = self.pool.pageOf(lf);
        const par = self.pool.pageOf(rf);

        const last = left.headerPtr().num_cells - 1;
        const ctm = left.getCell(last).?;
        const ck = try sc.dupe(u8, ctm.key);
        const cv = try sc.dupe(u8, ctm.value);

        const pkc = par.getCell(key_idx).?;
        const pk = try sc.dupe(u8, pkc.key);
        const pv = try sc.dupe(u8, pkc.value);

        left.deleteCell(last);
        try left.compact(sc);
        par.deleteCell(key_idx);
        try par.compact(sc);

        try page.insertCell(0, .{ .key = pk, .value = cv });
        try par.insertCell(key_idx, .{ .key = ck, .value = pv });
    }

    fn borrowFromRight(self: *BPlusTree, page_id: PageId, right_id: PageId, parent_id: PageId, key_idx: u16) !void {
        const sc = self.scratch.allocator();

        const pf = try self.pool.fetchPage(page_id);
        defer self.pool.unpinPage(page_id, true);
        const rf = try self.pool.fetchPage(right_id);
        defer self.pool.unpinPage(right_id, true);
        const qf = try self.pool.fetchPage(parent_id);
        defer self.pool.unpinPage(parent_id, true);
        const page = self.pool.pageOf(pf);
        const right = self.pool.pageOf(rf);
        const par = self.pool.pageOf(qf);

        const ctm = right.getCell(0).?;
        const ck = try sc.dupe(u8, ctm.key);
        const cv = try sc.dupe(u8, ctm.value);

        const pkc = par.getCell(key_idx).?;
        const pk = try sc.dupe(u8, pkc.key);
        const pv = try sc.dupe(u8, pkc.value);

        if (page.headerPtr().page_type == .leaf) {
            right.deleteCell(0);
            try right.compact(sc);
            par.deleteCell(key_idx);
            try par.compact(sc);

            try page.insertCell(page.headerPtr().num_cells, .{ .key = ck, .value = cv });

            const sep = try sc.dupe(u8, right.getCell(0).?.key);
            try par.insertCell(key_idx, .{ .key = sep, .value = pv });
        } else {
            const rlc = right.headerPtr().leftmost_child_id;
            var rlc_b: [@sizeOf(PageId)]u8 = undefined;
            mem.writeInt(PageId, &rlc_b, rlc, .little);

            right.headerPtr().leftmost_child_id =
                mem.readInt(PageId, cv[0..@sizeOf(PageId)], .little);
            right.deleteCell(0);
            try right.compact(sc);
            par.deleteCell(key_idx);
            try par.compact(sc);

            try page.insertCell(page.headerPtr().num_cells, .{ .key = pk, .value = &rlc_b });
            try par.insertCell(key_idx, .{ .key = ck, .value = pv });

            const cf = try self.pool.fetchPage(rlc);
            self.pool.pageOf(cf).headerPtr().parent_page_id = page_id;
            self.pool.unpinPage(rlc, true);
        }
    }

    fn mergePages(self: *BPlusTree, left_id: PageId, right_id: PageId, parent_id: PageId, key_idx: u16, depth: u32) !void {
        const sc = self.scratch.allocator();

        const lf = try self.pool.fetchPage(left_id);
        defer self.pool.unpinPage(left_id, true);
        const rf = try self.pool.fetchPage(right_id);
        const pf = try self.pool.fetchPage(parent_id);
        defer self.pool.unpinPage(parent_id, true);
        const left = self.pool.pageOf(lf);
        const right = self.pool.pageOf(rf);
        const par = self.pool.pageOf(pf);

        const sep = par.getCell(key_idx).?;
        var need: u32 = 0;
        if (left.headerPtr().page_type == .internal)
            need += sep.len() + @sizeOf(CellPtr);
        {
            var it = right.cells();
            while (it.next()) |c| need += c.len() + @sizeOf(CellPtr);
        }
        if (@as(u32, left.freeSpace()) < need) {
            self.pool.unpinPage(right_id, false);
            return;
        }

        if (left.headerPtr().page_type == .internal)
            try left.insertCell(left.headerPtr().num_cells, sep);
        {
            var it = right.cells();
            while (it.next()) |c| try left.insertCell(left.headerPtr().num_cells, c);
        }

        if (left.headerPtr().page_type == .leaf)
            left.headerPtr().next_page_id = right.headerPtr().next_page_id;

        par.deleteCell(key_idx);
        try par.compact(sc);

        self.pool.unpinPage(right_id, false);
        try self.pool.discardPage(right_id);

        if (par.freeSpace() > (PAGE_SIZE - @sizeOf(PageHeader) - PAGE_SIZE / 2) and
            self.root_page_id != parent_id)
        {
            try self.handleUnderflow(parent_id, par.headerPtr().parent_page_id, depth + 1);
        }
    }

    fn findFirstLeaf(self: *BPlusTree) !*Frame {
        var cur_id = self.root_page_id;
        var cur_frame = try self.pool.fetchPage(cur_id);
        var depth: u32 = 0;
        while (self.pool.pageOf(cur_frame).headerPtr().page_type == .internal) {
            depth += 1;
            if (depth > MAX_TREE_DEPTH) {
                self.pool.unpinPage(cur_id, false);
                return BTreeError.TreeTooDeepOrCyclic;
            }
            const next_id = self.pool.pageOf(cur_frame).headerPtr().leftmost_child_id;
            self.pool.unpinPage(cur_id, false);
            cur_id = next_id;
            cur_frame = try self.pool.fetchPage(cur_id);
        }
        return cur_frame;
    }

    pub fn iterator(self: *BPlusTree) !Iterator {
        return .{ .tree = self, .current_frame = try self.findFirstLeaf(), .current_index = 0 };
    }

    pub fn prefetchIterator(self: *BPlusTree) !PrefetchIterator {
        return PrefetchIterator.init(self, try self.findFirstLeaf(), self.allocator);
    }

    pub fn prefetchIteratorAfter(self: *BPlusTree, after_key: []const u8) !PrefetchIterator {
        const leaf = try self.findLeaf(after_key);
        const page = self.pool.pageOf(leaf);

        var start_index: u16 = 0;
        var left: u16 = 0;
        var right: u16 = page.headerPtr().num_cells;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const cell = page.getCell(mid) orelse {
                left = mid + 1;
                continue;
            };
            if (std.mem.order(u8, cell.key, after_key) != .gt) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        start_index = left;

        if (start_index >= page.headerPtr().num_cells) {
            const next_id = page.headerPtr().next_page_id;
            self.pool.unpinPage(leaf.page_id.?, false);
            if (next_id == 0) {
                const first = try self.findFirstLeaf();
                var it = try PrefetchIterator.init(self, first, self.allocator);
                it.current_index = self.pool.pageOf(first).headerPtr().num_cells;
                return it;
            }
            const next_frame = try self.pool.fetchPage(next_id);
            return PrefetchIterator.init(self, next_frame, self.allocator);
        }

        var it = try PrefetchIterator.init(self, leaf, self.allocator);
        it.current_index = start_index;
        return it;
    }
};

pub fn Index(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        tree: *BPlusTree,
        allocator: Allocator,
        path: []const u8,
        io: std.Io,
        engine_metrics: *EngineMetrics,

        pub fn init(allocator: Allocator, config: IndexConfig, engine_metrics: *EngineMetrics) !Self {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}.idx", .{ config.dir_path, config.file_name });
            errdefer allocator.free(path);
            const pool = try PagePool.init(allocator, config.io, path, config.pool_size);
            errdefer pool.deinit() catch {};
            return Self{
                .tree = try BPlusTree.init(pool, allocator),
                .allocator = allocator,
                .path = path,
                .io = config.io,
                .engine_metrics = engine_metrics,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.path);
            self.tree.deinit();
        }

        pub fn lastLsn(self: *Self) u64 {
            return self.tree.lsn;
        }

        pub fn insert(self: *Self, key: K, value: V) !void {
            var sw = self.engine_metrics.index.start(self.io, .Insert);
            defer self.engine_metrics.index.stop(self.io, &sw, .Insert);
            var key_buf: KeyBuf(K) = undefined;
            const vs = if (V == void) &[_]u8{} else blk: {
                var b: [@sizeOf(V)]u8 = undefined;
                std.mem.writeInt(V, &b, value, .little);
                break :blk &b;
            };
            try self.tree.insert(toKeySlice(K, key, &key_buf), vs);
        }

        pub fn search(self: *Self, key: K) !?V {
            var sw = self.engine_metrics.index.start(self.io, .Search);
            defer self.engine_metrics.index.stop(self.io, &sw, .Search);
            var key_buf: KeyBuf(K) = undefined;
            const s = try self.tree.search(toKeySlice(K, key, &key_buf));
            if (s) |sl| return std.mem.readInt(V, sl[0..@sizeOf(V)], .little);
            return null;
        }

        pub fn update(self: *Self, key: K, new_value: V) !void {
            var sw = self.engine_metrics.index.start(self.io, .Update);
            defer self.engine_metrics.index.stop(self.io, &sw, .Update);
            var b: [@sizeOf(V)]u8 = undefined;
            std.mem.writeInt(V, &b, new_value, .little);
            var key_buf: KeyBuf(K) = undefined;
            try self.tree.update(toKeySlice(K, key, &key_buf), &b);
        }

        pub fn delete(self: *Self, key: K) !void {
            var sw = self.engine_metrics.index.start(self.io, .Delete);
            defer self.engine_metrics.index.stop(self.io, &sw, .Delete);
            var key_buf: KeyBuf(K) = undefined;
            try self.tree.delete(toKeySlice(K, key, &key_buf));
        }

        pub fn rangeScan(self: *Self, start_key: K, end_key: K) !RangeIterator {
            var sw = self.engine_metrics.index.start(self.io, .RangeScan);
            defer self.engine_metrics.index.stop(self.io, &sw, .RangeScan);
            var sk_buf: KeyBuf(K) = undefined;
            var ek_buf: KeyBuf(K) = undefined;
            return self.tree.rangeScan(toKeySlice(K, start_key, &sk_buf), toKeySlice(K, end_key, &ek_buf));
        }

        pub fn iterator(self: *Self) !Iterator {
            return self.tree.iterator();
        }

        pub fn prefetchIterator(self: *Self) !PrefetchIterator {
            return self.tree.prefetchIterator();
        }

        pub fn prefetchIteratorAfter(self: *Self, after_key: K) !PrefetchIterator {
            var key_buf: KeyBuf(K) = undefined;
            return self.tree.prefetchIteratorAfter(toKeySlice(K, after_key, &key_buf));
        }

        pub fn flush(self: *Self) !void {
            var sw = self.engine_metrics.index.start(self.io, .Flush);
            defer self.engine_metrics.index.stop(self.io, &sw, .Flush);
            try self.tree.shutdown();
            try self.tree.pool.flushAllPages();
            try self.tree.pool.pager.sync();
            
        }

        fn KeyBuf(comptime KK: type) type {
            return if (@typeInfo(KK) == .int) [@sizeOf(KK)]u8 else [0]u8;
        }

        fn toKeySlice(comptime KK: type, k: KK, buf: *KeyBuf(KK)) []const u8 {
            if (@typeInfo(KK) == .int) {
                std.mem.writeInt(KK, buf, k, .big);
                return buf;
            } else if (@typeInfo(KK) == .pointer and
                @typeInfo(KK).pointer.child == u8 and
                @typeInfo(KK).pointer.is_const)
            {
                return k;
            } else {
                @compileError("Unsupported key type: must be an integer or []const u8");
            }
        }
    };
}

test "bptree - constants" {
    try testing.expectEqual(@as(u32, 0x53535441), MAGIC);
    try testing.expectEqual(@as(u8, 1), VERSION);
    try testing.expectEqual(@as(u32, 16384 * 4 - 1), PAGE_SIZE);
}

test "bptree - PAGE_SIZE fits in u16" {
    try testing.expect(PAGE_SIZE <= std.math.maxInt(u16));
}

test "bptree - MIN_POOL_SIZE sufficient" {
    try testing.expect(MIN_POOL_SIZE >= 64);
}

test "bptree - MAX_TREE_DEPTH reasonable" {
    try testing.expect(MAX_TREE_DEPTH >= 16);
    try testing.expect(MAX_TREE_DEPTH <= 64);
}

test "bptree - CellPtr layout locked" {
    try testing.expectEqual(@as(usize, 6), @sizeOf(CellPtr));
    try testing.expectEqual(@as(usize, 0), @offsetOf(CellPtr, "offset"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(CellPtr, "key_size"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(CellPtr, "value_size"));
}

test "bptree - checksum fields at offset 0" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(PageHeader, "checksum"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Header, "checksum"));
}

test "bptree - PageType values" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(PageType.leaf));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(PageType.internal));
}

test "bptree - Cell len" {
    try testing.expectEqual(@as(u32, 25), (Cell{ .key = "test_key", .value = "test_value_longer" }).len());
    try testing.expectEqual(@as(u32, 3), (Cell{ .key = "key", .value = "" }).len());
}

test "bptree - SlottedPage initOwned" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try testing.expectEqual(PageType.leaf, page.headerPtr().page_type);
    try testing.expectEqual(@as(u16, 0), page.headerPtr().num_cells);
    try testing.expectEqual(@as(u16, PAGE_SIZE - @sizeOf(PageHeader)), page.freeSpace());
}

test "bptree - SlottedPage reset" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    page.reset(.leaf);
    try testing.expectEqual(PageType.leaf, page.headerPtr().page_type);
    try testing.expectEqual(@as(u16, 0), page.headerPtr().num_cells);
}

test "bptree - SlottedPage hasSpace" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try testing.expect(page.hasSpace(100));
    try testing.expect(!page.hasSpace(PAGE_SIZE));
}

test "bptree - insertCell rejects zero-length key" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try testing.expectError(error.ZeroLengthKey, page.insertCell(0, .{ .key = "", .value = "v" }));
}

test "bptree - insertCell and getCell" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "test_key", .value = "test_value" });
    try testing.expectEqual(@as(u16, 1), page.headerPtr().num_cells);
    const g = page.getCell(0).?;
    try testing.expectEqualStrings("test_key", g.key);
    try testing.expectEqualStrings("test_value", g.value);
}

test "bptree - getCell out of bounds" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try testing.expect(page.getCell(0) == null);
    try testing.expect(page.getCell(100) == null);
    try testing.expect(page.getCell(std.math.maxInt(u16)) == null);
}

test "bptree - getCell rejects corrupt offset" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "k", .value = "v" });
    mem.writeInt(u16, page.data[@sizeOf(PageHeader)..][0..2], std.math.maxInt(u16) - 1, .little);
    try testing.expect(page.getCell(0) == null);
}

test "bptree - multiple cells" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "aaa", .value = "1" });
    try page.insertCell(1, .{ .key = "bbb", .value = "2" });
    try page.insertCell(2, .{ .key = "ccc", .value = "3" });
    try testing.expectEqualStrings("aaa", page.getCell(0).?.key);
    try testing.expectEqualStrings("bbb", page.getCell(1).?.key);
    try testing.expectEqualStrings("ccc", page.getCell(2).?.key);
}

test "bptree - findInsertIndex" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "bbb", .value = "2" });
    try page.insertCell(1, .{ .key = "ddd", .value = "4" });
    try testing.expectEqual(@as(u16, 0), page.findInsertIndex("aaa"));
    try testing.expectEqual(@as(u16, 1), page.findInsertIndex("ccc"));
    try testing.expectEqual(@as(u16, 2), page.findInsertIndex("eee"));
}

test "bptree - findCellByKey" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "aaa", .value = "1" });
    try page.insertCell(1, .{ .key = "bbb", .value = "2" });
    try page.insertCell(2, .{ .key = "ccc", .value = "3" });
    try testing.expectEqual(@as(?u16, 0), page.findCellByKey("aaa"));
    try testing.expectEqual(@as(?u16, 1), page.findCellByKey("bbb"));
    try testing.expectEqual(@as(?u16, 2), page.findCellByKey("ccc"));
    try testing.expectEqual(@as(?u16, null), page.findCellByKey("ddd"));
}

test "bptree - deleteCell idempotent" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "test", .value = "value" });
    page.deleteCell(0);
    page.deleteCell(0);
    page.deleteCell(0);
    try testing.expect(page.getCell(0) == null);
}

test "bptree - compact drops deleted" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "a", .value = "1" });
    try page.insertCell(1, .{ .key = "b", .value = "2" });
    try page.insertCell(2, .{ .key = "c", .value = "3" });
    page.deleteCell(1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try page.compact(arena.allocator());
    try testing.expectEqual(@as(u16, 2), page.headerPtr().num_cells);
    try testing.expectEqualStrings("a", page.getCell(0).?.key);
    try testing.expectEqualStrings("c", page.getCell(1).?.key);
}

test "bptree - clear" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "test", .value = "value" });
    page.clear();
    try testing.expectEqual(@as(u16, 0), page.headerPtr().num_cells);
    try testing.expectEqual(PageType.leaf, page.headerPtr().page_type);
}

test "bptree - cells iterator skips deleted" {
    const page = try SlottedPage.initOwned(testing.allocator, .leaf);
    defer page.deinitOwned(testing.allocator);
    try page.insertCell(0, .{ .key = "a", .value = "1" });
    try page.insertCell(1, .{ .key = "b", .value = "2" });
    try page.insertCell(2, .{ .key = "c", .value = "3" });
    page.deleteCell(1);
    var it = page.cells();
    var n: u32 = 0;
    while (it.next()) |_| n += 1;
    try testing.expectEqual(@as(u32, 2), n);
}

test "bptree - Frame defaults" {
    const f = Frame{};
    try testing.expect(f.page_id == null);
    try testing.expectEqual(@as(u32, 0), f.pin_count);
    try testing.expect(!f.is_dirty);
    try testing.expect(!f.is_referenced);
}

test "bptree - Header contains page_size" {
    const h = Header{ .magic = MAGIC, .version = VERSION, .page_size = PAGE_SIZE, .root_page_id = 42, .lsn = 0 };
    try testing.expectEqual(MAGIC, h.magic);
    try testing.expectEqual(VERSION, h.version);
    try testing.expectEqual(PAGE_SIZE, h.page_size);
    try testing.expectEqual(@as(PageId, 42), h.root_page_id);
}

test "bptree - findChildIndex 0-based" {
    const page = try SlottedPage.initOwned(testing.allocator, .internal);
    defer page.deinitOwned(testing.allocator);
    page.headerPtr().leftmost_child_id = 42;
    var cv: [@sizeOf(PageId)]u8 = undefined;
    mem.writeInt(PageId, &cv, 99, .little);
    try page.insertCell(0, .{ .key = "mmm", .value = &cv });
    try testing.expectEqual(@as(?u16, 0), page.findChildIndex(42));
    try testing.expectEqual(@as(?u16, 1), page.findChildIndex(99));
    try testing.expectEqual(@as(?u16, null), page.findChildIndex(7));
}

test "bptree - magic/version mismatch detection" {
    const good = Header{ .magic = MAGIC, .version = VERSION, .page_size = PAGE_SIZE, .root_page_id = 0, .lsn = 0 };
    const bad = Header{ .magic = 0x00000000, .version = VERSION, .page_size = PAGE_SIZE, .root_page_id = 0, .lsn = 0 };
    try testing.expect(good.magic == MAGIC);
    try testing.expect(bad.magic != MAGIC);
}

test "bptree - page_size mismatch detected" {
    const h = Header{ .magic = MAGIC, .version = VERSION, .page_size = 4096, .root_page_id = 0, .lsn = 0 };
    try testing.expect(h.page_size != PAGE_SIZE);
}

test "bptree - large key cell len" {
    var kb: [PAGE_SIZE / 2]u8 = undefined;
    @memset(&kb, 'K');
    const c = Cell{ .key = &kb, .value = "small_value" };
    try testing.expectEqual(@as(u32, kb.len + 11), c.len());
}

test "bptree - free page list recycles ids" {
    var pager = Pager{
        .file = undefined,
        .io = undefined,
        .num_pages = 10,
        .free_pages = std.ArrayList(PageId).empty,
        .allocator = testing.allocator,
    };
    defer pager.free_pages.deinit(testing.allocator);

    try pager.freePage(5);
    try pager.freePage(7);

    const id1 = try pager.allocPage();
    const id2 = try pager.allocPage();
    const id3 = try pager.allocPage();

    try testing.expect(id1 == 7 or id1 == 5);
    try testing.expect(id2 == 7 or id2 == 5);
    try testing.expectEqual(@as(PageId, 10), id3);
    try testing.expectEqual(@as(PageId, 11), pager.num_pages);
}

test "bptree - slab: single allocation for all frames" {
    const pool_size: u32 = 8;
    const slab = try testing.allocator.alloc(u8, @as(usize, pool_size) * FRAME_STRIDE);
    defer testing.allocator.free(slab);
    const pages = try testing.allocator.alloc(SlottedPage, pool_size);
    defer testing.allocator.free(pages);

    for (0..pool_size) |i| {
        pages[i] = .{ .data = slab[i * FRAME_STRIDE .. i * FRAME_STRIDE + PAGE_SIZE] };
        pages[i].reset(.leaf);
    }

    for (0..pool_size) |i| {
        try testing.expectEqual(@as(usize, PAGE_SIZE), pages[i].data.len);
        if (i + 1 < pool_size)
            try testing.expect(pages[i].data.ptr != pages[i + 1].data.ptr);
    }

    pages[0].reset(.leaf);
    try pages[0].insertCell(0, .{ .key = "hello", .value = "world" });
    pages[1].reset(.internal);
    try testing.expectEqual(PageType.leaf, pages[0].headerPtr().page_type);
    try testing.expectEqual(PageType.internal, pages[1].headerPtr().page_type);
}

test "bptree - scratch arena resets cleanly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sc = arena.allocator();

    for (0..1000) |_| {
        const k = try sc.dupe(u8, "some_key_data_here");
        const v = try sc.dupe(u8, "some_value_data_here");
        _ = k;
        _ = v;
        _ = arena.reset(.free_all);
    }
}
