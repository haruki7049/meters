//! Time-placed event: a position, a length in sample frames, and a note payload of any type.

const std = @import("std");
const Position = @import("./position.zig");

/// Returns an Event type carrying a note payload of type N.
///
/// `phrases` does not interpret N: what a note is (a pitch, a drum voice, a velocity, ...) and how
/// it sounds are left to the consumer.
pub fn inner(comptime N: type) type {
    return struct {
        /// When the event starts.
        position: Position,
        /// How long the event lasts, in sample frames: the offset of its end minus the offset of its
        /// start, so an event that ends where the next one starts tiles with it exactly.
        length: usize,
        /// The note payload, passed through unchanged.
        note: N,
    };
}

test {
    std.testing.refAllDecls(@This());
}
