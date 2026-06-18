const std = @import("std");
const Allocator = std.mem.Allocator;
const FieldValue = @import("field_extractor.zig").FieldValue;

pub const Operator = enum {
    eq,
    ne,
    gt,
    gte,
    lt,
    lte,
    contains,
    starts_with,
    in,
    exists,
    regex,
    between,
};

pub const Predicate = struct {
    field_name: []const u8,
    operator: Operator,
    value: FieldValue,
    in_values: ?[]FieldValue = null,
    regex_pattern: ?[]const u8 = null,
    upper_value: ?FieldValue = null,

    pub fn evaluate(self: *const Predicate, field_value: FieldValue) bool {
        return switch (self.operator) {
            .eq => self.evaluateEq(field_value),
            .ne => !self.evaluateEq(field_value),
            .gt => self.evaluateGt(field_value),
            .gte => self.evaluateGt(field_value) or self.evaluateEq(field_value),
            .lt => self.evaluateLt(field_value),
            .lte => self.evaluateLt(field_value) or self.evaluateEq(field_value),
            .contains => self.evaluateContains(field_value),
            .starts_with => self.evaluateStartsWith(field_value),
            .in => self.evaluateIn(field_value),
            .exists => true,
            .regex => self.evaluateRegex(field_value),
            .between => self.evaluateBetween(field_value),
        };
    }

    fn evaluateEq(self: *const Predicate, field_value: FieldValue) bool {
        return switch (self.value) {
            .string => |expected| switch (field_value) {
                .string => |actual| std.mem.eql(u8, expected, actual),
                else => false,
            },
            .i64_val => |expected| switch (field_value) {
                .i64_val => |actual| expected == actual,
                .u64_val => |actual| expected >= 0 and @as(u64, @intCast(expected)) == actual,
                else => false,
            },
            .u64_val => |expected| switch (field_value) {
                .u64_val => |actual| expected == actual,
                .i64_val => |actual| actual >= 0 and expected == @as(u64, @intCast(actual)),
                else => false,
            },
            .f64_val => |expected| switch (field_value) {
                .f64_val => |actual| expected == actual,
                else => false,
            },
            .bool_val => |expected| switch (field_value) {
                .bool_val => |actual| expected == actual,
                else => false,
            },
            else => false,
        };
    }

    fn evaluateGt(self: *const Predicate, field_value: FieldValue) bool {
        return switch (self.value) {
            .i64_val => |expected| switch (field_value) {
                .i64_val => |actual| actual > expected,
                .u64_val => |actual| @as(i64, @intCast(actual)) > expected,
                else => false,
            },
            .u64_val => |expected| switch (field_value) {
                .u64_val => |actual| actual > expected,
                .i64_val => |actual| actual > 0 and @as(u64, @intCast(actual)) > expected,
                else => false,
            },
            .f64_val => |expected| switch (field_value) {
                .f64_val => |actual| actual > expected,
                else => false,
            },
            else => false,
        };
    }

    fn evaluateLt(self: *const Predicate, field_value: FieldValue) bool {
        return switch (self.value) {
            .i64_val => |expected| switch (field_value) {
                .i64_val => |actual| actual < expected,
                .u64_val => |actual| @as(i64, @intCast(actual)) < expected,
                else => false,
            },
            .u64_val => |expected| switch (field_value) {
                .u64_val => |actual| actual < expected,
                .i64_val => |actual| actual > 0 and @as(u64, @intCast(actual)) < expected,
                else => false,
            },
            .f64_val => |expected| switch (field_value) {
                .f64_val => |actual| actual < expected,
                else => false,
            },
            else => false,
        };
    }

    fn evaluateContains(self: *const Predicate, field_value: FieldValue) bool {
        return switch (self.value) {
            .string => |needle| switch (field_value) {
                .string => |haystack| std.mem.indexOf(u8, haystack, needle) != null,
                else => false,
            },
            else => false,
        };
    }

    fn evaluateStartsWith(self: *const Predicate, field_value: FieldValue) bool {
        return switch (self.value) {
            .string => |prefix| switch (field_value) {
                .string => |actual| std.mem.startsWith(u8, actual, prefix),
                else => false,
            },
            else => false,
        };
    }

    fn evaluateIn(self: *const Predicate, field_value: FieldValue) bool {
        const vals = self.in_values orelse return false;
        for (vals) |v| {
            const matches = switch (v) {
                .string => |s| switch (field_value) {
                    .string => |actual| std.mem.eql(u8, s, actual),
                    else => false,
                },
                .i64_val => |expected| switch (field_value) {
                    .i64_val => |actual| expected == actual,
                    .i32_val => |actual| expected == @as(i64, actual),
                    .u64_val => |actual| expected >= 0 and @as(u64, @intCast(expected)) == actual,
                    else => false,
                },
                .f64_val => |expected| switch (field_value) {
                    .f64_val => |actual| expected == actual,
                    else => false,
                },
                .bool_val => |expected| switch (field_value) {
                    .bool_val => |actual| expected == actual,
                    else => false,
                },
                else => false,
            };
            if (matches) return true;
        }
        return false;
    }

    fn evaluateRegex(self: *const Predicate, field_value: FieldValue) bool {
        const pattern = self.regex_pattern orelse return false;
        const actual = switch (field_value) {
            .string => |s| s,
            else => return false,
        };
        return simpleRegexMatch(actual, pattern);
    }

    fn evaluateBetween(self: *const Predicate, field_value: FieldValue) bool {
        const upper = self.upper_value orelse return false;
        const gte_lower = self.evaluateGt(field_value) or self.evaluateEq(field_value);
        if (!gte_lower) return false;
        const upper_pred = Predicate{
            .field_name = self.field_name,
            .operator = .lte,
            .value = upper,
        };
        return upper_pred.evaluateLt(field_value) or upper_pred.evaluateEq(field_value);
    }
};

