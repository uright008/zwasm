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
//! non-blocking `read`, and the server-side
//! resources.
//!
//! Encoding note: p2 handles are 32-bit, so a variant payload starts at +4
//! (`result<own<T>, error-code>` writes the handle at +4, the error-code
//! discriminant at +4 and its payload at +8). This differs from the p3 host,
//! whose handles are 8-byte aligned (+8/+16).

const std = @import("std");

const ctx_mod = @import("component_wasi_ctx.zig");
const p3h = @import("component_wasi_p3_host.zig");
const p3http = @import("../wasi/p3_http.zig");
const resource_table = @import("../feature/component/resource_table.zig");
const Host = @import("../wasi/host.zig").Host;
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
    return &ctx.http_p2_requests.items[try outgoingRequestRep(ctx, handle)];
}

/// The request's index in `ctx.http_p2_requests` — what the child handles
/// (outgoing-body, its output-stream) carry as their rep.
fn outgoingRequestRep(ctx: *WasiP2Ctx, handle: u32) WasiP2Error!u32 {
    const h = try ctx.resources.peek(handle);
    if (h.rt != WasiP2Ctx.HTTP_P2_OUTGOING_REQUEST_RT) return resource_table.Error.TypeMismatch;
    if (h.rep >= ctx.http_p2_requests.items.len) return resource_table.Error.InvalidHandle;
    return h.rep;
}

fn requestByRep(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p3http.HttpRequest {
    if (rep >= ctx.http_p2_requests.items.len) return resource_table.Error.InvalidHandle;
    return &ctx.http_p2_requests.items[rep];
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
    var headers_rep: ?u32 = null;
    ex.transfer = startTransfer(ctx, req, opts, &status, &headers_rep) catch |e| {
        // A head that never arrives is the guest-visible `connection-timeout`
        // (ordinal 8); everything else stays the internal-error catch-all.
        if (e == error.ResponseTimeout) return writeErrorCode(mem, retptr, 8);
        return writeInternalError(mem, retptr);
    };
    ex.status = status;
    ex.headers_rep = headers_rep;
    ex.between_bytes_ns = opts.between_bytes_timeout_ns;

    const handle = ctx.resources.new(WasiP2Ctx.HTTP_P2_FUTURE_RT, idx) catch return WasiP2Error.OutOfMemory;
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 8, handle); // error-code's option<u64> case aligns the payload to 8
}

/// Trampoline for `Host.http_cancel_fn` (it takes `*anyopaque`).
fn cancelTransfer(target: *anyopaque) void {
    const t: *Transfer = @ptrCast(@alignCast(target));
    t.cancel();
}

/// Drop the transfer. Transfer.destroy unregisters it before freeing anything.
fn destroyExchange(ctx: *WasiP2Ctx, ex: *Exchange) void {
    if (ex.headers_rep) |rep| {
        if (rep < ctx.http_fields.items.len) ctx.http_fields.items[rep].deinit(ctx.alloc);
        ex.headers_rep = null;
    }
    ex.deinit(ctx.alloc);
}

