//! Declarative phrase structure and its placement in time as events.

const std = @import("std");
const Event = @import("./event.zig").inner;
const tempo = @import("./tempo.zig");

/// Returns a Phrase type whose notes carry a payload of type N.
///
/// `phrases` only places notes in time. It does not interpret N: a pitch, a drum voice, a
/// velocity or an instrument string all belong to N, and resolving N (for example to a frequency)
/// is left to the consumer.
pub fn inner(comptime N: type) type {
    return struct {
        const Self = @This();

        /// Raw note definition stored in phrase declarations (e.g. `phrase.zon`).
        pub const RawNote = struct {
            /// 0-indexed bar the note starts in.
            bar: usize = 0,
            /// Beat offset within the bar.
            beat: f64 = 0.0,
            /// Length in beats; must be finite and not negative.
            duration_beats: f64 = 1.0,
            /// The note payload, passed through to the event unchanged.
            note: N,
        };

        /// Errors `toEvents` returns.
        pub const ToEventsError = error{
            /// `bpm` is zero.
            InvalidBpm,
            /// A `duration_beats` is NaN, negative, infinite, or longer than a `usize` counts in frames.
            InvalidDuration,
        } || std.mem.Allocator.Error;

        name: []const u8,
        notes: []const RawNote,

        /// Places every note in time: its position, and its length in sample frames rounded to
        /// the nearest frame. Each note payload is passed through unchanged.
        /// The caller owns the returned slice.
        pub fn toEvents(
            self: Self,
            allocator: std.mem.Allocator,
            bpm: usize,
            sample_rate: u32,
        ) ToEventsError![]Event(N) {
            if (bpm == 0) return error.InvalidBpm;

            const events = try allocator.alloc(Event(N), self.notes.len);
            errdefer allocator.free(events);

            // Keep the fractional frame of a beat, so longer notes do not accumulate its truncation.
            const spb_val: f64 = tempo.samplesPerBeat(bpm, sample_rate);

            for (self.notes, events) |item, *event| {
                event.* = .{
                    .position = .{ .bar = item.bar, .beat = item.beat },
                    .length = try frames(spb_val, item.duration_beats),
                    .note = item.note,
                };
            }

            return events;
        }
    };
}

/// The first frame count a `usize` cannot hold, 2^bits.
const frame_limit: f64 = std.math.ldexp(@as(f64, 1.0), @bitSizeOf(usize));

/// Converts a duration in beats to sample frames, rounded to the nearest frame.
fn frames(spb: f64, duration_beats: f64) error{InvalidDuration}!usize {
    // Written as a negation so that NaN, for which every comparison is false, is rejected too.
    if (!(duration_beats >= 0.0)) return error.InvalidDuration;
    const value = @round(spb * duration_beats);
    // Rejects infinity and lengths beyond what a usize counts.
    if (!(value < frame_limit)) return error.InvalidDuration;
    return @intFromFloat(value);
}

/// A pitch-like payload for the tests; `phrases` itself knows no pitch type.
const TestPitch = struct {
    code: enum { c, e, g, a },
    octave: i8,
};

test "Phrase toEvents places notes in time and passes the payload through" {
    const allocator = std.testing.allocator;

    const phrase = inner(TestPitch){
        .name = "TestEvents",
        .notes = &.{
            .{ .bar = 1, .beat = 1.5, .note = .{ .code = .c, .octave = 4 }, .duration_beats = 1.0 },
            .{ .bar = 2, .beat = 0.0, .note = .{ .code = .e, .octave = -1 }, .duration_beats = 0.5 },
        },
    };

    // 60 BPM, 44100 Hz => spb = 44100
    const events = try phrase.toEvents(allocator, 60, 44100);
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);

    try std.testing.expectEqual(@as(usize, 1), events[0].position.bar);
    try std.testing.expectEqual(@as(f64, 1.5), events[0].position.beat);
    try std.testing.expectEqual(@as(usize, 44100), events[0].length); // 1 beat
    try std.testing.expectEqual(TestPitch{ .code = .c, .octave = 4 }, events[0].note);

    try std.testing.expectEqual(@as(usize, 2), events[1].position.bar);
    try std.testing.expectEqual(@as(f64, 0.0), events[1].position.beat);
    try std.testing.expectEqual(@as(usize, 22050), events[1].length); // 0.5 beats
    try std.testing.expectEqual(TestPitch{ .code = .e, .octave = -1 }, events[1].note);
}

