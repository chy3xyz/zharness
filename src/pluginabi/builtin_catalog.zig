//! Static inventory projection for upstream model-facing tool packages.
//!
//! These rows describe capabilities compiled into zharness rather than files
//! discovered by the native or WASM plugin loaders. The package names are the
//! upstream module names; tool names are the names the zharness agent actually
//! registers and executes.

const std = @import("std");

pub const Builtin = struct {
    stable_id: []const u8,
    module_name: []const u8,
    tool_names: []const []const u8,
    enabled: bool = true,
    fiber_phase: []const u8 = "active",
    entry_id: []const u8,
};

pub const entries = [_]Builtin{
    .{
        .stable_id = "tool-fs",
        .module_name = "@deepseek-ai/dsh-tool-fs",
        .tool_names = &.{ "file_read", "file_write", "file_edit" },
        .entry_id = "builtin:tool-fs",
    },
    .{
        .stable_id = "tool-fs-search",
        .module_name = "@deepseek-ai/dsh-tool-fs-search",
        .tool_names = &.{ "glob", "grep" },
        .entry_id = "builtin:tool-fs-search",
    },
    .{
        .stable_id = "tool-bash",
        .module_name = "@deepseek-ai/dsh-tool-bash",
        .tool_names = &.{"shell"},
        .entry_id = "builtin:tool-bash",
    },
    .{
        .stable_id = "tool-web",
        .module_name = "@deepseek-ai/dsh-tool-web",
        .tool_names = &.{ "web_fetch", "web_search" },
        .entry_id = "builtin:tool-web",
    },
    .{
        .stable_id = "tool-ask-user",
        .module_name = "@deepseek-ai/dsh-tool-ask-user",
        .tool_names = &.{"ask_user"},
        .entry_id = "builtin:tool-ask-user",
    },
    .{
        .stable_id = "tool-subagent",
        .module_name = "@deepseek-ai/dsh-tool-subagent",
        .tool_names = &.{"spawn_agent"},
        .entry_id = "builtin:tool-subagent",
    },
    .{
        .stable_id = "tool-goal",
        .module_name = "@deepseek-ai/dsh-tool-goal",
        .tool_names = &.{"goal_set"},
        .entry_id = "builtin:tool-goal",
    },
    .{
        .stable_id = "tool-todo",
        .module_name = "@deepseek-ai/dsh-tool-todo",
        .tool_names = &.{ "plan_add", "plan_update", "plan_set", "todo_write" },
        .entry_id = "builtin:tool-todo",
    },
    .{
        .stable_id = "tool-skill",
        .module_name = "@deepseek-ai/dsh-tool-skill",
        .tool_names = &.{ "skill_use", "skill" },
        .entry_id = "builtin:tool-skill",
    },
    .{
        .stable_id = "memory",
        .module_name = "@deepseek-ai/dsh-memory",
        .tool_names = &.{ "memory_get", "memory_set" },
        .entry_id = "builtin:memory",
    },
    .{
        .stable_id = "git",
        .module_name = "@deepseek-ai/dsh-git",
        .tool_names = &.{ "git_status", "git_diff", "git_log", "git_commit" },
        .entry_id = "builtin:git",
    },
    .{
        .stable_id = "attachments",
        .module_name = "@deepseek-ai/dsh-attachments",
        .tool_names = &.{ "attachment_list", "attachment_read" },
        .entry_id = "builtin:attachments",
    },
};
