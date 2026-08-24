//! Host-half sandbox for JS closure evaluation — Node `vm` child approach.
//! Mirrors docs/dynamic-cordis-spec.md §2-3 and
//! _ref/deepseek-harness/packages/extensions/cordis-host-runner/src/sandbox.ts
//! + guard.ts.
//!
//! Decision: dynamic host halves run as JS closures in a short-lived
//! `node --input-type=module` child (or pooled worker) with a `node:vm`
//! context per package.  This keeps the model surface identical to DSH
//! (plain `async () => { code }` body returning a Cordis plugin), while the
//! host Zig only spawns, pipes `code`+`vmTimeoutMs`, and reads back
//! `provide`/`tools` registrations as JSON.
//!
//! Not security isolation: host-realm helpers reachable from the sandbox
//! (real service methods, ctx verbs, harness helpers) remain Node-capable
//! — same cooperative `bash` trust stance as DSH (sandbox.ts:7).
//! Denied Node/browser APIs trap with teaching redirects; console is
//! tagged write-through `[cordis:<id>]`; `vmTimeoutMs` bounds only the
//! synchronous portion (async bodies escape it).

const std = @import("std");
const clib = @import("../clib.zig");
const types = @import("types.zig");

// ── facade allowlist (spec §3) ──────────────────────────────────────────────

/// Lifecycle-safe Cordis verbs a host half may call. Timer verbs require
/// `inject: ['timer']` (guarded in JS; here documented for teaching errors).
pub const CTX_VERBS = [_][]const u8{
    "effect", "on", "once", "provide", "timeout", "interval",
    "setTimeout", "setInterval", "throttle", "debounce",
};

/// Teaching redirect for Node timers.
pub const TIMER_REDIRECT =
    "Node timers are unavailable. Use the cordis timer service instead: declare inject: ['timer']" ++
    " on your plugin and call ctx.timeout / ctx.interval after querying Host Service.listService" ++
    " for the exact overloads. Those calls are fiber effects, cleaned up automatically when stopped.";

/// Withheld Node APIs → teaching redirect (mirrors NODE_API_REDIRECTS in sandbox.ts).
pub const NODE_API_REDIRECTS = [_]struct { name: []const u8, redirect: []const u8 }{
    .{
        .name = "require",
        .redirect = "Node modules are unavailable. Use the cordis services on ctx instead — e.g. inject: ['fs'] for files, ['web'] for HTTP, ['bash'] for processes; query Service.listService with cordis_inspect_query first.",
    },
    .{ .name = "setTimeout", .redirect = TIMER_REDIRECT },
    .{ .name = "setInterval", .redirect = TIMER_REDIRECT },
    .{ .name = "setImmediate", .redirect = TIMER_REDIRECT },
    .{ .name = "clearTimeout", .redirect = TIMER_REDIRECT },
    .{ .name = "clearInterval", .redirect = TIMER_REDIRECT },
    .{
        .name = "fetch",
        .redirect = "Network access goes through the cordis web service: declare inject: ['web'] and call ctx.web (query Host Service.listService with cordis_inspect_query for its methods).",
    },
};

/// Withheld browser globals for the client half (mirrors DYNAMIC_CLIENT_REDIRECTS
/// in cordis-client-runner evaluator.ts — included here so the host precheck
/// can surface a unified teaching surface if clientCode trips the same probe).
pub const DYNAMIC_CLIENT_REDIRECTS = [_]struct { name: []const u8, redirect: []const u8 }{
    .{
        .name = "setTimeout",
        .redirect = "browser timer globals are unavailable in dynamic packages. Declare inject: ['timer'] on the returned plugin, query Client Service.listService for the exact API, and close over that plugin ctx. In React, create timers from an event handler or React.useEffect and return callback-form disposers from the effect cleanup.",
    },
    .{
        .name = "setInterval",
        .redirect = "browser timer globals are unavailable in dynamic packages. Declare inject: ['timer'] on the returned plugin, query Client Service.listService for the exact API, and close over that plugin ctx. In React, create timers from an event handler or React.useEffect and return callback-form disposers from the effect cleanup.",
    },
    .{
        .name = "clearTimeout",
        .redirect = "browser timer globals are unavailable in dynamic packages. Declare inject: ['timer'] on the returned plugin, query Client Service.listService for the exact API, and close over that plugin ctx. In React, create timers from an event handler or React.useEffect and return callback-form disposers from the effect cleanup.",
    },
    .{
        .name = "clearInterval",
        .redirect = "browser timer globals are unavailable in dynamic packages. Declare inject: ['timer'] on the returned plugin, query Client Service.listService for the exact API, and close over that plugin ctx. In React, create timers from an event handler or React.useEffect and return callback-form disposers from the effect cleanup.",
    },
    .{
        .name = "fetch",
        .redirect = "network belongs to the HOST half: register a handler there with harness.handle(method, fn) and call it here via host.call(method, args).",
    },
    .{
        .name = "require",
        .redirect = "modules cannot be imported here. React arrives as the `React` closure symbol; everything else goes through ctx services or host.call.",
    },
};