pub fn simpleRegexMatch(haystack: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern.len > 256) return false;
    const starts_anchor = pattern[0] == '^';
    const ends_anchor = pattern[pattern.len - 1] == '$';
    var core = pattern;
    if (starts_anchor) core = core[1..];
    if (ends_anchor and core.len > 0) core = core[0 .. core.len - 1];

    if (starts_anchor and ends_anchor) {
        return std.mem.eql(u8, haystack, core);
    } else if (starts_anchor) {
        return std.mem.startsWith(u8, haystack, core);
    } else if (ends_anchor) {
        return std.mem.endsWith(u8, haystack, core);
    } else {
        return std.mem.indexOf(u8, haystack, core) != null;
    }
}

pub const LogicalOperator = enum {
    and_op,
    or_op,
    not_op,
};

pub const QueryCondition = union(enum) {
    predicate: Predicate,
    compound: struct {
        operator: LogicalOperator,
        conditions: []QueryCondition,
    },

    pub fn evaluate(self: *const QueryCondition, document: anytype, allocator: Allocator) !bool {
        return switch (self.*) {
            .predicate => |pred| {
                const field_value = try self.extractFieldValue(document, pred.field_name, allocator);
                defer field_value.deinit(allocator);
                return pred.evaluate(field_value);
            },
            .compound => |compound| {
                switch (compound.operator) {
                    .and_op => {
                        for (compound.conditions) |*cond| {
                            if (!try cond.evaluate(document, allocator)) {
                                return false;
                            }
                        }
                        return true;
                    },
                    .or_op => {
                        for (compound.conditions) |*cond| {
                            if (try cond.evaluate(document, allocator)) {
                                return true;
                            }
                        }
                        return false;
                    },
                    .not_op => {
                        if (compound.conditions.len > 0) {
                            return !try compound.conditions[0].evaluate(document, allocator);
                        }
                        return true;
                    },
                }
            },
        };
    }

    fn extractFieldValue(self: *const QueryCondition, document: anytype, field_name: []const u8, allocator: Allocator) !FieldValue {
        _ = self;
        _ = document;
        _ = allocator;

        return FieldValue{ .string = field_name };
    }
};

pub const AggregateFunction = enum {
    count,
    sum,
    avg,
    min,
    max,
};

pub const Aggregation = struct {
    function: AggregateFunction,
    field_name: ?[]const u8,

    pub fn aggregate(self: *const Aggregation, values: []const FieldValue) !AggregateResult {
        return switch (self.function) {
            .count => AggregateResult{ .int = @intCast(values.len) },
            .sum => try self.sum(values),
            .avg => try self.avg(values),
            .min => try self.min(values),
            .max => try self.max(values),
        };
    }

    fn sum(self: *const Aggregation, values: []const FieldValue) !AggregateResult {
        _ = self;
        var total: i64 = 0;
        for (values) |value| {
            switch (value) {
                .int => |v| total += v,
                .float => |v| total += @intFromFloat(v),
                else => {},
            }
        }
        return AggregateResult{ .int = total };
    }

    fn avg(self: *const Aggregation, values: []const FieldValue) !AggregateResult {
        if (values.len == 0) return AggregateResult{ .float = 0.0 };

        const sum_result = try self.sum(values);
        return AggregateResult{
            .float = @as(f64, @floatFromInt(sum_result.int)) / @as(f64, @floatFromInt(values.len)),
        };
    }

    fn min(self: *const Aggregation, values: []const FieldValue) !AggregateResult {
        _ = self;
        if (values.len == 0) return error.NoValues;

        var min_val: i64 = std.math.maxInt(i64);
        for (values) |value| {
            switch (value) {
                .int => |v| {
                    if (v < min_val) min_val = v;
                },
                else => {},
            }
        }
        return AggregateResult{ .int = min_val };
    }

    fn max(self: *const Aggregation, values: []const FieldValue) !AggregateResult {
        _ = self;
        if (values.len == 0) return error.NoValues;

        var max_val: i64 = std.math.minInt(i64);
        for (values) |value| {
            switch (value) {
                .int => |v| {
                    if (v > max_val) max_val = v;
                },
                else => {},
            }
        }
        return AggregateResult{ .int = max_val };
    }
};

pub const AggregateResult = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
};

pub const AggregationSpec = struct {
    name: []const u8,
    function: AggregateFunction,
    field_name: ?[]const u8,
};

