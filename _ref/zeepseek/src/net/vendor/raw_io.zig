//! Minimal std.Io.Reader/Writer implementations over a raw POSIX socket fd,
//! used as the TLS record layer for the vendored tls_client.
//!
//! Raw posix.read/write bypass std.Io.Threaded's socket handling (which hangs
//! or mis-reports EOF on macOS streaming reads — see zigmodu's sockread notes)
//! and let us apply SO_RCVTIMEO-based read timeouts.

const std = @import("std");
const posix = std.posix;

pub const RawReader = struct {
    fd: posix.fd_t,
    io_reader: std.Io.Reader,

    pub fn init(fd: posix.fd_t, buffer: []u8) RawReader {
        return .{
            .fd = fd,
            .io_reader = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub const vtable = std.Io.Reader.VTable{
        .stream = streamImpl,
    };

    fn streamImpl(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *RawReader = @fieldParentPtr("io_reader", r);
        var tmp: [8192]u8 = undefined;
        const want = limit.minInt(tmp.len);
        if (want == 0) return 0;
        const n = posix.read(self.fd, tmp[0..want]) catch |e| switch (e) {
            error.WouldBlock => {
                return error.ReadFailed;
            },
            error.ConnectionResetByPeer => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        if (n == 0) return 0;
        return w.write(tmp[0..n]) catch error.WriteFailed;
    }
};

pub const RawWriter = struct {
    fd: posix.fd_t,
    io_writer: std.Io.Writer,

    pub fn init(fd: posix.fd_t, buffer: []u8) RawWriter {
        return .{
            .fd = fd,
            .io_writer = .{
                .vtable = &vtable,
                .buffer = buffer,
                .end = 0,
            },
        };
    }

    pub const vtable = std.Io.Writer.VTable{
        .drain = writeImpl,
        .rebase = rebaseImpl,
    };

    /// Compact the buffered bytes to the front without writing to the socket
    /// (defaultRebase asserts drain returns 0, which conflicts with a
    /// write-through drain like ours).
    fn rebaseImpl(w: *std.Io.Writer, preserve: usize, unused_capacity_len: usize) std.Io.Writer.Error!void {
        _ = unused_capacity_len;
        const self: *RawWriter = @fieldParentPtr("io_writer", w);
        const keep = self.io_writer.end -| preserve;
        if (keep > 0 and preserve > 0) {
            std.mem.copyForwards(u8, self.io_writer.buffer[0..keep], self.io_writer.buffer[preserve..self.io_writer.end]);
        }
        self.io_writer.end = keep;
    }

    fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn writeImpl(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *RawWriter = @fieldParentPtr("io_writer", w);
        var written: usize = 0;
        // Flush path: defaultFlush calls drain(&.{""}, 1) and expects us to
        // write buffer[0..end] and reset end.
        if (self.io_writer.end > 0) {
            writeAllFd(self.fd, self.io_writer.buffer[0..self.io_writer.end]) catch return error.WriteFailed;
            written += self.io_writer.end;
            self.io_writer.end = 0;
        }
        for (data) |d| {
            writeAllFd(self.fd, d) catch return error.WriteFailed;
            written += d.len;
        }
        if (splat > 0 and data.len > 0) {
            const last = data[data.len - 1];
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                writeAllFd(self.fd, last) catch return error.WriteFailed;
                written += last.len;
            }
        }
        return written;
    }
};
