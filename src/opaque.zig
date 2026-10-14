//! The marker that declares a column of a layer as an opaque payload, passed through unresolved.

const std = @import("std");

/// Returns the marker for a column of payloads of type N.
///
/// Written in a layer spec in place of a primitive, as in
/// `Layer(.{ .span = Span, .note = Opaque(Note) })`, it makes the column hold bare `N` values:
/// `notate` takes them, `map` transforms them, and `Layer.resolve` passes them through unchanged.
/// `meters` never reads them. A column is passed through only when it is declared with this
/// marker; every other column must be a primitive, or the layer type does not compile.
pub fn inner(comptime N: type) type {
    return struct {
        /// The payload type of the column.
        pub const Payload = N;
    };
}

test "the same payload type gives the same marker" {
    comptime std.debug.assert(inner(u8) == inner(u8));
    comptime std.debug.assert(inner(u8) != inner(i8));
    comptime std.debug.assert(inner(u8).Payload == u8);
}

test {
    std.testing.refAllDecls(@This());
}