pub const AccumulatorState = struct {
    function: AggregateFunction,
    count: u64 = 0,
    sum: f64 = 0,
    min: ?f64 = null,
    max: ?f64 = null,

    pub fn init(func: AggregateFunction) AccumulatorState {
        return .{ .function = func };
    }

    pub fn accumulate(self: *AccumulatorState, value: ?FieldValue) void {
        switch (self.function) {
            .count => self.count += 1,
            .sum, .avg => {
                if (value) |v| {
                    if (v.toF64()) |f| {
                        self.sum += f;
                        self.count += 1;
                    }
                }
            },
            .min => {
                if (value) |v| {
                    if (v.toF64()) |f| {
                        if (self.min == null or f < self.min.?) {
                            self.min = f;
                        }
                        self.count += 1;
                    }
                }
            },
            .max => {
                if (value) |v| {
                    if (v.toF64()) |f| {
                        if (self.max == null or f > self.max.?) {
                            self.max = f;
                        }
                        self.count += 1;
                    }
                }
            },
        }
    }

    pub fn finalize(self: *const AccumulatorState) AggregateResult {
        return switch (self.function) {
            .count => .{ .int = @intCast(self.count) },
            .sum => .{ .float = self.sum },
            .avg => .{ .float = if (self.count > 0) self.sum / @as(f64, @floatFromInt(self.count)) else 0 },
            .min => .{ .float = self.min orelse 0 },
            .max => .{ .float = self.max orelse 0 },
        };
    }
};

pub const GroupAccumulator = struct {
    accumulators: std.StringHashMap(AccumulatorState),
    allocator: Allocator,

    pub fn init(allocator: Allocator) GroupAccumulator {
        return .{
            .accumulators = std.StringHashMap(AccumulatorState).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GroupAccumulator) void {
        self.accumulators.deinit();
    }

    pub fn update(self: *GroupAccumulator, name: []const u8, func: AggregateFunction, value: ?FieldValue) !void {
        const gop = try self.accumulators.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = AccumulatorState.init(func);
        }
        gop.value_ptr.accumulate(value);
    }

    pub fn getResult(self: *const GroupAccumulator, name: []const u8) ?AggregateResult {
        if (self.accumulators.get(name)) |acc| {
            return acc.finalize();
        }
        return null;
    }
};

pub const Query = struct {
    allocator: Allocator,
    conditions: ?QueryCondition = null,
    aggregations: []Aggregation = &[_]Aggregation{},
    order_by: ?OrderBy = null,
    limit: ?usize = null,
    offset: usize = 0,

    pub fn init(allocator: Allocator) Query {
        return Query{
            .allocator = allocator,
        };
    }

    pub fn where(self: *Query, field_name: []const u8, operator: Operator, value: FieldValue) !void {
        const pred = Predicate{
            .field_name = field_name,
            .operator = operator,
            .value = value,
        };

        if (self.conditions == null) {
            self.conditions = QueryCondition{ .predicate = pred };
        } else {
            var conditions_list = try self.allocator.alloc(QueryCondition, 2);
            conditions_list[0] = self.conditions.?;
            conditions_list[1] = QueryCondition{ .predicate = pred };

            self.conditions = QueryCondition{
                .compound = .{
                    .operator = .and_op,
                    .conditions = conditions_list,
                },
            };
        }
    }

    pub fn execute(self: *Query, db: anytype) !QueryResult {
        _ = db;
        const result = QueryResult{
            .allocator = self.allocator,
            .documents = std.ArrayList([]const u8).init(self.allocator),
        };

        return result;
    }
};

pub const OrderBy = struct {
    field_name: []const u8,
    ascending: bool = true,
};

pub const QueryResult = struct {
    allocator: Allocator,
    documents: std.ArrayList([]const u8),

    pub fn deinit(self: *QueryResult) void {
        for (self.documents.items) |doc| {
            self.allocator.free(doc);
        }
        self.documents.deinit();
    }
};

pub const QueryPlanner = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) QueryPlanner {
        return QueryPlanner{
            .allocator = allocator,
        };
    }

    pub fn plan(self: *QueryPlanner, query: Query) !QueryPlan {
        _ = self;
        return QueryPlan{
            .strategy = if (query.conditions != null) .index_scan else .full_scan,
            .estimated_cost = 100,
        };
    }
};

pub const ExecutionStrategy = enum {
    full_scan,
    index_scan,
    multi_index,
};

pub const QueryPlan = struct {
    strategy: ExecutionStrategy,
    estimated_cost: u64,
};

pub const SortSpec = struct {
    field: []const u8,
    ascending: bool,
};

