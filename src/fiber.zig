const std = @import("std");
const context = @import("arch/context.zig");
const Context = context.Context;

pub const State = enum { ready, running, suspended, done };

/// Default fiber stack size (64 KiB), used when `Options.stack_size` is unset.
pub const default_stack_size = 64 * 1024;

/// Smallest stack `create` accepts (one page). Comfortably above the initial
/// frame `initStack` writes (~280 bytes on Windows), it prevents a too-small
/// stack from corrupting the heap during setup, and catches unit-confusion
/// mistakes (bytes vs. KiB). It is a floor, not a recommendation: a stack this
/// small holds the setup frame and ~3.8 KiB of working space, little more.
pub const min_stack_size = 4096;

/// Options for `Fiber.create`.
pub const Options = struct {
    /// Size in bytes of the stack allocated for the fiber.
    stack_size: usize = default_stack_size,
    /// Arbitrary user payload stored on the fiber and readable via `fiber.data`.
    data: ?*anyopaque = null,
};

threadlocal var current: ?*Fiber = null;
threadlocal var root_context: Context = .{};

pub const Fiber = struct {
    context: Context = .{},
    stack: []u8,
    entry: *const fn (*Fiber) void,
    state: State = .ready,
    caller: *Context = undefined,
    allocator: std.mem.Allocator,
    data: ?*anyopaque = null,

    pub fn create(
        allocator: std.mem.Allocator,
        entry: *const fn (*Fiber) void,
        options: Options,
    ) !*Fiber {
        if (options.stack_size < min_stack_size) return error.StackTooSmall;

        const self = try allocator.create(Fiber);
        errdefer allocator.destroy(self);

        const stack = try allocator.alloc(u8, options.stack_size);
        errdefer allocator.free(stack);

        self.* = .{
            .stack = stack,
            .entry = entry,
            .allocator = allocator,
            .data = options.data,
        };
        self.setupStack();
        return self;
    }

    /// Re-arm a finished (or never-started) fiber with a new entry and data,
    /// reusing the existing stack allocation. This is the pooling primitive:
    /// create a pool of fibers once, then `reset` each between jobs instead of
    /// reallocating a stack per job. Must not be called on a running or
    /// suspended fiber — that would orphan its in-progress frame.
    pub fn reset(self: *Fiber, entry: *const fn (*Fiber) void, data: ?*anyopaque) void {
        std.debug.assert(self.state == .done or self.state == .ready);
        self.entry = entry;
        self.data = data;
        self.state = .ready;
        self.setupStack();
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

    const f = try Fiber.create(allocator, &S.work, .{});
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

    const f = try Fiber.create(allocator, &S.work, .{});
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
        // Read/write MXCSR and the x87 control word through a self-managed stack
        // scratch. Zig 0.16 lowers the obvious operand forms inconsistently on
        // x86_64-linux: the "m"/"=m" memory constraint produces a wrong operand
        // address under optimized codegen (faulting `ldmxcsr` with a #GP), while
        // the `(%reg)` register-dereference form fails to assemble in Debug
        // ("invalid memory operand"). To dodge operand lowering entirely, move rsp
        // below the 128-byte red zone with `lea` (which leaves the flags alone),
        // address the scratch as `(%rsp)`, then restore rsp. Values move through
        // plain register operands.
        fn getMxcsr() u32 {
            var v: u32 = undefined;
            asm volatile (
                \\ leaq -144(%%rsp), %%rsp
                \\ stmxcsr (%%rsp)
                \\ movl (%%rsp), %[out]
                \\ leaq 144(%%rsp), %%rsp
                : [out] "=r" (v),
                :
                : .{ .memory = true });
            // MXCSR only defines bits 0-15; keep the result clean.
            return v & 0xffff;
        }
        fn setMxcsr(v: u32) void {
            const clean = v & 0xffff; // ldmxcsr #GPs on reserved bits
            asm volatile (
                \\ leaq -144(%%rsp), %%rsp
                \\ movl %[val], (%%rsp)
                \\ ldmxcsr (%%rsp)
                \\ leaq 144(%%rsp), %%rsp
                :
                : [val] "r" (clean),
                : .{ .memory = true });
        }
        fn getCw() u16 {
            var v: u32 = undefined;
            asm volatile (
                \\ leaq -144(%%rsp), %%rsp
                \\ fnstcw (%%rsp)
                \\ movl (%%rsp), %[out]
                \\ leaq 144(%%rsp), %%rsp
                : [out] "=r" (v),
                :
                : .{ .memory = true });
            // fnstcw writes 2 bytes; the scratch's upper half is uninitialized, so
            // keep only the control-word bits.
            return @truncate(v & 0xffff);
        }
        fn setCw(v: u16) void {
            const wide: u32 = v;
            asm volatile (
                \\ leaq -144(%%rsp), %%rsp
                \\ movl %[val], (%%rsp)
                \\ fldcw (%%rsp)
                \\ leaq 144(%%rsp), %%rsp
                :
                : [val] "r" (wide),
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

    const f = try Fiber.create(allocator, &S.work, .{});
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

    const inner = try Fiber.create(allocator, &S.inner, .{});
    defer inner.destroy();
    S.inner_fiber = inner;

    const outer = try Fiber.create(allocator, &S.outer, .{});
    defer outer.destroy();

    while (outer.state != .done) outer.resumeFiber();

    try std.testing.expectEqual(@as(usize, 5), S.n);
    try std.testing.expectEqualSlices(u8, "abcde", S.log[0..5]);
    try std.testing.expectEqual(State.done, inner.state);
    try std.testing.expectEqual(State.done, outer.state);
}

test "yield works from deep in the call stack" {
    const allocator = std.testing.allocator;

    const S = struct {
        var reached: usize = 0;
        var resumed: usize = 0;
        fn recurse(depth: usize) void {
            if (depth == 0) {
                reached = 100;
                Fiber.yield();
                resumed = 200;
                return;
            }
            recurse(depth - 1);
        }
        fn work(_: *Fiber) void {
            recurse(100);
        }
    };
    S.reached = 0;
    S.resumed = 0;

    const f = try Fiber.create(allocator, &S.work, .{});
    defer f.destroy();

    f.resumeFiber(); // descends 100 frames, then yields
    try std.testing.expectEqual(@as(usize, 100), S.reached);
    try std.testing.expectEqual(@as(usize, 0), S.resumed);
    try std.testing.expectEqual(State.suspended, f.state);

    f.resumeFiber(); // continues from deep in the stack to completion
    try std.testing.expectEqual(@as(usize, 200), S.resumed);
    try std.testing.expectEqual(State.done, f.state);
}

test "a fiber can yield many times" {
    const allocator = std.testing.allocator;

    const S = struct {
        var count: usize = 0;
        fn work(_: *Fiber) void {
            var i: usize = 0;
            while (i < 10_000) : (i += 1) {
                count += 1;
                Fiber.yield();
            }
        }
    };
    S.count = 0;

    const f = try Fiber.create(allocator, &S.work, .{});
    defer f.destroy();

    var resumes: usize = 0;
    while (f.state != .done) {
        f.resumeFiber();
        resumes += 1;
    }

    try std.testing.expectEqual(@as(usize, 10_000), S.count);
    try std.testing.expectEqual(@as(usize, 10_001), resumes);
}

test "local variables survive across yields" {
    const allocator = std.testing.allocator;

    const S = struct {
        var result: u64 = 0;
        fn work(_: *Fiber) void {
            var a: u64 = 3;
            var b: u64 = 5;
            var c: u64 = 7;
            Fiber.yield();
            a += 10;
            b += 20;
            Fiber.yield();
            c += 30;
            result = a * 1000 + b * 100 + c;
        }
    };
    S.result = 0;

    const f = try Fiber.create(allocator, &S.work, .{});
    defer f.destroy();

    while (f.state != .done) f.resumeFiber();

    // a=13, b=25, c=37 -> 13000 + 2500 + 37
    try std.testing.expectEqual(@as(u64, 15537), S.result);
}

test "independent fibers keep separate state when interleaved" {
    const allocator = std.testing.allocator;

    const S = struct {
        var counters = [_]u64{ 0, 0, 0 };
        // Three sibling entries, one per fiber. Each references `counters`
        // unqualified (a sibling container var), avoiding a self-reference to
        // the local `S` from a nested struct, which does not compile.
        fn w0(_: *Fiber) void {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                counters[0] += 1;
                Fiber.yield();
            }
        }
        fn w1(_: *Fiber) void {
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                counters[1] += 1;
                Fiber.yield();
            }
        }
        fn w2(_: *Fiber) void {
            var i: usize = 0;
            while (i < 2) : (i += 1) {
                counters[2] += 1;
                Fiber.yield();
            }
        }
    };
    S.counters = .{ 0, 0, 0 };

    const fibers = [_]*Fiber{
        try Fiber.create(allocator, &S.w0, .{}),
        try Fiber.create(allocator, &S.w1, .{}),
        try Fiber.create(allocator, &S.w2, .{}),
    };
    defer for (fibers) |f| f.destroy();

    // One resume each: under true interleaving every fiber advances exactly
    // once. Serial run-to-completion would instead drive the first fiber to 3
    // before the second ever started, so this positively confirms interleaving.
    for (fibers) |f| f.resumeFiber();
    try std.testing.expectEqual(@as(u64, 1), S.counters[0]);
    try std.testing.expectEqual(@as(u64, 1), S.counters[1]);
    try std.testing.expectEqual(@as(u64, 1), S.counters[2]);

    var remaining: usize = fibers.len;
    while (remaining > 0) {
        remaining = 0;
        for (fibers) |f| {
            if (f.state == .done) continue;
            f.resumeFiber();
            if (f.state != .done) remaining += 1;
        }
    }

    try std.testing.expectEqual(@as(u64, 3), S.counters[0]);
    try std.testing.expectEqual(@as(u64, 5), S.counters[1]);
    try std.testing.expectEqual(@as(u64, 2), S.counters[2]);
}

test "create reports OutOfMemory and leaks nothing on allocation failure" {
    const S = struct {
        fn work(_: *Fiber) void {}
    };

    // Fail allocation index 0 (the Fiber struct): create returns the error and
    // nothing is allocated.
    {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = 0 },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            Fiber.create(failing.allocator(), &S.work, .{}),
        );
    }

    // Fail allocation index 1 (the stack): the Fiber struct allocation must be
    // rolled back by errdefer. std.testing.allocator flags any leak.
    {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = 1 },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            Fiber.create(failing.allocator(), &S.work, .{}),
        );
    }
}

