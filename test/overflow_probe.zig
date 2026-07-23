const std = @import("std");
const fiber = @import("fiber");

fn recurse(depth: usize) void {
    var buf: [256]u8 = undefined; // a live per-frame buffer defeats tail-call elimination
    buf[0] = @truncate(depth);
    std.mem.doNotOptimizeAway(&buf);
    recurse(depth + 1);
    std.mem.doNotOptimizeAway(&buf); // keep the frame live past the call → not a tail call
}

fn overflow(_: *fiber.Fiber) void {
    recurse(0);
}

pub fn main(init: std.process.Init) !void {
    // Fail closed: a genuine guard fault kills the process below, before any
    // exit(). A setup error, or surviving the overflow, exits 0 — which the test
    // reads as "the guard did NOT fire" and fails.
    const f = fiber.Fiber.create(init.gpa, &overflow, .{ .stack_size = fiber.min_stack_size }) catch std.process.exit(0);
    defer f.destroy();
    f.resumeFiber(); // overflows into the guard page → fault; never returns
    std.process.exit(0); // reached only if the guard did NOT fire
}
