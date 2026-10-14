//! Win64 trap-recovery bridge via AddVectoredExceptionHandler +
//! threadlocal RecoveryInfo (ADR-0103).
//!
//! POSIX-equivalent contract: `arm(info)` + `disarm()` map to
//! `sigsetjmp` / `siglongjmp` semantics for Windows-target JIT
//! callers. On a hardware fault inside `[info.jit_code_start,
//! info.jit_code_end)`, the VEH callback rewrites the trapping
//! thread's `Rip` / `Rsp` / `Rax` so execution resumes at
//! `recovery_pc` with `recovery_rax_trap_code` in `RAX`.
//!
//! Mac / ubuntu builds compile this file but every public entry
//! point is a no-op there; the POSIX SIGSEGV handler still owns
//! recovery on those targets. See `test/spec/spec_assert_
//! runner_base.zig::installSigsegvHandler` for the comptime arm.
//!
//! Zone 0 (`src/platform/`). Pure Zig; the Win32 entry points
//! come from `std.os.windows.ntdll`, so no fresh `@extern` is
//! introduced here (libc_boundary.md does not fire).

const builtin = @import("builtin");
const std = @import("std");

/// Per-call recovery state. Filled in by `arm()` immediately
/// before the JIT body is invoked; consumed by `vehHandler` on
/// a matching fault.
pub const RecoveryInfo = struct {
    /// Inclusive lower bound of the JIT-emitted code region the
    /// recovery applies to. Faults outside `[start, end)` pass
    /// through to the next handler.
    jit_code_start: usize,
    /// Exclusive upper bound.
    jit_code_end: usize,
    /// Resume-point program counter (the caller's recovery label).
    recovery_pc: usize,
    /// Resume-point stack pointer (Win64 ABI invariants assumed
    /// to hold at this SP).
    recovery_sp: usize,
    /// Value loaded into RAX on resume — the trap code the runner
    /// observes via its `Error.Trap`-coded return value.
    recovery_rax_trap_code: u64,
};

const ActiveRecovery = struct {
    info: RecoveryInfo,
    active: bool,
};

threadlocal var recovery: ActiveRecovery = .{
    .info = .{
        .jit_code_start = 0,
        .jit_code_end = 0,
        .recovery_pc = 0,
        .recovery_sp = 0,
        .recovery_rax_trap_code = 0,
    },
    .active = false,
};

/// Install the VEH callback. Idempotent — safe to call multiple
/// times; the second call is a no-op. No-op on non-Windows
/// targets.
pub fn install() void {
    if (comptime builtin.os.tag != .windows) return;
    impl.install();
}

/// Remove the VEH callback. Safe to call when not installed.
/// No-op on non-Windows targets.
pub fn uninstall() void {
    if (comptime builtin.os.tag != .windows) return;
    impl.uninstall();
}

/// Arm the threadlocal recovery context. `disarm()` MUST be
/// called on every exit path (success or failure) — pair via
/// `defer` at the callsite. No-op on non-Windows.
pub fn arm(info: RecoveryInfo) void {
    if (comptime builtin.os.tag != .windows) return;
    recovery.info = info;
    @atomicStore(bool, &recovery.active, true, .release);
}

/// Clear the threadlocal recovery context. No-op on non-Windows.
pub fn disarm() void {
    if (comptime builtin.os.tag != .windows) return;
    @atomicStore(bool, &recovery.active, false, .release);
}

