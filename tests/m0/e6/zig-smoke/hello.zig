// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// E6 cross-compilation smoke test: built on Linux for x86_64-windows, run on
// the Windows runner. std.debug.print writes to stderr, and the probe reads
// both streams, so this does not depend on the stdout API, which changed
// across recent Zig releases.
const std = @import("std");

pub fn main() void {
    std.debug.print("subsystem-warrior e6 zig smoke\n", .{});
}
