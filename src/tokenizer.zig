const std = @import("std");

pub const Mode = enum { markup, expr, script_raw, style_raw };

pub const TokenKind = enum {
    eof,
    error_token,
    text,
    tag_open,
    tag_close,
    tag_end,
    tag_self_close,
    attr_name,
    attr_equals,
    attr_value,
    script_open,
    script_raw,
    script_close,
    style_open,
    style_raw,
    style_close,
    interpolation,
    if_open,
    else_block,
    if_close,
    each_open,
    each_close,
};

pub const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
    message: ?[]const u8 = null,
};

pub const Position = struct {
    line: usize,
    column: usize,
};

const CharClass = packed struct {
    whitespace: bool = false,
    ident_start: bool = false,
    ident_continue: bool = false,
    delimiter: bool = false,
    quote: bool = false,
    slash: bool = false,
};

fn buildClasses() [256]CharClass {
    var table: [256]CharClass = [_]CharClass{.{}} ** 256;
    for (&table, 0..) |*entry, i| {
        const c: u8 = @intCast(i);
        entry.whitespace = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        entry.ident_start = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
        entry.ident_continue = entry.ident_start or (c >= '0' and c <= '9') or c == '-' or c == ':';
        entry.delimiter = c == '<' or c == '>' or c == '/' or c == '=' or c == '{' or c == '}';
        entry.quote = c == '"' or c == '\'';
        entry.slash = c == '/';
    }
    return table;
}

const classes = buildClasses();

