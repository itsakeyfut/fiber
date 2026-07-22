# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `examples/basic.zig` and `examples/scheduler.zig`, runnable via
  `zig build examples`.
- GitHub Actions CI building and testing on Linux and Windows (x86_64).

### Removed

- `src/main.zig`; the demo now lives under `examples/`.

## [0.1.0] - 2026-07-22

Initial release.

### Added

- `Fiber` — a stackful fiber with a dedicated 64 KiB stack and cooperative
  `resumeFiber` / `yield` context switching.
- `Fiber.create` / `Fiber.destroy` for allocating and freeing a fiber and its stack.
- `Fiber.yield` (also re-exported as the module-level `yield`) to suspend the running
  fiber back to its caller.
- `State` enum (`ready`, `running`, `suspended`, `done`) tracking the fiber lifecycle.
- Hand-written `x86_64` context switch for the System V ABI (Linux/*BSD) and Windows,
  with the Windows path preserving the non-volatile `xmm6`–`xmm15` registers and
  `mxcsr`.
- `src/main.zig` demonstrating a run/yield/complete loop (`zig build run`).

[Unreleased]: https://github.com/itsakeyfut/fiber/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/itsakeyfut/fiber/releases/tag/v0.1.0
