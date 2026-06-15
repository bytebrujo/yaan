const std = @import("std");

pub const Value = union(enum) {
    null,
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
};

pub const Param = Value;

pub const Column = struct {
    name: []const u8,
    value: Value,
};

pub const Row = struct {
    columns: []Column,

    pub fn get(self: Row, name: []const u8) ?Value {
        for (self.columns) |column| {
            if (std.mem.eql(u8, column.name, name)) return column.value;
        }
        return null;
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    rows: []Row,

    pub fn deinit(self: *Result) void {
        for (self.rows) |row| {
            for (row.columns) |column| {
                self.allocator.free(column.name);
                deinitValue(self.allocator, column.value);
            }
            self.allocator.free(row.columns);
        }
        self.allocator.free(self.rows);
        self.* = .{ .allocator = self.allocator, .rows = &.{} };
    }
};

pub fn TypedRows(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        items: []T,
        owned_strings: std.ArrayList([]u8) = .empty,

        pub fn deinit(self: *@This()) void {
            for (self.owned_strings.items) |value| self.allocator.free(value);
            self.owned_strings.deinit(self.allocator);
            self.allocator.free(self.items);
            self.* = .{ .allocator = self.allocator, .items = &.{} };
        }
    };
}

pub const Database = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, params: []const Param) anyerror!Result,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn execute(self: Database, allocator: std.mem.Allocator, sql: []const u8, params: []const Param) !Result {
        return self.vtable.execute(self.ptr, allocator, sql, params);
    }

    pub fn queryAs(self: Database, allocator: std.mem.Allocator, comptime T: type, sql: []const u8, params: []const Param) !TypedRows(T) {
        var result = try self.execute(allocator, sql, params);
        defer result.deinit();
        var rows: TypedRows(T) = .{
            .allocator = allocator,
            .items = try allocator.alloc(T, result.rows.len),
        };
        errdefer rows.deinit();
        for (result.rows, 0..) |row, i| {
            rows.items[i] = try mapRow(allocator, &rows.owned_strings, T, row);
        }
        return rows;
    }

    pub fn close(self: Database) void {
        self.vtable.close(self.ptr);
    }
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    connections: []Database,
    in_use: []bool,

    pub const Lease = struct {
        pool: *Pool,
        index: usize,
        db: Database,

        pub fn deinit(self: *Lease) void {
            self.pool.release(self.index);
        }
    };

    pub fn init(allocator: std.mem.Allocator, connections: []const Database) !Pool {
        const copied = try allocator.dupe(Database, connections);
        errdefer allocator.free(copied);
        const in_use = try allocator.alloc(bool, copied.len);
        @memset(in_use, false);
        return .{ .allocator = allocator, .connections = copied, .in_use = in_use };
    }

    pub fn deinit(self: *Pool) void {
        for (self.connections) |connection| connection.close();
        self.allocator.free(self.connections);
        self.allocator.free(self.in_use);
        self.* = .{ .allocator = self.allocator, .connections = &.{}, .in_use = &.{} };
    }

    pub fn acquire(self: *Pool) !Lease {
        for (self.in_use, 0..) |used, i| {
            if (!used) {
                self.in_use[i] = true;
                return .{ .pool = self, .index = i, .db = self.connections[i] };
            }
        }
        return error.NoDatabaseConnectionAvailable;
    }

    fn release(self: *Pool, index: usize) void {
        if (index < self.in_use.len) self.in_use[index] = false;
    }
};

pub const Memory = struct {
    allocator: std.mem.Allocator,
    tables: std.StringHashMap(Table),

    const Table = struct {
        rows: std.ArrayList(Row),

        fn deinit(self: *Table, allocator: std.mem.Allocator) void {
            for (self.rows.items) |row| deinitRow(allocator, row);
            self.rows.deinit(allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Memory {
        return .{ .allocator = allocator, .tables = .init(allocator) };
    }

    pub fn deinit(self: *Memory) void {
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.tables.deinit();
    }

    pub fn database(self: *Memory) Database {
        return .{ .ptr = self, .vtable = &.{
            .execute = execute,
            .close = close,
        } };
    }

    pub fn insert(self: *Memory, table_name: []const u8, columns: []const Column) !void {
        const entry = try self.tables.getOrPut(table_name);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, table_name);
            entry.value_ptr.* = .{ .rows = .empty };
        }
        try entry.value_ptr.rows.append(self.allocator, try cloneRow(self.allocator, .{ .columns = @constCast(columns) }));
    }

    fn execute(ptr: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, params: []const Param) !Result {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        const parsed = try parseSelect(sql);
        const table = self.tables.get(parsed.table) orelse return emptyResult(allocator);
        var rows: std.ArrayList(Row) = .empty;
        errdefer {
            for (rows.items) |row| deinitRow(allocator, row);
            rows.deinit(allocator);
        }
        for (table.rows.items) |row| {
            if (parsed.where_column) |column| {
                if (params.len == 0) return error.MissingQueryParameter;
                const value = row.get(column) orelse continue;
                if (!valueEql(value, params[0])) continue;
            }
            try rows.append(allocator, try cloneRow(allocator, row));
        }
        return .{ .allocator = allocator, .rows = try rows.toOwnedSlice(allocator) };
    }

    fn close(ptr: *anyopaque) void {
        _ = ptr;
    }
};

const ParsedSelect = struct {
    table: []const u8,
    where_column: ?[]const u8 = null,
};

fn parseSelect(sql: []const u8) !ParsedSelect {
    var tokens = std.mem.tokenizeAny(u8, sql, " \t\r\n;");
    const select_kw = tokens.next() orelse return error.UnsupportedMemoryQuery;
    const projection = tokens.next() orelse return error.UnsupportedMemoryQuery;
    const from_kw = tokens.next() orelse return error.UnsupportedMemoryQuery;
    const table = tokens.next() orelse return error.UnsupportedMemoryQuery;
    if (!std.ascii.eqlIgnoreCase(select_kw, "select") or
        !std.mem.eql(u8, projection, "*") or
        !std.ascii.eqlIgnoreCase(from_kw, "from"))
    {
        return error.UnsupportedMemoryQuery;
    }
    const maybe_where = tokens.next() orelse return .{ .table = table };
    if (!std.ascii.eqlIgnoreCase(maybe_where, "where")) return error.UnsupportedMemoryQuery;
    const column = tokens.next() orelse return error.UnsupportedMemoryQuery;
    const equals = tokens.next() orelse return error.UnsupportedMemoryQuery;
    const param = tokens.next() orelse return error.UnsupportedMemoryQuery;
    if (!std.mem.eql(u8, equals, "=") or !std.mem.eql(u8, param, "$1")) return error.UnsupportedMemoryQuery;
    if (tokens.next() != null) return error.UnsupportedMemoryQuery;
    return .{ .table = table, .where_column = column };
}

fn emptyResult(allocator: std.mem.Allocator) !Result {
    return .{ .allocator = allocator, .rows = try allocator.alloc(Row, 0) };
}

fn mapRow(allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8), comptime T: type, row: Row) !T {
    var item: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const value = row.get(field.name) orelse return error.MissingColumn;
        @field(item, field.name) = try mapValue(allocator, owned_strings, field.type, value);
    }
    return item;
}