/// Copy the response head's headers into `ctx.http_fields` as an immutable
/// resource (the WIT says `incoming-response.headers()` is immutable) and
/// return its index. Runs before the body reader exists, because `reader()`
/// invalidates the head's slices; the copies belong to the fields entry.
fn copyResponseHeaders(ctx: *WasiP2Ctx, head: std.http.Client.Response.Head) !u32 {
    var fields: p3http.HttpFields = .{};
    errdefer fields.deinit(ctx.alloc);
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        // A header this host cannot represent is skipped rather than failing
        // the whole response: the guest still gets the status and the rest.
        fields.appendChecked(ctx.alloc, h.name, h.value) catch continue;
    }
    fields.immutable = true;
    const idx: u32 = @intCast(ctx.http_fields.items.len);
    try ctx.http_fields.append(ctx.alloc, fields);
    return idx;
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
    host: *Host,
    request_initialized: bool = false,
    /// Persistent cancellation, including cancellation between two guest reads.
    cancelled: std.Io.Event = .unset,

    fn create(alloc: Allocator, io: std.Io, host: *Host) Allocator.Error!*Transfer {
        const self = try alloc.create(Transfer);
        // Allocator.create does not apply field defaults. Initialize the whole
        // value before publishing it to another thread.
        self.* = .{
            .client = .{ .allocator = alloc, .io = io },
            .request = undefined,
            .response = undefined,
            .reader = undefined,
            .host = host,
        };
        host.registerHttpCancel(io, self, cancelTransfer);
        return self;
    }

    pub fn destroy(self: *Transfer, alloc: Allocator) void {
        self.host.unregisterHttpCancel(self.client.io, self);
        // Network tasks are joined by runWithDeadline before ownership returns.
        if (self.request_initialized) self.request.deinit();
        self.client.deinit();
        alloc.destroy(self);
    }

    /// Only signal the task: request/connection fields belong to its IO worker
    /// and may still be uninitialized (DNS, connect or TLS handshake).
    pub fn cancel(self: *Transfer) void {
        self.cancelled.set(self.client.io);
    }

    fn waitCancelOrDeadline(self: *Transfer, deadline: std.Io.Timeout) anyerror!void {
        while (true) {
            self.cancelled.waitTimeout(self.client.io, deadline) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => {
                    // Event.waitTimeout also permits spurious wakeups.
                    if (deadline.deadline.untilNow(self.client.io).raw.nanoseconds >= 0)
                        return error.ResponseTimeout;
                    continue;
                },
            };
            return error.Canceled;
        }
    }

    /// Race the entire operation against a deadline and host cancellation.
    /// Joining both tasks before returning keeps all borrowed buffers alive and
    /// prevents a timeout from leaving background IO touching a freed transfer.
    fn runWithDeadline(self: *Transfer, timeout_ns: u64, comptime operation: anytype, args: std.meta.ArgsTuple(@TypeOf(operation))) !void {
        if (self.cancelled.isSet()) return error.Canceled;
        const io = self.client.io;
        const deadline = (std.Io.Timeout{ .duration = .{
            .raw = .fromNanoseconds(timeout_ns),
            .clock = .awake,
        } }).toDeadline(io);
        const Result = union(enum) { operation: anyerror!void, interrupted: anyerror!void };
        var buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(io, &buffer);
        defer select.cancelDiscard();
        // Both must be concurrent: an inline async operation could block before
        // we get to await/cancel the other task.
        try select.concurrent(.interrupted, waitCancelOrDeadline, .{ self, deadline });
        try select.concurrent(.operation, operation, args);
        const result = try select.await();
        if (self.cancelled.isSet()) return error.Canceled;
        switch (result) {
            .operation => |r| try r,
            .interrupted => |r| try r,
        }
    }

    /// Connect, send the head (and the body when the method carries one), then
    /// read the response head. `body` is the guest's `outgoing-body` buffer,
    /// which is empty for the bodiless methods.
    fn sendAndReceiveHead(self: *Transfer, method: std.http.Method, uri: std.Uri, headers: []const std.http.Header, body: []u8) anyerror!void {
        self.request = try self.client.request(method, uri, .{
            .extra_headers = headers,
            .redirect_behavior = .unhandled,
        });
        self.request_initialized = true;
        // `sendBodyComplete` asserts the method carries a body, so a bodiless
        // method (GET/HEAD/DELETE...) keeps the empty-body path even when the
        // guest wrote bytes into the body buffer.
        if (method.requestHasBody()) {
            try self.request.sendBodyComplete(body);
        } else {
            try self.request.sendBodiless();
        }
        self.response = try self.request.receiveHead(&self.head_buf);
    }

    fn readBody(self: *Transfer) anyerror!void {
        _ = try self.reader.peekGreedy(1);
    }
};

