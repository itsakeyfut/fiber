const std = @import("std");
const context = @import("arch/context.zig");
const Context = context.Context;

pub const State = enum { ready, running, suspended, done };

threadlocal var current: ?*Fiber = null;
threadlocal var root_context: Context = .{};

pub const Fiber = struct {
    context: Context = .{},
    stack: []u8,
    entry: *const fn (*Fiber) void,
    state: State = .ready,
    caller: *Context = undefined,
    allocator: std.mem.Allocator,

    const default_stack_size = 64 * 1024; // 64 KiB

    pub fn create(allocator: std.mem.Allocator, entry: *const fn (*Fiber) void) !*Fiber {
        const self = try allocator.create(Fiber);
        errdefer allocator.destroy(self);

        const stack = try allocator.alloc(u8, default_stack_size);
        errdefer allocator.free(stack);

        self.* = .{
            .stack = stack,
            .entry = entry,
            .allocator = allocator,
        };
        self.setupStack();
        return self;
    }

    pub fn destroy(self: *Fiber) void {
        const allocator = self.allocator;
        allocator.free(self.stack);
        allocator.destroy(self);
    }

    pub fn setupStack(self: *Fiber) void {
        self.context.rsp = context.initStack(self.stack, &trampoline, &trampolineTrap);
    }

    pub fn resumeFiber(self: *Fiber) void {
        std.debug.assert(self.state == .ready or self.state == .suspended);

        const caller = if (current) |c| &c.context else &root_context;
        const prev = current;

        self.caller = caller;
        current = self;
        self.state = .running;

        context.swap(caller, &self.context);

        current = prev;
    }

    pub fn yield() void {
        const self = current orelse @panic("yield() called outside of a fiber");
        self.state = .suspended;
        context.swap(&self.context, self.caller);
    }
};

fn trampoline() callconv(.c) void {
    const self = current.?;
    self.entry(self);
    self.state = .done;
    context.swap(&self.context, self.caller);
    unreachable;
}

fn trampolineTrap() callconv(.c) void {
    @panic("fiber trampoline returned unexpectedly");
}

test "fiber runs, yields, and completes" {
    const allocator = std.testing.allocator;

    const S = struct {
        var ticks: usize = 0;
        fn work(_: *Fiber) void {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                ticks += 1;
                Fiber.yield();
            }
        }
    };
    S.ticks = 0;

    const f = try Fiber.create(allocator, &S.work);
    defer f.destroy();

    var resumes: usize = 0;
    while (f.state != .done) {
        f.resumeFiber();
        resumes += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), S.ticks);
    try std.testing.expectEqual(State.done, f.state);
}

test "xmm6 is preserved across fiber switches" {
    // Windows-only by design: xmm6-xmm15 are callee-saved under the Win64 ABI
    // (so the switch must preserve them), but volatile under SysV (so the
    // switch correctly does not). This test only asserts the Win64 requirement.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const S = struct {
        var ok: bool = false;
        fn work(_: *Fiber) void {
            const sentinel: f64 = 1234.5;
            asm volatile ("movsd %[v], %%xmm6"
                :
                : [v] "x" (sentinel),
                : .{ .xmm6 = true });
            Fiber.yield();
            var got: f64 = 0;
            asm volatile ("movsd %%xmm6, %[o]"
                : [o] "=x" (got),
            );
            ok = (got == 1234.5);
        }
    };
    S.ok = false;

    const f = try Fiber.create(allocator, &S.work);
    defer f.destroy();

    while (f.state != .done) {
        // Clobber xmm6 in the caller context between resumes.
        const noise: f64 = 9999.0;
        asm volatile ("movsd %[v], %%xmm6"
            :
            : [v] "x" (noise),
            : .{ .xmm6 = true });
        f.resumeFiber();
    }

    try std.testing.expect(S.ok);
}

