//! Zig 0.18 `std.Io` compatibility shim.
//!
//! 0.18 replaced direct `Io.VTable` calls with the `io.operate(.{ ... })`
//! operation model. These helpers keep the older call shapes used by the
//! WASI p2/p3 host code so those call sites stay readable.

const std = @import("std");

pub fn read(io: std.Io, handle: std.Io.net.Socket.Handle, bufs: [][]u8) anyerror!usize {
    return (try (try io.operate(.{ .net_read = .{
        .socket_handle = handle,
        .data = bufs,
    } })).net_read).data_len;
}

pub fn write(io: std.Io, handle: std.Io.net.Socket.Handle, data: []const u8) anyerror!usize {
    const one = [_][]const u8{data};
    return writeVec(io, handle, &one);
}

pub fn writeVec(io: std.Io, handle: std.Io.net.Socket.Handle, data: []const []const u8) anyerror!usize {
    const r = try io.operate(.{ .net_write = .{
        .socket_handle = handle,
        .header = "",
        .data = data,
        .splat = 1,
    } });
    return try r.net_write;
}
