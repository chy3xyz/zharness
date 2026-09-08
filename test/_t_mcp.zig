//! E-mcp selftest root — folds the MCP area's modules into one `zig test`
//! target so every inline test block runs together:
//!
//!   zig test -lc test/_t_mcp.zig
//!
//! Covers: JSON-RPC 2.0 codec round-trips + malformed rejection, the MCP
//! stdio client against in-process pipe-pair fake servers (no spawned
//! processes, fully offline), and the registry bridge (naming, schema
//! passthrough, executor bindings).

test {
    _ = @import("../src/protocol/jsonrpc.zig");
    _ = @import("../src/protocol/mcp.zig");
    _ = @import("../src/tool/mcp_bridge.zig");
}