pub const ParsedQuery = struct {
    allocator: Allocator,
    predicates: std.ArrayList(Predicate),
    sort_field: ?[]const u8 = null,
    sort_ascending: bool = true,
    sort_fields: std.ArrayList(SortSpec) = .empty,
    limit: ?u32 = null,
    offset: u32 = 0,
    or_predicates: std.ArrayList(std.ArrayList(Predicate)) = .empty,
    projection_fields: ?[][]const u8 = null,
    aggregations: std.ArrayList(AggregationSpec) = .empty,
    group_by_fields: ?[][]const u8 = null,
    is_aggregation_query: bool = false,
    after_key: ?u128 = null,

    pub fn init(allocator: Allocator) ParsedQuery {
        return .{
            .allocator = allocator,
            .predicates = std.ArrayList(Predicate).empty,
            .aggregations = std.ArrayList(AggregationSpec).empty,
        };
    }

    pub fn deinit(self: *ParsedQuery) void {
        for (self.predicates.items) |pred| {
            self.freePredicate(pred);
        }
        self.predicates.deinit(self.allocator);
        for (self.or_predicates.items) |*group| {
            for (group.items) |pred| {
                self.freePredicate(pred);
            }
            group.deinit(self.allocator);
        }
        self.or_predicates.deinit(self.allocator);
        if (self.projection_fields) |fields| {
            for (fields) |f| {
                self.allocator.free(f);
            }
            self.allocator.free(fields);
        }
        if (self.sort_field) |sf| {
            self.allocator.free(sf);
        }
        for (self.sort_fields.items) |spec| {
            self.allocator.free(spec.field);
        }
        self.sort_fields.deinit(self.allocator);
        for (self.aggregations.items) |agg| {
            self.allocator.free(agg.name);
            if (agg.field_name) |fn_name| {
                self.allocator.free(fn_name);
            }
        }
        self.aggregations.deinit(self.allocator);
        if (self.group_by_fields) |fields| {
            for (fields) |f| {
                self.allocator.free(f);
            }
            self.allocator.free(fields);
        }
    }

    pub fn freePredicate(self: *const ParsedQuery, pred: Predicate) void {
        self.allocator.free(pred.field_name);
        if (pred.operator != .regex) {
            if (pred.value == .string) {
                self.allocator.free(pred.value.string);
            }
        } else {
            if (pred.regex_pattern) |rp| {
                self.allocator.free(rp);
            }
        }
        if (pred.in_values) |vals| {
            for (vals) |v| {
                if (v == .string) self.allocator.free(v.string);
            }
            self.allocator.free(vals);
        }
    }

    pub fn getBestIndexPredicate(self: *const ParsedQuery) ?Predicate {
        for (self.predicates.items) |pred| {
            if (pred.operator == .eq) return pred;
        }
        for (self.predicates.items) |pred| {
            if (pred.operator == .gt or pred.operator == .gte or
                pred.operator == .lt or pred.operator == .lte)
            {
                return pred;
            }
        }
        return null;
    }

    pub fn getBestEqIndexPredicate(self: *const ParsedQuery) ?Predicate {
        for (self.predicates.items) |pred| {
            if (pred.operator == .eq) return pred;
        }
        return null;
    }

    pub const IndexStrategy = union(enum) {
        eq: Predicate,
        range: struct {
            field_name: []const u8,
            min_val: ?FieldValue,
            max_val: ?FieldValue,
            min_inclusive: bool,
            max_inclusive: bool,
        },
        in_list: struct {
            field_name: []const u8,
            values: []FieldValue,
        },
    };

    pub fn getBestIndexStrategy(self: *const ParsedQuery) ?IndexStrategy {
        for (self.predicates.items) |pred| {
            if (pred.operator == .eq) return .{ .eq = pred };
        }

        for (self.predicates.items) |pred| {
            if (pred.operator == .in) {
                if (pred.in_values) |vals| {
                    return .{ .in_list = .{
                        .field_name = pred.field_name,
                        .values = vals,
                    } };
                }
            }
        }

        for (self.predicates.items) |pred| {
            if (pred.operator == .between) {
                if (pred.upper_value) |upper| {
                    return .{ .range = .{
                        .field_name = pred.field_name,
                        .min_val = pred.value,
                        .max_val = upper,
                        .min_inclusive = true,
                        .max_inclusive = true,
                    } };
                }
            }
        }

        var range_field: ?[]const u8 = null;
        for (self.predicates.items) |pred| {
            if (pred.operator == .gt or pred.operator == .gte or
                pred.operator == .lt or pred.operator == .lte)
            {
                range_field = pred.field_name;
                break;
            }
        }

        if (range_field) |field| {
            var min_val: ?FieldValue = null;
            var max_val: ?FieldValue = null;
            var min_inclusive: bool = false;
            var max_inclusive: bool = false;

            for (self.predicates.items) |pred| {
                if (!std.mem.eql(u8, pred.field_name, field)) continue;
                switch (pred.operator) {
                    .gt => {
                        min_val = pred.value;
                        min_inclusive = false;
                    },
                    .gte => {
                        min_val = pred.value;
                        min_inclusive = true;
                    },
                    .lt => {
                        max_val = pred.value;
                        max_inclusive = false;
                    },
                    .lte => {
                        max_val = pred.value;
                        max_inclusive = true;
                    },
                    else => {},
                }
            }

            return .{ .range = .{
                .field_name = field,
                .min_val = min_val,
                .max_val = max_val,
                .min_inclusive = min_inclusive,
                .max_inclusive = max_inclusive,
            } };
        }

        return null;
    }

    pub fn getRangeBounds(self: *const ParsedQuery, field_name: []const u8) struct { min: ?i64, max: ?i64, min_inclusive: bool, max_inclusive: bool } {
        var result: struct { min: ?i64, max: ?i64, min_inclusive: bool, max_inclusive: bool } = .{
            .min = null,
            .max = null,
            .min_inclusive = false,
            .max_inclusive = false,
        };

        for (self.predicates.items) |pred| {
            if (!std.mem.eql(u8, pred.field_name, field_name)) continue;

            switch (pred.operator) {
                .gt => {
                    if (pred.value == .int) {
                        result.min = pred.value.int;
                        result.min_inclusive = false;
                    }
                },
                .gte => {
                    if (pred.value == .int) {
                        result.min = pred.value.int;
                        result.min_inclusive = true;
                    }
                },
                .lt => {
                    if (pred.value == .int) {
                        result.max = pred.value.int;
                        result.max_inclusive = false;
                    }
                },
                .lte => {
                    if (pred.value == .int) {
                        result.max = pred.value.int;
                        result.max_inclusive = true;
                    }
                },
                .eq => {
                    if (pred.value == .int) {
                        result.min = pred.value.int;
                        result.max = pred.value.int;
                        result.min_inclusive = true;
                        result.max_inclusive = true;
                    }
                },
                else => {},
            }
        }
        return result;
    }
};

