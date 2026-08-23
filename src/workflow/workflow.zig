//! Workflow definitions (dev.md §XIX): a JSON document describing a named
//! DAG of agent tasks.
//!
//! Shape (hand-rolled parsing, repo style — no JSON library):
//!
//!   {
//!     "name": "research-to-merge",
//!     "steps": [
//!       { "id": "research", "prompt": "...", "max_turns": 8 },
//!       { "id": "architecture", "prompt": "...", "depends_on": ["research"] },
//!       ...
//!     ]
//!   }
//!
//! Contract:
//!   - `parse` is SYNTAX only: it maps JSON onto `Workflow` or fails with
//!     error.MalformedWorkflow. All strings come back freshly allocated from
//!     the caller's allocator (free everything via `Workflow.deinit`).
//!   - `validate` enforces SEMANTICS: at least one step, unique step ids,
//!     every `depends_on` entry references an existing id, prompts non-empty
//!     (after trimming whitespace), and the graph is acyclic. On rejection it
//!     returns a PascalCase error; `findCyclePath` renders the offending
//!     cycle as "a -> b -> a" so callers can report it.
//!   - Field lookup walks only TOP-LEVEL object members, so a prompt whose
//!     text contains something like `"id":` can never shadow a real field
//!     (unrestricted substring search would mis-parse that).
//!
//! Integration contract: main.zig reads the file, calls parse + validate,
//! then hands the Workflow to executor.Executor.run. Convenience wrapper
//! `parseValidated` does both in one call.
//!
//! Deliberately self-contained (no imports beyond std) so it stays testable
//! in isolation (`zig test -lc src/workflow/workflow.zig`).

const std = @import("std");

pub const Step = struct {
    id: []u8,
    prompt: []u8,
    /// Ids of steps that must complete before this one runs.
    depends_on: [][]u8,
    /// Optional turn cap surfaced to the runner via StepContext.max_turns.
    max_turns: ?u32 = null,

    pub fn deinit(self: *Step, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.prompt);
        for (self.depends_on) |d| alloc.free(d);
        alloc.free(self.depends_on);
    }
};

pub const Workflow = struct {
    name: []u8,
    steps: []Step,

    /// Deep-free all memory owned by this workflow.
    pub fn deinit(self: *Workflow, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.steps) |*s| s.deinit(alloc);
        alloc.free(self.steps);
    }

    /// Index of the step with the given id, or null.
    pub fn indexOfId(self: *const Workflow, id: []const u8) ?usize {
        for (self.steps, 0..) |*s, i| {
            if (std.mem.eql(u8, s.id, id)) return i;
        }
        return null;
    }

    /// Syntax-only parse; see module doc. Caller owns the result.
    pub fn parse(alloc: std.mem.Allocator, raw: []const u8) ParseError!Workflow {
        var wf = Workflow{
            .name = try alloc.dupe(u8, ""),
            .steps = try alloc.alloc(Step, 0),
        };
        errdefer wf.deinit(alloc);

        const name_val = objectFieldValue(raw, "name") orelse return error.MalformedWorkflow;
        const name = try ownedQuoted(alloc, name_val) orelse return error.MalformedWorkflow;
        alloc.free(wf.name);
        wf.name = name;

        const arr = objectFieldValue(raw, "steps") orelse return error.MalformedWorkflow;
        if (arr.len == 0 or arr[0] != '[') return error.MalformedWorkflow;
        const arr_end = findMatchingBracket(arr, 0) orelse return error.MalformedWorkflow;

        var steps: std.ArrayList(Step) = .empty;
        errdefer {
            for (steps.items) |*s| s.deinit(alloc);
            steps.deinit(alloc);
        }

        var i: usize = 1; // past '['
        while (i < arr_end - 1) : (i += 1) {
            if (arr[i] != '{') continue;
            const obj_end = findMatchingBrace(arr, i) orelse return error.MalformedWorkflow;
            const obj = arr[i..obj_end];

            const id_val = objectFieldValue(obj, "id") orelse return error.MalformedWorkflow;
            const id = try ownedQuoted(alloc, id_val) orelse return error.MalformedWorkflow;
            errdefer alloc.free(id);

            const prompt_val = objectFieldValue(obj, "prompt") orelse return error.MalformedWorkflow;
            const prompt = try ownedQuoted(alloc, prompt_val) orelse return error.MalformedWorkflow;
            errdefer alloc.free(prompt);

            const deps = try ownedStringArray(alloc, obj, "depends_on");
            errdefer freeStringArray(alloc, deps);

            const mt: ?u32 = if (objectFieldValue(obj, "max_turns")) |v|
                parseU32Literal(v) orelse return error.MalformedWorkflow
            else
                null;

            try steps.append(alloc, .{
                .id = id,
                .prompt = prompt,
                .depends_on = deps,
                .max_turns = mt,
            });
            i = obj_end - 1; // loop's += 1 lands right after '}'
        }

        wf.steps = try steps.toOwnedSlice(alloc);
        return wf;
    }

    /// Semantic validation; see module doc. Allocates only for cycle search.
    pub fn validate(self: *const Workflow, alloc: std.mem.Allocator) ValidateError!void {
        if (self.steps.len == 0) return error.EmptyWorkflow;
        for (self.steps, 0..) |*s, i| {
            if (s.id.len == 0) return error.MalformedWorkflow;
            if (std.mem.trim(u8, s.prompt, " \t\r\n").len == 0) return error.EmptyPrompt;
            // Unique ids.
            for (self.steps[i + 1 ..]) |*other| {
                if (std.mem.eql(u8, s.id, other.id)) return error.DuplicateStepId;
            }
            // Deps must reference existing ids.
            for (s.depends_on) |d| {
                if (self.indexOfId(d) == null) return error.UnknownDependency;
            }
        }
        // Any leftover cycle?
        if (try findCyclePath(alloc, self)) |rep| {
            alloc.free(rep);
            return error.CyclicDependency;
        }
    }

    /// parse + validate convenience for integrators.
    pub fn parseValidated(alloc: std.mem.Allocator, raw: []const u8) (ParseError || ValidateError)!Workflow {
        var wf = try parse(alloc, raw);
        errdefer wf.deinit(alloc);
        try wf.validate(alloc);
        return wf;
    }
};

