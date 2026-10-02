//! Time signature specification for music sequencing.

const std = @import("std");

const Self = @This();

/// Number of beats per measure (numerator).
numerator: usize = 4,
/// Note value that represents one beat (denominator).
denominator: usize = 4,

test {
    std.testing.refAllDecls(@This());
}