pub fn parseJsonQuery(allocator: Allocator, json_str: []const u8) !ParsedQuery {
    var query = ParsedQuery.init(allocator);
    errdefer query.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return query;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return query;

    if (root.object.get("filter")) |filter_val| {
        if (filter_val == .object) {
            try parseFilterObject(&query, filter_val.object);
        }
    }

    if (root.object.get("sort")) |sort_val| {
        if (sort_val == .object) {
            var it = sort_val.object.iterator();
            if (it.next()) |entry| {
                query.sort_field = try allocator.dupe(u8, entry.key_ptr.*);
                const asc = if (entry.value_ptr.* == .integer) entry.value_ptr.integer >= 0 else true;
                query.sort_ascending = asc;
                try query.sort_fields.append(allocator, .{
                    .field = try allocator.dupe(u8, entry.key_ptr.*),
                    .ascending = asc,
                });
            }
            while (it.next()) |entry| {
                const asc = if (entry.value_ptr.* == .integer) entry.value_ptr.integer >= 0 else true;
                try query.sort_fields.append(allocator, .{
                    .field = try allocator.dupe(u8, entry.key_ptr.*),
                    .ascending = asc,
                });
            }
        }
    } else if (root.object.get("orderBy")) |ob_val| {
        if (ob_val == .object) {
            if (ob_val.object.get("field")) |field_val| {
                if (field_val == .string) {
                    query.sort_field = try allocator.dupe(u8, field_val.string);
                    if (ob_val.object.get("direction")) |dir_val| {
                        if (dir_val == .string) {
                            query.sort_ascending = !std.mem.eql(u8, dir_val.string, "desc");
                        }
                    }
                    try query.sort_fields.append(allocator, .{
                        .field = try allocator.dupe(u8, field_val.string),
                        .ascending = query.sort_ascending,
                    });
                }
            }
        } else if (ob_val == .array) {
            for (ob_val.array.items, 0..) |item, idx| {
                if (item != .object) continue;
                const field_val = item.object.get("field") orelse continue;
                if (field_val != .string) continue;
                const dir_str = if (item.object.get("direction")) |d| (if (d == .string) d.string else "asc") else "asc";
                const asc = !std.mem.eql(u8, dir_str, "desc");

                if (idx == 0) {
                    query.sort_field = try allocator.dupe(u8, field_val.string);
                    query.sort_ascending = asc;
                }
                try query.sort_fields.append(allocator, .{
                    .field = try allocator.dupe(u8, field_val.string),
                    .ascending = asc,
                });
            }
        }
    }

    if (root.object.get("limit")) |limit_val| {
        if (limit_val == .integer) {
            query.limit = @intCast(limit_val.integer);
        }
    }

    if (root.object.get("offset")) |offset_val| {
        if (offset_val == .integer) {
            query.offset = @intCast(offset_val.integer);
        }
    } else if (root.object.get("skip")) |skip_val| {
        if (skip_val == .integer) {
            query.offset = @intCast(skip_val.integer);
        }
    }

    if (root.object.get("after")) |after_val| {
        if (after_val == .string) {
            query.after_key = std.fmt.parseInt(u128, after_val.string, 16) catch null;
        }
    }

    const proj_val = root.object.get("select") orelse
        root.object.get("$select") orelse
        root.object.get("pluck") orelse
        root.object.get("$pluck") orelse
        root.object.get("projection");
    if (proj_val) |pv| {
        if (pv == .array) {
            var proj_fields: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (proj_fields.items) |f| allocator.free(f);
                proj_fields.deinit(allocator);
            }
            for (pv.array.items) |item| {
                if (item == .string) {
                    try proj_fields.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            if (proj_fields.items.len > 0) {
                query.projection_fields = try proj_fields.toOwnedSlice(allocator);
            } else {
                proj_fields.deinit(allocator);
            }
        }
    }

    if (root.object.get("aggregate")) |agg_val| {
        if (agg_val == .object) {
            try parseAggregateObject(&query, agg_val.object);
            query.is_aggregation_query = true;
        }
    }

    if (root.object.get("group_by")) |group_by_val| {
        if (group_by_val == .array) {
            try parseGroupByArray(&query, group_by_val.array);
        }
    }

    if (query.or_predicates.items.len > 1 and query.predicates.items.len == 0) or_opt: {
        const first_group = query.or_predicates.items[0];
        if (first_group.items.len != 1 or first_group.items[0].operator != .eq) break :or_opt;
        const common_field = first_group.items[0].field_name;

        for (query.or_predicates.items[1..]) |group| {
            if (group.items.len != 1 or group.items[0].operator != .eq) break :or_opt;
            if (!std.mem.eql(u8, group.items[0].field_name, common_field)) break :or_opt;
        }

        const values = try allocator.alloc(FieldValue, query.or_predicates.items.len);
        errdefer allocator.free(values);
        for (query.or_predicates.items, 0..) |group, i| {
            const orig = group.items[0].value;
            values[i] = if (orig == .string)
                FieldValue{ .string = try allocator.dupe(u8, orig.string) }
            else
                orig;
        }

        const in_field = try allocator.dupe(u8, common_field);

        try query.predicates.append(allocator, .{
            .field_name = in_field,
            .operator = .in,
            .value = .{ .i64_val = 0 },
            .in_values = values,
        });

        for (query.or_predicates.items) |*group| {
            for (group.items) |pred| {
                query.freePredicate(pred);
            }
            group.deinit(allocator);
        }
        query.or_predicates.clearRetainingCapacity();
    }

    return query;
}

fn parseFilterObject(query: *ParsedQuery, obj: std.json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const field_name_raw = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;

        if (std.mem.eql(u8, field_name_raw, "$or")) {
            if (field_value == .array) {
                try parseOrArray(query, field_value.array);
            }
            continue;
        } else if (std.mem.startsWith(u8, field_name_raw, "$")) {
            continue;
        }

        const field_name = try query.allocator.dupe(u8, field_name_raw);
        errdefer query.allocator.free(field_name);

        if (field_value == .string) {
            const str_val = try query.allocator.dupe(u8, field_value.string);
            try query.predicates.append(query.allocator, .{
                .field_name = field_name,
                .operator = .eq,
                .value = .{ .string = str_val },
            });
        } else if (field_value == .integer) {
            try query.predicates.append(query.allocator, .{
                .field_name = field_name,
                .operator = .eq,
                .value = .{ .i64_val = field_value.integer },
            });
        } else if (field_value == .float) {
            try query.predicates.append(query.allocator, .{
                .field_name = field_name,
                .operator = .eq,
                .value = .{ .f64_val = field_value.float },
            });
        } else if (field_value == .bool) {
            try query.predicates.append(query.allocator, .{
                .field_name = field_name,
                .operator = .eq,
                .value = .{ .bool_val = field_value.bool },
            });
        } else if (field_value == .object) {
            try parseOperatorObject(query, field_name, field_value.object);
        }
    }
}