pub const ParseError = error{ MalformedWorkflow, OutOfMemory };
pub const ValidateError = error{
    EmptyWorkflow,
    DuplicateStepId,
    UnknownDependency,
    EmptyPrompt,
    CyclicDependency,
    MalformedWorkflow,
    OutOfMemory,
};

/// DFS node coloring for cycle search.
const Color = enum { white, gray, black };

/// Render the first cycle found (DFS, declaration order) as
/// "a -> b -> c -> a". Returns null when the graph is acyclic. Caller frees.
pub fn findCyclePath(alloc: std.mem.Allocator, wf: *const Workflow) !?[]u8 {
    const colors = try alloc.alloc(Color, wf.steps.len);
    defer alloc.free(colors);
    @memset(colors, .white);

    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(alloc);
    var report: ?[]u8 = null;

    for (0..wf.steps.len) |start| {
        if (colors[start] != .white) continue;
        if (try dfsCycle(alloc, wf, colors, &path, &report, start)) return report.?;
    }
    return null;
}

/// Recursive white/gray/black DFS. When an edge lands on a gray node the
/// current path suffix IS the cycle; it is rendered into `report` and the
/// search unwinds with `true`.
fn dfsCycle(
    alloc: std.mem.Allocator,
    wf: *const Workflow,
    colors: []Color,
    path: *std.ArrayList(usize),
    report: *?[]u8,
    si: usize,
) !bool {
    colors[si] = .gray;
    try path.append(alloc, si);
    defer {
        _ = path.pop();
        colors[si] = .black;
    }

    for (wf.steps[si].depends_on) |dep| {
        const di = wf.indexOfId(dep) orelse continue; // validate reports this separately
        if (colors[di] == .gray) {
            // Slice path from the gray occurrence to the end, close the loop.
            var cut: usize = 0;
            for (path.items, 0..) |p, k| {
                if (p == di) {
                    cut = k;
                    break;
                }
            }
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            for (path.items[cut..]) |p| {
                try out.appendSlice(alloc, wf.steps[p].id);
                try out.appendSlice(alloc, " -> ");
            }
            try out.appendSlice(alloc, wf.steps[di].id);
            report.* = try out.toOwnedSlice(alloc);
            return true;
        }
        if (colors[di] == .white) {
            if (try dfsCycle(alloc, wf, colors, path, report, di)) return true;
        }
    }
    return false;
}

// ── shared small JSON helpers (adapted from session/checkpoint.zig) ─────────

