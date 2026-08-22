const std = @import("std");

pub const Tokenizer = struct {
    pub fn count(text: []const u8) usize {
        if (text.len == 0) return 0;
        var ascii_bytes: usize = 0;
        var multi_byte_seqs: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const byte = text[i];
            if (byte < 0x80) {
                ascii_bytes += 1;
                i += 1;
            } else if (byte < 0xE0) {
                multi_byte_seqs += 1;
                i += 2;
            } else if (byte < 0xF0) {
                multi_byte_seqs += 1;
                i += 3;
            } else {
                multi_byte_seqs += 1;
                i += 4;
            }
        }
        return (ascii_bytes + 3) / 4 + multi_byte_seqs;
    }

    pub fn countMessages(messages: []const Message) usize {
        var total: usize = 0;
        for (messages) |msg| {
            total += count(msg.content);
            if (msg.name) |n| {
                total += count(n);
            }
        }
        return total;
    }

    pub const Message = struct {
        role: []const u8,
        content: []const u8,
        name: ?[]const u8 = null,
    };
};

test "tokenizer counts ascii" {
    const text = "hello world";
    const tokens = Tokenizer.count(text);
    try std.testing.expectEqual(@as(usize, 3), tokens);
}

test "tokenizer counts chinese" {
    const text = "你好世界";
    const tokens = Tokenizer.count(text);
    try std.testing.expectEqual(@as(usize, 4), tokens);
}

test "tokenizer counts mixed" {
    const text = "hello 你好 world 世界";
    const tokens = Tokenizer.count(text);
    try std.testing.expect(tokens > 0);
}

test "tokenizer empty string" {
    const tokens = Tokenizer.count("");
    try std.testing.expectEqual(@as(usize, 0), tokens);
}

test "tokenizer short ascii" {
    const text = "hi";
    const tokens = Tokenizer.count(text);
    try std.testing.expectEqual(@as(usize, 1), tokens);
}
