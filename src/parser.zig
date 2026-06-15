const std = @import("std");
const tokenizer = @import("tokenizer.zig");

pub const Diagnostic = struct {
    message: []const u8,
    offset: usize,
};

pub const Attr = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    expression: bool = false,
};

pub const Node = union(enum) {
    text: []const u8,
    element: Element,
    interpolation: []const u8,
    if_block: IfBlock,
    each_block: EachBlock,
};

pub const Element = struct {
    name: []const u8,
    attrs: []Attr,
    children: []Node,
};

pub const IfBlock = struct {
    condition: []const u8,
    then_children: []Node,
    else_children: []Node,
};

pub const EachBlock = struct {
    expression: []const u8,
    item: []const u8,
    index: ?[]const u8,
    key: ?[]const u8,
    children: []Node,
};

pub const Component = struct {
    source: []const u8,
    script: []const u8 = "",
    style: []const u8 = "",
    children: []Node = &.{},
    diagnostics: []Diagnostic = &.{},
};

const TagFrame = struct {
    name: []const u8,
    attrs: std.ArrayList(Attr) = .empty,
    children: std.ArrayList(Node) = .empty,
};

const IfFrame = struct {
    condition: []const u8,
    then_children: std.ArrayList(Node) = .empty,
    else_children: std.ArrayList(Node) = .empty,
    in_else: bool = false,
};

const EachFrame = struct {
    expression: []const u8,
    item: []const u8,
    index: ?[]const u8,
    key: ?[]const u8,
    children: std.ArrayList(Node) = .empty,
};