test "Phrase toEvents keeps the fractional samples per beat in note lengths" {
    const allocator = std.testing.allocator;

    const phrase = inner(TestPitch){
        .name = "Fractional",
        .notes = &.{
            .{ .note = .{ .code = .a, .octave = 4 }, .duration_beats = 2.0 },
            .{ .beat = 2.0, .note = .{ .code = .a, .octave = 4 }, .duration_beats = 16.0 },
        },
    };

    // 190 BPM, 44100 Hz => 13926.315... samples per beat.
    // A truncated spb of 13926 would give 27852 and 222816.
    const events = try phrase.toEvents(allocator, 190, 44100);
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 27853), events[0].length); // 27852.63...
    try std.testing.expectEqual(@as(usize, 222821), events[1].length); // 222821.05...
}

test "Phrase accepts any payload type, such as a drum voice" {
    const allocator = std.testing.allocator;

    const Drum = enum { kick, snare };
    const phrase = inner(Drum){
        .name = "Beat",
        .notes = &.{
            .{ .note = .kick, .duration_beats = 0.25 },
            .{ .beat = 1.0, .note = .snare, .duration_beats = 0.25 },
        },
    };

    // 120 BPM, 44100 Hz => spb = 22050, so a quarter beat is 5512.5 frames, rounded to 5513
    const events = try phrase.toEvents(allocator, 120, 44100);
    defer allocator.free(events);

    try std.testing.expectEqual(Drum.kick, events[0].note);
    try std.testing.expectEqual(Drum.snare, events[1].note);
    try std.testing.expectEqual(@as(usize, 5513), events[0].length);
}

test "Phrase payload carries what used to be fixed fields" {
    const allocator = std.testing.allocator;

    // Volume and the instrument string live in the payload, not in RawNote.
    const GuitarNote = struct { pitch: TestPitch, string: usize, volume: f64 = 1.0 };
    const phrase = inner(GuitarNote){
        .name = "Guitar",
        .notes = &.{
            .{ .note = .{ .pitch = .{ .code = .e, .octave = 2 }, .string = 5, .volume = 0.8 } },
        },
    };

    const events = try phrase.toEvents(allocator, 120, 44100);
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 5), events[0].note.string);
    try std.testing.expectEqual(@as(f64, 0.8), events[0].note.volume);
}

test "Phrase coerces from a ZON-shaped literal" {
    // Mirrors how a `phrase.zon` file is imported as `Phrase(N)` at comptime.
    const phrase: inner(TestPitch) = .{
        .name = "Zon",
        .notes = &.{
            .{ .bar = 0, .beat = 0.0, .note = .{ .code = .e, .octave = 4 }, .duration_beats = 1.0 },
            .{ .bar = 0, .beat = 1.0, .note = .{ .code = .g, .octave = 4 }, .duration_beats = 0.5 },
        },
    };

    try std.testing.expectEqualStrings("Zon", phrase.name);
    try std.testing.expectEqual(@as(usize, 2), phrase.notes.len);
    try std.testing.expectEqual(TestPitch{ .code = .g, .octave = 4 }, phrase.notes[1].note);
}

test "Phrase toEvents returns an empty slice for an empty phrase" {
    const allocator = std.testing.allocator;
    const phrase = inner(TestPitch){ .name = "Empty", .notes = &.{} };
    const events = try phrase.toEvents(allocator, 120, 44100);
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "Phrase toEvents accepts a zero duration" {
    const allocator = std.testing.allocator;
    const phrase = inner(TestPitch){ .name = "Zero", .notes = &.{
        .{ .note = .{ .code = .c, .octave = 4 }, .duration_beats = 0.0 },
    } };
    const events = try phrase.toEvents(allocator, 120, 44100);
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 0), events[0].length);
}

test "Phrase toEvents rejects a zero bpm" {
    const phrase = inner(TestPitch){ .name = "Bpm", .notes = &.{
        .{ .note = .{ .code = .c, .octave = 4 } },
    } };
    try std.testing.expectError(error.InvalidBpm, phrase.toEvents(std.testing.allocator, 0, 44100));
}

test "Phrase toEvents rejects invalid durations without leaking" {
    const invalid = [_]f64{
        -1.0,
        -std.math.floatMin(f64),
        std.math.nan(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
        // 1e300 beats is far more frames than a usize counts.
        1e300,
    };
    for (invalid) |duration| {
        // The invalid note comes second, so the slice is already allocated when it is reached;
        // std.testing.allocator fails the test if that slice leaks.
        const phrase = inner(TestPitch){ .name = "Duration", .notes = &.{
            .{ .note = .{ .code = .c, .octave = 4 } },
            .{ .beat = 1.0, .note = .{ .code = .e, .octave = 4 }, .duration_beats = duration },
        } };
        try std.testing.expectError(error.InvalidDuration, phrase.toEvents(std.testing.allocator, 120, 44100));
    }
}

test {
    std.testing.refAllDecls(@This());
}
