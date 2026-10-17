//! WASI Preview 2 `wasi:http` host — `wasi:http/types` + `wasi:http/outgoing-handler`.
//!
//! First slice: the guest-visible surface a real p2 client needs for a request
//! with a streamed response body — `fields`, `outgoing-request`,
//! `request-options`, `outgoing-handler.handle`, `future-incoming-response`,
//! `incoming-response` and `incoming-body`, plus the body `input-stream`.
//!
//! `handle` connects, sends and reads the response head, then leaves the
//! connection open: the guest's `input-stream.read` pulls body bytes on demand
//! through a fixed 16 KiB transfer buffer, so a response of any size streams
//! without a host-side copy of it. Not in this slice (next): request bodies
//! (`outgoing-body`), trailers, response headers, real readiness for the
//! non-blocking `read`, timeouts and cancellation, and the server-side
//! resources.
//!
//! Encoding note: p2 handles are 32-bit, so a variant payload starts at +4
//! (`result<own<T>, error-code>` writes the handle at +4, the error-code
//! discriminant at +4 and its payload at +8). This differs from the p3 host,
//! whose handles are 8-byte aligned (+8/+16).

const std = @import("std");

const ctx_mod = @import("component_wasi_ctx.zig");
const p3http = @import("../wasi/p3_http.zig");
const resource_table = @import("../feature/component/resource_table.zig");
const builtin = @import("builtin");
const Caller = @import("../zwasm/caller.zig").Caller;

const Allocator = std.mem.Allocator;
const WasiP2Ctx = ctx_mod.WasiP2Ctx;
const WasiP2Error = ctx_mod.WasiP2Error;
const Memory = ctx_mod.Memory;

/// The exchange state lives in `WasiP2Ctx` (`HttpP2Exchange`) so the resource
/// table, the ctx deinit and this module all speak about one type.
const Exchange = ctx_mod.HttpP2Exchange;

fn exchangeOf(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*Exchange {
    if (rep >= ctx.http_p2_exchanges.items.len) return resource_table.Error.InvalidHandle;
    return &ctx.http_p2_exchanges.items[rep];
}

/// `error-code` `internal-error(option<string>)`: discriminant 37, payload
/// `none`. The catch-all the WIT gives transport failures that have no
/// dedicated case.
///
/// Offsets: `error-code` carries `HTTP-request-body-size(option<u64>)`, so its
/// alignment is 8 — not 4. A `result<_, error-code>` therefore puts its payload
/// at +8 and the error-code payload at +16. (`result<own<T>, ()>` has no such
/// case and keeps the 4-byte alignment.)
fn writeInternalError(mem: Memory, retptr: u32) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1)); // err discriminant
    try mem.write(retptr + 8, @as(u8, 38)); // internal-error
    try mem.write(retptr + 16, @as(u8, 0)); // option<string> = none
}

/// Same shape, with a chosen `error-code` discriminant.
fn writeErrorCode(mem: Memory, retptr: u32, code: u8) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1)); // err discriminant
    try mem.write(retptr + 8, code);
}

// ============================================================
// `wasi:http/types` — fields
// ============================================================

/// `[constructor]fields` (also serves p3, which shares `ctx.http_fields`).
pub fn p2HttpFieldsNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const idx: u32 = @intCast(ctx.http_fields.items.len);
    ctx.http_fields.append(ctx.alloc, .{}) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_RT, idx);
}

// ============================================================
// `wasi:http/types` — outgoing-request
// ============================================================

/// `[constructor]outgoing-request(headers: own<fields>) -> own<outgoing-request>`.
pub fn p2HttpOutgoingRequestNew(caller: *Caller, headers: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(headers);
    if (h.rt != WasiP2Ctx.HTTP_FIELDS_RT) return resource_table.Error.TypeMismatch;
    const idx: u32 = @intCast(ctx.http_p2_requests.items.len);
    ctx.http_p2_requests.append(ctx.alloc, .{ .headers_rep = h.rep }) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_P2_OUTGOING_REQUEST_RT, idx);
}

