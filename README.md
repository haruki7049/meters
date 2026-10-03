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
| `tempo.spb` | Samples per beat for a given BPM and sample rate |

`toEvents` returns `error.InvalidBpm` for a zero BPM and `error.InvalidDuration` for a `duration_beats` that is NaN,
negative or infinite.

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
    // 120 BPM, 44100 Hz
    const events = try melody.toEvents(allocator, 120, 44100);
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
