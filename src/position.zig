//! Musical position representation by bar and beat offsets.

const std = @import("std");
const TimeSignature = @import("./time-signature.zig");
const tempo = @import("./tempo.zig");

const Self = @This();

/// 0-indexed measure/bar number.
bar: usize = 0,
/// Beat offset within the bar; must be finite and not negative.
beat: f64 = 0.0,

/// Errors `toSampleOffset` returns.
pub const ToSampleOffsetError = error{
    /// `beat` is NaN, negative or infinite, or the offset does not fit in a `usize`.
    InvalidPosition,
} || tempo.Error;

/// Calculate the sample frame offset given BPM, Time Signature, and sample rate.
/// BPM is defined relative to quarter notes (denominator = 4).
/// The offset is rounded to the nearest frame.
pub fn toSampleOffset(self: Self, bpm: usize, time_sig: TimeSignature, sample_rate: u32) ToSampleOffsetError!usize {
    // Written as a negation so that NaN is rejected too; infinity is caught below.
    if (!(self.beat >= 0.0)) return error.InvalidPosition;

    const spb = try tempo.samplesPerBeat(bpm, time_sig, sample_rate);
    const num_f: f64 = @floatFromInt(time_sig.numerator);
    const total_beats: f64 = (@as(f64, @floatFromInt(self.bar)) * num_f) + self.beat;

    // Round instead of truncating: a product that lands just below an integer (e.g. 44099.99...)
    // would otherwise lose a frame.
    return tempo.framesFromBeats(total_beats, spb) orelse error.InvalidPosition;
}

test "Position toSampleOffset 4/4 meter" {
    const pos = Self{ .bar = 1, .beat = 2.0 };
    // 60 BPM, 44100 Hz, 4/4 meter
    // quarter note = 44100 samples
    // total_beats = 1 * 4 + 2 = 6 beats
    // expected = 6 * 44100 = 264600
    const offset = try pos.toSampleOffset(60, .{}, 44100);
    try std.testing.expectEqual(@as(usize, 264600), offset);
}

test "Position toSampleOffset 6/8 meter" {
    const pos = Self{ .bar = 1, .beat = 0.0 };
    const time_sig = TimeSignature{ .numerator = 6, .denominator = 8 };
    // 60 BPM, 44100 Hz, 6/8 meter
    // quarter note = 44100 samples
    // 8th note beat = 44100 * (4/8) = 22050 samples
    // 1 bar = 6 beats = 6 * 22050 = 132300 samples
    const offset = try pos.toSampleOffset(60, time_sig, 44100);
    try std.testing.expectEqual(@as(usize, 132300), offset);
}

test "Position toSampleOffset 4/7 meter" {
    const pos = Self{ .bar = 1, .beat = 0.0 };
    const time_sig = TimeSignature{ .numerator = 4, .denominator = 7 };
    // 60 BPM, 44100 Hz, 4/7 meter
    // 1 beat = 44100 * (4/7) = 25200 samples
    // 1 bar = 4 beats = 4 * 25200 = 100800 samples
    const offset = try pos.toSampleOffset(60, time_sig, 44100);
    try std.testing.expectEqual(@as(usize, 100800), offset);
}

test "Position toSampleOffset invalid time signature" {
    const pos = Self{ .bar = 0, .beat = 0.0 };
    try std.testing.expectError(error.InvalidTimeSignature, pos.toSampleOffset(60, .{ .denominator = 0 }, 44100));
    try std.testing.expectError(error.InvalidTimeSignature, pos.toSampleOffset(60, .{ .numerator = 0 }, 44100));
}

test "Position toSampleOffset invalid bpm" {
    const pos = Self{ .bar = 1, .beat = 0.0 };
    try std.testing.expectError(error.InvalidBpm, pos.toSampleOffset(0, .{}, 44100));
}