/// Connect, send, read the response head. The body is left unread.
fn startTransfer(ctx: *WasiP2Ctx, req: *p3http.HttpRequest, opts: p3http.HttpRequestOptions, status_out: *u16, headers_out: *?u32) !*Transfer {
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

    const t = try Transfer.create(alloc, io, ctx.host);
    errdefer t.destroy(alloc);
    const uri = try std.Uri.parse(url);
    // A single deadline covers DNS, connect, TLS, sending and the complete
    // response head, including partial headers and interim 100 responses.
    const deadline = effectiveDeadline(opts.first_byte_timeout_ns, effectiveDeadline(opts.connect_timeout_ns, ctx.host.http_head_deadline_ns));
    // The guest's `outgoing-body` buffer (empty unless it wrote one and called
    // finish). It is owned by the request, which outlives the transfer.
    const body: []u8 = if (req.p2_body_finished) req.p2_body.items else &.{};
    try t.runWithDeadline(deadline, Transfer.sendAndReceiveHead, .{ t, method, uri, extra.items, body });
    // Read the status and copy the headers BEFORE the body stream is
    // initialized: `reader()` invalidates the head's string pointers.
    status_out.* = @intCast(@backingInt(t.response.head.status));
    headers_out.* = try copyResponseHeaders(ctx, t.response.head);
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
    // Bound the actual HTTP/TLS read, including an incomplete chunk header or
    // TLS record. Socket readiness alone does not bound those parser reads.
    const deadline = effectiveDeadline(ex.between_bytes_ns, ctx.host.http_read_deadline_ns);
    t.runWithDeadline(deadline, Transfer.readBody, .{t}) catch |e| switch (e) {
        error.EndOfStream => {
            destroyExchange(ctx, ex);
            return writeStreamClosed(mem, retptr);
        },
        else => {
            t.cancel(); // a failed/cancelled parser must never be reused
            return WasiP2Error.ReadFailed;
        },
    };
    const chunk = t.reader.buffered();
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

test "wasi:http@0.2.x: transfer initialization survives dirty allocator memory" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = try Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    var bytes: [@sizeOf(Transfer) + @alignOf(Transfer)]u8 = @splat(0xff);
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    const t = try Transfer.create(fixed.allocator(), io, &host);
    defer t.destroy(fixed.allocator());
    try testing.expect(!t.cancelled.isSet());
    try testing.expect(!t.request_initialized);
    // Cancellation is safe even before request/connection initialization.
    host.cancelHttp();
    try testing.expect(t.cancelled.isSet());
    try testing.expectError(error.Canceled, t.runWithDeadline(1, Transfer.readBody, .{t}));
}

/// A peer that makes progress once, then stalls inside an HTTP/TLS frame.
const PartialServer = struct {
    reply: []const u8,
    sent: std.Io.Event = .unset,

    fn serve(self: *PartialServer, io: std.Io, server: *std.Io.net.Server) void {
        const conn = server.accept(io) catch return;
        defer conn.close(io);
        var buf: [4096]u8 = undefined;
        var bufs = [_][]u8{&buf};
        _ = conn.read(io, &bufs) catch return;
        var writer = conn.writer(io, &buf);
        writer.interface.writeAll(self.reply) catch return;
        writer.interface.flush() catch return;
        self.sent.set(io);
        // A finite fallback also ensures a broken deadline fails the test
        // instead of hanging the suite forever.
        io.sleep(.fromSeconds(3), .awake) catch {};
    }
};

