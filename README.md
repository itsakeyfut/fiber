# fiber

[![Zig](https://img.shields.io/badge/zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Stackful fibers for Zig — cooperative context switching with your own stack.

## Why fibers?

A fiber is a lightweight thread of execution that you schedule yourself. Unlike an
OS thread, a fiber never runs in parallel and is never preempted: it runs until it
voluntarily hands control back with `yield()`, and it resumes exactly where it left
off. Because each fiber owns a real stack, it can suspend from deep inside a call
tree — not just at the top of a state machine.

```
1. resumeFiber()   // caller -> fiber, fiber starts running
2. yield()         // fiber  -> caller, fiber's stack is frozen mid-function
3. resumeFiber()   // caller -> fiber, execution continues after the yield
4. return          // fiber's entry returns, state becomes .done
```

That "freeze mid-function and continue later" property is what makes fibers a natural
substrate for cooperative schedulers, coroutines, generators, and per-entity behavior
scripts in a game loop — anything that wants to pause work and pick it up next frame
without unwinding the stack into an explicit state machine.

The switch itself is a small hand-written assembly routine that saves the
callee-saved registers, swaps the stack pointer, and jumps — no kernel involvement,
no allocation per switch.

## Install

Fetch the package (pins to a tagged release):

```sh
zig fetch --save "git+https://github.com/itsakeyfut/fiber#v0.1.0"
```

Then wire the module into your `build.zig`:

```zig
const fiber = b.dependency("fiber", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("fiber", fiber.module("fiber"));
```

Requires Zig `0.16.0` or newer.

## Usage

```zig
const std = @import("std");
const Fiber = @import("fiber").Fiber;

fn worker(_: *Fiber) void {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        std.debug.print("  fiber: {d}\n", .{i});
        Fiber.yield(); // hand control back to the caller
    }
    std.debug.print("  fiber: finished\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const f = try Fiber.create(allocator, &worker);
    defer f.destroy();

    std.debug.print("main: start\n", .{});
    while (f.state != .done) {
        f.resumeFiber();
    }
    std.debug.print("main: done\n", .{});
}
```

A runnable version lives in [`src/main.zig`](src/main.zig):

```sh
zig build run
```

## API

The `fiber` module exposes a single stackful fiber type.

| Symbol | Signature | Description |
| --- | --- | --- |
| `Fiber.create` | `(allocator, entry: *const fn (*Fiber) void) !*Fiber` | Allocate a fiber and its stack, ready to run `entry`. Does not start it. |
| `Fiber.destroy` | `(*Fiber) void` | Free the fiber and its stack. |
| `Fiber.resumeFiber` | `(*Fiber) void` | Switch into the fiber. Returns when the fiber yields or finishes. |
| `Fiber.yield` | `() void` | Suspend the current fiber and switch back to its caller. Panics if called outside a fiber. |
| `State` | `enum { ready, running, suspended, done }` | The fiber's lifecycle state, readable via `fiber.state`. |

`yield` is also re-exported at the module root as `@import("fiber").yield`.

Each fiber allocates a fixed **64 KiB** stack at `create` time. `entry` receives its
own `*Fiber` so it can reach fiber-local data; returning from `entry` moves the fiber
to `.done`, after which it must not be resumed again.

Fibers are single-threaded: a fiber and the code that resumes it must run on the same
OS thread. `current` is tracked per-thread, so nested resumes (a fiber resuming another
fiber) restore the correct caller chain.

## Platform support

The context switch is implemented in per-target assembly:

| Target | Status |
| --- | --- |
| `x86_64` Linux / *BSD (System V ABI) | Supported |
| `x86_64` Windows | Supported (preserves the non-volatile `xmm6`–`xmm15` and `mxcsr`) |
| `x86_64` macOS | Not yet supported |
| Other architectures | Not supported |

Unsupported targets fail at compile time with a clear message rather than miscompiling.

## Testing

```sh
zig build test
```

The suite covers the run/yield/complete cycle and, on Windows, verifies that the
non-volatile SIMD state (`xmm6`) and the floating-point control word (`mxcsr`) survive
a context switch.

## License

[MIT](LICENSE) © itsakeyfut
