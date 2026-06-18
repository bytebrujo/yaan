//! Source-located build diagnostics.
//!
//! Yaan's compile pipeline (see `project.zig`) runs an explicit semantic-analysis
//! phase before it renders any output. Instead of ad-hoc `std.debug.print` calls
//! threaded through validation, each check appends a `Diagnostic` to a shared
//! `Bag`. The bag is sorted and rendered once, giving deterministic, source-located
//! output (`file:line:col: error[CODE]: message`) and a single error tally that
//! gates rendering.
//!
//! Subprocess type-check backstops (the `*_check.zig` shims compiled by
//! `project.zig`) already print rich compiler output of their own; their failure
//! counts feed the same tally via `noteExternal` rather than being re-rendered.

const std = @import("std");

pub const Severity = enum {
    @"error",
    warning,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
        };
    }
};

/// One diagnostic anchored to a source location. `line`/`col` are 1-based; a
/// `line` of 0 marks a file-scoped diagnostic with no specific position (the
/// position suffix is then omitted when rendered).
pub const Diagnostic = struct {
    severity: Severity = .@"error",
    file: []const u8,
    line: u32 = 0,
    col: u32 = 0,
    /// Stable machine-readable code, e.g. "E_DUP_ROUTE_SHAPE". Borrowed (always
    /// a string literal); never owned by the bag.
    code: []const u8,
    message: []const u8,

    /// Append `file:line:col: severity[CODE]: message\n` to `out`. The position
    /// suffix is dropped when `line == 0`.
    pub fn render(self: Diagnostic, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (self.line > 0) {
            try out.print(allocator, "{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
                self.file, self.line, self.col, self.severity.label(), self.code, self.message,
            });
        } else {
            try out.print(allocator, "{s}: {s}[{s}]: {s}\n", .{
                self.file, self.severity.label(), self.code, self.message,
            });
        }
    }
};

/// Accumulates diagnostics across the pipeline phases. Owns a private copy of
/// each diagnostic's `file` and `message` (codes are borrowed literals). Call
/// `deinit` to release them.
pub const Bag = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    /// Failures from external backstops (type-check subprocesses) that already
    /// printed their own detailed output. Counted toward `errorCount`, never
    /// re-rendered.
    external_failures: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Bag {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Bag) void {
        for (self.items.items) |d| {
            self.allocator.free(d.file);
            self.allocator.free(d.message);
        }
        self.items.deinit(self.allocator);
    }

    /// Append `d`, taking ownership of copies of its `file` and `message`.
    pub fn add(self: *Bag, d: Diagnostic) !void {
        const file_copy = try self.allocator.dupe(u8, d.file);
        errdefer self.allocator.free(file_copy);
        const msg_copy = try self.allocator.dupe(u8, d.message);
        var owned = d;
        owned.file = file_copy;
        owned.message = msg_copy;
        try self.items.append(self.allocator, owned);
    }

    /// Append a diagnostic whose message is formatted now and then copied in.
    pub fn addf(
        self: *Bag,
        severity: Severity,
        file: []const u8,
        line: u32,
        col: u32,
        code: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try self.add(.{
            .severity = severity,
            .file = file,
            .line = line,
            .col = col,
            .code = code,
            .message = msg,
        });
    }

    /// Record `n` failures from an external backstop that printed its own detail.
    pub fn noteExternal(self: *Bag, n: usize) void {
        self.external_failures += n;
    }

    /// Total errors: located `error`-severity diagnostics plus backstop failures.
    /// Warnings never count. This is what gates rendering.
    pub fn errorCount(self: *const Bag) usize {
        var n: usize = self.external_failures;
        for (self.items.items) |d| {
            if (d.severity == .@"error") n += 1;
        }
        return n;
    }

    pub fn warningCount(self: *const Bag) usize {
        var n: usize = 0;
        for (self.items.items) |d| {
            if (d.severity == .warning) n += 1;
        }
        return n;
    }

    fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
        const f = std.mem.order(u8, a.file, b.file);
        if (f != .eq) return f == .lt;
        if (a.line != b.line) return a.line < b.line;
        return a.col < b.col;
    }

    /// Stable-sort diagnostics by (file, line, col) for deterministic output.
    pub fn sort(self: *Bag) void {
        std.mem.sort(Diagnostic, self.items.items, {}, lessThan);
    }

    /// Sort and append every located diagnostic to `out`.
    pub fn renderAll(self: *Bag, out: *std.ArrayList(u8)) !void {
        self.sort();
        for (self.items.items) |d| {
            try d.render(self.allocator, out);
        }
    }

    /// Sort and print every located diagnostic to stderr. Backstop failures are
    /// not reprinted (they emitted their own compiler output already).
    pub fn flush(self: *Bag) void {
        self.sort();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        for (self.items.items) |d| {
            d.render(self.allocator, &buf) catch return;
        }
        if (buf.items.len > 0) std.debug.print("{s}", .{buf.items});
    }
};

test "diagnostic renders with and without a position" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const located: Diagnostic = .{
        .file = "src/routes/+page.yn",
        .line = 12,
        .col = 3,
        .code = "E_DUP_ROUTE_SHAPE",
        .message = "duplicate route shape",
    };
    try located.render(allocator, &out);
    try std.testing.expectEqualStrings(
        "src/routes/+page.yn:12:3: error[E_DUP_ROUTE_SHAPE]: duplicate route shape\n",
        out.items,
    );

    out.clearRetainingCapacity();
    const file_scoped: Diagnostic = .{
        .severity = .warning,
        .file = "src/routes/+page.yn",
        .code = "W_IMG_NO_ALT",
        .message = "<img> without alt",
    };
    try file_scoped.render(allocator, &out);
    try std.testing.expectEqualStrings(
        "src/routes/+page.yn: warning[W_IMG_NO_ALT]: <img> without alt\n",
        out.items,
    );
}

test "bag counts errors and warnings and sorts deterministically" {
    const allocator = std.testing.allocator;
    var bag = Bag.init(allocator);
    defer bag.deinit();

    try bag.add(.{ .file = "b.yn", .line = 1, .col = 1, .code = "E_X", .message = "second file" });
    try bag.add(.{ .severity = .warning, .file = "a.yn", .line = 9, .col = 1, .code = "W_Y", .message = "a warning" });
    try bag.addf(.@"error", "a.yn", 2, 4, "E_Z", "value {d}", .{7});
    bag.noteExternal(3);

    try std.testing.expectEqual(@as(usize, 5), bag.errorCount()); // 2 located errors + 3 external
    try std.testing.expectEqual(@as(usize, 1), bag.warningCount());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try bag.renderAll(&out);
    // Sorted by file, then line: a.yn:2 (E_Z), a.yn:9 (W_Y), b.yn:1 (E_X).
    try std.testing.expectEqualStrings(
        \\a.yn:2:4: error[E_Z]: value 7
        \\a.yn:9:1: warning[W_Y]: a warning
        \\b.yn:1:1: error[E_X]: second file
        \\
    , out.items);
}