fn checkPartialTimeout(reply: []const u8, scheme: p3http.Scheme, body: bool, guest_timeout: bool) !void {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    var peer: PartialServer = .{ .reply = reply };
    var serving = try io.concurrent(PartialServer.serve, .{ &peer, io, &server });
    defer serving.cancel(io);
    var host = try Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    host.http_head_deadline_ns = if (guest_timeout) 30 * std.time.ns_per_s else 300 * std.time.ns_per_ms;
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var req: p3http.HttpRequest = .{
        .headers_rep = 0,
        .authority = try std.fmt.allocPrint(testing.allocator, "127.0.0.1:{d}", .{server.socket.address.getPort()}),
        .scheme = scheme,
    };
    defer req.deinit(testing.allocator);
    var status: u16 = 0;
    const opts: p3http.HttpRequestOptions = if (guest_timeout)
        .{ .first_byte_timeout_ns = 300 * std.time.ns_per_ms }
    else
        .{};
    const started = std.Io.Timestamp.now(io, .awake);
    if (body) {
        var headers: ?u32 = null;
        const t = try startTransfer(&ctx, &req, opts, &status, &headers);
        defer t.destroy(testing.allocator);
        try testing.expectEqual(@as(u16, 200), status);
        try testing.expectError(error.ResponseTimeout, t.runWithDeadline(300 * std.time.ns_per_ms, Transfer.readBody, .{t}));
    } else {
        var headers: ?u32 = null;
        const result = startTransfer(&ctx, &req, opts, &status, &headers);
        if (result) |t| t.destroy(testing.allocator) else |_| {}
        try testing.expectError(error.ResponseTimeout, result);
    }
    const elapsed = started.durationTo(.now(io, .awake)).nanoseconds;
    try testing.expect(elapsed >= 200 * std.time.ns_per_ms);
    try testing.expect(elapsed < 2 * std.time.ns_per_s);
    try testing.expect(host.http_cancel_target.load(.acquire) == null);
}

test "wasi:http@0.2.x: partial response head cannot bypass the host deadline" {
    try checkPartialTimeout("HTTP/1.1 200 OK\r\nContent-Length:", .http, false, false);
}

test "wasi:http@0.2.x: first-byte timeout bounds a partial response head" {
    try checkPartialTimeout("HTTP/1.1 200 OK\r\nContent-Length:", .http, false, true);
}

test "wasi:http@0.2.x: partial chunk header cannot bypass the body deadline" {
    try checkPartialTimeout("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nA", .http, true, false);
}

test "wasi:http@0.2.x: TLS handshake cannot bypass the host deadline" {
    try checkPartialTimeout("", .https, false, false);
}

test "wasi:http@0.2.x: host cancellation interrupts a partial response head" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    var peer: PartialServer = .{ .reply = "HTTP/1.1 200" };
    var serving = try io.concurrent(PartialServer.serve, .{ &peer, io, &server });
    defer serving.cancel(io);
    var host = try Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var req: p3http.HttpRequest = .{
        .headers_rep = 0,
        .authority = try std.fmt.allocPrint(testing.allocator, "127.0.0.1:{d}", .{server.socket.address.getPort()}),
        .scheme = .http,
    };
    defer req.deinit(testing.allocator);
    var status: u16 = 0;
    var headers: ?u32 = null;
    var pending = try io.concurrent(startTransfer, .{ &ctx, &req, p3http.HttpRequestOptions{}, &status, &headers });
    defer {
        if (pending.cancel(io)) |t| t.destroy(testing.allocator) else |_| {}
    }
    try peer.sent.wait(io);
    const started = std.Io.Timestamp.now(io, .awake);
    host.cancelHttp();
    try testing.expectError(error.Canceled, pending.await(io));
    try testing.expect(started.durationTo(.now(io, .awake)).nanoseconds < std.time.ns_per_s);
    try testing.expect(host.http_cancel_target.load(.acquire) == null);
}

// ============================================================
// wasi:http@0.2.x spellings that 0.3 renamed or dropped
// ============================================================
//
// `fields.entries` (0.3: `copy-all`), the `*-timeout` getters (0.3:
// `get-*-timeout`), and the whole `outgoing-request` resource (0.3 renamed it
// `request` with `get-*` getters). The data model is shared with the 0.3 layer;
// only the ABI differs, and the offsets below come from the generated bindings
// of wasip2 1.0.4 (wasi:http 0.2.12), not from guessing:
//
//   result<_, header-error>        disc @0, err @1   (0.2 header-error is a
//                                  payload-less 3-case enum; 0.3's has
//                                  other(option<string>) and puts it at @4)
//   result<own<fields>, header-error>  disc @0, payload @4 (handle or err)
//   list<T>                        ptr @0, len @4
//   option<duration>               disc @0, u64 @8
//   method                         disc @0, other(string) @4
//   option<scheme>                 opt @0, scheme disc @4, other(string) @8
//   option<string>                 disc @0, ptr @4, len @8