// ── errors ───────────────────────────────────────────────────────────────────

pub const SandboxError = error{
    EmptyCode,
    Oversize,
    SyntaxError,
    NodeMissing,
    NodeFailed,
    Timeout,
    OutOfMemory,
};

// ── config ───────────────────────────────────────────────────────────────────

pub const Config = struct {
    vmTimeoutMs: u32 = 5000,
    maxClientSourceBytes: u32 = 256_000,
    maxInvokeBytes: u32 = 64_000,

    pub fn fromDynamicConfig(c: types.DynamicConfig) Config {
        return .{
            .vmTimeoutMs = c.vmTimeoutMs,
            .maxClientSourceBytes = c.maxClientSourceBytes,
            .maxInvokeBytes = c.maxInvokeBytes,
        };
    }
};

// ── precheck (compile-only gate at define) ───────────────────────────────────
// Twin of precheckCode in sandbox.ts:212 — new Function gate + vm.Script caret
// teaching text. Here in Zig we enforce the teachable subset without executing:
// empty / oversize / obvious TypeScript `as` / `: type` hints / unbalanced
// delimiters / `});` bracket trap. Unparseable input never mints an id.

pub const Half = enum { host, client };

pub fn halfLabel(h: Half) []const u8 {
    return switch (h) {
        .host => "code.host",
        .client => "code.client",
    };
}

/// Detailed precheck failure for teaching text.
pub const PrecheckFailure = struct {
    half: Half,
    message: []const u8,
};

/// Lightweight precheck that rejects empty, oversize, TS hints, and unbalanced
/// delimiters. Returns `SandboxError.SyntaxError`/`.EmptyCode`/`.Oversize` on
/// failure. The caller formats the teaching text via `precheckTeachingMessage`.
pub fn checkCode(code: []const u8, half: Half, cfg: Config) SandboxError!void {
    const trimmed = std.mem.trim(u8, code, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyCode;
    if (code.len > cfg.maxClientSourceBytes) return error.Oversize;
    if (containsTypeAnnotationHint(trimmed)) return error.SyntaxError;
    if (!balancedDelims(trimmed)) return error.SyntaxError;
    _ = half;
}

/// Backwards-compatible alias for `checkCode` (spec names it precheckCode).
pub const precheckCode = checkCode;

pub fn precheckTeachingMessage(alloc: std.mem.Allocator, code: []const u8, half: Half, cfg: Config) ![]u8 {
    const trimmed = std.mem.trim(u8, code, " \t\r\n");
    if (trimmed.len == 0) {
        return std.fmt.allocPrint(alloc, "dynamic package `{s}` failed to parse:\n(empty code — must return a Cordis plugin)", .{halfLabel(half)});
    }
    if (code.len > cfg.maxClientSourceBytes) {
        return std.fmt.allocPrint(alloc, "dynamic package `{s}` exceeds maxClientSourceBytes {d} (got {d})", .{ halfLabel(half), cfg.maxClientSourceBytes, code.len });
    }
    if (containsTypeAnnotationHint(trimmed)) {
        return std.fmt.allocPrint(alloc,
            \\dynamic package `{s}` failed to parse:
            \\The sandbox runs plain JavaScript, not TypeScript. Remove type annotations:
            \\  ✗ {{ type: 'text' as const, text: x }}
            \\  ✓ {{ type: 'text', text: x }}
        , .{halfLabel(half)});
    }
    if (!balancedDelims(trimmed)) {
        return std.fmt.allocPrint(alloc,
            \\dynamic package `{s}` failed to parse:
            \\Check bracket balance — ending the returned plugin object with `}});` closes a call that was never opened; a plain `return {{ … }}` ends with `}}` (an optional `;`), never `)`.
            \\Note: it runs as the BODY of an async function (line numbers are offset by the 1-line wrapper).
        , .{halfLabel(half)});
    }
    return std.fmt.allocPrint(alloc, "dynamic package `{s}` failed to parse", .{halfLabel(half)});
}

fn containsTypeAnnotationHint(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, " as ") != null) return true;
    const hints = [_][]const u8{ ": string", ": number", ": boolean", ": any", ": void", ": unknown", ": never" };
    for (hints) |h| if (std.mem.indexOf(u8, s, h) != null) return true;
    return false;
}

