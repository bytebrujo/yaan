const std = @import("std");

pub fn scopeCss(allocator: std.mem.Allocator, css: []const u8, scope: []const u8) ![]u8 {
    // Keyframe names are collected from the whole stylesheet up front so that
    // `animation`/`animation-name` usages can be rewritten to their scoped
    // names regardless of where (top level or inside @media) they are declared.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    try collectKeyframeNames(allocator, &names, css);

    var out: std.ArrayList(u8) = .empty;
    try scopeBlock(allocator, &out, css, scope, names.items);
    return out.toOwnedSlice(allocator);
}

pub fn scopeName(allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(source);
    return std.fmt.allocPrint(allocator, "data-yn-{x}", .{hasher.final()});
}

/// Scopes one stylesheet body. Recurses into conditional group rules (@media,
/// @supports, @container) so their nested selectors are scoped too. Other
/// at-rules (@font-face, @page, @import, ...) are emitted verbatim.
fn scopeBlock(allocator: std.mem.Allocator, out: *std.ArrayList(u8), css: []const u8, scope: []const u8, names: []const []const u8) anyerror!void {
    var i: usize = 0;
    while (i < css.len) {
        const brace = std.mem.indexOfScalarPos(u8, css, i, '{') orelse {
            try out.appendSlice(allocator, css[i..]);
            break;
        };
        const selector = std.mem.trim(u8, css[i..brace], " \t\r\n");
        const end = findRuleEnd(css, brace) orelse css.len;
        if (std.mem.startsWith(u8, selector, "@keyframes")) {
            try writeKeyframes(allocator, out, css[i..end], scope);
        } else if (isConditionalGroupRule(selector)) {
            // Emit the "@media (...) " prelude, then scope the inner rules.
            try out.appendSlice(allocator, css[i..brace]);
            try out.append(allocator, '{');
            try scopeBlock(allocator, out, css[brace + 1 .. end - 1], scope, names);
            try out.append(allocator, '}');
        } else if (std.mem.startsWith(u8, selector, "@")) {
            try out.appendSlice(allocator, css[i..end]);
        } else {
            try writeScopedSelector(allocator, out, css[i..brace], scope);
            const body = try rewriteAnimations(allocator, css[brace..end], scope, names);
            defer allocator.free(body);
            try out.appendSlice(allocator, body);
        }
        i = end;
    }
}

fn isConditionalGroupRule(selector: []const u8) bool {
    return std.mem.startsWith(u8, selector, "@media") or
        std.mem.startsWith(u8, selector, "@supports") or
        std.mem.startsWith(u8, selector, "@container");
}

fn writeScopedSelector(allocator: std.mem.Allocator, out: *std.ArrayList(u8), selector_src: []const u8, scope: []const u8) !void {
    var first = true;
    var parts = std.mem.splitScalar(u8, selector_src, ',');
    while (parts.next()) |part| {
        if (!first) try out.appendSlice(allocator, ",");
        first = false;
        const selector = std.mem.trim(u8, part, " \t\r\n");
        try appendScopedSelector(allocator, out, selector, scope);
    }
}

/// Appends the scope attribute to each compound selector, splitting on
/// top-level combinators while ignoring those inside () or [] (e.g. :not(),
/// :global()). Each compound is scoped (or left global) independently.
fn appendScopedSelector(allocator: std.mem.Allocator, out: *std.ArrayList(u8), selector: []const u8, scope: []const u8) !void {
    var i: usize = 0;
    var depth: usize = 0;
    var compound_start: usize = 0;
    while (i < selector.len) : (i += 1) {
        const c = selector[i];
        if (c == '(' or c == '[') {
            depth += 1;
        } else if (c == ')' or c == ']') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and (c == '>' or c == '+' or c == '~' or c == ' ')) {
            try scopeCompound(allocator, out, selector[compound_start..i], scope);
            try out.append(allocator, c);
            compound_start = i + 1;
        }
    }
    try scopeCompound(allocator, out, selector[compound_start..], scope);
}

/// Scopes one compound selector. `:global(...)` opts a fragment out of scoping:
/// a whole-compound wrapper (e.g. `:global(body)`) is emitted unscoped, and a
/// mixed compound (e.g. `div:global(.x)`) is unwrapped before scoping. Compounds
/// with any local part get the scope attribute before their first pseudo, so it
/// lands on the subject and never after a pseudo-element (which would be invalid).
fn scopeCompound(allocator: std.mem.Allocator, out: *std.ArrayList(u8), compound: []const u8, scope: []const u8) !void {
    if (compound.len == 0) return;
    if (globalWrapperInner(compound)) |inner| {
        // Entire compound is :global(...): emit its contents unscoped.
        try out.appendSlice(allocator, inner);
        return;
    }
    if (std.mem.indexOf(u8, compound, ":global(") != null) {
        const unwrapped = try unwrapGlobals(allocator, compound);
        defer allocator.free(unwrapped);
        try insertScopeBeforePseudo(allocator, out, unwrapped, scope);
        return;
    }
    try insertScopeBeforePseudo(allocator, out, compound, scope);
}