/// `result<_, header-error>` in the 0.2 layout.
fn writeHeaderErrP2(mem: Memory, retptr: u32, e: ?p3http.FieldsError) WasiP2Error!void {
    if (e) |err| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 1, p3http.headerErrorOrdinal(err));
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// `option<duration>` (option<u64>: disc @0, value @8).
fn writeOptionDuration(mem: Memory, retptr: u32, ns: ?u64) WasiP2Error!void {
    if (ns) |v| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 8, v);
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// `option<string>` (disc @0, ptr @4, len @8).
fn writeOptionString(ctx: *WasiP2Ctx, mem: Memory, retptr: u32, s: ?[]const u8) WasiP2Error!void {
    if (s) |str| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, try p3h.http3AllocBlob(ctx, mem, str));
        try mem.write(retptr + 8, @as(u32, @intCast(str.len)));
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// `[static]fields.from-list` → `result<own<fields>, header-error>`.
pub fn p2HttpFieldsFromList(caller: *Caller, entries_ptr: u32, entries_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    var fields: p3http.HttpFields = .{};
    var i: u32 = 0;
    while (i < entries_len) : (i += 1) {
        const rec = entries_ptr + i * 16; // tuple<field-name, field-value> = 2 strings
        const name = mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4)) catch return WasiP2Error.OutOfBounds;
        const value = mem.sliceAt(try mem.read(u32, rec + 8), try mem.read(u32, rec + 12)) catch return WasiP2Error.OutOfBounds;
        fields.appendChecked(ctx.alloc, name, value) catch |e| {
            fields.deinit(ctx.alloc);
            try mem.write(retptr, @as(u8, 1));
            try mem.write(retptr + 4, p3http.headerErrorOrdinal(e)); // payload aligns to the own handle
            return;
        };
    }
    const handle = try p3h.http3MintFields(ctx, fields);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

/// `[method]fields.get` → `list<field-value>`.
pub fn p2HttpFieldsGet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const fields = try p3h.http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(ctx.alloc);
    fields.get(&values, ctx.alloc, name) catch return WasiP2Error.OutOfMemory;
    try p3h.http3WriteValueList(ctx, mem, retptr, values.items);
}

/// `[method]fields.has` → `bool` (a plain i32 return).
pub fn p2HttpFieldsHas(caller: *Caller, self: u32, name_ptr: u32, name_len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const fields = try p3h.http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    return @intFromBool(fields.has(name));
}

/// `[method]fields.set` → `result<_, header-error>`.
pub fn p2HttpFieldsSet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, values_ptr: u32, values_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const fields = try p3h.http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(ctx.alloc);
    var i: u32 = 0;
    while (i < values_len) : (i += 1) {
        const rec = values_ptr + i * 8; // list<field-value>
        const v = mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4)) catch return WasiP2Error.OutOfBounds;
        values.append(ctx.alloc, v) catch return WasiP2Error.OutOfMemory;
    }
    fields.set(ctx.alloc, name, values.items) catch |e| return writeHeaderErrP2(mem, retptr, e);
    try writeHeaderErrP2(mem, retptr, null);
}

/// `[method]fields.delete` → `result<_, header-error>`.
pub fn p2HttpFieldsDelete(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const fields = try p3h.http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    fields.delete(ctx.alloc, name) catch |e| return writeHeaderErrP2(mem, retptr, e);
    try writeHeaderErrP2(mem, retptr, null);
}

/// `[method]fields.append` → `result<_, header-error>`.
pub fn p2HttpFieldsAppend(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, value_ptr: u32, value_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const fields = try p3h.http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    const value = mem.sliceAt(value_ptr, value_len) catch return WasiP2Error.OutOfBounds;
    fields.append(ctx.alloc, name, value) catch |e| return writeHeaderErrP2(mem, retptr, e);
    try writeHeaderErrP2(mem, retptr, null);
}

