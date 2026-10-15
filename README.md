# meters

Minimal score structure library in Zig

Pure Zig with no dependencies beyond `std`. Requires Zig `0.16.0`.

`meters` handles time and placement only: bars, beats, time signatures, tempo, and layers of score information placed
in time. It does not know what a note is. A score is a `Layer` of named columns: `Span` says when each note starts and
its note value, and how the note is struck (high or low, how strong, open or closed, ...) is a column of its own. Every
column is a primitive: a type with `ResolveT` and `resolve(self, ctx: meters.Context)` that resolves itself, without
`meters` reading it. `meters` provides `Span`; the other primitives, such as notes, the consumer writes.

## One score per vibrating body

A score is written for one vibrating body: one drum, one cymbal, one string. Which body sounds is not written in the
score, note by note; it is decided by which score the user hands to which body. To write a drum kit, write one score
for the kick, one for the snare, one for the hi-hat, and so on.

- **What goes in a score**: when each note is struck, its note value, and how it is struck, written per note as
  primitives (open or closed, high or low, how strong).
- **What does not**: which body or instrument a note belongs to. A column that picks the body note by note mixes
  several bodies in one score; split it into one score per body instead. Separate scores can be reused on their own.

`meters` does not enforce this: nothing checks a column, and a layer that mixes bodies still compiles. It is a rule
for writing scores, kept by the user.

## Where it fits

`meters` produces no sound. It sits at the bottom of a small family of packages, and the audio is made further up:

```text
meters      bars, beats, tempo and layers, placed in sample frames
  │
  ├────────▶ resonator   structures built on meters positions
  │             │
  ▼             ▼
sequencer   schedules lightmix waves on tracks, micro-fades overlaps, renders audio
```

