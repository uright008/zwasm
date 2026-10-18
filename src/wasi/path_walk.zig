//! fork-only (PATCHES.md `p10`): kernel-enforced containment for preopen paths.
//!
//! `path.confine()` is lexical — it counts `..` and rejects absolute paths, but
//! it cannot see a SYMLINK COMPONENT that redirects the real resolution, so a
//! guest could name `link/../../outside` and leave its preopen (the audit's
//! finding). This walker closes that by opening every INTERMEDIATE component
//! with `follow_symlinks = false`: the kernel refuses to traverse a symlink, so
//! the directory the caller finally operates in is one the kernel verified to be
//! inside the root.
//!
//! That is also what makes the lexical `..` counting sound: with no symlink
//! component, lexical depth equals real depth, so `confine()`'s rule ("an ascent
//! past the root is not capable") means what it says. `openat2`'s
//! `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS` would compress this walk into one
//! syscall; it is an optimisation, not a precondition (and macOS has no
//! `openat2`).
//!
//! The LEAF is not opened here. The caller receives `(parent, name)` and must
//! avoid following it — see `openLeaf` / `statLeaf` below, and the note in
//! `fd.zig`'s `pathOpen` for why a stat-then-open check is not enough: the guest
//! can create the symlink itself, in its own directory, between the two calls.

const std = @import("std");
const builtin = @import("builtin");

/// The separators the host kernel treats as path separators. Same rule as
/// `path.separators`: WASI writes `/`, but on Windows a `\` separates too, and
/// the kernel is what resolves the path.
const separators: []const u8 = if (builtin.os.tag == .windows) "/\\" else "/";

pub const Walked = struct {
    /// The verified parent directory of the leaf. Every component between the
    /// preopen root and this directory was opened with symlinks refused.
    parent: std.Io.Dir,
    /// The leaf's name — one component, no separators. `"."` when the path
    /// named the directory itself (e.g. `"a/b/.."`), which every caller already
    /// handles as "the directory".
    name: []const u8,

    /// The walk always owns `parent`, even when the path named a single
    /// component (it opens `.` on the root rather than borrowing it). That is
    /// one rule to remember instead of a flag: every caller closes.
    pub fn close(self: Walked, io: std.Io) void {
        self.parent.close(io);
    }
};

pub const Error = error{
    /// The path is empty, absolute, carries a drive prefix, holds an interior
    /// NUL, or ascends past the root — `confine()`'s rules, restated here so a
    /// caller that forgot to run it cannot walk out.
    Invalid,
    /// A component is a symlink. Following one could leave the preopen, and
    /// nothing about the guest's request tells us where it points, so the walk
    /// refuses rather than resolve-and-recheck.
    Escape,
    NotFound,
    NotDir,
    AccessDenied,
    NameTooLong,
    OutOfMemory,
    Unexpected,
};

/// Walk `path` from `root`, refusing symlink components, and return the leaf's
/// parent directory plus the leaf name.
///
/// `root` is borrowed: the caller keeps ownership of it, and of the returned
/// `parent` (which is `root` itself when the path is a single component).
pub fn walk(io: std.Io, root: std.Io.Dir, path: []const u8) Error!Walked {
    if (path.len == 0) return Error.Invalid;
    if (std.mem.findScalar(u8, separators, path[0]) != null) return Error.Invalid;
    if (builtin.os.tag == .windows and path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0]))
        return Error.Invalid;
    if (std.mem.findScalar(u8, path, 0) != null) return Error.Invalid;

    // Open the root itself first, so `parent` is always ours to close.
    var current = root.openDir(io, ".", .{ .iterate = true }) catch |err| return map(err);
    errdefer current.close(io);

    var depth: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, separators);
    var name: []const u8 = ".";
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth == 0) return Error.Escape; // ascends past the preopen root
            depth -= 1;
            // `..` is always a directory entry, never a symlink, so it needs no
            // no-follow flag; it still cannot leave the root, because the depth
            // it descends was built from real (symlink-free) components.
            const up = current.openDir(io, "..", .{ .iterate = true }) catch |err| return map(err);
            current.close(io);
            current = up;
            name = ".";
            continue;
        }
        if (it.peek() == null) {
            // The last component is the leaf: the caller operates on it.
            return .{ .parent = current, .name = seg };
        }
        const next = current.openDir(io, seg, .{ .follow_symlinks = false, .iterate = true }) catch |err| {
            // `ELOOP` is what the kernel answers for a symlink component with
            // follow off — the escape this walker exists to refuse.
            if (err == error.SymLinkLoop or err == error.NotDir) return Error.Escape;
            return map(err);
        };
        current.close(io);
        current = next;
        depth += 1;
        name = ".";
    }
    return .{ .parent = current, .name = name };
}

fn map(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => Error.NotFound,
        error.NotDir => Error.NotDir,
        error.AccessDenied, error.PermissionDenied => Error.AccessDenied,
        error.NameTooLong => Error.NameTooLong,
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.Unexpected,
    };
}