/// `[method]fields.entries` → `list<tuple<field-name, field-value>>`: every
/// pair in insertion order, repeated names included (0.3 spells this
/// `copy-all`).
pub fn p2HttpFieldsEntries(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const fields = try p3h.http3FieldsSelf(ctx, self);
    const n = fields.entries.items.len;
    const base = if (n == 0) 4 else try ctx.reallocGuest(@intCast(n * 16), 4);
    for (fields.entries.items, 0..) |p, i| {
        const rec = base + @as(u32, @intCast(i * 16));
        try mem.write(rec, try p3h.http3AllocBlob(ctx, mem, p.name));
        try mem.write(rec + 4, @as(u32, @intCast(p.name.len)));
        try mem.write(rec + 8, try p3h.http3AllocBlob(ctx, mem, p.value));
        try mem.write(rec + 12, @as(u32, @intCast(p.value.len)));
    }
    try mem.write(retptr, base);
    try mem.write(retptr + 4, @as(u32, @intCast(n)));
}

/// `[method]fields.clone` → `own<fields>` (a plain i32 return).
pub fn p2HttpFieldsClone(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const src = try p3h.http3FieldsSelf(ctx, self);
    var copy: p3http.HttpFields = .{};
    src.cloneInto(ctx.alloc, &copy) catch {
        copy.deinit(ctx.alloc);
        return WasiP2Error.OutOfMemory;
    };
    copy.immutable = src.immutable; // a clone of an immutable view stays immutable
    return p3h.http3MintFields(ctx, copy);
}

/// `[method]request-options.connect-timeout` (0.2 name) → `option<duration>`.
pub fn p2HttpRequestOptionsConnectGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    return requestOptionsTimeoutGet(caller, self, retptr, "connect_timeout_ns");
}

/// `[method]request-options.first-byte-timeout`.
pub fn p2HttpRequestOptionsFirstByteGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    return requestOptionsTimeoutGet(caller, self, retptr, "first_byte_timeout_ns");
}

/// `[method]request-options.between-bytes-timeout`.
pub fn p2HttpRequestOptionsBetweenBytesGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    return requestOptionsTimeoutGet(caller, self, retptr, "between_bytes_timeout_ns");
}

fn requestOptionsTimeoutGet(caller: *Caller, self: u32, retptr: u32, comptime field: []const u8) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const rep = ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_RT, self) catch
        try ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_VIEW_RT, self);
    if (rep >= ctx.http_reqopts.items.len) return WasiP2Error.InvalidHandle;
    return writeOptionDuration(mem, retptr, @field(ctx.http_reqopts.items[rep], field));
}

/// `[method]outgoing-request.method` → `method` (disc @0, `other` string @4).
pub fn p2HttpOutgoingRequestMethod(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const req = try outgoingRequestOf(ctx, self);
    const ord: u8 = switch (req.method) {
        .get => 0,
        .head => 1,
        .post => 2,
        .put => 3,
        .delete => 4,
        .connect => 5,
        .options => 6,
        .trace => 7,
        .patch => 8,
        .other => 9,
    };
    try mem.write(retptr, ord);
    if (req.method == .other) {
        try mem.write(retptr + 4, try p3h.http3AllocBlob(ctx, mem, req.method.other));
        try mem.write(retptr + 8, @as(u32, @intCast(req.method.other.len)));
    }
}

/// `[method]outgoing-request.set-method` → `result` (0 = ok, 1 = err).
pub fn p2HttpOutgoingRequestSetMethod(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const req = try outgoingRequestOf(ctx, self);
    const next: p3http.Method = switch (disc) {
        0 => .get,
        1 => .head,
        2 => .post,
        3 => .put,
        4 => .delete,
        5 => .connect,
        6 => .options,
        7 => .trace,
        8 => .patch,
        9 => blk: {
            const s = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
            if (!p3http.validMethod(s)) return 1;
            break :blk .{ .other = ctx.alloc.dupe(u8, s) catch return WasiP2Error.OutOfMemory };
        },
        else => return 1,
    };
    req.method.deinit(ctx.alloc);
    req.method = next;
    return 0;
}

