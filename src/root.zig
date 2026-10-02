//! Minimal music theory and score data structures.
//!
//! Pure Zig (std only): pitches, notes, positions, time signatures, tempo conversion,
//! and declarative phrases that resolve into frequency-annotated note events.

const std = @import("std");

/// Note event with position, frequency, length in sample frames, and volume.
pub const Note = @import("./note.zig").inner;
/// Declarative phrase of raw notes, parameterized by sample type T and pitch type N.
pub const Phrase = @import("./phrase.zig").inner;
/// 12-tone equal temperament pitch (pitch class code and octave).
pub const Pitch = @import("./pitch.zig");
/// Musical position by bar and beat offsets.
pub const Position = @import("./position.zig");
/// Time signature (numerator / denominator).
pub const TimeSignature = @import("./time-signature.zig");
/// Tempo conversions between beats and sample frames.
pub const tempo = @import("./tempo.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("./note.zig");
    _ = @import("./phrase.zig");
    _ = @import("./pitch.zig");
    _ = @import("./position.zig");
    _ = @import("./tempo.zig");
    _ = @import("./time-signature.zig");
}