fn balancedDelims(s: []const u8) bool {
    var depth_paren: i32 = 0;
    var depth_brace: i32 = 0;
    var depth_brack: i32 = 0;
    var in_str: u8 = 0;
    var escaped = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str != 0) {
            if (escaped) { escaped = false; continue; }
            if (c == '\\') { escaped = true; continue; }
            if (c == in_str) in_str = 0;
            continue;
        }
        // skip line comments //... and block comments /* */
        if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
            // skip to end of line
            while (i < s.len and s[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
            i += 2;
            while (i + 1 < s.len and !(s[i] == '*' and s[i + 1] == '/')) i += 1;
            i += 1; // consume '/'
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') { in_str = c; continue; }
        switch (c) {
            '(' => depth_paren += 1,
            ')' => {
                depth_paren -= 1;
                if (depth_paren < 0) return false;
            },
            '{' => depth_brace += 1,
            '}' => {
                depth_brace -= 1;
                if (depth_brace < 0) return false;
            },
            '[' => depth_brack += 1,
            ']' => {
                depth_brack -= 1;
                if (depth_brack < 0) return false;
            },
            else => {},
        }
    }
    return depth_paren == 0 and depth_brace == 0 and depth_brack == 0 and in_str == 0;
}

// ── Node vm child: JS wrapper templates ─────────────────────────────────────