const Frame = union(enum) {
    root: std.ArrayList(Node),
    tag: TagFrame,
    if_block: IfFrame,
    each_block: EachFrame,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Component {
    var toks = tokenizer.Tokenizer.init(allocator, source);
    defer toks.deinit();

    var frames: std.ArrayList(Frame) = .empty;
    defer {
        for (frames.items) |*frame| deinitFrame(frame, allocator);
        frames.deinit(allocator);
    }
    try frames.append(allocator, .{ .root = .empty });

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    var script: []const u8 = "";
    var style: []const u8 = "";
    var pending_attrs: std.ArrayList(Attr) = .empty;
    defer pending_attrs.deinit(allocator);
    var last_attr_index: ?usize = null;

    while (true) {
        const tok = try toks.next();
        switch (tok.kind) {
            .eof => break,
            .error_token => try diagnostics.append(allocator, .{ .message = tok.message orelse "tokenizer error", .offset = tok.start }),
            .text => try appendNode(&frames, allocator, .{ .text = source[tok.start..tok.end] }),
            .script_raw => script = source[tok.start..tok.end],
            .style_raw => style = source[tok.start..tok.end],
            .script_open, .style_open => {
                pending_attrs.clearRetainingCapacity();
                last_attr_index = null;
            },
            .attr_name => {
                const name = trim(source[tok.start..tok.end]);
                try pending_attrs.append(allocator, .{ .name = name });
                last_attr_index = pending_attrs.items.len - 1;
            },
            .attr_value => {
                if (last_attr_index) |i| {
                    const raw = source[tok.start..tok.end];
                    pending_attrs.items[i].value = unquote(raw);
                    pending_attrs.items[i].expression = isExpressionAttr(raw);
                }
            },
            .tag_open => {
                pending_attrs.clearRetainingCapacity();
                last_attr_index = null;
                const raw = source[tok.start..tok.end];
                var name = raw[1..];
                name = trim(name);
                try frames.append(allocator, .{ .tag = .{ .name = name } });
            },
            .tag_close => {
                const close_name = closeTagName(source[tok.start..tok.end]);
                try closeTag(&frames, allocator, close_name, &diagnostics, tok.start);
            },
            .tag_self_close => {
                if (frames.items.len > 1 and frames.items[frames.items.len - 1] == .tag) {
                    if (pending_attrs.items.len > 0) {
                        try frames.items[frames.items.len - 1].tag.attrs.appendSlice(allocator, pending_attrs.items);
                        pending_attrs.clearRetainingCapacity();
                    }
                    var frame = frames.pop().?;
                    const elem = try finishTag(&frame.tag, allocator);
                    frame.tag.attrs.deinit(allocator);
                    frame.tag.children.deinit(allocator);
                    try appendNode(&frames, allocator, .{ .element = elem });
                }
            },
            .tag_end, .attr_equals, .script_close, .style_close => {
                if (tok.kind == .tag_end and frames.items.len > 1 and frames.items[frames.items.len - 1] == .tag) {
                    var frame = &frames.items[frames.items.len - 1].tag;
                    if (pending_attrs.items.len > 0) {
                        frame.attrs.clearRetainingCapacity();
                        try frame.attrs.appendSlice(allocator, pending_attrs.items);
                        pending_attrs.clearRetainingCapacity();
                    }
                }
            },
            .interpolation => try appendNode(&frames, allocator, .{ .interpolation = inner(source[tok.start..tok.end]) }),
            .if_open => {
                const condition = trimBlock(source[tok.start..tok.end], "{#if");
                try frames.append(allocator, .{ .if_block = .{ .condition = condition } });
            },
            .else_block => {
                if (frames.items.len == 0 or frames.items[frames.items.len - 1] != .if_block) {
                    try diagnostics.append(allocator, .{ .message = "else without matching if", .offset = tok.start });
                } else frames.items[frames.items.len - 1].if_block.in_else = true;
            },
            .if_close => try closeIf(&frames, allocator, &diagnostics, tok.start),
            .each_open => {
                const info = parseEachHeader(trimBlock(source[tok.start..tok.end], "{#each"));
                try frames.append(allocator, .{ .each_block = .{
                    .expression = info.expression,
                    .item = info.item,
                    .index = info.index,
                    .key = info.key,
                } });
            },
            .each_close => try closeEach(&frames, allocator, &diagnostics, tok.start),
        }

        if (tok.kind == .script_close or tok.kind == .style_close) {
            for (pending_attrs.items) |a| {
                if (std.mem.eql(u8, a.name, "context") and a.value != null and std.mem.eql(u8, a.value.?, "module")) {
                    try diagnostics.append(allocator, .{ .message = "module scripts are not supported in v1", .offset = tok.start });
                }
            }
            pending_attrs.clearRetainingCapacity();
            last_attr_index = null;
        }
    }

    while (frames.items.len > 1) {
        const top = frames.pop().?;
        switch (top) {
            .tag => |f| {
                try diagnostics.append(allocator, .{ .message = "unclosed element", .offset = 0 });
                var mut = f;
                mut.attrs.deinit(allocator);
                mut.children.deinit(allocator);
            },
            .if_block => |f| {
                try diagnostics.append(allocator, .{ .message = "unclosed if block", .offset = 0 });
                var mut = f;
                mut.then_children.deinit(allocator);
                mut.else_children.deinit(allocator);
            },
            .each_block => |f| {
                try diagnostics.append(allocator, .{ .message = "unclosed each block", .offset = 0 });
                var mut = f;
                mut.children.deinit(allocator);
            },
            .root => {},
        }
    }

    var root = frames.pop().?.root;
    return .{
        .source = source,
        .script = trim(script),
        .style = trim(style),
        .children = try root.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

pub fn deinitComponent(component: *Component, allocator: std.mem.Allocator) void {
    deinitNodes(component.children, allocator);
    allocator.free(component.children);
    allocator.free(component.diagnostics);
}

fn deinitFrame(frame: *Frame, allocator: std.mem.Allocator) void {
    switch (frame.*) {
        .root => |*nodes| nodes.deinit(allocator),
        .tag => |*tag| {
            tag.attrs.deinit(allocator);
            deinitNodeList(&tag.children, allocator);
        },
        .if_block => |*ifb| {
            deinitNodeList(&ifb.then_children, allocator);
            deinitNodeList(&ifb.else_children, allocator);
        },
        .each_block => |*each| deinitNodeList(&each.children, allocator),
    }
}

fn deinitNodeList(list: *std.ArrayList(Node), allocator: std.mem.Allocator) void {
    deinitNodes(list.items, allocator);
    list.deinit(allocator);
}

fn deinitNodes(nodes: []Node, allocator: std.mem.Allocator) void {
    for (nodes) |*node| switch (node.*) {
        .element => |*e| {
            allocator.free(e.attrs);
            deinitNodes(e.children, allocator);
            allocator.free(e.children);
        },
        .if_block => |*b| {
            deinitNodes(b.then_children, allocator);
            allocator.free(b.then_children);
            deinitNodes(b.else_children, allocator);
            allocator.free(b.else_children);
        },
        .each_block => |*b| {
            deinitNodes(b.children, allocator);
            allocator.free(b.children);
        },
        else => {},
    };
}

fn appendNode(frames: *std.ArrayList(Frame), allocator: std.mem.Allocator, node: Node) !void {
    const top = &frames.items[frames.items.len - 1];
    switch (top.*) {
        .root => |*nodes| try nodes.append(allocator, node),
        .tag => |*tag| try tag.children.append(allocator, node),
        .if_block => |*ifb| {
            if (ifb.in_else) try ifb.else_children.append(allocator, node) else try ifb.then_children.append(allocator, node);
        },
        .each_block => |*each| try each.children.append(allocator, node),
    }
}

fn closeTag(frames: *std.ArrayList(Frame), allocator: std.mem.Allocator, name: []const u8, diagnostics: *std.ArrayList(Diagnostic), offset: usize) !void {
    if (frames.items.len <= 1 or frames.items[frames.items.len - 1] != .tag) {
        try diagnostics.append(allocator, .{ .message = "closing tag without matching opening tag", .offset = offset });
        return;
    }
    var frame = frames.pop().?;
    if (!std.mem.eql(u8, frame.tag.name, name)) {
        try diagnostics.append(allocator, .{ .message = "mismatched closing tag", .offset = offset });
    }
    const elem = try finishTag(&frame.tag, allocator);
    frame.tag.attrs.deinit(allocator);
    frame.tag.children.deinit(allocator);
    try appendNode(frames, allocator, .{ .element = elem });
}

fn finishTag(tag: *TagFrame, allocator: std.mem.Allocator) !Element {
    return .{
        .name = tag.name,
        .attrs = try tag.attrs.toOwnedSlice(allocator),
        .children = try tag.children.toOwnedSlice(allocator),
    };
}

fn closeIf(frames: *std.ArrayList(Frame), allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic), offset: usize) !void {
    if (frames.items.len <= 1 or frames.items[frames.items.len - 1] != .if_block) {
        try diagnostics.append(allocator, .{ .message = "if close without matching if", .offset = offset });
        return;
    }
    var frame = frames.pop().?;
    const ifb = IfBlock{
        .condition = frame.if_block.condition,
        .then_children = try frame.if_block.then_children.toOwnedSlice(allocator),
        .else_children = try frame.if_block.else_children.toOwnedSlice(allocator),
    };
    try appendNode(frames, allocator, .{ .if_block = ifb });
}

fn closeEach(frames: *std.ArrayList(Frame), allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic), offset: usize) !void {
    if (frames.items.len <= 1 or frames.items[frames.items.len - 1] != .each_block) {
        try diagnostics.append(allocator, .{ .message = "each close without matching each", .offset = offset });
        return;
    }
    var frame = frames.pop().?;
    const each = EachBlock{
        .expression = frame.each_block.expression,
        .item = frame.each_block.item,
        .index = frame.each_block.index,
        .key = frame.each_block.key,
        .children = try frame.each_block.children.toOwnedSlice(allocator),
    };
    try appendNode(frames, allocator, .{ .each_block = each });
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn inner(s: []const u8) []const u8 {
    if (s.len >= 2) return trim(s[1 .. s.len - 1]);
    return "";
}

fn trimBlock(s: []const u8, prefix: []const u8) []const u8 {
    if (s.len < prefix.len + 1) return "";
    return trim(s[prefix.len .. s.len - 1]);
}

fn unquote(s: []const u8) []const u8 {
    const v = trim(s);
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) return v[1 .. v.len - 1];
    if (v.len >= 2 and v[0] == '{' and v[v.len - 1] == '}') return trim(v[1 .. v.len - 1]);
    return v;
}

fn isExpressionAttr(s: []const u8) bool {
    const v = trim(s);
    return v.len >= 2 and v[0] == '{' and v[v.len - 1] == '}';
}

fn closeTagName(s: []const u8) []const u8 {
    if (s.len < 3) return "";
    var body = s[2..];
    if (body.len > 0 and body[body.len - 1] == '>') body = body[0 .. body.len - 1];
    return trim(body);
}

const EachHeader = struct {
    expression: []const u8,
    item: []const u8,
    index: ?[]const u8,
    key: ?[]const u8,
};

fn parseEachHeader(header: []const u8) EachHeader {
    const key_start = std.mem.lastIndexOfScalar(u8, header, '(');
    var key: ?[]const u8 = null;
    var body = header;
    if (key_start) |ks| {
        if (std.mem.lastIndexOfScalar(u8, header, ')')) |ke| {
            if (ke > ks) {
                key = trim(header[ks + 1 .. ke]);
                body = trim(header[0..ks]);
            }
        }
    }
    const as_pos = std.mem.indexOf(u8, body, " as ") orelse return .{ .expression = trim(body), .item = "item", .index = null, .key = key };
    const expr = trim(body[0..as_pos]);
    const rest = trim(body[as_pos + 4 ..]);
    if (std.mem.indexOfScalar(u8, rest, ',')) |comma| {
        return .{ .expression = expr, .item = trim(rest[0..comma]), .index = trim(rest[comma + 1 ..]), .key = key };
    }
    return .{ .expression = expr, .item = rest, .index = null, .key = key };
}

test "parser recognizes keyed each and events" {
    var component = try parse(std.testing.allocator,
        \\<script>const items = $state([]);</script>
        \\<ul>{#each items() as item, i (item.id)}<li on:click={() => select(item)}>{item.name}</li>{/each}</ul>
    );
    defer deinitComponent(&component, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), component.diagnostics.len);
    try std.testing.expectEqualStrings("const items = $state([]);", component.script);
    var ul_index: usize = 0;
    while (component.children[ul_index] != .element) ul_index += 1;
    const ul = component.children[ul_index].element;
    const each = ul.children[0].each_block;
    try std.testing.expectEqualStrings("items()", each.expression);
    try std.testing.expectEqualStrings("item", each.item);
    try std.testing.expectEqualStrings("i", each.index.?);
    try std.testing.expectEqualStrings("item.id", each.key.?);
}

test "parser preserves expression attributes" {
    var component = try parse(std.testing.allocator, "<img src={asset(\"logo.png\")} alt=\"Logo\" />");
    defer deinitComponent(&component, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), component.children.len);
    const element = component.children[0].element;
    try std.testing.expectEqual(@as(usize, 2), element.attrs.len);
    try std.testing.expectEqualStrings("src", element.attrs[0].name);
    try std.testing.expect(element.attrs[0].expression);
    try std.testing.expectEqualStrings("asset(\"logo.png\")", element.attrs[0].value.?);
}
