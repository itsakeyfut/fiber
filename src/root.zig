//! Fiber library

const fiber = @import("fiber.zig");

pub const Fiber = fiber.Fiber;
pub const State = fiber.State;
pub const yield = fiber.Fiber.yield;
pub const min_stack_size = fiber.min_stack_size;

test {
    @import("std").testing.refAllDecls(@This());
    _ = fiber;
    _ = @import("stack.zig");
}