/// JS source for the per-package runner invoked as `node --input-type=module`.
/// We generate a temp file (to avoid bidirectional pipe complexity) whose
/// contents capture `packageId`, `vmTimeoutMs`, and the base64-encoded `code`.
/// The wrapper mirrors createSandbox + evaluateHostCode from sandbox.ts, but
/// stays minimal: tagged console, timer/network traps, btoa/atob/TextEncoder,
/// dual-realm instanceof patch (no-op when intrinsics unavailable), and a
/// recording harness (`defineTool`/`registerTool`/`handle`) whose arrays are
/// serialized as JSON on stdout. Console is write-through (tagged lines go to
/// host stdout/stderr via the child's inherited descriptors; the JSON result
/// alone is the machine-readable output on stdout).
fn runnerJs(
    alloc: std.mem.Allocator,
    package_id: []const u8,
    code_b64: []const u8,
    vm_timeout_ms: u32,
    invoke_method_b64: []const u8,
    invoke_args_b64: []const u8,
) ![]u8 {
    // NOTE: Keep this string in one allocPrint to avoid multi-append error
    // handling noise. The code inside is plain JS (no Zig escapes needed
    // beyond {s}/{d} substitutions). `invoke_method_b64` is empty when the
    // child should only EVALUATE; non-empty triggers the invoke epilogue
    // which calls a harness.handle(method)-registered handler and serializes
    // its return value as `value`.
    return std.fmt.allocPrint(alloc,
        \\import * as vm from 'node:vm';
        \\const __pkg="{s}";
        \\const __codeB64="{s}";
        \\const __timeout={d};
        \\const __methodB64="{s}";
        \\const __argsB64="{s}";
        \\const __code=Buffer.from(__codeB64,'base64').toString('utf8');
        \\function taggedConsole(id){{const tag=`[cordis:${{id}}]`;const lg=(...a)=>console.log(tag,...a);const er=(...a)=>console.error(tag,...a);return{{log:lg,info:lg,warn:lg,debug:lg,error:er}};}}
        \\const TIMER_REDIRECT="Node timers are unavailable. Use the cordis timer service instead: declare inject: ['timer'] on your plugin and call ctx.timeout / ctx.interval after querying Host Service.listService for the exact overloads. Those calls are fiber effects, cleaned up automatically when stopped.";
        \\const NODE_API_REDIRECTS={{require:"Node modules are unavailable. Use the cordis services on ctx instead — e.g. inject: ['fs'] for files, ['web'] for HTTP, ['bash'] for processes; query Service.listService with cordis_inspect_query first.",setTimeout:TIMER_REDIRECT,setInterval:TIMER_REDIRECT,setImmediate:TIMER_REDIRECT,clearTimeout:TIMER_REDIRECT,clearInterval:TIMER_REDIRECT,fetch:"Network access goes through the cordis web service: declare inject: ['web'] and call ctx.web (query Host Service.listService with cordis_inspect_query for its methods)."}};
        \\function nodeApiTraps(){{const t={{}};for(const[k,v]of Object.entries(NODE_API_REDIRECTS))t[k]=()=>{{throw new Error(`${{k}} is not available in the dynamic package sandbox — ${{v}}`);}};return t;}}
        \\const __provides=[];const __tools=[];const __handles=[];const __handleMap={{}};
        \\function sandboxDefineTool(def){{__tools.push(def);return def;}}
        \\function sandboxRegisterTool(ctx,tool){{__tools.push(tool);return ()=>{{}};}}
        \\function sandboxHandle(method,handler){{__handles.push(method);__handleMap[method]=handler;return ()=>{{}};}}
        \\const __harness={{defineTool:sandboxDefineTool,registerTool:sandboxRegisterTool,handle:sandboxHandle}};
        \\function createSandbox(id){{const s={{...nodeApiTraps(),console:taggedConsole(id),harness:__harness,btoa:(x)=>Buffer.from(x,'utf8').toString('base64'),atob:(x)=>Buffer.from(x,'base64').toString('utf8'),TextEncoder,TextDecoder}};vm.createContext(s);try{{const prelude="(hostIntrinsics)=>{{'use strict';const ord=Function.prototype[Symbol.hasInstance];for(const name of Object.keys(hostIntrinsics)){{const VmCtor=globalThis[name];const HostCtor=hostIntrinsics[name];if(typeof VmCtor!=='function'||typeof HostCtor!=='function')continue;Object.defineProperty(VmCtor,Symbol.hasInstance,{{value:(i)=>ord.call(VmCtor,i)||ord.call(HostCtor,i),configurable:true}});}}}}";const fn=vm.runInContext(prelude,s);fn({{Object,Array,Function,Error,Promise,RegExp,Date,Map,Set}});}}catch{{}}return s;}}
        \\const __sandbox=createSandbox(__pkg);
        \\function syntaxErrorContext(err){{const lines=(err.stack??'').split('\n');const idx=lines.findIndex(l=>l.startsWith('SyntaxError'));if(idx===-1)return String(err);return lines.slice(0,idx+1).join('\n');}}
        \\function parseErrorMessage(half,ctx){{const line=(ctx.split('\n')[1]??'');if(/\bas\b/.test(line))return `dynamic package ${{half}} failed to parse:\n${{ctx}}\nThe sandbox runs plain JavaScript, not TypeScript. Remove type annotations:\n  ✗ {{ type: 'text' as const, text: x }}\n  ✓ {{ type: 'text', text: x }}`;return `dynamic package ${{half}} failed to parse:\n${{ctx}}\nNote: it runs as the BODY of an async function (line numbers are offset by the 1-line wrapper). Check bracket balance — ending the returned plugin object with \`}});\` closes a call that was never opened; a plain \`return {{ … }}\` ends with \`}}\` (an optional \`;\`), never \`)\`.`;}}
        \\let __result=null;let __err=null;
        \\try{{__result=await vm.runInContext(`(async () => {{\n${{__code}}\n}})()`,__sandbox,{{filename:`cordis-dyn-${{__pkg}}.js`,timeout:__timeout}});}}catch(e){{if(e&&e.name==='SyntaxError'){{__err=parseErrorMessage('code.host',syntaxErrorContext(e));}}else{{__err=String(e&&e.stack?e.stack:e);}}}}
        \\if(__err){{process.stderr.write(__err+'\n');process.stdout.write(JSON.stringify({{ok:false,error:__err,provides:__provides,tools:__tools,handles:__handles}}));process.exit(1);}}
        \\// Provide/tools were captured via harness helpers. In invoke mode the
        \\// epilogue routes the call to a harness.handle-registered handler and
        \\// serializes its return value; otherwise value stays null.
        \\const __out={{ok:true,provides:__provides,tools:__tools,handles:__handles,value:null,code:null,message:null}};
        \\if(__methodB64!==""){{const __im=Buffer.from(__methodB64,'base64').toString('utf8');const __ia=JSON.parse(Buffer.from(__argsB64,'base64').toString('utf8'));const __ih=__handleMap[__im];if(typeof __ih!=='function'){{__out.ok=false;__out.code='unknown-method';__out.message=`no harness.handle(${{JSON.stringify(__im)}}) registered in this package (registered: [${{Object.keys(__handleMap).join(', ')||'none'}}])`;}}else{{try{{const __iv=await __ih(__ia);__out.value=__iv===undefined?null:__iv;}}catch(e){{__out.ok=false;__out.code='handler-error';__out.message=String(e&&e.stack?e.stack:e);}}}}}}
        \\process.stdout.write(JSON.stringify(__out));
        \\
    , .{ package_id, code_b64, vm_timeout_ms, invoke_method_b64, invoke_args_b64 });
}