fn outgoingRequestOf(ctx: *WasiP2Ctx, handle: u32) WasiP2Error!*p3http.HttpRequest {
    const h = try ctx.resources.peek(handle);
    if (h.rt != WasiP2Ctx.HTTP_P2_OUTGOING_REQUEST_RT) return resource_table.Error.TypeMismatch;
    if (h.rep >= ctx.http_p2_requests.items.len) return resource_table.Error.InvalidHandle;
    return &ctx.http_p2_requests.items[h.rep];
}

/// `[method]outgoing-request.set-scheme(option<scheme>) -> result`.
/// Flat params: option disc, scheme disc, string ptr, string len.
pub fn p2HttpOutgoingRequestSetScheme(caller: *Caller, self: u32, opt_disc: u32, scheme_disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const req = try outgoingRequestOf(ctx, self);
    if (opt_disc == 0) {
        if (req.scheme) |*old| old.deinit(ctx.alloc);
        req.scheme = null;
        return 0;
    }
    const name = mem.sliceAt(ptr, len) catch return 1;
    const scheme: p3http.Scheme = switch (scheme_disc) {
        0 => .http,
        1 => .https,
        else => .{ .other = ctx.alloc.dupe(u8, name) catch return WasiP2Error.OutOfMemory },
    };
    if (req.scheme) |*old| old.deinit(ctx.alloc);
    req.scheme = scheme;
    return 0;
}

/// `[method]outgoing-request.set-authority(option<string>) -> result`.
pub fn p2HttpOutgoingRequestSetAuthority(caller: *Caller, self: u32, opt_disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const req = try outgoingRequestOf(ctx, self);
    if (req.authority) |old| ctx.alloc.free(old);
    req.authority = null;
    if (opt_disc == 0) return 0;
    const name = mem.sliceAt(ptr, len) catch return 1;
    req.authority = ctx.alloc.dupe(u8, name) catch return WasiP2Error.OutOfMemory;
    return 0;
}

/// `[method]outgoing-request.set-path-with-query(option<string>) -> result`.
pub fn p2HttpOutgoingRequestSetPathWithQuery(caller: *Caller, self: u32, opt_disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const req = try outgoingRequestOf(ctx, self);
    if (req.path_with_query) |old| ctx.alloc.free(old);
    req.path_with_query = null;
    if (opt_disc == 0) return 0;
    const name = mem.sliceAt(ptr, len) catch return 1;
    req.path_with_query = ctx.alloc.dupe(u8, name) catch return WasiP2Error.OutOfMemory;
    return 0;
}

// ============================================================
// `wasi:http/types` — request-options
// ============================================================

/// `[constructor]request-options` — shares `ctx.http_reqopts` and
/// `HTTP_REQOPTS_RT` with the p3 host: same WIT resource, one host model.
pub fn p2HttpRequestOptionsNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const idx: u32 = @intCast(ctx.http_reqopts.items.len);
    ctx.http_reqopts.append(ctx.alloc, .{}) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_RT, idx);
}

fn setOptionTimeout(ctx: *WasiP2Ctx, handle: u32, opt_disc: u32, ns: i64, comptime field: []const u8) WasiP2Error!u32 {
    // A `request.get-options` view rejects sets (p3 mints those; keep the same
    // rule here).
    const h = ctx.resources.peek(handle) catch return resource_table.Error.InvalidHandle;
    if (h.rt != WasiP2Ctx.HTTP_REQOPTS_RT and h.rt != WasiP2Ctx.HTTP_REQOPTS_VIEW_RT) {
        return resource_table.Error.TypeMismatch;
    }
    if (h.rep >= ctx.http_reqopts.items.len) return resource_table.Error.InvalidHandle;
    const opts = &ctx.http_reqopts.items[h.rep];
    if (opts.immutable) return 1;
    if (opt_disc == 0) {
        @field(opts, field) = null;
        return 0;
    }
    if (ns < 0) return 1;
    @field(opts, field) = @intCast(ns);
    return 0;
}