/// Open the leaf WITHOUT following it.
///
/// POSIX gets `O_NOFOLLOW`, so the kernel refuses a symlink leaf instead of
/// resolving it — race-free, which a stat-then-open check is not (the guest can
/// create the link itself between the two calls, inside its own directory).
/// Windows has no `openat`, so it falls back to the stat check; the fork's
/// targets are Linux and macOS.
pub fn openLeaf(
    io: std.Io,
    parent: std.Io.Dir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
    allow_directory: bool,
) Error!std.Io.File {
    if (builtin.os.tag == .windows) {
        if (try statLeaf(io, parent, name)) |st| {
            if (st.kind == .sym_link) return Error.Escape;
        }
        return parent.openFile(io, name, .{ .mode = mode, .allow_directory = allow_directory }) catch |err| return map(err);
    }
    const flags: std.posix.O = .{
        .ACCMODE = switch (mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .NOFOLLOW = true,
        .CLOEXEC = true,
        .DIRECTORY = allow_directory and false, // directories are opened by the caller's dir path
    };
    const fd = std.posix.openat(parent.handle, name, flags, 0) catch |err| switch (err) {
        error.SymLinkLoop => return Error.Escape,
        else => return map(err),
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// `stat` the leaf WITHOUT following it, returning `null` when it is a symlink
/// (which the caller must answer as an escape, not follow). Never following is
/// what makes this race-free; for every non-symlink the result is identical to
/// the following stat the guest asked for.
pub fn statLeaf(io: std.Io, parent: std.Io.Dir, name: []const u8) Error!?std.Io.File.Stat {
    const st = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return map(err);
    if (st.kind == .sym_link) return null;
    return st;
}

// ============================================================
// Tests
// ============================================================

test "walk refuses a symlink component, and stays inside for real ones" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // root/
    //   link -> ../outside.txt      (inside the root, pointing outside)
    //   sub/file.txt
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "outside" });
    try tmp.dir.createDir(io, "root", .default_dir);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    try root.createDir(io, "sub", .default_dir);
    try root.writeFile(io, .{ .sub_path = "sub/file.txt", .data = "inside" });
    try root.symLink(io, "../outside.txt", "link", .{});

    // A real component walks, and the leaf comes back by name.
    {
        const w = try walk(io, root, "sub/file.txt");
        defer w.close(io);
        try testing.expectEqualStrings("file.txt", w.name);
        const st = try w.parent.statFile(io, w.name, .{});
        try testing.expectEqual(@as(u64, 6), st.size);
    }
    // `..` that stays inside is fine; the leaf is the directory.
    {
        const w = try walk(io, root, "sub/..");
        defer w.close(io);
        try testing.expectEqualStrings(".", w.name);
    }
    // A symlink as an INTERMEDIATE component is refused, however it is spelled:
    // this is the escape the walker exists for (the kernel refuses to traverse).
    try testing.expectError(Error.Escape, walk(io, root, "link/anything"));
    try testing.expectError(Error.Escape, walk(io, root, "sub/../link/deeper"));
    // A symlink LEAF still walks - the parent it returns is verified, and the
    // leaf is the caller's responsibility (see `statLeaf` / `openLeaf`).
    {
        const w = try walk(io, root, "link");
        defer w.close(io);
        try testing.expectEqualStrings("link", w.name);
        try testing.expectEqual(@as(?std.Io.File.Stat, null), try statLeaf(io, w.parent, w.name));
    }
    // Ascending past the root is refused before any syscall.
    try testing.expectError(Error.Escape, walk(io, root, ".."));
    try testing.expectError(Error.Escape, walk(io, root, "sub/../.."));
    // Absolute / empty / NUL are refused.
    try testing.expectError(Error.Invalid, walk(io, root, "/etc/passwd"));
    try testing.expectError(Error.Invalid, walk(io, root, ""));
    try testing.expectError(Error.Invalid, walk(io, root, "a\x00b"));
}

test "openLeaf does not follow a symlink leaf" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "outside" });
    try tmp.dir.createDir(io, "root", .default_dir);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "real.txt", .data = "inside" });
    try root.symLink(io, "../outside.txt", "link", .{});

    // A real file opens.
    const f = try openLeaf(io, root, "real.txt", .read_only, false);
    defer f.close(io);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 6), try f.readPositionalAll(io, &buf, 0));

    // The symlink leaf is refused instead of resolving to the file outside.
    if (builtin.os.tag != .windows) {
        try testing.expectError(Error.Escape, openLeaf(io, root, "link", .read_only, false));
    }
    // And the stat helper reports it as a symlink, so a caller can answer an
    // escape rather than follow it.
    try testing.expectEqual(@as(?std.Io.File.Stat, null), try statLeaf(io, root, "link"));
}