test "fiber data payload is passed through and readable by the entry" {
    const allocator = std.testing.allocator;

    const S = struct {
        const Ctx = struct { value: u32 };
        fn work(f: *Fiber) void {
            const ctx: *Ctx = @ptrCast(@alignCast(f.data.?));
            ctx.value += 100;
        }
    };

    var ctx = S.Ctx{ .value = 1 };
    const f = try Fiber.create(allocator, &S.work, .{ .data = &ctx });
    defer f.destroy();

    while (f.state != .done) f.resumeFiber();

    try std.testing.expectEqual(@as(u32, 101), ctx.value);
}

test "fiber data can be set on the handle after create" {
    const allocator = std.testing.allocator;

    const S = struct {
        const Ctx = struct { value: u32 };
        fn work(f: *Fiber) void {
            const ctx: *Ctx = @ptrCast(@alignCast(f.data.?));
            ctx.value = 42;
        }
    };

    var ctx = S.Ctx{ .value = 0 };
    const f = try Fiber.create(allocator, &S.work, .{});
    defer f.destroy();
    f.data = &ctx; // set after create, before first resume

    while (f.state != .done) f.resumeFiber();

    try std.testing.expectEqual(@as(u32, 42), ctx.value);
}

test "custom stack size is honored" {
    const allocator = std.testing.allocator;

    const S = struct {
        var ran: bool = false;
        fn work(_: *Fiber) void {
            Fiber.yield();
            ran = true;
        }
    };
    S.ran = false;

    const custom = 128 * 1024; // differs from the 64 KiB default
    const f = try Fiber.create(allocator, &S.work, .{ .stack_size = custom });
    defer f.destroy();

    try std.testing.expectEqual(@as(usize, custom), f.stack.len);

    while (f.state != .done) f.resumeFiber();
    try std.testing.expect(S.ran);
}

