//! Minimal score structure: time signatures, tempo conversion, positions, and layers of score
//! information placed in time.
//!
//! Pure Zig (std only). `meters` handles only time and placement: what a note is and how it
//! sounds are left to the consumer, through primitives the consumer writes and payloads declared
//! with `Opaque(N)`, which `meters` passes through without reading.

const std = @import("std");

/// Returns the layer type made of the given named columns, for example
/// `Layer(.{ .span = Span, .note = Opaque(Note) })`.
pub const Layer = @import("./layer.zig").inner;
/// Errors of `zip`, besides the allocator's.
pub const ZipError = @import("./layer.zig").ZipError;
/// Marks a column of a layer as an opaque payload of type N, passed through unresolved.
pub const Opaque = @import("./opaque.zig").inner;
/// The time primitive: a bar, a beat and a length in beats, resolved to a start and a length in
/// frames.
pub const Span = @import("./span.zig");
/// Everything a primitive may need to resolve itself.
pub const Context = @import("./context.zig");
/// Musical position by bar and beat offsets.
pub const Position = @import("./position.zig");
/// Time signature (numerator / denominator).
pub const TimeSignature = @import("./time-signature.zig");
/// Tempo conversions between beats and sample frames.
pub const tempo = @import("./tempo.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("./context.zig");
    _ = @import("./layer.zig");
    _ = @import("./opaque.zig");
    _ = @import("./position.zig");
    _ = @import("./span.zig");
    _ = @import("./tempo.zig");
    _ = @import("./time-signature.zig");
}