fn mapValue(allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8), comptime T: type, value: Value) !T {
    if (T == []const u8) {
        const string = switch (value) {
            .string => |v| v,
            else => return error.InvalidColumnType,
        };
        const owned = try allocator.dupe(u8, string);
        errdefer allocator.free(owned);
        try owned_strings.append(allocator, owned);
        return owned;
    }
    if (T == i64) return switch (value) {
        .int => |v| v,
        .uint => |v| std.math.cast(i64, v) orelse error.InvalidColumnType,
        else => error.InvalidColumnType,
    };
    if (T == u64) return switch (value) {
        .uint => |v| v,
        .int => |v| std.math.cast(u64, v) orelse error.InvalidColumnType,
        else => error.InvalidColumnType,
    };
    if (T == bool) return switch (value) {
        .bool => |v| v,
        else => error.InvalidColumnType,
    };
    if (T == f64) return switch (value) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .uint => |v| @floatFromInt(v),
        else => error.InvalidColumnType,
    };
    return error.UnsupportedColumnType;
}

fn cloneRow(allocator: std.mem.Allocator, row: Row) !Row {
    const columns = try allocator.alloc(Column, row.columns.len);
    errdefer allocator.free(columns);
    for (row.columns, 0..) |column, i| {
        columns[i] = .{
            .name = try allocator.dupe(u8, column.name),
            .value = try cloneValue(allocator, column.value),
        };
    }
    return .{ .columns = columns };
}

fn deinitRow(allocator: std.mem.Allocator, row: Row) void {
    for (row.columns) |column| {
        allocator.free(column.name);
        deinitValue(allocator, column.value);
    }
    allocator.free(row.columns);
}

fn cloneValue(allocator: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .null => .null,
        .int => |int| .{ .int = int },
        .uint => |uint| .{ .uint = uint },
        .float => |float| .{ .float = float },
        .bool => |boolean| .{ .bool = boolean },
    };
}

fn deinitValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .string => |string| allocator.free(string),
        else => {},
    }
}

fn valueEql(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .string => |a_string| switch (b) {
            .string => |b_string| std.mem.eql(u8, a_string, b_string),
            else => false,
        },
        .int => |a_int| switch (b) {
            .int => |b_int| a_int == b_int,
            .uint => |b_uint| a_int >= 0 and @as(u64, @intCast(a_int)) == b_uint,
            else => false,
        },
        .uint => |a_uint| switch (b) {
            .uint => |b_uint| a_uint == b_uint,
            .int => |b_int| b_int >= 0 and a_uint == @as(u64, @intCast(b_int)),
            else => false,
        },
        .float => |a_float| switch (b) {
            .float => |b_float| a_float == b_float,
            else => false,
        },
        .bool => |a_bool| switch (b) {
            .bool => |b_bool| a_bool == b_bool,
            else => false,
        },
    };
}

test "memory driver maps parameterized query rows to structs" {
    const User = struct {
        id: i64,
        name: []const u8,
    };
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.insert("users", &.{
        .{ .name = "id", .value = .{ .int = 42 } },
        .{ .name = "name", .value = .{ .string = "Ada" } },
    });
    const db = memory.database();
    var users = try db.queryAs(std.testing.allocator, User, "select * from users where id = $1", &.{.{ .int = 42 }});
    defer users.deinit();
    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    try std.testing.expectEqual(@as(i64, 42), users.items[0].id);
    try std.testing.expectEqualStrings("Ada", users.items[0].name);
}

test "pool leases and releases database connections" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    const db = memory.database();
    var pool = try Pool.init(std.testing.allocator, &.{db});
    defer pool.deinit();
    var lease = try pool.acquire();
    lease.deinit();
    var next = try pool.acquire();
    next.deinit();
}