pub const Tokenizer = struct {
    source: []const u8,
    cursor: usize = 0,
    modes: [16]Mode = undefined,
    mode_len: usize = 1,
    pending: std.ArrayList(Token) = .empty,
    in_tag: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Tokenizer {
        var t = Tokenizer{ .source = source, .allocator = allocator };
        t.modes[0] = .markup;
        return t;
    }

    pub fn deinit(self: *Tokenizer) void {
        self.pending.deinit(self.allocator);
    }

    pub fn next(self: *Tokenizer) !Token {
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        return switch (self.currentMode()) {
            .markup => self.scanMarkup(),
            .expr => self.scanExpressionToken(),
            .script_raw => self.scanRaw(.script_raw),
            .style_raw => self.scanRaw(.style_raw),
        };
    }

    pub fn position(self: *const Tokenizer, offset: usize) Position {
        var line: usize = 1;
        var col: usize = 1;
        const capped = @min(offset, self.source.len);
        for (self.source[0..capped]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .column = col };
    }

    fn currentMode(self: *const Tokenizer) Mode {
        return self.modes[self.mode_len - 1];
    }

    fn pushMode(self: *Tokenizer, mode: Mode) void {
        if (self.mode_len < self.modes.len) {
            self.modes[self.mode_len] = mode;
            self.mode_len += 1;
        }
    }

    fn popMode(self: *Tokenizer) void {
        if (self.mode_len > 1) self.mode_len -= 1;
    }

    fn scanMarkup(self: *Tokenizer) !Token {
        if (self.cursor >= self.source.len) return .{ .kind = .eof, .start = self.cursor, .end = self.cursor };

        if (self.in_tag) return self.scanTagPart();

        const start = self.cursor;
        const c = self.source[self.cursor];
        if (c == '<') return self.scanTagStart();
        if (c == '{') {
            if (self.cursor + 1 < self.source.len and self.source[self.cursor + 1] == '{') {
                self.cursor += 2;
                return .{ .kind = .text, .start = start, .end = start + 1 };
            }
            return self.scanBrace();
        }

        while (self.cursor < self.source.len) : (self.cursor += 1) {
            if (self.source[self.cursor] == '<' or self.source[self.cursor] == '{') break;
        }
        return .{ .kind = .text, .start = start, .end = self.cursor };
    }

    fn scanTagStart(self: *Tokenizer) !Token {
        const start = self.cursor;
        if (std.mem.startsWith(u8, self.source[start..], "</")) {
            self.cursor += 2;
            const name_start = self.cursor;
            while (self.cursor < self.source.len and classes[self.source[self.cursor]].ident_continue) self.cursor += 1;
            const name = self.source[name_start..self.cursor];
            self.skipWhitespace();
            if (self.cursor < self.source.len and self.source[self.cursor] == '>') self.cursor += 1;
            if (std.ascii.eqlIgnoreCase(name, "script")) return .{ .kind = .script_close, .start = start, .end = self.cursor };
            if (std.ascii.eqlIgnoreCase(name, "style")) return .{ .kind = .style_close, .start = start, .end = self.cursor };
            return .{ .kind = .tag_close, .start = start, .end = self.cursor };
        }

        self.cursor += 1;
        const name_start = self.cursor;
        while (self.cursor < self.source.len and classes[self.source[self.cursor]].ident_continue) self.cursor += 1;
        const name = self.source[name_start..self.cursor];
        self.in_tag = true;
        if (std.ascii.eqlIgnoreCase(name, "script")) return .{ .kind = .script_open, .start = start, .end = self.cursor };
        if (std.ascii.eqlIgnoreCase(name, "style")) return .{ .kind = .style_open, .start = start, .end = self.cursor };
        return .{ .kind = .tag_open, .start = start, .end = self.cursor };
    }

    fn scanTagPart(self: *Tokenizer) !Token {
        self.skipWhitespace();
        if (self.cursor >= self.source.len) return .{ .kind = .error_token, .start = self.source.len, .end = self.source.len, .message = "unclosed tag" };
        const start = self.cursor;
        if (std.mem.startsWith(u8, self.source[start..], "/>")) {
            self.cursor += 2;
            self.in_tag = false;
            return .{ .kind = .tag_self_close, .start = start, .end = self.cursor };
        }
        if (self.source[start] == '>') {
            self.cursor += 1;
            self.in_tag = false;
            const before = self.findOpeningTagStart(start);
            if (before) |tag| {
                if (std.ascii.eqlIgnoreCase(tag, "script")) self.pushMode(.script_raw);
                if (std.ascii.eqlIgnoreCase(tag, "style")) self.pushMode(.style_raw);
            }
            return .{ .kind = .tag_end, .start = start, .end = self.cursor };
        }
        if (self.source[start] == '=') {
            self.cursor += 1;
            return .{ .kind = .attr_equals, .start = start, .end = self.cursor };
        }
        if (classes[self.source[start]].quote) {
            const quote = self.source[start];
            self.cursor += 1;
            while (self.cursor < self.source.len and self.source[self.cursor] != quote) self.cursor += 1;
            if (self.cursor < self.source.len) self.cursor += 1;
            return .{ .kind = .attr_value, .start = start, .end = self.cursor };
        }
        if (self.source[start] == '{') {
            return self.scanExpression(start, .attr_value);
        }
        while (self.cursor < self.source.len and !classes[self.source[self.cursor]].whitespace and self.source[self.cursor] != '>' and self.source[self.cursor] != '=' and self.source[self.cursor] != '/') self.cursor += 1;
        return .{ .kind = .attr_name, .start = start, .end = self.cursor };
    }

    fn scanBrace(self: *Tokenizer) !Token {
        const start = self.cursor;
        if (std.mem.startsWith(u8, self.source[start..], "{#if")) return self.scanBlock(start, .if_open);
        if (std.mem.startsWith(u8, self.source[start..], "{#each")) return self.scanBlock(start, .each_open);
        if (std.mem.startsWith(u8, self.source[start..], "{:else")) return self.scanSimpleBlock(start, .else_block);
        if (std.mem.startsWith(u8, self.source[start..], "{/if}")) {
            self.cursor += 5;
            return .{ .kind = .if_close, .start = start, .end = self.cursor };
        }
        if (std.mem.startsWith(u8, self.source[start..], "{/each}")) {
            self.cursor += 7;
            return .{ .kind = .each_close, .start = start, .end = self.cursor };
        }
        return self.scanExpression(start, .interpolation);
    }

    fn scanSimpleBlock(self: *Tokenizer, start: usize, kind: TokenKind) Token {
        while (self.cursor < self.source.len and self.source[self.cursor] != '}') self.cursor += 1;
        if (self.cursor < self.source.len) self.cursor += 1;
        return .{ .kind = kind, .start = start, .end = self.cursor };
    }

    fn scanBlock(self: *Tokenizer, start: usize, kind: TokenKind) !Token {
        return self.scanExpression(start, kind);
    }

    fn scanExpression(self: *Tokenizer, start: usize, kind: TokenKind) !Token {
        self.cursor = start + 1;
        var curly: usize = 0;
        var paren: usize = 0;
        var bracket: usize = 0;
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            switch (c) {
                '\'', '"' => self.skipString(c),
                '`' => self.skipTemplateLiteral(),
                '/' => {
                    if (self.cursor + 1 < self.source.len and self.source[self.cursor + 1] == '/') self.skipLineComment() else if (self.cursor + 1 < self.source.len and self.source[self.cursor + 1] == '*') self.skipBlockComment() else self.cursor += 1;
                },
                '{' => {
                    curly += 1;
                    self.cursor += 1;
                },
                '}' => {
                    if (curly == 0 and paren == 0 and bracket == 0) {
                        self.cursor += 1;
                        return .{ .kind = kind, .start = start, .end = self.cursor };
                    }
                    if (curly > 0) curly -= 1;
                    self.cursor += 1;
                },
                '(' => {
                    paren += 1;
                    self.cursor += 1;
                },
                ')' => {
                    if (paren > 0) paren -= 1;
                    self.cursor += 1;
                },
                '[' => {
                    bracket += 1;
                    self.cursor += 1;
                },
                ']' => {
                    if (bracket > 0) bracket -= 1;
                    self.cursor += 1;
                },
                else => self.cursor += 1,
            }
        }
        return .{ .kind = .error_token, .start = start, .end = self.cursor, .message = "unterminated expression" };
    }

    fn scanExpressionToken(self: *Tokenizer) Token {
        self.popMode();
        return .{ .kind = .eof, .start = self.cursor, .end = self.cursor };
    }

    fn scanRaw(self: *Tokenizer, mode: Mode) !Token {
        const start = self.cursor;
        const close = if (mode == .script_raw) "</script>" else "</style>";
        const close_kind: TokenKind = if (mode == .script_raw) .script_close else .style_close;
        if (std.mem.indexOf(u8, self.source[start..], close)) |rel| {
            const raw_end = start + rel;
            self.cursor = raw_end + close.len;
            self.popMode();
            try self.pending.append(self.allocator, .{ .kind = close_kind, .start = raw_end, .end = self.cursor });
            return .{ .kind = if (mode == .script_raw) .script_raw else .style_raw, .start = start, .end = raw_end };
        }
        self.cursor = self.source.len;
        self.popMode();
        return .{ .kind = .error_token, .start = start, .end = self.cursor, .message = if (mode == .script_raw) "unclosed script block" else "unclosed style block" };
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.cursor < self.source.len and classes[self.source[self.cursor]].whitespace) self.cursor += 1;
    }

    fn skipString(self: *Tokenizer, quote: u8) void {
        self.cursor += 1;
        while (self.cursor < self.source.len) : (self.cursor += 1) {
            if (self.source[self.cursor] == '\\') {
                self.cursor += 1;
                continue;
            }
            if (self.source[self.cursor] == quote) {
                self.cursor += 1;
                return;
            }
        }
    }

    fn skipTemplateLiteral(self: *Tokenizer) void {
        self.cursor += 1;
        while (self.cursor < self.source.len) : (self.cursor += 1) {
            if (self.source[self.cursor] == '\\') {
                self.cursor += 1;
                continue;
            }
            if (self.source[self.cursor] == '`') {
                self.cursor += 1;
                return;
            }
        }
    }

    fn skipLineComment(self: *Tokenizer) void {
        self.cursor += 2;
        while (self.cursor < self.source.len and self.source[self.cursor] != '\n') self.cursor += 1;
    }

    fn skipBlockComment(self: *Tokenizer) void {
        self.cursor += 2;
        while (self.cursor + 1 < self.source.len) : (self.cursor += 1) {
            if (self.source[self.cursor] == '*' and self.source[self.cursor + 1] == '/') {
                self.cursor += 2;
                return;
            }
        }
        self.cursor = self.source.len;
    }

    fn findOpeningTagStart(self: *Tokenizer, gt: usize) ?[]const u8 {
        var i = gt;
        while (i > 0) {
            i -= 1;
            if (self.source[i] == '<') {
                var j = i + 1;
                while (j < self.source.len and classes[self.source[j]].ident_continue) j += 1;
                return self.source[i + 1 .. j];
            }
        }
        return null;
    }
};