test "FP control state is preserved across fiber switches" {
    const allocator = std.testing.allocator;

    const Fp = struct {
        fn getMxcsr() u32 {
            var v: u32 = 0;
            // Pass the address in a register and dereference in the asm string:
            // "m"/"=m" constraints mis-lower on the Zig 0.16 x86_64-windows path.
            asm volatile ("stmxcsr (%[o])"
                :
                : [o] "r" (&v),
                : .{ .memory = true });
            return v;
        }
        fn setMxcsr(v: u32) void {
            var local = v;
            asm volatile ("ldmxcsr (%[i])"
                :
                : [i] "r" (&local),
                : .{ .memory = true });
        }
        fn getCw() u16 {
            var v: u16 = 0;
            asm volatile ("fnstcw (%[o])"
                :
                : [o] "r" (&v),
                : .{ .memory = true });
            return v;
        }
        fn setCw(v: u16) void {
            var local = v;
            asm volatile ("fldcw (%[i])"
                :
                : [i] "r" (&local),
                : .{ .memory = true });
        }
    };

    const S = struct {
        var ok_mxcsr: bool = false;
        var ok_cw: bool = false;
        fn work(_: *Fiber) void {
            // MXCSR round-toward-zero: RC bits 13-14 set.
            Fp.setMxcsr((Fp.getMxcsr() & ~@as(u32, 0x6000)) | 0x6000);
            // x87 round-toward-zero: RC bits 10-11 set.
            Fp.setCw(Fp.getCw() | 0x0C00);
            Fiber.yield();
            ok_mxcsr = (Fp.getMxcsr() & 0x6000) == 0x6000;
            ok_cw = (Fp.getCw() & 0x0C00) == 0x0C00;
        }
    };
    S.ok_mxcsr = false;
    S.ok_cw = false;

    const saved_mxcsr = Fp.getMxcsr();
    const saved_cw = Fp.getCw();

    const f = try Fiber.create(allocator, &S.work);
    defer f.destroy();

    while (f.state != .done) {
        // Caller runs in the default rounding mode between resumes, so a leaked
        // control word from the fiber would corrupt the fiber's own check.
        Fp.setMxcsr(saved_mxcsr & ~@as(u32, 0x6000));
        Fp.setCw(0x037F);
        f.resumeFiber();
    }

    // Restore the test runner's FP environment.
    Fp.setMxcsr(saved_mxcsr);
    Fp.setCw(saved_cw);

    try std.testing.expect(S.ok_mxcsr);
    try std.testing.expect(S.ok_cw);
}

test "callee-saved general-purpose registers survive fiber switches" {
    const allocator = std.testing.allocator;

    const S = struct {
        var ok: bool = false;
        fn work(_: *Fiber) void {
            asm volatile (
                \\ movabsq $0x1111111111111111, %%rbx
                \\ movabsq $0x2222222222222222, %%r12
                \\ movabsq $0x3333333333333333, %%r13
                \\ movabsq $0x4444444444444444, %%r14
                \\ movabsq $0x5555555555555555, %%r15
                ::: .{ .rbx = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true });
            Fiber.yield();
            var b: u64 = 0;
            var c12: u64 = 0;
            var c13: u64 = 0;
            var c14: u64 = 0;
            var c15: u64 = 0;
            asm volatile (
                \\ movq %%rbx, %[b]
                \\ movq %%r12, %[c12]
                \\ movq %%r13, %[c13]
                \\ movq %%r14, %[c14]
                \\ movq %%r15, %[c15]
                : [b] "=r" (b),
                  [c12] "=r" (c12),
                  [c13] "=r" (c13),
                  [c14] "=r" (c14),
                  [c15] "=r" (c15),
                :
                : .{ .rbx = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true });
            ok = b == 0x1111111111111111 and c12 == 0x2222222222222222 and
                c13 == 0x3333333333333333 and c14 == 0x4444444444444444 and
                c15 == 0x5555555555555555;
        }
    };
    S.ok = false;

    const f = try Fiber.create(allocator, &S.work);
    defer f.destroy();

    while (f.state != .done) {
        // Clobber every callee-saved GP register in the caller between resumes,
        // so a switch that failed to preserve them would be caught.
        asm volatile (
            \\ movabsq $0xdeadbeefdeadbeef, %%rbx
            \\ movabsq $0xdeadbeefdeadbeef, %%r12
            \\ movabsq $0xdeadbeefdeadbeef, %%r13
            \\ movabsq $0xdeadbeefdeadbeef, %%r14
            \\ movabsq $0xdeadbeefdeadbeef, %%r15
            ::: .{ .rbx = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true });
        f.resumeFiber();
    }

    try std.testing.expect(S.ok);
}

test "a fiber can resume another fiber (nesting)" {
    const allocator = std.testing.allocator;

    const S = struct {
        var log: [8]u8 = undefined;
        var n: usize = 0;
        var inner_fiber: *Fiber = undefined;

        fn record(c: u8) void {
            log[n] = c;
            n += 1;
        }
        fn inner(_: *Fiber) void {
            record('b');
            Fiber.yield();
            record('d');
        }
        fn outer(_: *Fiber) void {
            record('a');
            inner_fiber.resumeFiber(); // nested resume
            record('c');
            inner_fiber.resumeFiber(); // resume inner to completion
            record('e');
        }
    };
    S.n = 0;

    const inner = try Fiber.create(allocator, &S.inner);
    defer inner.destroy();
    S.inner_fiber = inner;

    const outer = try Fiber.create(allocator, &S.outer);
    defer outer.destroy();

    while (outer.state != .done) outer.resumeFiber();

    try std.testing.expectEqual(@as(usize, 5), S.n);
    try std.testing.expectEqualSlices(u8, "abcde", S.log[0..5]);
    try std.testing.expectEqual(State.done, inner.state);
    try std.testing.expectEqual(State.done, outer.state);
}