/// Decoded copy of a quoted-string VALUE span (span must include the quotes);
/// null when the value is not a JSON string. Caller frees.
fn ownedQuoted(alloc: std.mem.Allocator, value_span: []const u8) !?[]u8 {
    if (value_span.len < 2 or value_span[0] != '"') return null;
    // Trim the surrounding quotes, then decode escapes.
    const raw = value_span[1 .. value_span.len - 1];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                'b' => try out.append(alloc, 0x08),
                'f' => try out.append(alloc, 0x0C),
                'u' => {
                    // \uXXXX — take BMP codepoint when well-formed, else the
                    // raw bytes (prompts tolerate imperfect unicode).
                    if (i + 4 < raw.len) {
                        const cp = std.fmt.parseInt(u21, raw[i + 1 .. i + 5], 16) catch {
                            try out.append(alloc, raw[i]);
                            continue;
                        };
                        var utf8_buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                        try out.appendSlice(alloc, utf8_buf[0..n]);
                        i += 4;
                    } else {
                        try out.append(alloc, raw[i]);
                    }
                },
                else => try out.append(alloc, raw[i]),
            }
        } else {
            try out.append(alloc, raw[i]);
        }
    }
    return try out.toOwnedSlice(alloc);
}

/// Decoded copies of every string element in the array field `key` of the
/// object `obj`. Absent field or empty array → empty slice. Caller frees via
/// freeStringArray.
fn ownedStringArray(alloc: std.mem.Allocator, obj: []const u8, key: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    const span = objectFieldValue(obj, key) orelse return out.toOwnedSlice(alloc);
    if (span.len == 0 or span[0] != '[') return out.toOwnedSlice(alloc);
    const end = findMatchingBracket(span, 0) orelse return out.toOwnedSlice(alloc);

    var i: usize = 1; // past '['
    while (i < end - 1) : (i += 1) {
        if (span[i] != '"') continue;
        // Extend to the closing quote (escape-aware).
        var j = i + 1;
        while (j < span.len and span[j] != '"') : (j += 1) {
            if (span[j] == '\\') j += 1;
        }
        if (j >= span.len) break;
        const elem = try ownedQuoted(alloc, span[i .. j + 1]);
        if (elem) |s| try out.append(alloc, s);
        i = j; // loop's += 1 lands past the closing quote
    }
    return out.toOwnedSlice(alloc);
}

fn freeStringArray(alloc: std.mem.Allocator, arr: [][]u8) void {
    for (arr) |s| alloc.free(s);
    alloc.free(arr);
}

/// Raw value span for a TOP-LEVEL member of the object `obj` (which must
/// start with '{'). Unlike naive substring search this only ever matches real
/// members, so prompt bodies containing `"id":` cannot shadow fields.
/// Whitespace-tolerant; first matching member wins.
fn objectFieldValue(obj: []const u8, key: []const u8) ?[]const u8 {
    if (obj.len == 0 or obj[0] != '{') return null;
    const end = findMatchingBrace(obj, 0) orelse return null;
    const body = obj[1 .. end - 1];

    var i: usize = 0;
    while (i < body.len) {
        // Skip separators/whitespace between members.
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or
            body[i] == '\n' or body[i] == '\r' or body[i] == ',')) : (i += 1)
        {}
        if (i >= body.len) break;
        if (body[i] != '"') return null; // malformed; bail rather than guess

        // Member name (escape-aware).
        i += 1;
        const ks = i;
        while (i < body.len and body[i] != '"') : (i += 1) {
            if (body[i] == '\\' and i + 1 < body.len) i += 1;
        }
        if (i >= body.len) return null;
        const key_raw = body[ks..i];
        i += 1; // past closing quote

        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or
            body[i] == '\n' or body[i] == '\r')) : (i += 1)
        {}
        if (i >= body.len or body[i] != ':') return null;
        i += 1;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or
            body[i] == '\n' or body[i] == '\r')) : (i += 1)
        {}
        if (i >= body.len) return null;

        // Value extent by kind.
        const vstart = i;
        switch (body[i]) {
            '"' => {
                i += 1;
                while (i < body.len and body[i] != '"') : (i += 1) {
                    if (body[i] == '\\' and i + 1 < body.len) i += 1;
                }
                if (i >= body.len) return null;
                i += 1; // past closing quote
            },
            '[' => i = findMatchingBracket(body, i) orelse return null,
            '{' => i = findMatchingBrace(body, i) orelse return null,
            else => {
                // Number / literal: runs until a structural character.
                while (i < body.len and body[i] != ',' and body[i] != '}') : (i += 1) {}
            },
        }
        if (std.mem.eql(u8, key_raw, key)) return body[vstart..i];
    }
    return null;
}

