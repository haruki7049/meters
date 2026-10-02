//! Tempo conversions between beats and sample frames.

const std = @import("std");

/// Samples per beat.
///
/// BPM = 120, and SAMPLE_RATE = 44100, then spb(BPM, SAMPLE_RATE) is 22050.
pub fn spb(bpm: usize, sample_rate: u32) usize {
    if (bpm == 0) return 0;
    const samples_per_beat: usize = @intFromFloat(@as(f32, @floatFromInt(60)) / @as(f32, @floatFromInt(bpm)) * @as(f32, @floatFromInt(sample_rate)));
    return samples_per_beat;
}

test "spb" {
    try std.testing.expectEqual(@as(usize, 22050), spb(120, 44100));
    try std.testing.expectEqual(@as(usize, 44100), spb(60, 44100));
    try std.testing.expectEqual(@as(usize, 24000), spb(120, 48000));
    try std.testing.expectEqual(@as(usize, 0), spb(0, 44100));
}

test {
    std.testing.refAllDecls(@This());
}