test "Position toSampleOffset rounds to the nearest frame" {
    // 190 BPM, 44100 Hz: one beat is 13926.315... frames.
    // Beat 19/6 is exactly 44100 frames, but the f64 product lands just below it.
    const sextuplet = Self{ .bar = 0, .beat = 19.0 / 6.0 };
    try std.testing.expectEqual(@as(usize, 44100), try sextuplet.toSampleOffset(190, .{}, 44100));

    // Two beats are 27852.63... frames, so the offset rounds up.
    const two_beats = Self{ .bar = 0, .beat = 2.0 };
    try std.testing.expectEqual(@as(usize, 27853), try two_beats.toSampleOffset(190, .{}, 44100));
}

test "Position toSampleOffset stays within half a frame on 16th, 32nd and sextuplet grids" {
    const bpm: usize = 190;
    const sample_rate: u32 = 44100;
    // Positions are k/48 beats, which covers 16ths (k % 12), 32nds (k % 6) and sextuplets (k % 8).
    // The exact offset is k * 60 * sample_rate / (bpm * 48) frames.
    const den: i128 = @as(i128, bpm) * 48;
    for (0..24) |bar| {
        for (0..4 * 48) |k_in_bar| {
            if (k_in_bar % 6 != 0 and k_in_bar % 8 != 0) continue;
            const pos = Self{ .bar = bar, .beat = @as(f64, @floatFromInt(k_in_bar)) / 48.0 };
            const offset = try pos.toSampleOffset(bpm, .{}, sample_rate);

            const k: i128 = @intCast(bar * 4 * 48 + k_in_bar);
            const num: i128 = k * 60 * sample_rate;
            // |offset - num / den| <= 1/2, kept in integers.
            const diff = 2 * (@as(i128, @intCast(offset)) * den - num);
            try std.testing.expect(@abs(diff) <= den);
        }
    }
}

test "Position toSampleOffset invalid position NaN or negative" {
    const pos_nan = Self{ .bar = 0, .beat = std.math.nan(f64) };
    try std.testing.expectError(error.InvalidPosition, pos_nan.toSampleOffset(60, .{}, 44100));

    const pos_neg = Self{ .bar = 0, .beat = -1.0 };
    try std.testing.expectError(error.InvalidPosition, pos_neg.toSampleOffset(60, .{}, 44100));
}

test "Position toSampleOffset rejects infinite beats and offsets beyond a usize" {
    try std.testing.expectError(error.InvalidPosition, (Self{ .beat = std.math.inf(f64) }).toSampleOffset(120, .{}, 44100));
    try std.testing.expectError(error.InvalidPosition, (Self{ .beat = -std.math.inf(f64) }).toSampleOffset(120, .{}, 44100));
    // maxInt(usize) bars of 4 beats at 22050 frames each is far beyond a usize.
    try std.testing.expectError(error.InvalidPosition, (Self{ .bar = std.math.maxInt(usize) }).toSampleOffset(120, .{}, 44100));
    // A finite beat whose offset overflows: 1e300 beats.
    try std.testing.expectError(error.InvalidPosition, (Self{ .beat = 1e300 }).toSampleOffset(120, .{}, 44100));
}

test "Position toSampleOffset invalid sample rate" {
    try std.testing.expectError(error.InvalidSampleRate, (Self{ .bar = 1 }).toSampleOffset(120, .{}, 0));
}

test "Position toSampleOffset 3/4, 2/2 and 12/8 meters" {
    // 120 BPM, 44100 Hz: a quarter is 22050 frames.
    // 3/4: bar 2 = 2 * 3 quarters = 6 * 22050 = 132300
    try std.testing.expectEqual(@as(usize, 132300), try (Self{ .bar = 2 }).toSampleOffset(120, .{ .numerator = 3, .denominator = 4 }, 44100));
    // 2/2: bar 1, beat 1 = 3 halves = 3 * 44100 = 132300
    try std.testing.expectEqual(@as(usize, 132300), try (Self{ .bar = 1, .beat = 1.0 }).toSampleOffset(120, .{ .numerator = 2, .denominator = 2 }, 44100));
    // 12/8: bar 1 = 12 eighths = 12 * 11025 = 132300
    try std.testing.expectEqual(@as(usize, 132300), try (Self{ .bar = 1 }).toSampleOffset(120, .{ .numerator = 12, .denominator = 8 }, 44100));
}

test {
    std.testing.refAllDecls(@This());
}
