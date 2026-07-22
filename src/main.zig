const std = @import("std");
const fiber = @import("fiber");
const Fiber = fiber.Fiber;

fn worker(_: *Fiber) void {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        std.debug.print("  fiber: {d}\n", .{i});
        Fiber.yield(); // Yield control back to the main fiber
    }
    std.debug.print("  fiber: finished\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const f = try Fiber.create(allocator, &worker);
    defer f.destroy();

    std.debug.print("main: start\n", .{});
    while (f.state != .done) {
        std.debug.print("main: resuming fiber\n", .{});
        f.resumeFiber();
    }
    std.debug.print("main: done\n", .{});
}