fn parseOperatorObject(query: *ParsedQuery, field_name: []const u8, obj: std.json.ObjectMap) !void {
    try parseOperatorObjectInto(query, field_name, obj, null);
}

fn parseOperatorObjectInto(query: *ParsedQuery, field_name: []const u8, obj: std.json.ObjectMap, target: ?*std.ArrayList(Predicate)) !void {
    var first = true;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const op_str = entry.key_ptr.*;
        const op_value = entry.value_ptr.*;

        const operator = parseOperatorString(op_str) orelse continue;

        if (operator == .in) {
            if (op_value == .array) {
                var in_vals = std.ArrayList(FieldValue).empty;
                errdefer {
                    for (in_vals.items) |v| {
                        if (v == .string) query.allocator.free(v.string);
                    }
                    in_vals.deinit(query.allocator);
                }
                for (op_value.array.items) |item| {
                    if (try parseJsonValueAlloc(query.allocator, item)) |v| {
                        try in_vals.append(query.allocator, v);
                    }
                }
                const name = if (first) field_name else try query.allocator.dupe(u8, field_name);
                first = false;
                const pred = Predicate{
                    .field_name = name,
                    .operator = .in,
                    .value = .{ .bool_val = false },
                    .in_values = try in_vals.toOwnedSlice(query.allocator),
                };
                if (target) |t| {
                    try t.append(query.allocator, pred);
                } else {
                    try query.predicates.append(query.allocator, pred);
                }
            }
            continue;
        }

        if (operator == .exists) {
            const name = if (first) field_name else try query.allocator.dupe(u8, field_name);
            first = false;
            const exists_val = if (op_value == .bool) op_value.bool else true;
            const pred = Predicate{
                .field_name = name,
                .operator = .exists,
                .value = .{ .bool_val = exists_val },
            };
            if (target) |t| {
                try t.append(query.allocator, pred);
            } else {
                try query.predicates.append(query.allocator, pred);
            }
            continue;
        }

        if (operator == .regex) {
            if (op_value == .string) {
                const name = if (first) field_name else try query.allocator.dupe(u8, field_name);
                first = false;
                const pattern = try query.allocator.dupe(u8, op_value.string);
                const pred = Predicate{
                    .field_name = name,
                    .operator = .regex,
                    .value = .{ .string = pattern },
                    .regex_pattern = pattern,
                };
                if (target) |t| {
                    try t.append(query.allocator, pred);
                } else {
                    try query.predicates.append(query.allocator, pred);
                }
            }
            continue;
        }

        if (operator == .between) {
            if (op_value == .array) {
                const items = op_value.array.items;
                if (items.len == 2) {
                    const lower = try parseJsonValueAlloc(query.allocator, items[0]) orelse continue;
                    const upper = try parseJsonValueAlloc(query.allocator, items[1]) orelse continue;
                    const name = if (first) field_name else try query.allocator.dupe(u8, field_name);
                    first = false;
                    const pred = Predicate{
                        .field_name = name,
                        .operator = .between,
                        .value = lower,
                        .upper_value = upper,
                    };
                    if (target) |t| {
                        try t.append(query.allocator, pred);
                    } else {
                        try query.predicates.append(query.allocator, pred);
                    }
                }
            }
            continue;
        }

        const value = try parseJsonValueAlloc(query.allocator, op_value) orelse continue;

        const name = if (first) field_name else try query.allocator.dupe(u8, field_name);
        first = false;

        const pred = Predicate{
            .field_name = name,
            .operator = operator,
            .value = value,
        };

        if (target) |t| {
            try t.append(query.allocator, pred);
        } else {
            try query.predicates.append(query.allocator, pred);
        }
    }
}