/// Unsigned integer from a bare literal span (numbers/true/null style).
/// Null on garbage or values exceeding u32 range.
fn parseU32Literal(span_in: []const u8) ?u32 {
    const s = std.mem.trim(u8, span_in, " \t\r\n");
    if (s.len == 0 or s.len > 10) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    if (v > std.math.maxInt(u32)) return null;
    return @intCast(v);
}

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '{') return null;
    var count: i32 = 1;
    var i = start + 1;
    while (i < json.len and count > 0) : (i += 1) {
        switch (json[i]) {
            '{' => count += 1,
            '}' => count -= 1,
            '"' => {
                i += 1;
                while (i < json.len and json[i] != '"') : (i += 1) {
                    if (json[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (count == 0) return i;
    return null;
}

fn findMatchingBracket(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '[') return null;
    var count: i32 = 1;
    var i = start + 1;
    while (i < json.len and count > 0) : (i += 1) {
        switch (json[i]) {
            '[' => count += 1,
            ']' => count -= 1,
            '{' => {
                // Nested object — skip wholesale; back off one so the loop's
                // increment re-examines the char right after it.
                if (findMatchingBrace(json, i)) |be| {
                    i = be - 1;
                    continue;
                }
                return null;
            },
            '"' => {
                i += 1;
                while (i < json.len and json[i] != '"') : (i += 1) {
                    if (json[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (count == 0) return i;
    return null;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const sample_wf =
    \\{
    \\  "name": "ship-it",
    \\  "steps": [
    \\    { "id": "research", "prompt": "study the codebase \"deeply\"" },
    \\    { "id": "arch", "prompt": "design modules\nline two", "depends_on": ["research"], "max_turns": 4 },
    \\    { "id": "impl", "prompt": "write it", "depends_on": ["arch"] },
    \\    { "id": "review", "prompt": "review it", "depends_on": ["impl", "arch"] }
    \\  ]
    \\}
;

test "parse extracts fields incl escapes optionals and deps" {
    const alloc = testing.allocator;
    var wf = try Workflow.parse(alloc, sample_wf);
    defer wf.deinit(alloc);

    try testing.expectEqualStrings("ship-it", wf.name);
    try testing.expectEqual(@as(usize, 4), wf.steps.len);

    try testing.expectEqualStrings("research", wf.steps[0].id);
    try testing.expectEqualStrings("study the codebase \"deeply\"", wf.steps[0].prompt);
    try testing.expectEqual(@as(usize, 0), wf.steps[0].depends_on.len);
    try testing.expect(wf.steps[0].max_turns == null);

    try testing.expectEqualStrings("design modules\nline two", wf.steps[1].prompt);
    try testing.expectEqual(@as(usize, 1), wf.steps[1].depends_on.len);
    try testing.expectEqualStrings("research", wf.steps[1].depends_on[0]);
    try testing.expectEqual(@as(u32, 4), wf.steps[1].max_turns.?);

    try testing.expectEqual(@as(usize, 2), wf.steps[3].depends_on.len);
    try testing.expectEqual(@as(?usize, 2), wf.indexOfId("impl"));
    try testing.expect(wf.indexOfId("nope") == null);

    try wf.validate(alloc);
}

test "validate rejects duplicate id unknown dep and empty prompt" {
    const alloc = testing.allocator;

    const dup_json =
        \\{"name":"x","steps":[
        \\ {"id":"a","prompt":"p"},
        \\ {"id":"a","prompt":"q","depends_on":["a"]}]}
    ;
    {
        var wf = try Workflow.parse(alloc, dup_json);
        defer wf.deinit(alloc);
        try testing.expectError(error.DuplicateStepId, wf.validate(alloc));
    }

    const unknown_json =
        \\{"name":"x","steps":[
        \\ {"id":"a","prompt":"p","depends_on":["ghost"]}]}
    ;
    {
        var wf = try Workflow.parse(alloc, unknown_json);
        defer wf.deinit(alloc);
        try testing.expectError(error.UnknownDependency, wf.validate(alloc));
    }

    const empty_prompt_json =
        \\{"name":"x","steps":[{"id":"a","prompt":"   \n\t "}]}
    ;
    {
        var wf = try Workflow.parse(alloc, empty_prompt_json);
        defer wf.deinit(alloc);
        try testing.expectError(error.EmptyPrompt, wf.validate(alloc));
    }

    const no_steps_json = "{\"name\":\"x\",\"steps\":[]}";
    {
        var wf = try Workflow.parse(alloc, no_steps_json);
        defer wf.deinit(alloc);
        try testing.expectError(error.EmptyWorkflow, wf.validate(alloc));
    }
}

test "cycle rejected with offending path reported" {
    const alloc = testing.allocator;

    const cyclic_json =
        \\{"name":"loop","steps":[
        \\ {"id":"a","prompt":"pa","depends_on":["c"]},
        \\ {"id":"b","prompt":"pb","depends_on":["a"]},
        \\ {"id":"c","prompt":"pc","depends_on":["b"]}]}
    ;
    var wf = try Workflow.parse(alloc, cyclic_json);
    defer wf.deinit(alloc);
    try testing.expectError(error.CyclicDependency, wf.validate(alloc));

    const rep = (try findCyclePath(alloc, &wf)).?;
    defer alloc.free(rep);
    // DFS from a: a -> c -> b -> a.
    try testing.expectEqualStrings("a -> c -> b -> a", rep);
}

test "self dependency is a one node cycle" {
    const alloc = testing.allocator;
    const json =
        \\{"name":"solo","steps":[{"id":"a","prompt":"p","depends_on":["a"]}]}
    ;
    var wf = try Workflow.parse(alloc, json);
    defer wf.deinit(alloc);
    try testing.expectError(error.CyclicDependency, wf.validate(alloc));

    const rep = (try findCyclePath(alloc, &wf)).?;
    defer alloc.free(rep);
    try testing.expectEqualStrings("a -> a", rep);
}

test "acyclic diamond yields null cycle report" {
    const alloc = testing.allocator;
    const json =
        \\{"name":"d","steps":[
        \\ {"id":"a","prompt":"1"},
        \\ {"id":"b","prompt":"2","depends_on":["a"]},
        \\ {"id":"c","prompt":"3","depends_on":["a"]},
        \\ {"id":"d","prompt":"4","depends_on":["b","c"]}]}
    ;
    var wf = try Workflow.parse(alloc, json);
    defer wf.deinit(alloc);
    try wf.validate(alloc);
    try testing.expect(try findCyclePath(alloc, &wf) == null);
}

test "prompt containing id-like text cannot shadow real fields" {
    const alloc = testing.allocator;
    const json =
        \\{"name":"trap","steps":[
        \\ {"id":"real","prompt":"always answer with {\"id\":\"fake\",\"prompt\":\"hijack\"}"}]}
    ;
    var wf = try Workflow.parse(alloc, json);
    defer wf.deinit(alloc);
    try wf.validate(alloc);
    try testing.expectEqualStrings("real", wf.steps[0].id);
    try testing.expectEqualStrings(
        "always answer with {\"id\":\"fake\",\"prompt\":\"hijack\"}",
        wf.steps[0].prompt,
    );
}

test "malformed documents rejected" {
    const alloc = testing.allocator;
    try testing.expectError(
        error.MalformedWorkflow,
        Workflow.parse(alloc, "{\"steps\":[{\"id\":\"a\",\"prompt\":\"p\"}]}"), // no name
    );
    try testing.expectError(
        error.MalformedWorkflow,
        Workflow.parse(alloc, "{\"name\":\"x\"}"), // no steps
    );
    try testing.expectError(
        error.MalformedWorkflow,
        Workflow.parse(alloc, "{\"name\":\"x\",\"steps\":[{\"prompt\":\"p\"}]}"), // no id
    );
    try testing.expectError(
        error.MalformedWorkflow,
        Workflow.parse(alloc, "{\"name\":\"x\",\"steps\":[{\"id\":\"a\"}]}"), // no prompt
    );
    try testing.expectError(
        error.MalformedWorkflow,
        Workflow.parse(alloc, "not json at all"),
    );
    try testing.expectError(
        error.MalformedWorkflow,
        Workflow.parse(alloc, "{\"name\":\"x\",\"steps\":[{\"id\":\"a\",\"prompt\":\"p\",\"max_turns\":99999999999}]}"),
    );
}

test "unicode escape decoded in prompt" {
    const alloc = testing.allocator;
    var wf = try Workflow.parse(alloc, "{\"name\":\"u\",\"steps\":[{\"id\":\"a\",\"prompt\":\"caf\\u00e9 \\u4f60\\u597d\"}]}");
    defer wf.deinit(alloc);
    try testing.expectEqualStrings("café 你好", wf.steps[0].prompt);
}
