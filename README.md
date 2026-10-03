# phrases

Minimal score structure library in Zig

Pure Zig with no dependencies beyond `std`. Requires Zig `0.16.0`.

`phrases` handles time and placement only: bars, beats, time signatures, tempo, and phrases of notes placed in time.
It does not know what a note is. The payload type `N` of `Phrase(N)` and `Event(N)` carries whatever a note means to
the consumer (a pitch, a drum voice, a velocity, an instrument string, ...), and resolving it, for example to a
frequency, is the consumer's job.

## Provided types

| Symbol | Description |
| :--- | :--- |
| `Phrase(N)` | Declarative phrase of raw notes (`bar`, `beat`, `duration_beats`, `note: N`), with `toEvents` |
| `Event(N)` | Time-placed event: `position`, `length` (sample frames), `note: N` |
| `Position` | Bar and beat offset, with `toSampleOffset` |
| `TimeSignature` | `numerator` / `denominator` (defaults to 4/4) |
| `tempo` | `samplesPerBeat` (a beat of a time signature, in frames) and `framesFromBeats` (rounded once, to the nearest frame) |

Positions and lengths share one beat: a beat of the time signature passed to `toEvents` and `toSampleOffset`, so in
6/8 one beat is an 8th note. A beat at or past the numerator carries into the following bars (in 4/4, bar 0 beat 5 is
bar 1 beat 1), so computed beat offsets can be used as they are. An event's length is the offset of its end minus the
offset of its start, so back-to-back notes tile with no frame of gap or overlap. Invalid input returns an error instead of a wrong value or a panic: `error.InvalidBpm`,
`error.InvalidTimeSignature` or `error.InvalidSampleRate` for a zero parameter, `error.InvalidPosition` for a beat
that is NaN, negative or infinite or an offset beyond a `usize`, and `error.InvalidDuration` for such a
`duration_beats`. The error sets are public (`tempo.Error`, `Position.ToSampleOffsetError`,
`Phrase(N).ToEventsError`).

## Usage

```sh
zig fetch --save git+https://github.com/haruki7049/phrases
```

```zig
// build.zig
const phrases = b.dependency("phrases", .{ .target = target, .optimize = optimize });
mod.addImport("phrases", phrases.module("phrases"));
```

```zig
const std = @import("std");
const phrases = @import("phrases");

// Any payload type works; a pitch type from another library, such as `pitches`, is typical.
const Note = struct { name: []const u8, volume: f64 = 1.0 };
const Phrase = phrases.Phrase(Note);

// A phrase can also be loaded at comptime from a ZON file: `const p: Phrase = @import("phrase.zon");`
const melody: Phrase = .{
    .name = "Melody",
    .notes = &.{
        .{ .bar = 0, .beat = 0.0, .note = .{ .name = "E4" }, .duration_beats = 1.0 },
        .{ .bar = 0, .beat = 1.0, .note = .{ .name = "G4", .volume = 0.8 }, .duration_beats = 0.5 },
    },
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // 120 BPM, 4/4, 44100 Hz
    const events = try melody.toEvents(allocator, 120, .{}, 44100);
    defer allocator.free(events);
    // events[1]: position bar 0 beat 1.0, length 11025 frames, note .{ .name = "G4", .volume = 0.8 }
}
```

## Development

```sh
zig build test
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.
