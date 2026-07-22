//! Basic fiber usage.
//!
//! Create a single fiber, resume it repeatedly, and watch how it suspends at
//! each `yield` and continues from exactly where it left off the next time it
//! is resumed. Run with `zig build examples`.

const std = @import("std");
const fiber = @import("fiber");
const Fiber = fiber.Fiber;

fn counter(_: *Fiber) void {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        std.debug.print("  fiber: tick {d}\n", .{i});
        Fiber.yield(); // freeze here; control returns to the caller
    }
    std.debug.print("  fiber: finished\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const f = try Fiber.create(gpa, &counter, .{});
    defer f.destroy();

    std.debug.print("main: created fiber (state={s})\n", .{@tagName(f.state)});

    var resumes: usize = 0;
    while (f.state != .done) {
        resumes += 1;
        std.debug.print("main: resume #{d}\n", .{resumes});
        f.resumeFiber();
        std.debug.print("main: back in main (state={s})\n", .{@tagName(f.state)});
    }

    std.debug.print("main: fiber done after {d} resumes\n", .{resumes});
}