fn parseOrArray(query: *ParsedQuery, arr: std.json.Array) !void {
    for (arr.items) |item| {
        if (item != .object) continue;

        var group: std.ArrayList(Predicate) = .empty;
        errdefer {
            for (group.items) |pred| {
                query.allocator.free(pred.field_name);
                if (pred.value == .string) query.allocator.free(pred.value.string);
            }
            group.deinit(query.allocator);
        }

        var obj_it = item.object.iterator();
        while (obj_it.next()) |field_entry| {
            const fname_raw = field_entry.key_ptr.*;
            const fvalue = field_entry.value_ptr.*;

            if (std.mem.startsWith(u8, fname_raw, "$")) continue;

            const fname = try query.allocator.dupe(u8, fname_raw);
            errdefer query.allocator.free(fname);

            if (fvalue == .string) {
                const str_val = try query.allocator.dupe(u8, fvalue.string);
                try group.append(query.allocator, .{ .field_name = fname, .operator = .eq, .value = .{ .string = str_val } });
            } else if (fvalue == .integer) {
                try group.append(query.allocator, .{ .field_name = fname, .operator = .eq, .value = .{ .i64_val = fvalue.integer } });
            } else if (fvalue == .float) {
                try group.append(query.allocator, .{ .field_name = fname, .operator = .eq, .value = .{ .f64_val = fvalue.float } });
            } else if (fvalue == .bool) {
                try group.append(query.allocator, .{ .field_name = fname, .operator = .eq, .value = .{ .bool_val = fvalue.bool } });
            } else if (fvalue == .object) {
                try parseOperatorObjectInto(query, fname, fvalue.object, &group);
            }
        }

        if (group.items.len > 0) {
            try query.or_predicates.append(query.allocator, group);
        } else {
            group.deinit(query.allocator);
        }
    }
}

fn parseOperatorString(op_str: []const u8) ?Operator {
    if (std.mem.eql(u8, op_str, "$eq")) return .eq;
    if (std.mem.eql(u8, op_str, "$ne")) return .ne;
    if (std.mem.eql(u8, op_str, "$gt")) return .gt;
    if (std.mem.eql(u8, op_str, "$gte")) return .gte;
    if (std.mem.eql(u8, op_str, "$lt")) return .lt;
    if (std.mem.eql(u8, op_str, "$lte")) return .lte;
    if (std.mem.eql(u8, op_str, "$contains")) return .contains;
    if (std.mem.eql(u8, op_str, "$startsWith")) return .starts_with;
    if (std.mem.eql(u8, op_str, "$in")) return .in;
    if (std.mem.eql(u8, op_str, "$exists")) return .exists;
    if (std.mem.eql(u8, op_str, "$regex")) return .regex;
    if (std.mem.eql(u8, op_str, "$between")) return .between;
    return null;
}

fn parseJsonValue(val: std.json.Value) ?FieldValue {
    return switch (val) {
        .string => |s| FieldValue{ .string = s },
        .integer => |i| FieldValue{ .i64_val = i },
        .float => |f| FieldValue{ .i64_val = @intFromFloat(f) },
        .bool => |b| FieldValue{ .bool_val = b },
        else => null,
    };
}

fn parseJsonValueAlloc(allocator: Allocator, val: std.json.Value) !?FieldValue {
    return switch (val) {
        .string => |s| FieldValue{ .string = try allocator.dupe(u8, s) },
        .integer => |i| FieldValue{ .i64_val = i },
        .float => |f| FieldValue{ .f64_val = f },
        .bool => |b| FieldValue{ .bool_val = b },
        else => null,
    };
}