test "reset re-arms a finished fiber for reuse without reallocating" {
    const allocator = std.testing.allocator;

    const S = struct {
        var first_ran: u32 = 0;
        fn first(_: *Fiber) void {
            first_ran += 1;
        }
        fn second(f: *Fiber) void {
            const n: *u32 = @ptrCast(@alignCast(f.data.?));
            n.* += 10;
            Fiber.yield(); // suspend/resume on the re-armed (reused) stack
            n.* += 100;
        }
    };
    S.first_ran = 0;

    const f = try Fiber.create(allocator, &S.first, .{});
    defer f.destroy();

    const stack_ptr = f.stack.ptr;
    const stack_len = f.stack.len;

    while (f.state != .done) f.resumeFiber();
    try std.testing.expectEqual(@as(u32, 1), S.first_ran);
    try std.testing.expectEqual(State.done, f.state);

    // Re-arm the same fiber with a new entry + data; same stack buffer.
    var counter: u32 = 5;
    f.reset(&S.second, &counter);
    try std.testing.expectEqual(State.ready, f.state);
    try std.testing.expectEqual(stack_ptr, f.stack.ptr); // no realloc
    try std.testing.expectEqual(stack_len, f.stack.len);

    while (f.state != .done) f.resumeFiber();
    try std.testing.expectEqual(@as(u32, 115), counter);
}

test "create rejects a stack size below the minimum before allocating" {
    const S = struct {
        fn work(_: *Fiber) void {}
    };

    // Below the floor -> error.
    try std.testing.expectError(
        error.StackTooSmall,
        Fiber.create(std.testing.allocator, &S.work, .{ .stack_size = 0 }),
    );
    try std.testing.expectError(
        error.StackTooSmall,
        Fiber.create(std.testing.allocator, &S.work, .{ .stack_size = min_stack_size - 1 }),
    );

    // Prove the check precedes any allocation: with a FailingAllocator whose
    // first allocation fails, a too-small size must still yield StackTooSmall
    // (the allocator is never reached) rather than OutOfMemory.
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.StackTooSmall,
        Fiber.create(failing.allocator(), &S.work, .{ .stack_size = 0 }),
    );
}

test "create accepts the minimum stack size" {
    const allocator = std.testing.allocator;

    const S = struct {
        var ticks: u32 = 0;
        // Minimal body by design: at the 4096 floor only ~3.8 KiB remains after
        // the setup frame, and there is no guard page yet (C3).
        fn work(_: *Fiber) void {
            ticks += 1;
            Fiber.yield();
            ticks += 1;
        }
    };
    S.ticks = 0;

    const f = try Fiber.create(allocator, &S.work, .{ .stack_size = min_stack_size });
    defer f.destroy();

    while (f.state != .done) f.resumeFiber();
    try std.testing.expectEqual(@as(u32, 2), S.ticks);
}