/// `[method]outgoing-request.scheme` → `option<scheme>`.
pub fn p2HttpOutgoingRequestScheme(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const req = try outgoingRequestOf(ctx, self);
    const scheme = req.scheme orelse {
        try mem.write(retptr, @as(u8, 0));
        return;
    };
    try mem.write(retptr, @as(u8, 1));
    switch (scheme) {
        .http => try mem.write(retptr + 4, @as(u8, 0)),
        .https => try mem.write(retptr + 4, @as(u8, 1)),
        .other => |s| {
            try mem.write(retptr + 4, @as(u8, 2));
            try mem.write(retptr + 8, try p3h.http3AllocBlob(ctx, mem, s));
            try mem.write(retptr + 12, @as(u32, @intCast(s.len)));
        },
    }
}

/// `[method]outgoing-request.authority` → `option<string>`.
pub fn p2HttpOutgoingRequestAuthority(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const req = try outgoingRequestOf(ctx, self);
    return writeOptionString(ctx, mem, retptr, req.authority);
}

/// `[method]outgoing-request.path-with-query` → `option<string>`.
pub fn p2HttpOutgoingRequestPathWithQuery(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const req = try outgoingRequestOf(ctx, self);
    return writeOptionString(ctx, mem, retptr, req.path_with_query);
}

/// `[method]outgoing-request.headers` → `own<fields>`. The WIT says the
/// returned resource is immutable, so this is an immutable SNAPSHOT: `set`,
/// `append` and `delete` on it fail `header-error.immutable`.
pub fn p2HttpOutgoingRequestHeaders(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const req = try outgoingRequestOf(ctx, self);
    if (req.headers_rep >= ctx.http_fields.items.len) return WasiP2Error.InvalidHandle;
    var copy: p3http.HttpFields = .{};
    ctx.http_fields.items[req.headers_rep].cloneInto(ctx.alloc, &copy) catch {
        copy.deinit(ctx.alloc);
        return WasiP2Error.OutOfMemory;
    };
    copy.immutable = true;
    const idx: u32 = @intCast(ctx.http_fields.items.len);
    ctx.http_fields.append(ctx.alloc, copy) catch {
        copy.deinit(ctx.alloc);
        return WasiP2Error.OutOfMemory;
    };
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, idx);
}

/// `[method]incoming-response.headers` → `own<fields>`, immutable per the WIT.
pub fn p2HttpIncomingResponseHeaders(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_RESPONSE_RT) return resource_table.Error.TypeMismatch;
    const ex = try exchangeOf(ctx, h.rep);
    const rep = ex.headers_rep orelse return WasiP2Error.InvalidHandle;
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, rep);
}

/// `[static]incoming-body.finish(this)` → `own<future-trailers>`. Takes the
/// body over; this host decides the trailers from the head it already read, so
/// the future is ready immediately.
pub fn p2HttpIncomingBodyFinish(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_BODY_RT) return resource_table.Error.TypeMismatch;
    const ex = try exchangeOf(ctx, h.rep);
    ex.trailers_taken = true;
    return ctx.resources.new(WasiP2Ctx.HTTP_P2_TRAILERS_RT, h.rep);
}

/// `[method]future-trailers.get` → `option<result<result<option<trailers>,
/// error-code>>>`: the same triple nesting as `future-incoming-response.get`
/// (offsets 0 / 8 / 16 / 24 / 28, straight from the generated bindings). This
/// host surfaces no trailers, so the value is `some(ok(ok(none)))`, and the
/// outer result turns `err` after the first retrieval.
pub fn p2HttpFutureTrailersGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_TRAILERS_RT) return resource_table.Error.TypeMismatch;
    const ex = try exchangeOf(ctx, h.rep);
    try mem.write(retptr, @as(u8, 1)); // some
    if (ex.trailers_retrieved) {
        try mem.write(retptr + 8, @as(u8, 1)); // outer err: already retrieved
        return;
    }
    ex.trailers_retrieved = true;
    try mem.write(retptr + 8, @as(u8, 0)); // outer ok
    try mem.write(retptr + 16, @as(u8, 0)); // inner ok
    try mem.write(retptr + 24, @as(u8, 0)); // option<trailers> = none
}

/// `[method]future-trailers.subscribe` → `own<pollable>`; ready at once, since
/// the trailers are already decided.
pub fn p2HttpFutureTrailersSubscribe(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_TRAILERS_RT) return resource_table.Error.TypeMismatch;
    _ = try exchangeOf(ctx, h.rep);
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