fn parseAggregateObject(query: *ParsedQuery, obj: std.json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const spec = entry.value_ptr.*;

        if (spec != .object) continue;

        var spec_it = spec.object.iterator();
        while (spec_it.next()) |spec_entry| {
            const func_str = spec_entry.key_ptr.*;
            const func_val = spec_entry.value_ptr.*;

            const func = parseAggregateFunctionString(func_str) orelse continue;
            const field_name: ?[]const u8 = switch (func_val) {
                .string => |s| try query.allocator.dupe(u8, s),
                .bool => null,
                else => null,
            };

            try query.aggregations.append(query.allocator, .{
                .name = try query.allocator.dupe(u8, name),
                .function = func,
                .field_name = field_name,
            });
        }
    }
}

fn parseAggregateFunctionString(func_str: []const u8) ?AggregateFunction {
    if (std.mem.eql(u8, func_str, "$count")) return .count;
    if (std.mem.eql(u8, func_str, "$sum")) return .sum;
    if (std.mem.eql(u8, func_str, "$avg")) return .avg;
    if (std.mem.eql(u8, func_str, "$min")) return .min;
    if (std.mem.eql(u8, func_str, "$max")) return .max;
    return null;
}

fn parseGroupByArray(query: *ParsedQuery, arr: std.json.Array) !void {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |f| query.allocator.free(f);
        fields.deinit(query.allocator);
    }

    for (arr.items) |item| {
        if (item == .string) {
            try fields.append(query.allocator, try query.allocator.dupe(u8, item.string));
        }
    }

    query.group_by_fields = try fields.toOwnedSlice(query.allocator);
}

test "parse simple equality query" {
    const allocator = std.testing.allocator;
    const json =
        \\{"filter":{"status":"active"}}
    ;
    var query = try parseJsonQuery(allocator, json);
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 1), query.predicates.items.len);
    try std.testing.expectEqual(Operator.eq, query.predicates.items[0].operator);
    try std.testing.expectEqualStrings("status", query.predicates.items[0].field_name);
}

test "parse range query" {
    const allocator = std.testing.allocator;
    const json =
        \\{"filter":{"age":{"$gte":18,"$lt":65}}}
    ;
    var query = try parseJsonQuery(allocator, json);
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 2), query.predicates.items.len);
}

test "parse query with sort and limit" {
    const allocator = std.testing.allocator;
    const json =
        \\{"filter":{"status":"active"},"sort":{"created_at":-1},"limit":10,"offset":5}
    ;
    var query = try parseJsonQuery(allocator, json);
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 1), query.predicates.items.len);
    try std.testing.expect(query.sort_field != null);
    try std.testing.expectEqualStrings("created_at", query.sort_field.?);
    try std.testing.expectEqual(false, query.sort_ascending);
    try std.testing.expectEqual(@as(u32, 10), query.limit.?);
    try std.testing.expectEqual(@as(u32, 5), query.offset);
}

test "parse between query" {
    const allocator = std.testing.allocator;
    const json =
        \\{"filter":{"price":{"$between":[10,50]}}}
    ;
    var query = try parseJsonQuery(allocator, json);
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 1), query.predicates.items.len);
    const pred = query.predicates.items[0];
    try std.testing.expectEqual(Operator.between, pred.operator);
    try std.testing.expectEqualStrings("price", pred.field_name);
    try std.testing.expectEqual(@as(i64, 10), pred.value.i64_val);
    try std.testing.expect(pred.upper_value != null);
    try std.testing.expectEqual(@as(i64, 50), pred.upper_value.?.i64_val);
}

test "between predicate evaluate - value in range" {
    const pred = Predicate{
        .field_name = "price",
        .operator = .between,
        .value = .{ .i64_val = 10 },
        .upper_value = .{ .i64_val = 50 },
    };
    try std.testing.expect(pred.evaluate(.{ .i64_val = 25 }));
    try std.testing.expect(pred.evaluate(.{ .i64_val = 10 }));
    try std.testing.expect(pred.evaluate(.{ .i64_val = 50 }));
    try std.testing.expect(!pred.evaluate(.{ .i64_val = 9 }));
    try std.testing.expect(!pred.evaluate(.{ .i64_val = 51 }));
}

test "between predicate evaluate - missing upper_value returns false" {
    const pred = Predicate{
        .field_name = "price",
        .operator = .between,
        .value = .{ .i64_val = 10 },
        .upper_value = null,
    };
    try std.testing.expect(!pred.evaluate(.{ .i64_val = 25 }));
}

test "between maps to range index strategy" {
    const allocator = std.testing.allocator;
    const json =
        \\{"filter":{"age":{"$between":[18,65]}}}
    ;
    var query = try parseJsonQuery(allocator, json);
    defer query.deinit();

    const strategy = query.getBestIndexStrategy();
    try std.testing.expect(strategy != null);
    try std.testing.expectEqual(ParsedQuery.IndexStrategy.range, @as(std.meta.Tag(ParsedQuery.IndexStrategy), strategy.?));
    const range = strategy.?.range;
    try std.testing.expectEqualStrings("age", range.field_name);
    try std.testing.expect(range.min_val != null);
    try std.testing.expect(range.max_val != null);
    try std.testing.expect(range.min_inclusive);
    try std.testing.expect(range.max_inclusive);
}