/// `[method]request-options.set-connect-timeout(option<duration>) -> result`.
pub fn p2HttpRequestOptionsSetConnectTimeout(caller: *Caller, self: u32, opt_disc: u32, ns: i64) WasiP2Error!u32 {
    return setOptionTimeout(caller.data(WasiP2Ctx), self, opt_disc, ns, "connect_timeout_ns");
}

pub fn p2HttpRequestOptionsSetFirstByteTimeout(caller: *Caller, self: u32, opt_disc: u32, ns: i64) WasiP2Error!u32 {
    return setOptionTimeout(caller.data(WasiP2Ctx), self, opt_disc, ns, "first_byte_timeout_ns");
}

pub fn p2HttpRequestOptionsSetBetweenBytesTimeout(caller: *Caller, self: u32, opt_disc: u32, ns: i64) WasiP2Error!u32 {
    return setOptionTimeout(caller.data(WasiP2Ctx), self, opt_disc, ns, "between_bytes_timeout_ns");
}

// ============================================================
// `wasi:http/outgoing-handler`
// ============================================================

/// `handle(request: own<outgoing-request>, options: option<own<request-options>>)
///  -> result<own<future-incoming-response>, error-code>`.
pub fn p2HttpOutgoingHandlerHandle(caller: *Caller, request: u32, opt_disc: u32, opt_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);

    const req = outgoingRequestOf(ctx, request) catch {
        return writeInternalError(mem, retptr);
    };
    var opts: p3http.HttpRequestOptions = .{};
    if (opt_disc != 0) {
        const oh = ctx.resources.peek(opt_handle) catch {
            return writeInternalError(mem, retptr);
        };
        const is_opts = oh.rt == WasiP2Ctx.HTTP_REQOPTS_RT or oh.rt == WasiP2Ctx.HTTP_REQOPTS_VIEW_RT;
        if (!is_opts or oh.rep >= ctx.http_reqopts.items.len) {
            return writeInternalError(mem, retptr);
        }
        opts = ctx.http_reqopts.items[oh.rep];
    }

    const idx: u32 = @intCast(ctx.http_p2_exchanges.items.len);
    ctx.http_p2_exchanges.append(ctx.alloc, .{}) catch return WasiP2Error.OutOfMemory;
    const ex = &ctx.http_p2_exchanges.items[idx];
    var status: u16 = 0;
    ex.transfer = startTransfer(ctx, req, opts, &status) catch |e| {
        // A head that never arrives is the guest-visible `connection-timeout`
        // (ordinal 8); everything else stays the internal-error catch-all.
        if (e == error.ResponseTimeout) return writeErrorCode(mem, retptr, 8);
        return writeInternalError(mem, retptr);
    };
    ex.status = status;
    ex.between_bytes_ns = opts.between_bytes_timeout_ns;
    registerCancel(ctx, ex.transfer.?);

    const handle = ctx.resources.new(WasiP2Ctx.HTTP_P2_FUTURE_RT, idx) catch return WasiP2Error.OutOfMemory;
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 8, handle); // error-code's option<u64> case aligns the payload to 8
}

/// Wait until `handle` is readable, or `timeout_ns` expires. Same readiness
/// idiom as `p2_sockets.pollOnce`, with a deadline instead of a zero timeout.
/// Windows uses the AFD path there; here it falls back to no deadline.
fn waitReadable(handle: std.Io.net.Socket.Handle, timeout_ns: u64) WasiP2Error!bool {
    if (builtin.os.tag == .windows) return true;
    const ms: i32 = @intCast(@min(timeout_ns / std.time.ns_per_ms, @as(u64, std.math.maxInt(i32))));
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, ms) catch return WasiP2Error.ReadFailed;
    return n > 0 and (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0;
}

