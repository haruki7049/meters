//! Tempo conversions between beats and sample frames.
//!
//! Every conversion in `phrases` goes through `samplesPerBeat` and `framesFromBeats`, so positions
//! and lengths share one beat length and one rounding.

const std = @import("std");
const TimeSignature = @import("./time-signature.zig");

/// Errors of invalid timing parameters.
pub const Error = error{
    /// `bpm` is zero.
    InvalidBpm,
    /// The numerator or the denominator of the time signature is zero.
    InvalidTimeSignature,
    /// `sample_rate` is zero.
    InvalidSampleRate,
};

/// Samples per beat of `time_signature`, without rounding.
///
/// BPM counts quarter notes, and the denominator scales the beat: an 8th-note beat (6/8) is half
/// a quarter. At 120 BPM and 44100 Hz a beat is 22050 frames in 4/4 and 11025 frames in 6/8.
pub fn samplesPerBeat(bpm: usize, time_signature: TimeSignature, sample_rate: u32) Error!f64 {
    if (bpm == 0) return error.InvalidBpm;
    if (time_signature.numerator == 0 or time_signature.denominator == 0) return error.InvalidTimeSignature;
    if (sample_rate == 0) return error.InvalidSampleRate;

    const bpm_f: f64 = @floatFromInt(bpm);
    const sample_rate_f: f64 = @floatFromInt(sample_rate);
    const den_f: f64 = @floatFromInt(time_signature.denominator);

    // Keep this order of operations: changing it changes the last bits, and so which way some
    // offsets round.
    const samples_per_quarter: f64 = (60.0 / bpm_f) * sample_rate_f;
    return samples_per_quarter * (4.0 / den_f);
}

/// The first frame count a `usize` cannot hold, 2^bits.
const frame_limit: f64 = std.math.ldexp(@as(f64, 1.0), @bitSizeOf(usize));

/// Converts a number of beats to sample frames, rounded to the nearest frame once, at the end.
/// Returns null when `beats` is NaN, negative or infinite, or when the frame count does not fit
/// in a `usize`; the caller turns that into its own error.
pub fn framesFromBeats(beats: f64, samples_per_beat: f64) ?usize {
    // Written as a negation so that NaN, for which every comparison is false, is rejected too.
    if (!(beats >= 0.0)) return null;
    const frames = @round(beats * samples_per_beat);
    // Rejects infinity and frame counts beyond what a usize holds.
    if (!(frames < frame_limit)) return null;
    return @intFromFloat(frames);
}

test "samplesPerBeat in 4/4 keeps the fractional frame" {
    // 60 / 120 * 44100 = 22050
    try std.testing.expectEqual(@as(f64, 22050.0), try samplesPerBeat(120, .{}, 44100));
    // 60 / 60 * 44100 = 44100
    try std.testing.expectEqual(@as(f64, 44100.0), try samplesPerBeat(60, .{}, 44100));
    // 60 / 120 * 48000 = 24000
    try std.testing.expectEqual(@as(f64, 24000.0), try samplesPerBeat(120, .{}, 48000));
    // 60 / 190 * 44100 = 13926.315...
    try std.testing.expectApproxEqAbs(@as(f64, 13926.315789473684), try samplesPerBeat(190, .{}, 44100), 1e-9);
}

test "samplesPerBeat scales the beat by the denominator" {
    // 120 BPM, 44100 Hz: a quarter is 22050 frames.
    // 6/8: an 8th-note beat is 22050 * 4/8 = 11025
    try std.testing.expectEqual(@as(f64, 11025.0), try samplesPerBeat(120, .{ .numerator = 6, .denominator = 8 }, 44100));
    // 2/2: a half-note beat is 22050 * 4/2 = 44100
    try std.testing.expectEqual(@as(f64, 44100.0), try samplesPerBeat(120, .{ .numerator = 2, .denominator = 2 }, 44100));
    // 3/4: a quarter-note beat, the numerator does not change it
    try std.testing.expectEqual(@as(f64, 22050.0), try samplesPerBeat(120, .{ .numerator = 3, .denominator = 4 }, 44100));
    // 4/7 at 60 BPM: 44100 * 4/7 = 25200
    try std.testing.expectApproxEqAbs(@as(f64, 25200.0), try samplesPerBeat(60, .{ .numerator = 4, .denominator = 7 }, 44100), 1e-9);
}

test "samplesPerBeat rejects invalid parameters" {
    try std.testing.expectError(error.InvalidBpm, samplesPerBeat(0, .{}, 44100));
    try std.testing.expectError(error.InvalidTimeSignature, samplesPerBeat(120, .{ .numerator = 0 }, 44100));
    try std.testing.expectError(error.InvalidTimeSignature, samplesPerBeat(120, .{ .denominator = 0 }, 44100));
    try std.testing.expectError(error.InvalidSampleRate, samplesPerBeat(120, .{}, 0));
}

test "framesFromBeats rounds to the nearest frame" {
    // 190 BPM, 44100 Hz: 2 beats = 27852.63... frames, 16 beats = 222821.05... frames
    const spb = try samplesPerBeat(190, .{}, 44100);
    try std.testing.expectEqual(@as(?usize, 27853), framesFromBeats(2.0, spb));
    try std.testing.expectEqual(@as(?usize, 222821), framesFromBeats(16.0, spb));
    try std.testing.expectEqual(@as(?usize, 0), framesFromBeats(0.0, spb));
}

test "framesFromBeats rejects beats that have no frame count" {
    const spb = try samplesPerBeat(120, .{}, 44100);
    try std.testing.expectEqual(@as(?usize, null), framesFromBeats(-1.0, spb));
    try std.testing.expectEqual(@as(?usize, null), framesFromBeats(-std.math.floatMin(f64), spb));
    try std.testing.expectEqual(@as(?usize, null), framesFromBeats(std.math.nan(f64), spb));
    try std.testing.expectEqual(@as(?usize, null), framesFromBeats(std.math.inf(f64), spb));
    try std.testing.expectEqual(@as(?usize, null), framesFromBeats(-std.math.inf(f64), spb));
    // 1e300 beats is far more frames than a usize holds.
    try std.testing.expectEqual(@as(?usize, null), framesFromBeats(1e300, spb));
}

test {
    std.testing.refAllDecls(@This());
}
