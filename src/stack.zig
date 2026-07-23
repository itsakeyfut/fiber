const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) {
        @compileError("fiber guard-paged stacks require Linux or Windows");
    }
}

/// Allocate a guard-protected stack: a usable region of at least `size` bytes,
/// rounded up to a page multiple, with one no-access guard page immediately
/// below it. A stack overflow faults on the guard page instead of corrupting
/// memory. Returns the usable region (the guard page is not part of the slice).
pub fn alloc(size: usize) error{OutOfMemory}![]u8 {
    const ps = std.heap.pageSize();
    const usable_len = std.mem.alignForward(usize, size, ps);
    const total = usable_len + ps; // usable + one guard page
    return switch (builtin.os.tag) {
        .linux => allocLinux(total, usable_len, ps),
        .windows => allocWindows(total, usable_len, ps),
        else => comptime unreachable,
    };
}

/// Free a stack returned by `alloc`.
pub fn free(usable: []u8) void {
    const ps = std.heap.pageSize();
    switch (builtin.os.tag) {
        .linux => freeLinux(usable, ps),
        .windows => freeWindows(usable, ps),
        else => comptime unreachable,
    }
}

fn allocLinux(total: usize, usable_len: usize, ps: usize) error{OutOfMemory}![]u8 {
    const mapping = std.posix.mmap(
        null,
        total,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return error.OutOfMemory;
    errdefer std.posix.munmap(mapping);
    // Make the low page a no-access guard. std.posix.mprotect is absent in
    // Zig 0.16, so use the raw Linux syscall; PROT all-false = PROT_NONE.
    const rc = std.os.linux.mprotect(mapping.ptr, ps, .{});
    if (std.os.linux.errno(rc) != .SUCCESS) return error.OutOfMemory;
    return mapping[ps .. ps + usable_len];
}

fn freeLinux(usable: []u8, ps: usize) void {
    const base: [*]align(std.heap.page_size_min) u8 = @alignCast(usable.ptr - ps);
    std.posix.munmap(base[0 .. usable.len + ps]);
}

fn allocWindows(total: usize, usable_len: usize, ps: usize) error{OutOfMemory}![]u8 {
    const w = std.os.windows;
    const proc = w.GetCurrentProcess();
    // Reserve the whole region; the guard page stays reserved-but-uncommitted,
    // so any access to it raises an access violation.
    var base: ?*anyopaque = null;
    var reserve_size: w.SIZE_T = total;
    if (w.ntdll.NtAllocateVirtualMemory(proc, @ptrCast(&base), 0, &reserve_size, .{ .RESERVE = true }, .{ .READWRITE = true }) != .SUCCESS) {
        return error.OutOfMemory;
    }
    const region_base = @intFromPtr(base);
    errdefer {
        var b: ?*anyopaque = @ptrFromInt(region_base);
        var s: w.SIZE_T = 0;
        _ = w.ntdll.NtFreeVirtualMemory(proc, @ptrCast(&b), &s, .{ .RELEASE = true });
    }
    // Commit only the usable region (above the guard page).
    var commit: ?*anyopaque = @ptrFromInt(region_base + ps);
    var commit_size: w.SIZE_T = usable_len;
    if (w.ntdll.NtAllocateVirtualMemory(proc, @ptrCast(&commit), 0, &commit_size, .{ .COMMIT = true }, .{ .READWRITE = true }) != .SUCCESS) {
        return error.OutOfMemory;
    }
    const usable_ptr: [*]u8 = @ptrFromInt(region_base + ps);
    return usable_ptr[0..usable_len];
}

fn freeWindows(usable: []u8, ps: usize) void {
    const w = std.os.windows;
    var base: ?*anyopaque = @ptrFromInt(@intFromPtr(usable.ptr) - ps);
    var size: w.SIZE_T = 0; // 0 + RELEASE frees the whole reservation from base
    _ = w.ntdll.NtFreeVirtualMemory(w.GetCurrentProcess(), @ptrCast(&base), &size, .{ .RELEASE = true });
}

test "alloc returns a page-aligned, page-rounded, writable usable region" {
    const ps = std.heap.pageSize();
    const s = try alloc(ps);
    defer free(s);
    try std.testing.expect(@intFromPtr(s.ptr) % ps == 0);
    try std.testing.expect(s.len % ps == 0);
    try std.testing.expect(s.len >= ps);
    @memset(s, 0); // the usable region must be writable (not the guard page)
}

test "alloc rounds a non-page-multiple size up to a page" {
    const ps = std.heap.pageSize();
    const s = try alloc(ps + 1);
    defer free(s);
    try std.testing.expectEqual(std.mem.alignForward(usize, ps + 1, ps), s.len);
}