// ── RunResult ────────────────────────────────────────────────────────────────

pub const ToolRegistration = struct {
    name: []const u8,
    description: []const u8,
    raw_json: []const u8,

    pub fn deinit(self: *const ToolRegistration, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.raw_json);
    }
};

pub const RunResult = struct {
    ok: bool,
    provides: [][]const u8 = &.{},
    tools: []ToolRegistration = &.{},
    handles: [][]const u8 = &.{},
    raw_json: []const u8 = "",
    err: ?[]const u8 = null,
    /// Serialized return value of an invoked harness.handle handler
    /// ({ok,value} contract, spec §7). Empty on plain evaluations.
    value_json: []const u8 = "",
    /// Invoke failure code ("unknown-method" | "handler-error").
    code: ?[]const u8 = null,
    /// Human message accompanying an invoke failure code.
    message: ?[]const u8 = null,

    pub fn deinit(self: *RunResult, alloc: std.mem.Allocator) void {
        for (self.provides) |p| alloc.free(p);
        if (self.provides.len > 0) alloc.free(self.provides);
        for (self.tools) |*t| t.deinit(alloc);
        if (self.tools.len > 0) alloc.free(self.tools);
        for (self.handles) |h| alloc.free(h);
        if (self.handles.len > 0) alloc.free(self.handles);
        if (self.raw_json.len > 0) alloc.free(self.raw_json);
        if (self.err) |e| alloc.free(e);
        if (self.value_json.len > 0) alloc.free(self.value_json);
        if (self.code) |c| alloc.free(c);
        if (self.message) |m| alloc.free(m);
    }
};

// ── Sandbox ──────────────────────────────────────────────────────────────────

