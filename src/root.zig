//! Fiber library

const fiber = @import("fiber.zig");

pub const Fiber = fiber.Fiber;
pub const State = fiber.State;
pub const yield = fiber.Fiber.yield;

test {
    @import("std").testing.refAllDecls(@This());
    _ = fiber;
}
