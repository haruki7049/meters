//! Everything a primitive may need to resolve itself: the tempo, the meter and the sample rate a
//! layer is resolved with, and the origin of the element being resolved. The same for every
//! primitive.

const std = @import("std");
const TimeSignature = @import("./time-signature.zig");

/// Tempo in quarter notes per minute, whatever the denominator of `time_signature`.
bpm: usize,
/// Meter the beats of the layer are counted in.
time_signature: TimeSignature = .{},
/// Sample rate the frame positions and lengths are counted in.
sample_rate: u32,
/// Beats from bar 0 beat 0 to the start of the segment an element was written in.
///
/// `Layer.resolve` adds the origin of each element to the origin given by the caller, so a
/// primitive that places itself in time (such as `Span`) adds it to its own position. Every other
/// primitive ignores it.
origin: f64 = 0.0,

test {
    std.testing.refAllDecls(@This());
}