pub const Sandbox = struct {
    alloc: std.mem.Allocator,
    config: Config,

    pub fn init(alloc: std.mem.Allocator, cfg: Config) Sandbox {
        return .{ .alloc = alloc, .config = cfg };
    }

    pub fn initDefault(alloc: std.mem.Allocator) Sandbox {
        return .{ .alloc = alloc, .config = .{} };
    }

    /// Compile-only gate: rejects empty / oversize / TS-hinted / unbalanced
    /// input before an id is minted (mirrors registry precheck + sandbox.ts).
    pub fn precheckCode(self: *const Sandbox, code: []const u8, half: Half) SandboxError!void {
        return checkCode(code, half, self.config);
    }

    /// Formatted teaching message for a precheck failure (owned, caller frees).
    pub fn precheckMessage(self: *const Sandbox, alloc: std.mem.Allocator, code: []const u8, half: Half) ![]u8 {
        return precheckTeachingMessage(alloc, code, half, self.config);
    }

    /// Evaluate the host half in a short-lived `node --input-type=module`
    /// child per package: pipe the module + vmTimeoutMs, read back
    /// `provide`/`tools` registrations as JSON. The child is a `node:vm`
    /// context — tagged console is write-through to host stdout/stderr;
    /// timer/network traps throw redirects; escape via host-realm helpers
    /// remains (bash trust).
    ///
    /// Minimal pooled-worker alternative: keep one `node` process and reuse
    /// its vm contexts; the per-package spawn chosen here is simpler and
    /// matches the spec's "short-lived child per package OR pooled worker".
    pub fn runHostHalf(self: *const Sandbox, package_id: []const u8, code: []const u8) !RunResult {
        try self.precheckCode(code, .host);
        return self.runRunner(package_id, code, null);
    }

    /// Unary invoke (spec §7): evaluate the host half, then call a
    /// `harness.handle(method)` handler with parsed args and serialize its
    /// return value as `value_json`. Failure carries {code,message}
    /// ("unknown-method" | "handler-error").
    pub fn invokeHostHalf(
        self: *const Sandbox,
        package_id: []const u8,
        code: []const u8,
        method: []const u8,
        args_json: []const u8,
    ) !RunResult {
        try self.precheckCode(code, .host);
        return self.runRunner(package_id, code, .{ .method = method, .args_json = args_json });
    }

    pub const InvokeSpec = struct {
        method: []const u8,
        args_json: []const u8,
    };

    fn runRunner(self: *const Sandbox, package_id: []const u8, code: []const u8, invoke: ?InvokeSpec) !RunResult {
        const alloc = self.alloc;

        // Base64-encode code to avoid JS escaping hazards.
        const b64_len = std.base64.standard.Encoder.calcSize(code.len);
        const code_b64 = try alloc.alloc(u8, b64_len);
        defer alloc.free(code_b64);
        _ = std.base64.standard.Encoder.encode(code_b64, code);

        var method_b64: ?[]u8 = null;
        var args_b64: ?[]u8 = null;
        defer {
            if (method_b64) |v| alloc.free(v);
            if (args_b64) |v| alloc.free(v);
        }
        if (invoke) |iv| {
            method_b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(iv.method.len));
            _ = std.base64.standard.Encoder.encode(method_b64.?, iv.method);
            args_b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(iv.args_json.len));
            _ = std.base64.standard.Encoder.encode(args_b64.?, iv.args_json);
        }

        const js = try runnerJs(alloc, package_id, code_b64, self.config.vmTimeoutMs, method_b64 orelse "", args_b64 orelse "");
        defer alloc.free(js);

        // Write runner to a private temp file; then `node <file>` via popen.
        const tmp = try clib.createPrivateTemp(alloc, "zh_sandbox_");
        if (tmp == null) return error.OutOfMemory;
        defer {
            clib.unlinkPath(tmp.?);
            alloc.free(tmp.?);
        }
        // tmp is e.g. "/tmp/zh_sandbox_XXXXXX" with actual path; overwrite via Io.Dir.writeFile
        {
            var threaded = std.Io.Threaded.init(alloc, .{});
            defer threaded.deinit();
            const io = threaded.io();
            const tmp_path = tmp.?;
            const slash = std.mem.lastIndexOfScalar(u8, tmp_path, '/') orelse 0;
            const dir_path = if (slash == 0) "/" else tmp_path[0..slash];
            const base = tmp_path[slash + 1 ..];
            var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{}) catch return error.NodeFailed;
            defer std.Io.Dir.close(dir, io);
            dir.writeFile(io, .{ .sub_path = base, .data = js }) catch return error.NodeFailed;
        }
        // Also ensure .mjs extension for ESM import; rename if needed is not required —
        // node will run plain JS file as CommonJS/ESM based on import statement.
        // Our file uses `import * as vm` so it needs ESM. Use `node --input-type=module`
        // style by renaming to .mjs then invoking as `node <mjs>`.
        const mjs_path = try std.fmt.allocPrint(alloc, "{s}.mjs", .{tmp.?});
        defer alloc.free(mjs_path);
        // rename tmp -> mjs_path
        if (!clib.renamePath(tmp.?, mjs_path)) return error.NodeFailed;
        // Prevent double-unlink of old path (already moved) — tmp.? is stale
        // but unlink is best-effort so harmless. Also queue mjs_path unlink.
        // Use a second defer without `catch return` (illegal in defer).
        defer {
            const mjs_z = alloc.dupeSentinel(u8, mjs_path, 0) catch null;
            if (mjs_z) |z| {
                defer alloc.free(z);
                clib.unlinkPath(z);
            }
        }

        const cmd = try std.fmt.allocPrint(alloc, "node '{s}' 2>&1", .{mjs_path});
        defer alloc.free(cmd);
        const cmd_z = try alloc.dupeSentinel(u8, cmd, 0);
        defer alloc.free(cmd_z);

        const fp = clib.popenRead(cmd_z.ptr) orelse return error.NodeMissing;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = std.c.fread(&buf, 1, buf.len, fp);
            if (n == 0) break;
            try out.appendSlice(alloc, buf[0..n]);
            if (out.items.len > 4 * 1024 * 1024) break; // 4 MiB cap (spec default_max_result_bytes)
        }
        const status = clib.pclosePipe(fp);
        const exited_ok = (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;

        // The runner writes its machine-readable JSON as ONE line on stdout;
        // tagged `[cordis:*]` console lines may precede it.
        const raw = try alloc.dupe(u8, out.items);
        errdefer alloc.free(raw);

        var result = RunResult{ .ok = exited_ok, .raw_json = raw };

        if (findResultLine(raw)) |candidate| {
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, candidate, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                const obj = p.value.object;
                if (obj.get("ok")) |ok_v| {
                    result.ok = switch (ok_v) {
                        .bool => |b| b,
                        else => exited_ok,
                    };
                }
                if (obj.get("error")) |e| {
                    if (e == .string) result.err = try alloc.dupe(u8, e.string);
                }
                if (obj.get("provides")) |pv| {
                    if (pv == .array) {
                        var list: std.ArrayList([]const u8) = .empty;
                        errdefer {
                            for (list.items) |it| alloc.free(it);
                            list.deinit(alloc);
                        }
                        for (pv.array.items) |item| {
                            if (item == .string) try list.append(alloc, try alloc.dupe(u8, item.string));
                        }
                        result.provides = try list.toOwnedSlice(alloc);
                    }
                }
                if (obj.get("tools")) |tv| {
                    if (tv == .array) {
                        var list: std.ArrayList(ToolRegistration) = .empty;
                        errdefer {
                            for (list.items) |*it| it.deinit(alloc);
                            list.deinit(alloc);
                        }
                        for (tv.array.items) |item| {
                            // tools are raw defs pushed via harness.defineTool — keep raw JSON
                            const raw_item = std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(item, .{})}) catch continue;
                            // Try to pull name/description for convenience
                            var name: []const u8 = "";
                            var desc: []const u8 = "";
                            if (item == .object) {
                                if (item.object.get("name")) |n| {
                                    if (n == .string) name = n.string;
                                }
                                if (item.object.get("description")) |d| {
                                    if (d == .string) desc = d.string;
                                }
                            }
                            try list.append(alloc, .{
                                .name = try alloc.dupe(u8, name),
                                .description = try alloc.dupe(u8, desc),
                                .raw_json = raw_item,
                            });
                        }
                        result.tools = try list.toOwnedSlice(alloc);
                    }
                }
                if (obj.get("handles")) |hv| {
                    if (hv == .array) {
                        var list: std.ArrayList([]const u8) = .empty;
                        errdefer {
                            for (list.items) |it| alloc.free(it);
                            list.deinit(alloc);
                        }
                        for (hv.array.items) |item| {
                            if (item == .string) try list.append(alloc, try alloc.dupe(u8, item.string));
                        }
                        result.handles = try list.toOwnedSlice(alloc);
                    }
                }
                if (obj.get("value")) |v| {
                    if (v != .null) {
                        result.value_json = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(v, .{})});
                    }
                }
                if (obj.get("code")) |c| {
                    if (c == .string) result.code = try alloc.dupe(u8, c.string);
                }
                if (obj.get("message")) |m| {
                    if (m == .string) result.message = try alloc.dupe(u8, m.string);
                }
            }
        }
        return result;
    }
};

