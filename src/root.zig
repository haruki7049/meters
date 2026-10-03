//! Minimal score structure: positions, time signatures, tempo conversion, and declarative
//! phrases placed in time as events.
//!
//! Pure Zig (std only). `phrases` handles only time and placement: what a note is and how it
//! sounds are left to the consumer, through the payload type of `Phrase(N)` and `Event(N)`.

const std = @import("std");

/// Time-placed event with a position, a length in sample frames, and a note payload of type N.
pub const Event = @import("./event.zig").inner;
/// Declarative phrase of raw notes whose payload is of type N.
pub const Phrase = @import("./phrase.zig").inner;
/// Musical position by bar and beat offsets.
pub const Position = @import("./position.zig");
/// Time signature (numerator / denominator).
pub const TimeSignature = @import("./time-signature.zig");
/// Tempo conversions between beats and sample frames.
pub const tempo = @import("./tempo.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("./event.zig");
    _ = @import("./phrase.zig");
    _ = @import("./position.zig");
    _ = @import("./tempo.zig");
    _ = @import("./time-signature.zig");
}
