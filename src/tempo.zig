//! Tempo conversions between beats and sample frames.

const std = @import("std");

/// Samples per beat, without rounding.
///
/// BPM = 190, and SAMPLE_RATE = 44100, then samplesPerBeat(BPM, SAMPLE_RATE) is 13926.315...
pub fn samplesPerBeat(bpm: usize, sample_rate: u32) f64 {
    if (bpm == 0) return 0;
    return 60.0 / @as(f64, @floatFromInt(bpm)) * @as(f64, @floatFromInt(sample_rate));
}

/// Samples per beat, rounded to the nearest frame.
///
/// BPM = 120, and SAMPLE_RATE = 44100, then spb(BPM, SAMPLE_RATE) is 22050.
pub fn spb(bpm: usize, sample_rate: u32) usize {
    return @intFromFloat(@round(samplesPerBeat(bpm, sample_rate)));
}

test "spb" {
    try std.testing.expectEqual(@as(usize, 22050), spb(120, 44100));
    try std.testing.expectEqual(@as(usize, 44100), spb(60, 44100));
    try std.testing.expectEqual(@as(usize, 24000), spb(120, 48000));
    try std.testing.expectEqual(@as(usize, 0), spb(0, 44100));
}

test "spb rounds to the nearest frame" {
    // 60 / 110 * 44100 = 24054.54...
    try std.testing.expectEqual(@as(usize, 24055), spb(110, 44100));
    // 60 / 190 * 44100 = 13926.31...
    try std.testing.expectEqual(@as(usize, 13926), spb(190, 44100));
}

test "samplesPerBeat keeps the fractional frame" {
    try std.testing.expectApproxEqAbs(@as(f64, 13926.315789473684), samplesPerBeat(190, 44100), 1e-9);
    try std.testing.expectEqual(@as(f64, 22050.0), samplesPerBeat(120, 44100));
    try std.testing.expectEqual(@as(f64, 0.0), samplesPerBeat(0, 44100));
}

test {
    std.testing.refAllDecls(@This());
}
