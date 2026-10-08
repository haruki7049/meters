//! Time signature: beats per bar and the note value of one beat. Defaults to 4/4.

const std = @import("std");

const Self = @This();

/// Number of beats per bar (numerator); must not be zero.
numerator: usize = 4,
/// Note value of one beat (denominator): 4 is a quarter note, 8 an 8th note. A beat is a quarter
/// scaled by `4 / denominator`, so a value such as 7 works too; must not be zero.
denominator: usize = 4,

test {
    std.testing.refAllDecls(@This());
}
