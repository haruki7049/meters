# meters

Minimal score structure library in Zig

Pure Zig with no dependencies beyond `std`. Requires Zig `0.16.0`.

`meters` handles time and placement only: bars, beats, time signatures, tempo, and phrases of notes placed in time.
It does not know what a note is. The payload type `N` of `Phrase(N)` and `Event(N)` carries whatever a note means to
the consumer (a pitch, a drum voice, a velocity, an instrument string, ...), and resolving it, for example to a
frequency, is the consumer's job.

## Where it fits

`meters` produces no sound. It sits at the bottom of a small family of packages, and the audio is made further up:

```text
meters      bars, beats, tempo and phrases, placed in sample frames
  │
  ├────────▶ resonator   which lane a note goes to: instrument strings, canon voices
  │             │
  ▼             ▼
sequencer   schedules lightmix waves on tracks, micro-fades overlaps, renders audio
```

- [`resonator`](https://github.com/haruki7049/resonator): voice-routing structures, built on `meters.Position`.
- [`sequencer`](https://github.com/haruki7049/sequencer): places [`lightmix`](https://github.com/haruki7049/lightmix)
  waves at `meters` positions and renders them into a wave or a stream of blocks.
- [`pulse`](https://github.com/haruki7049/pulse): a drum solo built on all of the above.

## Provided types

| Symbol | Description |
| :--- | :--- |
| `Phrase(N)` | Declarative phrase of raw notes (`bar`, `beat`, `duration_beats`, `note: N`), with `toEvents` |
| `Event(N)` | Time-placed event: `position`, `length` (sample frames), `note: N` |
| `Position` | Bar and beat offset, with `toSampleOffset` |
| `TimeSignature` | `numerator` / `denominator` (defaults to 4/4) |
| `tempo` | `samplesPerBeat` (a beat of a time signature, in frames) and `framesFromBeats` (rounded once, to the nearest frame) |

## Timing rules

- **One beat for everything**: positions and lengths are counted in beats of the time signature passed to `toEvents`
  and `toSampleOffset`. BPM always counts quarter notes, and the denominator scales the beat, so in 6/8 one beat is
  an 8th note, half a quarter.
- **Beats carry past the bar**: bars are 0-indexed, and a beat at or past the numerator carries into the following
  bars (in 4/4, bar 0 beat 5 is bar 1 beat 1), so computed beat offsets can be used as they are.
- **Rounded once**: offsets are computed in `f64` and rounded to the nearest frame once, at the end.
- **Back-to-back notes tile**: an event's length is the offset of its end minus the offset of its start, so a note
  that ends on the beat where the next one starts leaves no frame of gap or overlap. On a binary grid (halves,
  quarters, 16ths, ...) this always holds; on a grid such as triplets, `beat + duration_beats` can differ from the
  next beat in the last bit of an `f64` and, rarely, leave one frame.
- **Errors, not panics**: invalid input returns an error instead of a wrong value or a panic: `error.InvalidBpm`,
  `error.InvalidTimeSignature` or `error.InvalidSampleRate` for a zero parameter, `error.InvalidPosition` for a beat
  that is NaN, negative or infinite or an offset beyond a `usize`, and `error.InvalidDuration` for such a
  `duration_beats`. The error sets are public (`tempo.Error`, `Position.ToSampleOffsetError`,
  `Phrase(N).ToEventsError`).

## Usage

```sh
zig fetch --save git+https://github.com/haruki7049/meters
```

```zig
// build.zig
const meters = b.dependency("meters", .{ .target = target, .optimize = optimize });
mod.addImport("meters", meters.module("meters"));
```

### Phrases and events

A `Phrase(N)` lists notes by bar, beat and duration. `toEvents` places them in time for a tempo, a time signature
and a sample rate, and returns one `Event(N)` per note:

- `position`: the note's `Position` (bar and beat), as written in the phrase.
- `length`: how long the note lasts, in sample frames.
- `note`: the payload, passed through unchanged.

An event keeps its position in bars and beats; `position.toSampleOffset`, called with the same tempo, time signature
and sample rate, gives the frame it starts on.

```zig
const std = @import("std");
const meters = @import("meters");

// Any payload type works; a pitch type from another library, such as `pitches`, is typical.
const Note = struct { name: []const u8, volume: f64 = 1.0 };
const Phrase = meters.Phrase(Note);

const melody: Phrase = .{
    .name = "Melody",
    .notes = &.{
        .{ .bar = 0, .beat = 0.0, .note = .{ .name = "E4" }, .duration_beats = 1.0 },
        .{ .bar = 0, .beat = 1.0, .note = .{ .name = "G4", .volume = 0.8 }, .duration_beats = 0.5 },
    },
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // 120 BPM, 4/4, 44100 Hz: a beat is 22050 frames
    const events = try melody.toEvents(allocator, 120, .{}, 44100);
    // The caller owns the returned slice.
    defer allocator.free(events);

    for (events) |event| {
        const start = try event.position.toSampleOffset(120, .{}, 44100);
        std.debug.print("{s}: frames {d}..{d}\n", .{ event.note.name, start, start + event.length });
    }
    // E4: frames 0..22050
    // G4: frames 22050..33075
}
```

### Phrases in ZON

A phrase can be written as a ZON file and loaded at comptime, which keeps the score apart from the code. Fields left
out take their defaults (`bar = 0`, `beat = 0.0`, `duration_beats = 1.0`):

```zig
// melody.zon
.{
    .name = "Melody",
    .notes = .{
        .{ .bar = 0, .beat = 0.0, .note = .{ .name = "E4" }, .duration_beats = 1.0 },
        .{ .bar = 0, .beat = 1.0, .note = .{ .name = "G4", .volume = 0.8 }, .duration_beats = 0.5 },
        // bar 0 beat 5 carries into bar 1 beat 1
        .{ .beat = 5.0, .note = .{ .name = "C5" } },
    },
}
```

```zig
const melody: Phrase = @import("melody.zon");
```

### Positions without a phrase

`Position` converts a single bar and beat to a frame offset, without building a phrase:

```zig
const position: meters.Position = .{ .bar = 1, .beat = 2.0 };
// 120 BPM, 4/4, 44100 Hz: 1 * 4 + 2 = 6 beats of 22050 frames
const offset = try position.toSampleOffset(120, .{}, 44100); // 132300
```

## Development

```sh
zig build test
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.
