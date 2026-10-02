//! Musical position representation by bar and beat offsets.

const std = @import("std");
const TimeSignature = @import("./time-signature.zig");

const Self = @This();

/// 0-indexed measure/bar number.
bar: usize = 0,
/// Beat offset within the bar.
beat: f64 = 0.0,

/// Calculate the sample frame offset given BPM, Time Signature, and sample rate.
/// BPM is defined relative to quarter notes (denominator = 4).
pub fn toSampleOffset(self: Self, bpm: usize, time_sig: TimeSignature, sample_rate: u32) !usize {
    if (std.math.isNan(self.beat) or self.beat < 0.0) {
        return error.InvalidPosition;
    }
    if (time_sig.denominator == 0 or time_sig.numerator == 0) {
        return error.InvalidTimeSignature;
    }

    const bpm_f: f64 = @floatFromInt(bpm);
    const sample_rate_f: f64 = @floatFromInt(sample_rate);
    const num_f: f64 = @floatFromInt(time_sig.numerator);
    const den_f: f64 = @floatFromInt(time_sig.denominator);

    // Standard BPM is based on quarter notes (denominator = 4)
    const samples_per_quarter: f64 = (60.0 / bpm_f) * sample_rate_f;
    // Scale sample duration per beat according to denominator (e.g. 8th note beat = 4/8 of quarter)
    const spb: f64 = samples_per_quarter * (4.0 / den_f);

    const total_beats: f64 = (@as(f64, @floatFromInt(self.bar)) * num_f) + self.beat;

    return @intFromFloat(total_beats * spb);
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

test "Position toSampleOffset invalid position NaN or negative" {
    const pos_nan = Self{ .bar = 0, .beat = std.math.nan(f64) };
    try std.testing.expectError(error.InvalidPosition, pos_nan.toSampleOffset(60, .{}, 44100));

    const pos_neg = Self{ .bar = 0, .beat = -1.0 };
    try std.testing.expectError(error.InvalidPosition, pos_neg.toSampleOffset(60, .{}, 44100));
}

test {
    std.testing.refAllDecls(@This());
}
