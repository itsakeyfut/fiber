//! A tiny cooperative scheduler.
//!
//! Several fibers share a single OS thread. Each runs until it voluntarily
//! yields, and the scheduler round-robins over them until every fiber finishes.
//! Their output interleaves — this is the core of a cooperative task system,
//! the kind of thing a game engine drives once per frame. Run with
//! `zig build examples`.

const std = @import("std");
const fiber = @import("fiber");
const Fiber = fiber.Fiber;

/// Build a worker entry point that logs `steps` progress lines under `name`,
/// yielding after each one. Each fiber needs its own entry function, so we
/// generate one per task at comptime.
fn makeWorker(comptime name: []const u8, comptime steps: usize) *const fn (*Fiber) void {
    return &struct {
        fn run(_: *Fiber) void {
            var i: usize = 0;
            while (i < steps) : (i += 1) {
                std.debug.print("  [{s}] step {d}/{d}\n", .{ name, i + 1, steps });
                Fiber.yield();
            }
            std.debug.print("  [{s}] finished\n", .{name});
        }
    }.run;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const entries = [_]*const fn (*Fiber) void{
        makeWorker("A", 3),
        makeWorker("B", 5),
        makeWorker("C", 2),
    };

    var fibers: [entries.len]*Fiber = undefined;
    var created: usize = 0;
    errdefer for (fibers[0..created]) |f| f.destroy();
    for (&fibers, entries) |*slot, entry| {
        slot.* = try Fiber.create(gpa, entry, .{});
        created += 1;
    }
    defer for (fibers) |f| f.destroy();

    std.debug.print("scheduler: running {d} fibers\n", .{fibers.len});

    // Round-robin: each round gives every still-running fiber one turn, until
    // they have all reached `.done`.
    var round: usize = 0;
    var remaining: usize = fibers.len;
    while (remaining > 0) {
        round += 1;
        std.debug.print("-- round {d} --\n", .{round});
        remaining = 0;
        for (fibers) |f| {
            if (f.state == .done) continue;
            f.resumeFiber();
            if (f.state != .done) remaining += 1;
        }
    }

    std.debug.print("scheduler: all fibers finished in {d} rounds\n", .{round});
}
