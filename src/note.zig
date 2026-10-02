//! Musical note representation with position, frequency, duration length, and volume.

const std = @import("std");
const Position = @import("./position.zig");

/// Returns a Note type parameterised by numeric floating point type T.
pub fn inner(comptime T: type) type {
    return struct {
        position: Position = .{},
        freq: T,
        length: usize,
        volume: T = 1.0,
    };
}

test {
    std.testing.refAllDecls(@This());
}
