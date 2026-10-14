//! When a note starts and how long it lasts: the time primitive of a layer. Resolves to the frame
//! the note starts on and its length in frames.
//!
//! A span counts a bar, a beat and a length in beats of the time signature, from the start of the
//! segment it was written in; `Context.origin` places that segment. Its length is the offset of its
//! end minus the offset of its start, never a length rounded on its own, so a note that ends where
//! the next one starts tiles with it exactly, also across segments.
//!
//! The length is the note value written in `beats`, resolved to frames, and nothing more: `meters`
//! hands it over as resolved and does not decide how long the note actually sounds. Whether that
//! length is used as the sounding length or ignored is up to the instrument the user implements.

const std = @import("std");
const Context = @import("./context.zig");
const tempo = @import("./tempo.zig");

const Self = @This();

/// 0-indexed bar, counted from the start of the segment the note was written in.
bar: usize = 0,
/// Beat offset from the start of `bar`; must be finite and not negative. A beat at or past the
/// numerator of the time signature carries into the following bars: in 4/4, bar 0 beat 5 is the
/// same position as bar 1 beat 1.
beat: f64 = 0.0,
/// Length in beats of the time signature; must be finite and not negative.
beats: f64 = 1.0,

/// Where a note sounds, in sample frames.
pub const Frames = struct {
    /// The frame the note starts on, counted from bar 0 beat 0.
    start: usize,
    /// The note value in frames: the offset of its end minus the offset of its start. Whether it is
    /// used as the sounding length or ignored is up to the instrument the user implements.
    length: usize,
};

/// What a span resolves to.
pub const ResolveT = Frames;

/// Errors `resolve` returns.
pub const ResolveError = error{
    /// `beat` is NaN, negative or infinite, or the start does not fit in a `usize`.
    InvalidPosition,
    /// `beats` is NaN, negative or infinite, or the end does not fit in a `usize`.
    InvalidDuration,
} || tempo.Error;

/// Resolves this span to frames: it starts `ctx.origin` beats, plus `bar` bars, plus `beat` beats
/// after bar 0 beat 0, and ends `beats` beats later. Both offsets are rounded to the nearest frame
/// once, and the length is the end minus the start.
///
/// With an origin of zero, the start is the frame `Position.toSampleOffset` gives for the same bar
/// and beat. The beats are compared as `f64`, so on a binary grid (halves, quarters, 16ths, ...)
/// back-to-back notes always tile; on a grid such as triplets, `beat + beats` can differ from the
/// next beat in the last bit and, rarely, leave one frame of gap or overlap.
pub fn resolve(self: Self, ctx: Context) ResolveError!ResolveT {
    // Written as a negation so that NaN is rejected too; infinity is caught below.
    if (!(self.beat >= 0.0)) return error.InvalidPosition;

    const spb = try tempo.samplesPerBeat(ctx.bpm, ctx.time_signature, ctx.sample_rate);
    const numerator: f64 = @floatFromInt(ctx.time_signature.numerator);
    const bar_start = ctx.origin + @as(f64, @floatFromInt(self.bar)) * numerator;
    const start = tempo.framesFromBeats(bar_start + self.beat, spb) orelse return error.InvalidPosition;

    // Written as a negation so that NaN is rejected too.
    if (!(self.beats >= 0.0 and std.math.isFinite(self.beats))) return error.InvalidDuration;
    // The start is valid, so an end too far to have an offset is the length's fault.
    const end = tempo.framesFromBeats(bar_start + (self.beat + self.beats), spb) orelse return error.InvalidDuration;

    // Rounding is monotonic and beats is not negative, so end >= start.
    return .{ .start = start, .length = end - start };
}

const Position = @import("./position.zig");
const TimeSignature = @import("./time-signature.zig");

test "resolve gives the start and the length in frames" {
    // 60 BPM, 44100 Hz => spb = 44100. Bar 1 beat 1.5 is 5.5 beats = 242550 frames.
    const frames = try (Self{ .bar = 1, .beat = 1.5, .beats = 1.0 }).resolve(.{ .bpm = 60, .sample_rate = 44100 });
    try std.testing.expectEqual(@as(usize, 242550), frames.start);
    try std.testing.expectEqual(@as(usize, 44100), frames.length);
}

test "resolve keeps the fractional samples per beat in lengths" {
    // 190 BPM, 44100 Hz => 13926.315... samples per beat.
    // A truncated spb of 13926 would give 27852 and 222816.
    const ctx: Context = .{ .bpm = 190, .sample_rate = 44100 };
    try std.testing.expectEqual(@as(usize, 27853), (try (Self{ .beats = 2.0 }).resolve(ctx)).length); // 27852.63...
    try std.testing.expectEqual(@as(usize, 222821), (try (Self{ .beat = 2.0, .beats = 16.0 }).resolve(ctx)).length); // 222821.05...
}

test "resolve adds the origin to the start, not to the length" {
    // 120 BPM, 44100 Hz => spb = 22050. Origin 8 beats plus bar 1 beat 1 is 13 beats.
    const frames = try (Self{ .bar = 1, .beat = 1.0, .beats = 0.5 }).resolve(.{ .bpm = 120, .sample_rate = 44100, .origin = 8.0 });
    try std.testing.expectEqual(@as(usize, 13 * 22050), frames.start);
    try std.testing.expectEqual(@as(usize, 11025), frames.length);
}