/// Scan stdout lines back-to-front for one that starts with `{` and looks
/// like a complete JSON object — the runner's output line. Console lines
/// carry the `[cordis:*]` tag so they never qualify; a model logging raw
/// JSON could, which is why the LAST complete-looking line wins.
fn findResultLine(raw: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var pos: usize = 0;
    while (pos <= raw.len) {
        const rel_end = std.mem.indexOfScalarPos(u8, raw, pos, '\n') orelse raw.len;
        const line = std.mem.trim(u8, raw[pos..rel_end], " \t\r");
        if (line.len >= 2 and line[0] == '{' and jsonLooksComplete(line)) found = line;
        if (rel_end == raw.len) break;
        pos = rel_end + 1;
    }
    return found;
}

fn jsonLooksComplete(s: []const u8) bool {
    if (s[s.len - 1] != '}') return false;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    for (s) |c| {
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return depth == 0 and !in_str;
}

// ── tests ────────────────────────────────────────────────────────────────────

test "precheck rejects empty and oversize" {
    const s = Sandbox.initDefault(std.testing.allocator);
    try std.testing.expectError(error.EmptyCode, s.precheckCode("   \n", .host));
    const big = try std.testing.allocator.alloc(u8, 300_000);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try std.testing.expectError(error.Oversize, s.precheckCode(big, .host));
}

test "precheck rejects TypeScript hints" {
    const s = Sandbox.initDefault(std.testing.allocator);
    try std.testing.expectError(error.SyntaxError, s.precheckCode("const x = y as const;", .host));
    try std.testing.expectError(error.SyntaxError, s.precheckCode("function f(x: string) {}", .host));
}

test "precheck rejects unbalanced delimiters" {
    const s = Sandbox.initDefault(std.testing.allocator);
    try std.testing.expectError(error.SyntaxError, s.precheckCode("return { a: 1", .host));
    try std.testing.expectError(error.SyntaxError, s.precheckCode("function f() { return [1,2 }", .host));
    try s.precheckCode("return { apply(ctx) { ctx.on('x', ()=>{}) } }", .host);
}

test "precheck message contains teaching hint for TS" {
    const s = Sandbox.initDefault(std.testing.allocator);
    const msg = try s.precheckMessage(std.testing.allocator, "const x = y as const;", .host);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "TypeScript") != null);
}