/// The socket behind a live transfer, for readiness waits.
fn connectionHandle(t: *Transfer) ?std.Io.net.Socket.Handle {
    const conn = t.request.connection orelse return null;
    return conn.stream_reader.stream.socket.handle;
}

/// Trampoline for `Host.http_cancel_fn` (it takes `*anyopaque`).
fn cancelTransfer(target: *anyopaque) void {
    const t: *Transfer = @ptrCast(@alignCast(target));
    t.cancel();
}

/// Publish the live transfer for host-side cancellation.
fn registerCancel(ctx: *WasiP2Ctx, t: *Transfer) void {
    ctx.host.http_cancel_fn = cancelTransfer;
    ctx.host.http_cancel_target.store(t, .release);
}

/// Drop the transfer (and its connection) and clear the cancel target.
fn destroyExchange(ctx: *WasiP2Ctx, ex: *Exchange) void {
    if (ex.transfer) |t| {
        _ = ctx.host.http_cancel_target.cmpxchgStrong(t, null, .release, .acquire);
    }
    ex.deinit(ctx.alloc);
}

/// Guest value and host cap, whichever is smaller.
fn effectiveDeadline(guest_ns: ?u64, host_ns: u64) u64 {
    return @min(guest_ns orelse host_ns, host_ns);
}

/// A live exchange. `handle` leaves the connection open and the guest's
/// `input-stream.read` pulls body bytes from it on demand.
///
/// Everything lives in ONE heap allocation because the std client's pointers
/// are self-referential: `Response` borrows `request`, `head_buf` backs the
/// response head, and the `Reader` from `Response.reader` points into the
/// connection. None of them may move, so the transfer is never stored by value
/// in a reallocating list.
pub const Transfer = struct {
    client: std.http.Client,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    reader: *std.Io.Reader,
    head_buf: [8192]u8 = undefined,
    transfer_buf: [16 * 1024]u8 = undefined,
    /// Set by `cancel` before the socket is shut down, so a read that the
    /// cancel unblocks fails the call instead of looking like a normal EOF.
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn destroy(self: *Transfer, alloc: Allocator) void {
        // LIFO of the eager path: request (closes the connection) then client.
        self.request.deinit();
        self.client.deinit();
        alloc.destroy(self);
    }

    /// Cancel from another thread: shut the socket down so a body read blocked
    /// in the kernel returns. Idempotent; the transfer itself is still owned by
    /// the guest-facing handles and is freed by `destroyExchange`.
    pub fn cancel(self: *Transfer) void {
        self.cancelled.store(true, .release);
        const conn = self.request.connection orelse return;
        conn.stream_reader.stream.shutdown(self.client.io, .both) catch {};
    }
};

