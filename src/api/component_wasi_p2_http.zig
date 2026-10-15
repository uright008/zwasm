//! WASI Preview 2 `wasi:http` host — `wasi:http/types` + `wasi:http/outgoing-handler`.
//!
//! First slice: the guest-visible surface a real p2 client needs for a request
//! with a streamed response body — `fields`, `outgoing-request`,
//! `request-options`, `outgoing-handler.handle`, `future-incoming-response`,
//! `incoming-response` and `incoming-body`, plus the body `input-stream`.
//!
//! The exchange runs eagerly with a bounded body buffer, and the socket is
//! closed before `handle` returns, so the body is served from host memory.
//! Not in this slice (next): a lazy reader that streams from the live
//! connection, request bodies (`outgoing-body`), trailers, response headers,
//! and the server-side resources.
//!
//! Encoding note: p2 handles are 32-bit, so a variant payload starts at +4
//! (`result<own<T>, error-code>` writes the handle at +4, the error-code
//! discriminant at +4 and its payload at +8). This differs from the p3 host,
//! whose handles are 8-byte aligned (+8/+16).

const std = @import("std");

const ctx_mod = @import("component_wasi_ctx.zig");
const p3http = @import("../wasi/p3_http.zig");
const resource_table = @import("../feature/component/resource_table.zig");
const Caller = @import("../zwasm/caller.zig").Caller;

const Allocator = std.mem.Allocator;
const WasiP2Ctx = ctx_mod.WasiP2Ctx;
const WasiP2Error = ctx_mod.WasiP2Error;
const Memory = ctx_mod.Memory;

/// Bounded response body. A larger body fails the call with `internal-error`
/// instead of buffering without limit; the lazy-reader slice removes the cap.
pub const MAX_BODY_BYTES: usize = 8 * 1024 * 1024;

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
    try mem.write(retptr + 8, @as(u8, 37)); // internal-error
    try mem.write(retptr + 16, @as(u8, 0)); // option<string> = none
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
    performExchange(ctx, req, opts, ex) catch {
        return writeInternalError(mem, retptr);
    };

    const handle = ctx.resources.new(WasiP2Ctx.HTTP_P2_FUTURE_RT, idx) catch return WasiP2Error.OutOfMemory;
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 8, handle); // error-code's option<u64> case aligns the payload to 8
}

/// The transport: one blocking exchange, bounded body buffering. The scheme is
/// honoured (`std.http.Client` does verified TLS for `https`), the authority
/// and path come from the request, and headers are copied from the fields
/// resource minus `content-length` (the std client computes it).
fn performExchange(ctx: *WasiP2Ctx, req: *p3http.HttpRequest, opts: p3http.HttpRequestOptions, ex: *Exchange) !void {
    _ = opts; // timeouts land with the lazy-reader slice (they need a deadline loop)
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

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var hreq = try client.request(method, uri, .{ .extra_headers = extra.items });
    defer hreq.deinit();
    try hreq.sendBodiless();
    var head_buf: [8192]u8 = undefined;
    var hresp = try hreq.receiveHead(&head_buf);

    ex.status = @intCast(@intFromEnum(hresp.head.status));

    var transfer_buf: [16 * 1024]u8 = undefined;
    const rdr = hresp.reader(&transfer_buf);
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    while (true) {
        const chunk = rdr.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (body.items.len + chunk.len > MAX_BODY_BYTES) return error.BodyTooLarge;
        try body.appendSlice(alloc, chunk);
        rdr.toss(chunk.len);
    }
    ex.body = try body.toOwnedSlice(alloc);
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

/// Body `input-stream.read` / `blocking-read`: serve from the buffered body,
/// `stream-error::closed` at the end. Nothing blocks, so the two variants are
/// the same host path.
pub fn bodyStreamRead(ctx: *WasiP2Ctx, mem: Memory, rep: u32, len: u64, retptr: u32) WasiP2Error!void {
    const ex = try exchangeOf(ctx, rep);
    const want: usize = @intCast(@min(len, std.math.maxInt(u32)));
    const remaining = ex.body[ex.body_pos..];
    const n = @min(want, remaining.len);
    if (n == 0) {
        try mem.write(retptr, @as(u8, 1)); // err
        try mem.write(retptr + 4, @as(u8, 1)); // stream-error::closed
        return;
    }
    const ptr = try ctx.reallocGuest(@intCast(n), 1);
    @memcpy(mem.sliceAt(ptr, @intCast(n)) catch return WasiP2Error.OutOfBounds, remaining[0..n]);
    ex.body_pos += n;
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 4, ptr);
    try mem.write(retptr + 8, @as(u32, @intCast(n)));
}

/// Drop-side cleanup for the exchange-backed handles. Called from
/// `p2ResourceDrop`; the body buffer is released once the reader is gone.
pub fn dropExchangeHandle(ctx: *WasiP2Ctx, rt: u32, rep: u32) void {
    if (rep >= ctx.http_p2_exchanges.items.len) return;
    if (rt == WasiP2Ctx.HTTP_P2_BODY_STREAM_RT) {
        ctx.http_p2_exchanges.items[rep].deinit(ctx.alloc);
    }
}