/// If `compound` is exactly `:global( ... )` (the closing paren is the last
/// char), returns the inner selector; otherwise null.
fn globalWrapperInner(compound: []const u8) ?[]const u8 {
    const prefix = ":global(";
    if (!std.mem.startsWith(u8, compound, prefix)) return null;
    var depth: usize = 1;
    var i = prefix.len;
    while (i < compound.len) : (i += 1) {
        if (compound[i] == '(') depth += 1;
        if (compound[i] == ')') {
            depth -= 1;
            if (depth == 0) {
                return if (i == compound.len - 1) compound[prefix.len..i] else null;
            }
        }
    }
    return null;
}

/// Replaces each `:global(INNER)` in `compound` with `INNER`, leaving the rest
/// intact, so the remainder can be scoped normally.
fn unwrapGlobals(allocator: std.mem.Allocator, compound: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const prefix = ":global(";
    var i: usize = 0;
    while (i < compound.len) {
        if (std.mem.startsWith(u8, compound[i..], prefix)) {
            var depth: usize = 1;
            var j = i + prefix.len;
            const inner_start = j;
            while (j < compound.len and depth > 0) : (j += 1) {
                if (compound[j] == '(') depth += 1;
                if (compound[j] == ')') depth -= 1;
            }
            const inner_end = if (depth == 0) j - 1 else j;
            try out.appendSlice(allocator, compound[inner_start..inner_end]);
            i = j;
        } else {
            try out.append(allocator, compound[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn insertScopeBeforePseudo(allocator: std.mem.Allocator, out: *std.ArrayList(u8), compound: []const u8, scope: []const u8) !void {
    if (compound.len == 0) return;
    var depth: usize = 0;
    var insert: usize = compound.len;
    var j: usize = 0;
    while (j < compound.len) : (j += 1) {
        const c = compound[j];
        if (c == '(' or c == '[') {
            depth += 1;
        } else if (c == ')' or c == ']') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and c == ':') {
            insert = j;
            break;
        }
    }
    try out.appendSlice(allocator, compound[0..insert]);
    try out.print(allocator, "[{s}]", .{scope});
    try out.appendSlice(allocator, compound[insert..]);
}

fn findRuleEnd(css: []const u8, open_brace: usize) ?usize {
    var depth: usize = 0;
    var i = open_brace;
    while (i < css.len) : (i += 1) {
        if (css[i] == '{') depth += 1;
        if (css[i] == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn writeKeyframes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), rule: []const u8, scope: []const u8) !void {
    const open = std.mem.indexOfScalar(u8, rule, '{') orelse {
        try out.appendSlice(allocator, rule);
        return;
    };
    const header = std.mem.trim(u8, rule[0..open], " \t\r\n");
    var it = std.mem.tokenizeScalar(u8, header, ' ');
    const at = it.next() orelse "@keyframes";
    const name = it.next() orelse "";
    try out.print(allocator, "{s} {s}-{s} {s}", .{ at, name, scope, rule[open..] });
}

/// Collects every `@keyframes <name>` declared anywhere in the stylesheet. The
/// returned slices reference `css`.
fn collectKeyframeNames(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), css: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, css, i, "@keyframes")) |pos| {
        var j = pos + "@keyframes".len;
        while (j < css.len and (css[j] == ' ' or css[j] == '\t')) j += 1;
        const start = j;
        while (j < css.len and isIdentChar(css[j])) j += 1;
        if (j > start) try names.append(allocator, css[start..j]);
        i = if (j > pos) j else pos + 1;
    }
}

/// Rewrites `animation`/`animation-name` declarations within a rule body so
/// references to locally-declared keyframes use their scoped names. `body`
/// includes the surrounding braces. Unknown names (assumed global) are left
/// untouched.
fn rewriteAnimations(allocator: std.mem.Allocator, body: []const u8, scope: []const u8, names: []const []const u8) ![]u8 {
    if (names.len == 0 or body.len < 2 or body[0] != '{' or body[body.len - 1] != '}') {
        return allocator.dupe(u8, body);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    const inner = body[1 .. body.len - 1];
    var start: usize = 0;
    var i: usize = 0;
    var depth: usize = 0;
    var quote: u8 = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '(' or c == '[') {
            depth += 1;
        } else if (c == ')' or c == ']') {
            if (depth > 0) depth -= 1;
        } else if (c == ';' and depth == 0) {
            try writeDeclaration(allocator, &out, inner[start..i], scope, names);
            try out.append(allocator, ';');
            start = i + 1;
        }
    }
    try writeDeclaration(allocator, &out, inner[start..], scope, names);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn writeDeclaration(allocator: std.mem.Allocator, out: *std.ArrayList(u8), decl: []const u8, scope: []const u8, names: []const []const u8) !void {
    const colon = std.mem.indexOfScalar(u8, decl, ':') orelse {
        try out.appendSlice(allocator, decl);
        return;
    };
    const prop = std.mem.trim(u8, decl[0..colon], " \t\r\n");
    try out.appendSlice(allocator, decl[0 .. colon + 1]);
    if (isAnimationProperty(prop)) {
        try rewriteValueNames(allocator, out, decl[colon + 1 ..], scope, names);
    } else {
        try out.appendSlice(allocator, decl[colon + 1 ..]);
    }
}

fn isAnimationProperty(prop: []const u8) bool {
    return std.ascii.eqlIgnoreCase(prop, "animation") or
        std.ascii.eqlIgnoreCase(prop, "animation-name") or
        std.ascii.eqlIgnoreCase(prop, "-webkit-animation") or
        std.ascii.eqlIgnoreCase(prop, "-webkit-animation-name");
}

fn rewriteValueNames(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8, scope: []const u8, names: []const []const u8) !void {
    var i: usize = 0;
    while (i < value.len) {
        if (isIdentChar(value[i])) {
            const start = i;
            while (i < value.len and isIdentChar(value[i])) i += 1;
            const ident = value[start..i];
            if (containsName(names, ident)) {
                try out.print(allocator, "{s}-{s}", .{ ident, scope });
            } else {
                try out.appendSlice(allocator, ident);
            }
        } else {
            try out.append(allocator, value[i]);
            i += 1;
        }
    }
}

fn containsName(names: []const []const u8, ident: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, ident)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

test "scopes combinators and global selectors" {
    const out = try scopeCss(std.testing.allocator, "button > span, :global(body) { color: red; }", "data-yn-a");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "button[data-yn-a] > span[data-yn-a]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "body") != null);
}

test "global keeps its fragment unscoped while scoping the rest of the selector" {
    // Trailing local part must be scoped, not dropped.
    const a = try scopeCss(std.testing.allocator, ":global(.dark) .card { color: red; }", "data-yn-g");
    defer std.testing.allocator.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, ".dark .card[data-yn-g]") != null);

    // Leading local part is scoped, trailing :global stays global.
    const b = try scopeCss(std.testing.allocator, ".menu :global(.open) { color: red; }", "data-yn-g");
    defer std.testing.allocator.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, ".menu[data-yn-g] .open") != null);

    // Whole-compound wrapper stays fully global, even with a descendant inside.
    const c = try scopeCss(std.testing.allocator, ":global(.a .b) { color: red; }", "data-yn-g");
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, ".a .b") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "data-yn-g") == null);

    // No literal ":global(" ever leaks into the output.
    try std.testing.expect(std.mem.indexOf(u8, a, ":global(") == null);
    try std.testing.expect(std.mem.indexOf(u8, b, ":global(") == null);
    try std.testing.expect(std.mem.indexOf(u8, c, ":global(") == null);
}