/// Connect, send, read the response head. The body is left unread.
fn startTransfer(ctx: *WasiP2Ctx, req: *p3http.HttpRequest, opts: p3http.HttpRequestOptions, status_out: *u16) !*Transfer {
    const io = ctx_mod.ctxIo(ctx) catch return error.NoHostIo;
    const alloc = ctx.alloc;

    const authority = req.authority orelse return error.NoAuthority;
    const scheme: []const u8 = switch (req.scheme orelse .http) {
        .http => "http",
        .https => "https",
        .other => |s| s,
    };
    const path = req.path_with_query orelse "/";
    const url = try std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme, authority, path });
    defer alloc.free(url);

    const method: std.http.Method = switch (req.method) {
        .get => .GET,
        .head => .HEAD,
        .post => .POST,
        .put => .PUT,
        .delete => .DELETE,
        .connect => .CONNECT,
        .options => .OPTIONS,
        .trace => .TRACE,
        .patch => .PATCH,
        .other => return error.UnsupportedMethod,
    };

    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(alloc);
    if (req.headers_rep < ctx.http_fields.items.len) {
        for (ctx.http_fields.items[req.headers_rep].entries.items) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, "content-length")) continue;
            try extra.append(alloc, .{ .name = p.name, .value = p.value });
        }
    }

    const t = try alloc.create(Transfer);
    errdefer alloc.destroy(t);
    t.client = .{ .allocator = alloc, .io = io };
    errdefer t.client.deinit();

    const uri = try std.Uri.parse(url);
    t.request = try t.client.request(method, uri, .{
        .extra_headers = extra.items,
        // `wasi:http` hands redirects to the guest; following them silently
        // would hide the 3xx the guest asked to see.
        .redirect_behavior = .unhandled,
    });
    errdefer t.request.deinit();
    try t.request.sendBodiless();

    // Bound the wait for the response head: the guest's connect timeout and the
    // host cap, whichever is smaller. The connect inside `client.request` is
    // owned by std and stays bounded by the OS; this covers "slow TLS, no
    // headers" - the case a guest cannot outwait with a huge timeout.
    if (connectionHandle(t)) |h| {
        const deadline = effectiveDeadline(opts.connect_timeout_ns, ctx.host.http_head_deadline_ns);
        if (!(try waitReadable(h, deadline))) return error.ResponseTimeout;
    }
    t.response = try t.request.receiveHead(&t.head_buf);
    // Read the status BEFORE the body stream is initialized: `reader()`
    // invalidates the head's string pointers.
    status_out.* = @intCast(@intFromEnum(t.response.head.status));
    t.reader = t.response.reader(&t.transfer_buf);
    return t;
}

// ============================================================
// `wasi:http/types` — future-incoming-response / incoming-response / incoming-body
// ============================================================

/// `[method]future-incoming-response.get() -> option<result<own<incoming-response>, error-code>>`.
/// The exchange already completed, so the future is always ready.
pub fn p2HttpFutureGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_FUTURE_RT) return resource_table.Error.TypeMismatch;
    const ex = try exchangeOf(ctx, h.rep);

    // The WIT return is three levels deep:
    //   option<result<result<incoming-response, error-code>>>
    // outer `option` = readiness, outer `result` = at-most-once retrieval
    // (`err` on every call after the first that saw `some`), inner `result` =
    // the response or the transport error. Offsets match the generated
    // bindings (wasip2 proxy.rs `FutureIncomingResponse::get`): 0 / 8 / 16 / 24,
    // because error-code carries an `option<u64>` case and so aligns to 8.
    try mem.write(retptr, @as(u8, 1)); // some
    if (ex.retrieved) {
        try mem.write(retptr + 8, @as(u8, 1)); // outer err: already retrieved
        return;
    }
    ex.retrieved = true;
    const response = try ctx.resources.new(WasiP2Ctx.HTTP_P2_RESPONSE_RT, h.rep);
    try mem.write(retptr + 8, @as(u8, 0)); // outer ok
    try mem.write(retptr + 16, @as(u8, 0)); // inner ok
    try mem.write(retptr + 24, response);
}

/// `[method]future-incoming-response.subscribe() -> own<pollable>`.
pub fn p2HttpFutureSubscribe(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_FUTURE_RT) return resource_table.Error.TypeMismatch;
    _ = try exchangeOf(ctx, h.rep);
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// `[method]incoming-response.status() -> status-code`.
pub fn p2HttpIncomingResponseStatus(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_RESPONSE_RT) return resource_table.Error.TypeMismatch;
    return (try exchangeOf(ctx, h.rep)).status;
}

/// `[method]incoming-response.consume() -> result<own<incoming-body>, ()>`.
pub fn p2HttpIncomingResponseConsume(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_RESPONSE_RT) return resource_table.Error.TypeMismatch;
    _ = try exchangeOf(ctx, h.rep);
    const body = try ctx.resources.new(WasiP2Ctx.HTTP_P2_BODY_RT, h.rep);
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 4, body);
}

