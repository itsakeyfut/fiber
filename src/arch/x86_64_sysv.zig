pub const Context = extern struct { rsp: usize = 0 };

fn fiberSwapNaked() callconv(.naked) void {
    asm volatile (
        \\  pushq %%rbp
        \\  pushq %%rbx
        \\  pushq %%r12
        \\  pushq %%r13
        \\  pushq %%r14
        \\  pushq %%r15
        \\  // MXCSR (+0) and x87 control word (+8) in a 16-byte slot
        \\  subq $16, %%rsp
        \\  stmxcsr 0(%%rsp)
        \\  fnstcw 8(%%rsp)
        \\  // switch stacks
        \\  movq %%rsp, (%%rdi)
        \\  movq (%%rsi), %%rsp
        \\  // restore MXCSR + x87 control word
        \\  ldmxcsr 0(%%rsp)
        \\  fldcw 8(%%rsp)
        \\  addq $16, %%rsp
        \\  popq %%r15
        \\  popq %%r14
        \\  popq %%r13
        \\  popq %%r12
        \\  popq %%rbx
        \\  popq %%rbp
        \\  ret
    );
}

pub fn fiberSwap(from: *Context, to: *Context) callconv(.c) void {
    const f: *const fn (*Context, *Context) callconv(.c) void = @ptrCast(&fiberSwapNaked);
    f(from, to);
}

pub fn initStack(
    stack: []u8,
    entry: *const fn () callconv(.c) void,
    trap: *const fn () callconv(.c) void,
) usize {
    const top = @intFromPtr(stack.ptr) + stack.len;
    var sp = top & ~@as(usize, 0xF); // 16-byte aligned

    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = @intFromPtr(trap);

    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = @intFromPtr(entry);

    // 6 callee-saved GP slots (r15, r14, r13, r12, rbx, rbp)
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        sp -= @sizeOf(usize);
        @as(*usize, @ptrFromInt(sp)).* = 0;
    }

    // MXCSR (+0) / x87 control word (+8) 16-byte slot with defaults, matching
    // the Windows layout so the first swap-in loads a sane FP environment.
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = 0x0000037F; // x87 control word (slot+8)
    sp -= @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = 0x00001F80; // MXCSR (slot+0)

    return sp;
}