- [`resonator`](https://github.com/haruki7049/resonator): structures built on `meters.Position`.
- [`sequencer`](https://github.com/haruki7049/sequencer): places [`lightmix`](https://github.com/haruki7049/lightmix)
  waves at `meters` positions and renders them into a wave or a stream of blocks.
- [`pulse`](https://github.com/haruki7049/pulse): a drum solo built on all of the above.

## Provided types

| Symbol | Description |
| :--- | :--- |
| `Layer(spec)` | A layer of named columns, placed in time or not: `notate`, `zip`, `concat`, `join`, `repeat`, `map`, `resolve` |
| `Span` | The time primitive: `bar`, `beat` and `beats`, resolved to a `start` frame and a `length` in frames |
| `Context` | What a primitive resolves itself with: `bpm`, `time_signature`, `sample_rate`, and the element's `origin` |
| `ZipError` | Errors of `zip`, besides the allocator's |
| `Position` | Bar and beat offset, with `toSampleOffset` |
| `TimeSignature` | `numerator` / `denominator` (defaults to 4/4) |
| `tempo` | `samplesPerBeat` (a beat of a time signature, in frames) and `framesFromBeats` (rounded once, to the nearest frame) |

## Timing rules

- **One beat for everything**: positions and lengths are counted in beats of the time signature in the `Context`
  (and the one passed to `toSampleOffset`). BPM always counts quarter notes, and the denominator scales the beat, so in
  6/8 one beat is an 8th note, half a quarter.
- **Beats carry past the bar**: bars are 0-indexed, and a beat at or past the numerator carries into the following
  bars (in 4/4, bar 0 beat 5 is bar 1 beat 1), so computed beat offsets can be used as they are.
- **Rounded once**: offsets are computed in `f64` and rounded to the nearest frame once, at the end.
- **Back-to-back notes tile**: a span's length is the offset of its end minus the offset of its start, so a note that
  ends on the beat where the next one starts leaves no frame of gap or overlap, also across concatenated segments. On a
  binary grid (halves, quarters, 16ths, ...) this always holds; on a grid such as triplets, `beat + beats` can differ
  from the next beat in the last bit of an `f64` and, rarely, leave one frame.
- **A length is a note value, not a sounding length**: the `length` a `Span` resolves to is its note value in frames,
  computed from `beats`. `meters` hands it over as resolved and does not decide how long a note actually sounds:
  whether the length is used as the sounding length or ignored (a drum hit that rings out, for example) is up to the
  instrument the user implements.
- **Errors, not panics**: invalid input returns an error instead of a wrong value or a panic: `error.InvalidBpm`,
  `error.InvalidTimeSignature` or `error.InvalidSampleRate` for a zero parameter, `error.InvalidPosition` for a beat
  that is NaN, negative or infinite or an offset beyond a `usize`, and `error.InvalidDuration` for such a length in
  `beats`. The error sets are public (`tempo.Error`, `Position.ToSampleOffsetError`, `Span.ResolveError`,
  `Layer(spec).ResolveError`, `Layer(spec).MapError(T)`, `ZipError`).

## Usage

```sh
zig fetch --save git+https://github.com/haruki7049/meters
```

```zig
// build.zig
const meters = b.dependency("meters", .{ .target = target, .optimize = optimize });
mod.addImport("meters", meters.module("meters"));
```

### Layers

A layer type is made of named columns. Every column is a primitive, a type with `ResolveT` and
`resolve(self, ctx: meters.Context)`, such as `meters.Span` or a note the user writes. The order the columns are
written in does not matter, and a column without `ResolveT` and `resolve` does not compile.

A score is built from small layers:

- `notate(values)` writes a layer of one column that is not placed in time, borrowing `values`.
- `zip` pairs two layers element by element. A layer of one element that is not placed in time is broadcast onto every
  element of the other one, so one note can be given to a whole bar of rhythm.
- `concat`, `join` and `repeat` place layers one after another: each starts where the `extent` (in beats) of the ones
  before it ends.
- `map` transforms one column with a `transform.apply`, such as transposing the notes.

`resolve` turns every element into one value per column, under the same names: each primitive gives its `ResolveT`,
and a `Span` gives its `start` and `length` in frames. The caller owns the returned slice. `concat`, `join`, `repeat`
and `map` allocate too, `zip` allocates only to broadcast a layer of one element, and `notate` allocates nothing; no
operation frees its inputs, so a score is meant to be built with an arena.

```zig
const std = @import("std");
const meters = @import("meters");

// How a note is struck, written as a primitive: here it resolves to itself.
const Note = struct {
    name: []const u8,
    volume: f64 = 1.0,

    pub const ResolveT = Note;

    pub fn resolve(self: Note, ctx: meters.Context) ResolveT {
        _ = ctx;
        return self;
    }
};

const Rhythm = meters.Layer(.{ .span = meters.Span });
const Notes = meters.Layer(.{ .note = Note });

// One beat: an eighth and two sixteenths.
const gallop: Rhythm = .{
    .columns = .{ .span = &.{ .{ .beat = 0.0, .beats = 0.5 }, .{ .beat = 0.5, .beats = 0.25 }, .{ .beat = 0.75, .beats = 0.25 } } },
    .extent = 1.0,
};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Two beats of gallops, all on E2, then one on G2.
    const e2 = try (try gallop.repeat(allocator, 2)).zip(allocator, Notes.notate(&.{.{ .name = "E2" }}));
    const g2 = try gallop.zip(allocator, Notes.notate(&.{.{ .name = "G2", .volume = 0.8 }}));
    const score = try e2.concat(allocator, g2);

    // 120 BPM, 4/4, 44100 Hz: a beat is 22050 frames
    for (try score.resolve(allocator, .{ .bpm = 120, .sample_rate = 44100 })) |note| {
        std.debug.print("{s}: frames {d}..{d}\n", .{ note.note.name, note.span.start, note.span.start + note.span.length });
    }
    // E2: frames 0..11025
    // E2: frames 11025..16538
    // E2: frames 16538..22050
    // E2: frames 22050..33075
    // ...
    // G2: frames 60638..66150
}
```

### Layers in ZON

A layer can be written as a ZON file and loaded at comptime, which keeps the score apart from the code. Fields of a
`Span` left out take their defaults (`bar = 0`, `beat = 0.0`, `beats = 1.0`):

```zig
// melody.zon
.{
    .columns = .{
        .note = .{ .{ .name = "E4" }, .{ .name = "G4", .volume = 0.8 }, .{ .name = "C5" } },
        .span = .{
            .{ .bar = 0, .beat = 0.0, .beats = 1.0 },
            .{ .bar = 0, .beat = 1.0, .beats = 0.5 },
            // bar 0 beat 5 carries into bar 1 beat 1
            .{ .beat = 5.0 },
        },
    },
    // The layer lasts two bars of 4/4 when concatenated.
    .extent = 8.0,
}
```

```zig
const Melody = meters.Layer(.{ .span = meters.Span, .note = Note });
const melody: Melody = @import("melody.zon");
```

### Positions without a layer

`Position` converts a single bar and beat to a frame offset, without building a layer:

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