/// `[method]incoming-body.stream() -> result<own<input-stream>, ()>`.
pub fn p2HttpIncomingBodyStream(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_BODY_RT) return resource_table.Error.TypeMismatch;
    const ex = try exchangeOf(ctx, h.rep);
    if (ex.stream_taken) {
        // The WIT says `stream` consumes the body; a second call is an err.
        try mem.write(retptr, @as(u8, 1));
        return;
    }
    ex.stream_taken = true;
    const stream = try ctx.resources.new(WasiP2Ctx.HTTP_P2_BODY_STREAM_RT, h.rep);
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 4, stream);
}

/// Body `input-stream.read` / `blocking-read`: pull from the live connection.
/// `peekGreedy(1)` blocks until at least one byte or EOF — so both variants
/// take the same host path, and the guest sees `stream-error::closed` at the
/// end. Leftover bytes stay in the reader's transfer buffer for the next call.
pub fn bodyStreamRead(ctx: *WasiP2Ctx, mem: Memory, rep: u32, len: u64, retptr: u32) WasiP2Error!void {
    const ex = try exchangeOf(ctx, rep);
    const want: usize = @intCast(@min(len, std.math.maxInt(u32)));
    const t = ex.transfer orelse return writeStreamClosed(mem, retptr);
    if (want == 0) return writeStreamClosed(mem, retptr);
    // A cancelled transfer must not read as a clean end of body.
    if (t.cancelled.load(.acquire)) return WasiP2Error.ReadFailed;

    // Only poll when nothing is buffered anywhere in the chain: `receiveHead`
    // (and any earlier read) may already have pulled body bytes off the socket
    // - into the connection reader's buffer (`request.reader.in`) or into the
    // body reader - and the raw fd would then look unreadable while the data
    // sits in a buffer.
    if (t.reader.bufferedLen() == 0 and t.request.reader.in.bufferedLen() == 0) {
        if (connectionHandle(t)) |h| {
            const deadline = effectiveDeadline(ex.between_bytes_ns, ctx.host.http_read_deadline_ns);
            if (!(try waitReadable(h, deadline))) return WasiP2Error.ReadFailed;
        }
    }
    const chunk = t.reader.peekGreedy(1) catch |e| switch (e) {
        error.EndOfStream => {
            // A shutdown from `cancel` also surfaces as EOF: report the
            // cancellation as a failed call, not as a clean end of body.
            if (t.cancelled.load(.acquire)) return WasiP2Error.ReadFailed;
            destroyExchange(ctx, ex); // body finished: close the connection
            return writeStreamClosed(mem, retptr);
        },
        else => return WasiP2Error.ReadFailed,
    };
    if (t.cancelled.load(.acquire)) return WasiP2Error.ReadFailed; // raced with cancel
    const n = @min(want, chunk.len);
    const ptr = try ctx.reallocGuest(@intCast(n), 1);
    @memcpy(mem.sliceAt(ptr, @intCast(n)) catch return WasiP2Error.OutOfBounds, chunk[0..n]);
    t.reader.toss(n);
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 4, ptr);
    try mem.write(retptr + 8, @as(u32, @intCast(n)));
}

fn writeStreamClosed(mem: Memory, retptr: u32) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1)); // err
    try mem.write(retptr + 4, @as(u8, 1)); // stream-error::closed
}

/// Drop-side cleanup for the exchange-backed handles. The body reader owns the
/// live transfer, so dropping it closes the connection and frees the transfer.
pub fn dropExchangeHandle(ctx: *WasiP2Ctx, rt: u32, rep: u32) void {
    if (rep >= ctx.http_p2_exchanges.items.len) return;
    if (rt == WasiP2Ctx.HTTP_P2_BODY_STREAM_RT) {
        destroyExchange(ctx, &ctx.http_p2_exchanges.items[rep]);
    }
}
