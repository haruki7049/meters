//! 12-tone equal temperament pitch representation and frequency conversion.
//!
//! Architectural & Mathematical Overview:
//! 1. Pitch Representation: Models chromatic notes as a combination of pitch class enum `Code`
//!    (0-11 for C through B) and octave integer (`octave`).
//! 2. MIDI Note Mapping: Maps pitches to MIDI note numbers via `MIDI = 12 * (octave + 1) + code`.
//! 3. Semitone Transposition (`add`): Adds signed semitone offsets to MIDI numbers, clamping minimum
//!    pitch to MIDI 12 (C0) to avoid sub-audible frequencies.
//! 4. Frequency Calculation (`gen`): Converts pitch to frequency in Hz via standard tuning formula:
//!    `f = 440.0 * 2^((MIDI - 69) / 12)`, where A4 (MIDI 69) = 440.0 Hz.

const std = @import("std");

const Self = @This();

/// Note pitch class code (chromatic scale degree).
code: Code,
/// Octave index (e.g. 4 for middle octave A4 = 440 Hz).
octave: usize,

/// Transposes a pitch by a given number of semitones (positive or negative).
/// Clamps output pitch to octave 0 (MIDI note 12) if negative offset exceeds valid range.
pub fn add(self: Self, semitones: isize) Self {
    const self_midi_number: isize = @intCast(12 * (self.octave + 1) + @intFromEnum(self.code));
    const result_midi_number: isize = self_midi_number + semitones;
    const clamped_midi: isize = @max(12, result_midi_number);

    const result_code: Code = @enumFromInt(@as(u8, @intCast(@mod(clamped_midi, 12))));
    const div = @divFloor(clamped_midi, 12);
    const result_octave: usize = if (div > 0) @intCast(div - 1) else 0;

    return Self{
        .code = result_code,
        .octave = result_octave,
    };
}

/// Computes the exact fundamental frequency in Hertz (Hz) for this pitch assuming A4 = 440 Hz standard tuning.
pub fn gen(self: Self) f64 {
    const midi_number: isize = @intCast(12 * (self.octave + 1) + @intFromEnum(self.code));
    const exp: f64 = @floatFromInt(midi_number - 69);
    const result: f64 = 440.0 * std.math.pow(f64, 2.0, exp / 12.0);
    return result;
}

/// Note pitch class codes (chromatic scale). `s` suffix indicates a sharp note.
pub const Code = enum(u8) {
    c = 0,
    cs = 1,
    d = 2,
    ds = 3,
    e = 4,
    f = 5,
    fs = 6,
    g = 7,
    gs = 8,
    a = 9,
    as = 10,
    b = 11,
};

test "gen" {
    const a_4: f64 = 440.0;
    const result_a_4: f64 = Self.gen(.{ .code = .a, .octave = 4 });
    try std.testing.expectApproxEqRel(a_4, result_a_4, 0.0001);

    const g_3: f64 = 195.998;
    const result_g_3: f64 = Self.gen(.{ .code = .g, .octave = 3 });
    try std.testing.expectApproxEqRel(g_3, result_g_3, 0.0001);

    const c_7: f64 = 2093.005;
    const result_c_7: f64 = Self.gen(.{ .code = .c, .octave = 7 });
    try std.testing.expectApproxEqRel(c_7, result_c_7, 0.0001);
}

test "add" {
    const pitch_a_4: Self = Self{ .code = .a, .octave = 4 };
    const result_a_4: Self = pitch_a_4.add(3);
    try std.testing.expectEqual(result_a_4, Self{ .code = .c, .octave = 5 });

    // Negative semitones (descending)
    const pitch_c_4: Self = Self{ .code = .c, .octave = 4 };
    const result_b_3: Self = pitch_c_4.add(-1);
    try std.testing.expectEqual(result_b_3, Self{ .code = .b, .octave = 3 });

    const result_c_3: Self = pitch_c_4.add(-12);
    try std.testing.expectEqual(result_c_3, Self{ .code = .c, .octave = 3 });

    // Extreme negative semitones clamped to octave 0
    const result_clamped: Self = pitch_c_4.add(-100);
    try std.testing.expectEqual(result_clamped, Self{ .code = .c, .octave = 0 });
}

test {
    std.testing.refAllDecls(@This());
}