/// Run `jit_fn(args)` under VEH protection on Windows. Returns
/// `true` if `jit_fn` either (a) trapped via a hardware fault
/// inside `[jit_code_start, jit_code_end)` (VEH redirected to
/// the function's return point with `Rax = 1`), or (b) returned
/// `error.Trap` from the entry shim. Returns `false` on clean
/// success.
///
/// **Must NOT be inlined ** — `@returnAddress()` must point at
/// the caller's RIP after this function returns, and inline asm
/// captures the helper's frame RSP. Marked `noinline` per
/// ADR-0103 Consequences refinement.
///
/// POSIX path: callers gate via `if (comptime builtin.os.tag ==
/// .windows) ...` and keep the existing `sigsetjmp` site inline
/// in the caller frame (per discipline at
/// `spec_assert_runner_base.zig:2306-2312`).
pub noinline fn callJitOrTrap(
    jit_code_start: usize,
    jit_code_end: usize,
    comptime jit_fn: anytype,
    args: anytype,
) bool {
    if (comptime builtin.os.tag != .windows) return false;
    var rsp_on_entry: usize = undefined;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("mov %%rsp, %[sp]"
            : [sp] "=r" (rsp_on_entry),
            :
            : .{ .memory = true });
    }
    arm(.{
        .jit_code_start = jit_code_start,
        .jit_code_end = jit_code_end,
        .recovery_pc = @returnAddress(),
        .recovery_sp = rsp_on_entry + 8,
        .recovery_rax_trap_code = 1,
    });
    defer disarm();
    @call(.never_inline, jit_fn, args) catch |err| switch (err) {
        error.Trap => return true,
    };
    return false;
}