test "scope attribute lands before pseudo-elements and pseudo-classes" {
    const out = try scopeCss(std.testing.allocator, "button::before { content: ''; } a:hover { color: blue; } .a:not(.b)::after { color: red; }", "data-yn-x");
    defer std.testing.allocator.free(out);
    // Pseudo-element must follow the attribute, never precede it.
    try std.testing.expect(std.mem.indexOf(u8, out, "button[data-yn-x]::before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "button::before[data-yn-x]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a[data-yn-x]:hover") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".a[data-yn-x]:not(.b)::after") != null);
}

test "selectors inside @media are scoped" {
    const out = try scopeCss(std.testing.allocator, "@media (max-width: 600px) { button { color: red; } .card > h2 { margin: 0; } }", "data-yn-m");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@media (max-width: 600px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "button[data-yn-m]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".card[data-yn-m] > h2[data-yn-m]") != null);
}

test "keyframe names are scoped at declaration and usage" {
    const out = try scopeCss(std.testing.allocator, "@keyframes spin { to { transform: rotate(360deg); } } .loader { animation: spin 1s linear infinite; }", "data-yn-k");
    defer std.testing.allocator.free(out);
    // Declaration is renamed.
    try std.testing.expect(std.mem.indexOf(u8, out, "@keyframes spin-data-yn-k") != null);
    // Usage is rewritten to the same scoped name; keywords are left alone.
    try std.testing.expect(std.mem.indexOf(u8, out, "animation: spin-data-yn-k 1s linear infinite") != null);
}

test "unknown animation names are left untouched" {
    const out = try scopeCss(std.testing.allocator, ".x { animation: globalspin 2s; }", "data-yn-u");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "animation: globalspin 2s") != null);
}

test "keyframes declared inside @media are scoped and usable" {
    const out = try scopeCss(std.testing.allocator, "@media screen { @keyframes pulse { from { opacity: 0; } } .p { animation-name: pulse; } }", "data-yn-z");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@keyframes pulse-data-yn-z") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "animation-name: pulse-data-yn-z") != null);
}