// ---- wasi:http@0.2.x outgoing-body (request bodies) ----

/// The guest writes a request body through an output-stream whose writes land
/// in the owning request's buffer. The buffer is host-bounded: a body larger
/// than this fails the write (the guest sees `stream-error::closed`), which is
/// the documented limit of this slice.
pub const MAX_REQUEST_BODY_BYTES: usize = 8 * 1024 * 1024;

fn bodyRequestOf(ctx: *WasiP2Ctx, handle: u32) WasiP2Error!*p3http.HttpRequest {
    const h = try ctx.resources.peek(handle);
    if (h.rt != WasiP2Ctx.HTTP_P2_OUTGOING_BODY_RT) return resource_table.Error.TypeMismatch;
    return requestByRep(ctx, h.rep);
}

/// `[method]outgoing-request.body` → `result<own<outgoing-body>>` (retptr:
/// disc @0, handle @4, per the generated bindings).
pub fn p2HttpOutgoingRequestBody(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const rep = try outgoingRequestRep(ctx, self);
    const handle = try ctx.resources.new(WasiP2Ctx.HTTP_P2_OUTGOING_BODY_RT, rep);
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 4, handle);
}

/// `[method]outgoing-body.write` → `result<own<output-stream>>`; at most once.
pub fn p2HttpOutgoingBodyWrite(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP_P2_OUTGOING_BODY_RT) return resource_table.Error.TypeMismatch;
    const req = try requestByRep(ctx, h.rep);
    if (req.p2_body_stream_taken or req.p2_body_finished) {
        try mem.write(retptr, @as(u8, 1)); // err: the stream was already taken
        return;
    }
    req.p2_body_stream_taken = true;
    const handle = try ctx.resources.new(WasiP2Ctx.HTTP_P2_BODY_OUT_STREAM_RT, h.rep);
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 4, handle);
}

/// Append to the owning request's body buffer (the `output-stream.write` /
/// `blocking-write-and-flush` path for a body stream). Returns the accepted
/// length through `retptr` exactly like the fd-backed streams.
pub fn bodyOutStreamWrite(ctx: *WasiP2Ctx, mem: Memory, rep: u32, bytes: []const u8, retptr: u32) WasiP2Error!void {
    const req = try requestByRep(ctx, rep);
    if (req.p2_body.items.len + bytes.len > MAX_REQUEST_BODY_BYTES) {
        try mem.write(retptr, @as(u8, 1)); // err: stream-error::closed
        try mem.write(retptr + 4, @as(u8, 1));
        return;
    }
    req.p2_body.appendSlice(ctx.alloc, bytes) catch return WasiP2Error.OutOfMemory;
    try mem.write(retptr, @as(u8, 0)); // ok
    try mem.write(retptr + 4, @as(u32, @intCast(bytes.len)));
}

/// Dropping the body's output-stream is what lets `finish` proceed.
pub fn dropBodyOutStream(ctx: *WasiP2Ctx, rep: u32) void {
    if (rep >= ctx.http_p2_requests.items.len) return;
    ctx.http_p2_requests.items[rep].p2_body_stream_taken = false;
}

/// `[static]outgoing-body.finish(this, option<trailers>)` →
/// `result<_, error-code>` (retptr: disc @0, error-code disc @8 because
/// error-code aligns to 8).
pub fn p2HttpOutgoingBodyFinish(caller: *Caller, self: u32, trailers_disc: u32, trailers_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctx_mod.ctxMemory(caller);
    _ = trailers_handle;
    const req = try bodyRequestOf(ctx, self);
    if (req.p2_body_stream_taken) {
        // The WIT says a live output-stream child traps. Report it as a failed
        // call rather than silently finalising a body the guest may still write.
        return WasiP2Error.ReadFailed;
    }
    if (trailers_disc == 1) {
        // Request trailers are not carried by this host (documented); the body
        // itself still finalises.
    }
    req.p2_body_finished = true;
    try mem.write(retptr, @as(u8, 0)); // ok
}