const impl = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;

    // Not exported by std.os.windows; declared per MSDN
    // (errhandlingapi.h / winnt.h).
    const EXCEPTION_CONTINUE_EXECUTION: c_long = -1;
    const EXCEPTION_INT_DIVIDE_BY_ZERO: u32 = 0xC0000094;
    const EXCEPTION_INT_OVERFLOW: u32 = 0xC0000095;
    const EXCEPTION_STACK_OVERFLOW: u32 = 0xC00000FD;

    // Minimal stderr write for the exhausted-stack diagnostic (mirrors
    // `signal.zig`'s D-292 pattern). kernel32 = Windows system library, not
    // libc (ADR-0070 does not fire); Zig 0.16 std.os.windows omits these.
    extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) callconv(.winapi) win.HANDLE;
    extern "kernel32" fn WriteFile(hFile: win.HANDLE, lpBuffer: [*]const u8, nBytes: win.DWORD, lpWritten: ?*win.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
    const STD_ERROR_HANDLE: win.DWORD = @bitCast(@as(i32, -12)); // MSDN

    var veh_handle: ?win.PVOID = null;

    /// D-279 H3 confirmation primitive. A Win64 stack overflow (1 MB default
    /// thread stack vs 8 MB on Mac/Linux) is the leading hypothesis for the
    /// intermittent SIMD-JIT exit-3 crash — it would be Win64-only,
    /// depth-dependent, message-less, and NOT VEH-recovered. This logs it
    /// wherever it fires (armed or not — a stack overflow is process-fatal
    /// regardless), then CONTINUE_SEARCHes: diagnostic ONLY, no recovery, so
    /// ADR-0105 D4's deliberate "do not recover stack overflows" stands (no
    /// guard-page restoration). The write is a single fixed-string `WriteFile`
    /// — no Zig formatting / stderr lock / allocation — so it survives the
    /// exhausted-stack guard-page slack that a `std.debug.print` would fault in.
    fn diagStackOverflow() void {
        const msg = "[d-279-veh] STACK-OVERFLOW (H3 confirmed: Win64 1MB stack exhausted, not a miscompile)\n";
        const h = GetStdHandle(STD_ERROR_HANDLE);
        var written: win.DWORD = 0;
        _ = WriteFile(h, msg.ptr, @intCast(msg.len), &written, null);
    }

    /// D-279 permanent diagnostic. Emitted only when recovery is ARMED but
    /// the VEH cannot recover (unfiltered code, or RIP outside the JIT
    /// window) — i.e. the exact path that produces the silent Win64 exit-3
    /// crash. The process is about to die via the default handler, so a
    /// best-effort `std.debug.print` is safe here (no recovery to corrupt);
    /// it converts the no-repro heisenbug into a self-identifying log line.
    fn diagUnrecovered(comptime reason: []const u8, code: u32, rip: usize) void {
        std.debug.print(
            "[d-279-veh] UNRECOVERED ({s}): code=0x{x} rip=0x{x} jit=[0x{x},0x{x}) — default handler will crash (exit 3)\n",
            .{ reason, code, rip, recovery.info.jit_code_start, recovery.info.jit_code_end },
        );
    }

    /// D-279 H6 primitive (2026-06-07). A fatal-class exception while recovery
    /// is NOT armed previously CONTINUE_SEARCHed silently → Win64 exit-3 with no
    /// log (the @16fc1bb3 `address.2.wasm` NON-SIMD crash signature: zero
    /// `[d-279-veh]` output despite all three armed/overflow diagnostics being
    /// present). Logs code + RIP so the next Win64 RED pins whether the fault is
    /// in JIT compilation (the `[d-163-jit]` codegen path), the spec runner, or
    /// the interpreter — NONE of which arm VEH. The process is about to die via
    /// the default handler (CONTINUE_SEARCH), so a best-effort `std.debug.print`
    /// is safe (no recovery to corrupt), mirroring `diagUnrecovered`.
    fn diagUnarmedFatal(code: u32, rip: usize) void {
        std.debug.print(
            "[d-279-veh] UNARMED-FATAL: code=0x{x} rip=0x{x} — no recovery armed; default handler will crash (exit 3)\n",
            .{ code, rip },
        );
    }

    fn vehHandler(exception_info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
        // D-279 H3: catch a stack overflow BEFORE the armed-check — it may
        // fire outside an arm()-guarded JIT region (the spec-runner / interp /
        // host fn), which is exactly the unguarded path H3 predicts. Log +
        // CONTINUE_SEARCH (no recovery; ADR-0105 D4).
        if (exception_info.ExceptionRecord.ExceptionCode == EXCEPTION_STACK_OVERFLOW) {
            diagStackOverflow();
            return win.EXCEPTION_CONTINUE_SEARCH;
        }
        if (!@atomicLoad(bool, &recovery.active, .acquire)) {
            // D-279 H6 (2026-06-07): a fatal exception while recovery is NOT
            // armed was previously CONTINUE_SEARCHed SILENTLY → the default
            // handler crashes the process (Win64 exit 3) with no log. The
            // H3-refuting @16fc1bb3 crash (zwasm-spec-wasm-2-0-assert /
            // address.2.wasm, NON-SIMD, at JIT-compile time) emitted NO
            // [d-279-veh] line → it took exactly this path. Log fatal-class
            // codes only (the codes the armed branch handles) so normal
            // guard-page stack growth (0x80000001) and breakpoints are not
            // logged. Diagnostic only — still CONTINUE_SEARCH, no recovery,
            // so a genuine unrelated SEH consumer downstream is unaffected
            // (this VEH is at the back of the chain, First=0).
            switch (exception_info.ExceptionRecord.ExceptionCode) {
                win.EXCEPTION_ACCESS_VIOLATION,
                win.EXCEPTION_ILLEGAL_INSTRUCTION,
                EXCEPTION_INT_DIVIDE_BY_ZERO,
                EXCEPTION_INT_OVERFLOW,
                => diagUnarmedFatal(
                    exception_info.ExceptionRecord.ExceptionCode,
                    exception_info.ContextRecord.Rip,
                ),
                else => {},
            }
            return win.EXCEPTION_CONTINUE_SEARCH;
        }
        const code = exception_info.ExceptionRecord.ExceptionCode;
        switch (code) {
            win.EXCEPTION_ACCESS_VIOLATION,
            win.EXCEPTION_ILLEGAL_INSTRUCTION,
            EXCEPTION_INT_DIVIDE_BY_ZERO,
            EXCEPTION_INT_OVERFLOW,
            => {},
            // D-279 diagnostic: recovery is ARMED (we are inside a guarded
            // JIT execution) yet the exception code is one the recovery
            // filter does not handle → the default handler will crash the
            // process (Win64 exit 3). Emit the code+RIP first so the next
            // heisenbug occurrence is self-identifying instead of silent.
            else => {
                diagUnrecovered("unfiltered-code", code, exception_info.ContextRecord.Rip);
                return win.EXCEPTION_CONTINUE_SEARCH;
            },
        }
        // ADR-0105 D4 (2026-05-23): EXCEPTION_STACK_OVERFLOW removed
        // from the filter. The JIT-prologue stack-probe (ADR-0105 D2)
        // traps cleanly via the kind=4 stack-overflow trap stub
        // BEFORE SP descends past the guard page — VEH no longer
        // sees this exception code. Removing the arm dissolves the
        // guard-page-restoration headache (`_resetstkoflw()` etc.).
        const rip = exception_info.ContextRecord.Rip;
        if (rip < recovery.info.jit_code_start or rip >= recovery.info.jit_code_end) {
            // D-279 diagnostic: armed + a filtered exception code, but the
            // faulting RIP is OUTSIDE the JIT code range — i.e. the fault is
            // in non-JIT code (runtime/host/stack-walk) reached from JIT, the
            // FP-walk/stack-walk lineage (D-180/D-245). The default handler
            // crashes (exit 3); log RIP + the JIT window so the next crash
            // pinpoints whether it is genuinely out-of-range vs a stale range.
            diagUnrecovered("rip-outside-jit", code, rip);
            return win.EXCEPTION_CONTINUE_SEARCH;
        }
        // Redirect the trapping thread to the recovery label.
        exception_info.ContextRecord.Rip = recovery.info.recovery_pc;
        exception_info.ContextRecord.Rsp = recovery.info.recovery_sp;
        exception_info.ContextRecord.Rax = recovery.info.recovery_rax_trap_code;
        // One-shot: clear the armed flag so a subsequent fault
        // outside an `arm()`-guarded region surfaces normally.
        @atomicStore(bool, &recovery.active, false, .release);
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    fn install() void {
        if (veh_handle != null) return;
        // First = 0 places the handler at the back of the VEH
        // chain — pre-existing host handlers run first. Per
        // ADR-0103 Negative consequence mitigation.
        veh_handle = win.ntdll.RtlAddVectoredExceptionHandler(0, &vehHandler);
    }

    fn uninstall() void {
        if (veh_handle) |h| {
            _ = win.ntdll.RtlRemoveVectoredExceptionHandler(h);
            veh_handle = null;
        }
    }
} else struct {};

// -----------------------------------------------------------
// Tests — exercised on Mac / ubuntu (POSIX no-op path).
// windowsmini verifies the Windows-active branch at W4 reconcile.
// -----------------------------------------------------------

test "RecoveryInfo struct shape" {
    const info: RecoveryInfo = .{
        .jit_code_start = 0x1000,
        .jit_code_end = 0x2000,
        .recovery_pc = 0x3000,
        .recovery_sp = 0x4000,
        .recovery_rax_trap_code = 7,
    };
    try std.testing.expectEqual(@as(usize, 0x1000), info.jit_code_start);
    try std.testing.expectEqual(@as(usize, 0x2000), info.jit_code_end);
    try std.testing.expectEqual(@as(u64, 7), info.recovery_rax_trap_code);
}

test "install/uninstall non-Windows no-op" {
    // SIBLING-AT: src/platform/windows_traphandler.zig:62 (install impl)
    // — POSIX no-op path; Windows VEH path verified by W4 reconcile.
    if (comptime builtin.os.tag == .windows) return;
    install();
    uninstall();
    // Reaching here = no crash; install/uninstall returned cleanly.
}

test "arm/disarm non-Windows no-op leaves threadlocal untouched" {
    // SIBLING-AT: src/platform/windows_traphandler.zig:62 (install impl)
    // — POSIX no-op path; Windows VEH path verified by W4 reconcile.
    if (comptime builtin.os.tag == .windows) return;
    arm(.{
        .jit_code_start = 0xDEADBEEF,
        .jit_code_end = 0xFEEDFACE,
        .recovery_pc = 0,
        .recovery_sp = 0,
        .recovery_rax_trap_code = 0,
    });
    // arm() is a no-op on POSIX; the threadlocal must remain at
    // its initialiser state (active=false). Verified via the
    // private API surface to ensure the comptime gate fires.
    try std.testing.expect(!@atomicLoad(bool, &recovery.active, .acquire));
    disarm();
    try std.testing.expect(!@atomicLoad(bool, &recovery.active, .acquire));
}
