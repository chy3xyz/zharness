const std = @import("std");

pub const ZeepError = error{
    NetworkUnreachable,
    RateLimitExceeded,
    Timeout,
    ApiKeyMissing,
    ApiKeyInvalid,
    BudgetExhausted,
    ContextTooLarge,
    DbCorrupted,
    LoopAborted,
    ToolExecutionFailed,
    ToolExecutionDenied,
    SandboxViolation,
    SandboxInitFailed,
    TerminalNotSupported,
    InvalidConfig,
    RenderFailed,
    AllocatorExhausted,
    ConfigValidationFailed,
    MissingApiKey,
    FileNotFound,
    PathAlreadyExists,
    RestrictedCommand,
    RestrictedOperator,
    RestrictedBuiltin,
    RestrictedPrefix,
    DangerousPipe,
};

pub fn formatError(err: anyerror) []const u8 {
    inline for (@typeInfo(@TypeOf(err)).Error.Union.fields) |field| {
        if (err == @field(anyerror, field.name)) {
            return switch (@field(ZeepError, field.name)) {
                .NetworkUnreachable => "Network unreachable",
                .RateLimitExceeded => "Rate limit exceeded",
                .Timeout => "Request timed out",
                .ApiKeyMissing, .MissingApiKey => "API key missing",
                .ApiKeyInvalid => "API key invalid",
                .BudgetExhausted => "Budget exhausted",
                .ContextTooLarge => "Context too large",
                .DbCorrupted => "Database corrupted",
                .LoopAborted => "Loop aborted",
                .ToolExecutionFailed => "Tool execution failed",
                .ToolExecutionDenied => "Tool execution denied",
                .SandboxViolation => "Sandbox violation",
                .SandboxInitFailed => "Sandbox initialization failed",
                .TerminalNotSupported => "Terminal not supported",
                .InvalidConfig => "Invalid configuration",
                .RenderFailed => "Render failed",
                .AllocatorExhausted => "Allocator exhausted",
                .ConfigValidationFailed => "Config validation failed",
                .FileNotFound => "File not found",
                .PathAlreadyExists => "Path already exists",
                .RestrictedCommand => "Restricted command pattern",
                .RestrictedOperator => "Restricted operator in command",
                .RestrictedBuiltin => "Restricted builtin in command",
                .RestrictedPrefix => "Restricted prefix in command",
                .DangerousPipe => "Dangerous pipe in command",
            };
        }
    }
    return "Unknown error";
}