test "tokenizer emits block and raw tokens" {
    const source =
        \\<script>const x = "{not markup}";</script>
        \\<style>button { color: red; }</style>
        \\<button on:click={inc}>{count()}</button>
        \\{#each items as item (item.id)}<p>{item.name}</p>{/each}
    ;
    var t = Tokenizer.init(std.testing.allocator, source);
    defer t.deinit();
    var saw_script = false;
    var saw_style = false;
    var saw_each = false;
    while (true) {
        const tok = try t.next();
        if (tok.kind == .script_raw) saw_script = true;
        if (tok.kind == .style_raw) saw_style = true;
        if (tok.kind == .each_open) saw_each = true;
        if (tok.kind == .eof) break;
    }
    try std.testing.expect(saw_script);
    try std.testing.expect(saw_style);
    try std.testing.expect(saw_each);
}

test "nested braces and comments do not close interpolation" {
    const source = "<p>{fn({ value: \"}\" }) /* } */}</p>";
    var t = Tokenizer.init(std.testing.allocator, source);
    defer t.deinit();
    while (true) {
        const tok = try t.next();
        if (tok.kind == .interpolation) {
            try std.testing.expectEqualStrings("{fn({ value: \"}\" }) /* } */}", source[tok.start..tok.end]);
            return;
        }
        if (tok.kind == .eof) break;
    }
    return error.TestExpectedInterpolation;
}