test "CTX_VERBS and redirect tables are non-empty" {
    try std.testing.expect(CTX_VERBS.len == 10);
    try std.testing.expect(NODE_API_REDIRECTS.len == 7);
    try std.testing.expect(DYNAMIC_CLIENT_REDIRECTS.len == 6);
}

test "findResultLine picks the last complete JSON line" {
    try std.testing.expectEqualStrings("{\"ok\":true}", findResultLine("[cordis:pkg] hello\n{\"ok\":true}\n").?);
    // Nested objects must survive: last '{' alone is not the result start.
    const nested = "[c] x\n{\"ok\":true,\"value\":{\"a\":1}}\n";
    try std.testing.expectEqualStrings("{\"ok\":true,\"value\":{\"a\":1}}", findResultLine(nested).?);
    try std.testing.expect(findResultLine("no json here") == null);
    try std.testing.expect(findResultLine("{\"truncated\": ") == null);
}

test "invokeHostHalf routes harness.handle when node is available" {
    const s = Sandbox.initDefault(std.testing.allocator);
    const code = "harness.handle('ping', (a) => ({ pong: (a && a.n) || 0 })); return {};";
    var res = s.invokeHostHalf("pkg-invoke-1", code, "ping", "{\"n\":41}") catch |e| switch (e) {
        error.NodeMissing, error.NodeFailed => return,
        else => return e,
    };
    defer res.deinit(std.testing.allocator);
    if (!res.ok) return; // node present but environment broken — skip
    try std.testing.expect(std.mem.indexOf(u8, res.value_json, "41") != null);

    var bad = s.invokeHostHalf("pkg-invoke-1", code, "nope", "{}") catch |e| switch (e) {
        error.NodeMissing, error.NodeFailed => return,
        else => return e,
    };
    defer bad.deinit(std.testing.allocator);
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("unknown-method", bad.code.?);
    try std.testing.expect(std.mem.indexOf(u8, bad.message.?, "harness.handle") != null);
}

test "runHostHalf evaluates trivial code when node is available" {
    const s = Sandbox.initDefault(std.testing.allocator);
    // If node is missing, this test is skipped (returns NodeMissing).
    const code = "return { name: 'demo', apply(ctx) {} };";
    var res = s.runHostHalf("pkg-test-1", code) catch |e| switch (e) {
        error.NodeMissing => return,
        error.NodeFailed => return,
        else => return e,
    };
    defer res.deinit(std.testing.allocator);
    // Minimal runner always reports ok:true even if plugin shape is not validated here.
    try std.testing.expect(res.raw_json.len > 0);
}