test "resolve starts where Position.toSampleOffset does, with an origin of zero" {
    const bpm: usize = 190;
    const sample_rate: u32 = 44100;
    // Positions are k/48 beats, which covers 16ths, 32nds and sextuplets, over 8 bars of 4/4 and 6/8.
    for ([_]TimeSignature{ .{}, .{ .numerator = 6, .denominator = 8 } }) |meter| {
        for (0..8) |bar| {
            for (0..4 * 48) |k| {
                const beat = @as(f64, @floatFromInt(k)) / 48.0;
                const position: Position = .{ .bar = bar, .beat = beat };
                const frames = try (Self{ .bar = bar, .beat = beat }).resolve(.{ .bpm = bpm, .time_signature = meter, .sample_rate = sample_rate });
                try std.testing.expectEqual(try position.toSampleOffset(bpm, meter, sample_rate), frames.start);
            }
        }
    }
}

test "resolve accepts a zero length" {
    const frames = try (Self{ .beat = 1.0, .beats = 0.0 }).resolve(.{ .bpm = 120, .sample_rate = 44100 });
    try std.testing.expectEqual(@as(usize, 0), frames.length);
}

test "resolve in 6/8 gives an 8th-note beat" {
    // 60 BPM, 44100 Hz, 6/8: a beat is 44100 * 4/8 = 22050 frames
    const ctx: Context = .{ .bpm = 60, .time_signature = .{ .numerator = 6, .denominator = 8 }, .sample_rate = 44100 };
    try std.testing.expectEqual(@as(usize, 22050), (try (Self{}).resolve(ctx)).length);
    // 3 beats = 3 * 22050 = 66150, half a bar
    try std.testing.expectEqual(@as(usize, 66150), (try (Self{ .beat = 1.0, .beats = 3.0 }).resolve(ctx)).length);
}

test "resolve tiles a note whose end carries past the bar" {
    // A note from bar 0 beat 3 lasting 2.5 beats ends at bar 1 beat 1.5, where the next one starts.
    const ctx: Context = .{ .bpm = 190, .sample_rate = 44100 };
    const first = try (Self{ .bar = 0, .beat = 3.0, .beats = 2.5 }).resolve(ctx);
    const next = try (Self{ .bar = 1, .beat = 1.5 }).resolve(ctx);
    try std.testing.expectEqual(next.start, first.start + first.length);
}

test "resolve tiles back-to-back notes in every meter" {
    // One-beat notes on beats 0, 1 and 2: each must end exactly where the next one starts.
    const meters = [_]TimeSignature{
        .{ .numerator = 4, .denominator = 4 },
        .{ .numerator = 3, .denominator = 4 },
        .{ .numerator = 6, .denominator = 8 },
        .{ .numerator = 12, .denominator = 8 },
        .{ .numerator = 2, .denominator = 2 },
        .{ .numerator = 4, .denominator = 7 },
    };
    for (meters) |meter| {
        inline for (.{ 60, 120, 190 }) |bpm| {
            const ctx: Context = .{ .bpm = bpm, .time_signature = meter, .sample_rate = 44100 };
            for (0..2) |beat| {
                const current = try (Self{ .beat = @floatFromInt(beat) }).resolve(ctx);
                const next = try (Self{ .beat = @floatFromInt(beat + 1) }).resolve(ctx);
                try std.testing.expectEqual(next.start, current.start + current.length);
            }
        }
    }
}

test "resolve rejects invalid timing parameters" {
    const span: Self = .{};
    try std.testing.expectError(error.InvalidBpm, span.resolve(.{ .bpm = 0, .sample_rate = 44100 }));
    try std.testing.expectError(error.InvalidSampleRate, span.resolve(.{ .bpm = 120, .sample_rate = 0 }));
    try std.testing.expectError(error.InvalidTimeSignature, span.resolve(.{ .bpm = 120, .time_signature = .{ .numerator = 0 }, .sample_rate = 44100 }));
    try std.testing.expectError(error.InvalidTimeSignature, span.resolve(.{ .bpm = 120, .time_signature = .{ .denominator = 0 }, .sample_rate = 44100 }));
}

test "resolve rejects invalid positions" {
    const ctx: Context = .{ .bpm = 120, .sample_rate = 44100 };
    const invalid = [_]Self{
        .{ .beat = -1.0 },
        .{ .beat = std.math.nan(f64) },
        .{ .beat = std.math.inf(f64) },
        .{ .beat = -std.math.inf(f64) },
        // An offset beyond what a usize holds
        .{ .bar = std.math.maxInt(usize) },
    };
    for (invalid) |span| try std.testing.expectError(error.InvalidPosition, span.resolve(ctx));

    // An origin that is not a valid number of beats makes the start invalid too.
    try std.testing.expectError(error.InvalidPosition, (Self{}).resolve(.{ .bpm = 120, .sample_rate = 44100, .origin = std.math.nan(f64) }));
}

test "resolve rejects invalid lengths" {
    const ctx: Context = .{ .bpm = 120, .sample_rate = 44100 };
    const invalid = [_]f64{
        -1.0,
        -std.math.floatMin(f64),
        std.math.nan(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
        // 1e300 beats is far more frames than a usize counts.
        1e300,
    };
    for (invalid) |beats| try std.testing.expectError(error.InvalidDuration, (Self{ .beat = 1.0, .beats = beats }).resolve(ctx));
}

test {
    std.testing.refAllDecls(@This());
}
