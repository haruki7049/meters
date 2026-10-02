//! Declarative musical phrase structure and conversion into frequency-resolved note events.

const std = @import("std");
const Note = @import("./note.zig").inner;
const Pitch = @import("./pitch.zig");
const tempo = @import("./tempo.zig");

/// Returns a Phrase type parameterized by floating-point type T and pitch type N.
///
/// N is any pitch representation. When N declares `add(self, semitones: isize) N`
/// (as `Pitch` does), the transposing functions shift every note by that many semitones.
pub fn inner(comptime T: type, comptime N: type) type {
    return struct {
        const Self = @This();

        /// Raw note definition stored in musical phrase declarations (e.g. `phrase.zon`).
        pub const RawNote = struct {
            bar: usize = 0,
            beat: f64 = 0.0,
            note: N,
            duration_beats: f64 = 1.0,
            volume: T = 1.0,
            string: usize = 0,
        };

        name: []const u8,
        notes: []const RawNote,

        /// Converts raw notes into frequency-resolved Note events.
        /// S must declare `gen(note: N) f64` returning the frequency in Hz.
        /// The caller owns the returned slice.
        pub fn toEvents(
            self: Self,
            comptime S: type,
            allocator: std.mem.Allocator,
            bpm: usize,
            sample_rate: u32,
        ) ![]Note(T) {
            return self.toEventsTransposed(S, allocator, bpm, sample_rate, 0);
        }

        /// Converts raw notes transposed by semitones into frequency-resolved Note events.
        /// The caller owns the returned slice.
        pub fn toEventsTransposed(
            self: Self,
            comptime S: type,
            allocator: std.mem.Allocator,
            bpm: usize,
            sample_rate: u32,
            semitones: isize,
        ) ![]Note(T) {
            var events = try allocator.alloc(Note(T), self.notes.len);

            const spb_val: f64 = @floatFromInt(tempo.spb(bpm, sample_rate));

            for (self.notes, 0..) |item, i| {
                const note_val = if (@hasDecl(N, "add")) item.note.add(semitones) else item.note;
                events[i] = .{
                    .position = .{ .bar = item.bar, .beat = item.beat },
                    .freq = @floatCast(S.gen(note_val)),
                    .length = @intFromFloat(spb_val * item.duration_beats),
                    .volume = item.volume,
                };
            }

            return events;
        }
    };
}

test "Phrase toEvents converts raw notes into sequenced events" {
    const allocator = std.testing.allocator;

    const DummyNote = struct {
        code: enum { c, e },
        octave: usize,
    };

    const DummyScale = struct {
        pub fn gen(note: DummyNote) f64 {
            return switch (note.code) {
                .c => 261.63,
                .e => 329.63,
            };
        }
    };

    const phrase = inner(f64, DummyNote){
        .name = "TestEvents",
        .notes = &[_]inner(f64, DummyNote).RawNote{
            .{ .bar = 1, .beat = 1.5, .note = .{ .code = .c, .octave = 4 }, .duration_beats = 1.0, .volume = 0.8 },
            .{ .bar = 2, .beat = 0.0, .note = .{ .code = .e, .octave = 4 }, .duration_beats = 0.5, .volume = 0.6 },
        },
    };

    // 60 BPM, 44100 Hz => spb = 44100
    const events = try phrase.toEvents(DummyScale, allocator, 60, 44100);
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);

    try std.testing.expectEqual(@as(usize, 1), events[0].position.bar);
    try std.testing.expectEqual(@as(f64, 1.5), events[0].position.beat);
    try std.testing.expectApproxEqAbs(@as(f64, 261.63), events[0].freq, 1e-2);
    try std.testing.expectEqual(@as(usize, 44100), events[0].length);
    try std.testing.expectEqual(@as(f64, 0.8), events[0].volume);

    try std.testing.expectEqual(@as(usize, 2), events[1].position.bar);
    try std.testing.expectEqual(@as(f64, 0.0), events[1].position.beat);
    try std.testing.expectApproxEqAbs(@as(f64, 329.63), events[1].freq, 1e-2);
    try std.testing.expectEqual(@as(usize, 22050), events[1].length);
    try std.testing.expectEqual(@as(f64, 0.6), events[1].volume);
}

test "Phrase toEventsTransposed shifts Pitch notes by semitones" {
    const allocator = std.testing.allocator;

    const phrase = inner(f64, Pitch){
        .name = "Transposed",
        .notes = &[_]inner(f64, Pitch).RawNote{
            .{ .note = .{ .code = .a, .octave = 4 } },
            .{ .beat = 1.0, .note = .{ .code = .c, .octave = 4 }, .duration_beats = 2.0 },
        },
    };

    // 120 BPM, 44100 Hz => spb = 22050
    const events = try phrase.toEventsTransposed(Pitch, allocator, 120, 44100, 12);
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectApproxEqRel(@as(f64, 880.0), events[0].freq, 1e-4);
    try std.testing.expectEqual(@as(usize, 22050), events[0].length);
    try std.testing.expectEqual(@as(f64, 1.0), events[0].volume);
    try std.testing.expectApproxEqRel(Pitch.gen(.{ .code = .c, .octave = 5 }), events[1].freq, 1e-4);
    try std.testing.expectEqual(@as(f64, 1.0), events[1].position.beat);
    try std.testing.expectEqual(@as(usize, 44100), events[1].length);
}

test "Phrase coerces from a ZON-shaped literal" {
    // Mirrors how a `phrase.zon` file is imported as `Phrase(f64, Pitch)` at comptime.
    const phrase: inner(f64, Pitch) = .{
        .name = "Zon",
        .notes = &.{
            .{ .bar = 0, .beat = 0.0, .note = .{ .code = .e, .octave = 4 }, .duration_beats = 1.0 },
            .{ .bar = 0, .beat = 1.0, .note = .{ .code = .g, .octave = 4 }, .duration_beats = 0.5, .string = 2 },
        },
    };

    try std.testing.expectEqualStrings("Zon", phrase.name);
    try std.testing.expectEqual(@as(usize, 2), phrase.notes.len);
    try std.testing.expectEqual(Pitch.Code.g, phrase.notes[1].note.code);
    try std.testing.expectEqual(@as(usize, 2), phrase.notes[1].string);
}

test {
    std.testing.refAllDecls(@This());
}
