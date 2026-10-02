# phrases
Minimal music theory and score data structure library in Zig

Pure Zig with no dependencies beyond `std`. Requires Zig `0.16.0`.

## Provided types

| Symbol | Description |
| :--- | :--- |
| `Pitch` | 12-tone equal temperament pitch (`code` + `octave`), with `add` (transpose by semitones) and `gen` (frequency in Hz, A4 = 440 Hz) |
| `Note(T)` | Note event: `position`, `freq`, `length` (sample frames), `volume` |
| `Position` | Bar and beat offset, with `toSampleOffset` |
| `TimeSignature` | `numerator` / `denominator` (defaults to 4/4) |
| `tempo.spb` | Samples per beat for a given BPM and sample rate |
| `Phrase(T, N)` | Declarative phrase of raw notes with `toEvents` / `toEventsTransposed` |

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

const Phrase = phrases.Phrase(f64, phrases.Pitch);

// A phrase can also be loaded at comptime from a ZON file: `const p: Phrase = @import("phrase.zon");`
const melody: Phrase = .{
    .name = "Melody",
    .notes = &.{
        .{ .bar = 0, .beat = 0.0, .note = .{ .code = .e, .octave = 4 }, .duration_beats = 1.0 },
        .{ .bar = 0, .beat = 1.0, .note = .{ .code = .g, .octave = 4 }, .duration_beats = 0.5 },
    },
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // 120 BPM, 44100 Hz
    const events = try melody.toEvents(phrases.Pitch, allocator, 120, 44100);
    defer allocator.free(events);
}
```

## Development

```sh
zig build test
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.
