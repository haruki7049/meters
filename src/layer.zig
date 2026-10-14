//! Layers of score information: named columns of primitives and payloads, notation, zip,
//! concatenation and resolution.
//!
//! A primitive is any type with two declarations, `ResolveT` and
//! `resolve(self, ctx: Context) ResolveT` (or an error union of `ResolveT`), such as `Span`. A
//! payload is a value `meters` does not interpret, declared with the `Opaque(N)` marker and
//! passed through unresolved. `Layer` builds a layer type from named columns at compile time;
//! zip, concatenation and resolution are written once, here, and never read the data of a column.
//!
//! A layer also carries where it sits in time: its `extent` in beats, and the `origins` of its
//! elements. Concatenation places the second layer `extent` beats after the first one by adding to
//! the origins of its elements, and `resolve` hands each element its origin through
//! `Context.origin`. A primitive that places itself in time adds the origin; the others ignore it.
//!
//! Memory: `notate` borrows the values it is given. Zip borrows the slices of both layers, and
//! allocates only to broadcast a layer of one element. Concatenation (`concat`, `join`, `repeat`),
//! `map` and `resolve` allocate new slices with the allocator they are given and never free their
//! inputs, so a score is meant to be built with an arena and freed at once.

const std = @import("std");
const Context = @import("./context.zig");
const Opaque = @import("./opaque.zig").inner;

/// Errors `zip` returns, besides the allocator's.
pub const ZipError = error{
    /// The layers have different numbers of elements. Make them equal by concatenation first.
    MismatchedCount,
    /// Both layers are placed in time, and their extents or origins differ.
    MismatchedExtent,
};

/// Returns the layer type made of the given named columns, for example
/// `Layer(.{ .span = Span, .note = Opaque(Note) })`. Each column is a primitive or an `Opaque`
/// payload. Each combination of columns is its own type, and the order the columns are written in
/// does not matter.
pub fn inner(comptime spec: anytype) type {
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = @field(spec, field.name);
    }

    return Sorted(fields.len, names, types);
}

/// Whether `T` is an `Opaque` marker. Compares the type itself, so a primitive that happens to
/// declare `Payload` is not taken for one.
fn isOpaque(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(T, "Payload") or @TypeOf(T.Payload) != type) return false;

    return T == Opaque(T.Payload);
}

/// Rejects, at compile time, a type that does not keep the primitive contract.
fn assertPrimitive(comptime P: type) void {
    switch (@typeInfo(P)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => @compileError(@typeName(P) ++ " is not a primitive; declare a payload with `Opaque`"),
    }
    if (!@hasDecl(P, "ResolveT")) @compileError(@typeName(P) ++ " is not a primitive: it has no `ResolveT`; declare a payload with `Opaque`");
    if (!@hasDecl(P, "resolve")) @compileError(@typeName(P) ++ " is not a primitive: it has no `resolve`; declare a payload with `Opaque`");

    const info = @typeInfo(@TypeOf(P.resolve)).@"fn";
    if (info.params.len != 2 or info.params[1].type == null or info.params[1].type.? != Context)
        @compileError(@typeName(P) ++ ".resolve must take `self` and a `Context`");

    const R = info.return_type.?;
    const payload = switch (@typeInfo(R)) {
        .error_union => |error_union| error_union.payload,
        else => R,
    };
    if (payload != P.ResolveT) @compileError(@typeName(P) ++ ".resolve must return `ResolveT` or an error union of it");
}

/// The type a column declared as `T` holds: the payload of an `Opaque` marker, or the primitive.
fn Element(comptime T: type) type {
    return if (isOpaque(T)) T.Payload else T;
}

/// The type a column declared as `T` resolves to: the payload itself, or the primitive's `ResolveT`.
fn Output(comptime T: type) type {
    return if (isOpaque(T)) T.Payload else T.ResolveT;
}

/// The errors resolving a column declared as `T` can return; none for a payload.
fn Errors(comptime T: type) type {
    if (isOpaque(T)) return error{};

    return switch (@typeInfo(@typeInfo(@TypeOf(T.resolve)).@"fn".return_type.?)) {
        .error_union => |error_union| error_union.error_set,
        else => error{},
    };
}

/// Builds a struct type from field names and field types.
fn StructOf(comptime n: usize, comptime names: [n][]const u8, comptime types: [n]type) type {
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// Sorts the columns by name, so that the same columns in another order give the same type.
fn Sorted(comptime n: usize, comptime names: [n][]const u8, comptime types: [n]type) type {
    if (n == 0) @compileError("a layer needs at least one column");

    var order: [n]usize = undefined;
    for (&order, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, &order, names, struct {
        fn lessThan(all: [n][]const u8, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, all[a], all[b]);
        }
    }.lessThan);

    var sorted_names: [n][]const u8 = undefined;
    var sorted_types: [n]type = undefined;
    for (order, 0..) |from, to| {
        if (!isOpaque(types[from])) assertPrimitive(types[from]);
        sorted_names[to] = names[from];
        sorted_types[to] = types[from];
    }

    return LayerOf(StructOf(n, sorted_names, sorted_types));
}

/// The origin of element `i`; an empty `origins` means zero for every element.
fn originAt(origins: []const f64, i: usize) f64 {
    return if (origins.len == 0) 0.0 else origins[i];
}

/// Rebuilds a struct type from the fields of `S`, with each field type passed through `F`.
fn Mapped(comptime S: type, comptime F: fn (type) type) type {
    const fields = @typeInfo(S).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = F(field.type);
    }

    return StructOf(fields.len, names, types);
}

/// The type of a slice of `T`.
fn SliceOf(comptime T: type) type {
    return []const T;
}

/// The layer type of a sorted spec `S`: a struct with one field per column, holding the column's
/// declared type (a primitive or an `Opaque` marker).
fn LayerOf(comptime S: type) type {
    const specs = @typeInfo(S).@"struct".fields;
    const E = Mapped(S, Element);
    const fields = @typeInfo(E).@"struct".fields;

    return struct {
        const Self = @This();

        /// The declared type of each column: a primitive or an `Opaque` marker.
        pub const Spec = S;
        /// One element: one value per column.
        pub const Item = E;
        /// One slice per column.
        pub const Columns = Mapped(E, SliceOf);
        /// One resolved value per column, under the same names: the `ResolveT` of a primitive, or
        /// the payload itself.
        pub const Resolved = Mapped(S, Output);
        /// Names a column of this layer, for `map`.
        pub const Name = std.meta.FieldEnum(E);
        /// Errors `resolve` returns: the allocator's, and those of every primitive's `resolve`.
        pub const ResolveError = blk: {
            var set = std.mem.Allocator.Error;
            for (specs) |spec| set = set || Errors(spec.type);
            break :blk set;
        };

        /// Errors `map` returns with a transform of type `T`: the allocator's, and those
        /// `T.apply` returns.
        pub fn MapError(comptime T: type) type {
            const R = @typeInfo(@TypeOf(T.apply)).@"fn".return_type.?;
            return std.mem.Allocator.Error || switch (@typeInfo(R)) {
                .error_union => |error_union| error_union.error_set,
                else => error{},
            };
        }

        /// One slice per column, all with the same number of elements.
        columns: Columns,
        /// Length of this layer in beats: a layer concatenated after this one starts this many
        /// beats later. Zero for a layer that is not placed in time, such as a list of payloads.
        extent: f64 = 0.0,
        /// Beats from the start of this layer to the start of the segment each element was written
        /// in, one per element. Set by concatenation; empty means zero for every element.
        origins: []const f64 = &.{},

        /// A layer with no elements that lasts `extent` beats: silence to concatenate.
        pub fn empty(extent: f64) Self {
            var result: Self = .{ .columns = undefined, .extent = extent };
            inline for (fields) |field| @field(result.columns, field.name) = &.{};

            return result;
        }

        /// A layer of `values` that is not placed in time, for a layer type of one column.
        /// Allocates nothing and borrows `values`. A layer of several columns is written by
        /// zipping layers of one.
        pub fn notate(values: []const fields[0].type) Self {
            comptime if (fields.len != 1) @compileError("notate needs a layer of one column; zip layers of one instead");

            var result: Self = .{ .columns = undefined };
            @field(result.columns, fields[0].name) = values;

            return result;
        }

        /// Number of elements.
        pub fn count(self: Self) usize {
            return @field(self.columns, fields[0].name).len;
        }

        /// Whether this layer is placed in time.
        fn placed(self: Self) bool {
            return self.extent != 0.0 or self.origins.len != 0;
        }

        /// The layer type that zipping with `L` gives. A name used on both sides is a compile error.
        fn Zipped(comptime L: type) type {
            const all = specs ++ @typeInfo(L.Spec).@"struct".fields;
            var names: [all.len][]const u8 = undefined;
            var types: [all.len]type = undefined;
            for (all, 0..) |field, i| {
                if (i >= specs.len and @hasField(S, field.name))
                    @compileError("cannot zip: both layers have a column named `" ++ field.name ++ "`");
                names[i] = field.name;
                types[i] = field.type;
            }

            return Sorted(all.len, names, types);
        }

        /// Whether this layer is one element not placed in time, which `zip` broadcasts.
        fn scalar(self: Self) bool {
            return self.count() == 1 and !self.placed();
        }

        /// This layer's one element copied `n` times, in a layer not placed in time. Copies the
        /// element without reading it. The caller owns the returned slices.
        fn broadcast(self: Self, allocator: std.mem.Allocator, n: usize) std.mem.Allocator.Error!Self {
            var result: Self = .{ .columns = undefined };
            inline for (fields) |field| {
                const column = try allocator.alloc(field.type, n);
                @memset(column, @field(self.columns, field.name)[0]);
                @field(result.columns, field.name) = column;
            }

            return result;
        }

        /// Pairs this layer with another one, element by element.
        ///
        /// Returns `error.MismatchedCount` when the numbers of elements differ, never truncating or
        /// repeating, with one exception: a layer of one element that is not placed in time is
        /// broadcast, its element copied onto every element of the other layer, on either side.
        /// When only one layer is placed in time, the result takes its extent and origins; when
        /// both are, they must agree, or `error.MismatchedExtent` is returned.
        ///
        /// Memory: borrows the slices of both layers. Only a broadcast allocates, with `allocator`,
        /// the copies of the broadcast element; the caller owns them.
        pub fn zip(self: Self, allocator: std.mem.Allocator, other: anytype) (ZipError || std.mem.Allocator.Error)!Zipped(@TypeOf(other)) {
            if (self.count() != other.count()) {
                if (self.scalar()) return (try self.broadcast(allocator, other.count())).zip(allocator, other);
                if (other.scalar()) return self.zip(allocator, try other.broadcast(allocator, self.count()));
                return error.MismatchedCount;
            }

            var result: Zipped(@TypeOf(other)) = .{ .columns = undefined };
            inline for (fields) |field| @field(result.columns, field.name) = @field(self.columns, field.name);
            inline for (@typeInfo(@TypeOf(other).Item).@"struct".fields) |field| {
                @field(result.columns, field.name) = @field(other.columns, field.name);
            }

            if (!other.placed()) {
                result.extent = self.extent;
                result.origins = self.origins;
            } else if (!self.placed()) {
                result.extent = other.extent;
                result.origins = other.origins;
            } else {
                if (self.extent != other.extent) return error.MismatchedExtent;
                for (0..self.count()) |i| {
                    if (originAt(self.origins, i) != originAt(other.origins, i)) return error.MismatchedExtent;
                }
                result.extent = self.extent;
                result.origins = if (self.origins.len != 0) self.origins else other.origins;
            }

            return result;
        }

        /// Places `other` after this layer: its elements follow these ones, and it starts `extent`
        /// beats after this layer starts. The result lasts both extents. The caller owns the
        /// returned slices.
        pub fn concat(self: Self, allocator: std.mem.Allocator, other: Self) std.mem.Allocator.Error!Self {
            return place(allocator, &.{ self, other }, 1);
        }

        /// Concatenates `parts` in order: each part starts where the extents of the parts before
        /// it end. No parts gives an empty layer that lasts no time. Allocates each slice once,
        /// whatever the number of parts. The caller owns the returned slices.
        pub fn join(allocator: std.mem.Allocator, parts: []const Self) std.mem.Allocator.Error!Self {
            return place(allocator, parts, 1);
        }

        /// Concatenates this layer with itself until it appears `times` times. Zero times gives an
        /// empty layer that lasts no time. Allocates each slice once. The caller owns the returned
        /// slices.
        pub fn repeat(self: Self, allocator: std.mem.Allocator, times: usize) std.mem.Allocator.Error!Self {
            return place(allocator, &.{self}, times);
        }

        /// Concatenates `parts` in order, the whole sequence `times` times over. The result is the
        /// one that concatenating them one by one from an empty layer would give, down to the bits
        /// of the extent and the origins, but every slice is allocated once.
        fn place(allocator: std.mem.Allocator, parts: []const Self, times: usize) std.mem.Allocator.Error!Self {
            // Concatenation gives origins once a part has origins or starts after zero beats.
            var total: usize = 0;
            var extent: f64 = 0.0;
            var timed = false;
            for (0..times) |_| {
                for (parts) |part| {
                    if (part.origins.len != 0 or extent != 0.0) timed = true;
                    total += part.count();
                    extent += part.extent;
                }
            }

            var result: Self = .{ .columns = undefined, .extent = extent };
            inline for (fields) |field| {
                const column = try allocator.alloc(field.type, total);
                var at: usize = 0;
                for (0..times) |_| {
                    for (parts) |part| {
                        const values = @field(part.columns, field.name);
                        @memcpy(column[at..][0..values.len], values);
                        at += values.len;
                    }
                }
                @field(result.columns, field.name) = column;
            }
            if (!timed) return result;

            const origins = try allocator.alloc(f64, total);
            var at: usize = 0;
            var start: f64 = 0.0;
            for (0..times) |_| {
                for (parts) |part| {
                    for (0..part.count()) |i| origins[at + i] = start + originAt(part.origins, i);
                    at += part.count();
                    start += part.extent;
                }
            }
            result.origins = origins;

            return result;
        }

        /// Returns this layer with every element of the column `name` replaced by
        /// `transform.apply(element)`. `apply` takes and returns the column's element type (the
        /// primitive, or the payload of an `Opaque` column), or an error union of it. Shifting,
        /// transposing and other transformations of score information are written as such a
        /// `transform`, next to the type they understand. The caller owns the returned slice.
        pub fn map(self: Self, allocator: std.mem.Allocator, comptime name: Name, transform: anytype) MapError(@TypeOf(transform))!Self {
            const P = @FieldType(E, @tagName(name));
            const column = @field(self.columns, @tagName(name));

            const out = try allocator.alloc(P, column.len);
            errdefer allocator.free(out);
            for (column, out) |element, *mapped| {
                const value = transform.apply(element);
                mapped.* = if (@typeInfo(@TypeOf(value)) == .error_union) try value else value;
            }

            var result = self;
            @field(result.columns, @tagName(name)) = out;

            return result;
        }

        /// Resolves every element: each primitive's `resolve` is called with `ctx`, whose origin is
        /// moved to the origin of the element, and each payload is passed through unchanged.
        /// Returns the first error a primitive returns, and frees what it allocated. The caller
        /// owns the returned slice.
        pub fn resolve(self: Self, allocator: std.mem.Allocator, ctx: Context) ResolveError![]Resolved {
            const out = try allocator.alloc(Resolved, self.count());
            errdefer allocator.free(out);

            for (out, 0..) |*item, n| {
                var element_ctx = ctx;
                element_ctx.origin = ctx.origin + originAt(self.origins, n);
                inline for (specs) |spec| {
                    const element = @field(self.columns, spec.name)[n];
                    if (comptime isOpaque(spec.type)) {
                        @field(item, spec.name) = element;
                    } else {
                        const value = element.resolve(element_ctx);
                        @field(item, spec.name) = if (@typeInfo(@TypeOf(value)) == .error_union) try value else value;
                    }
                }
            }

            return out;
        }
    };
}

// Types used by the tests below, written the way a user of `meters` writes them.

const Span = @import("./span.zig");

/// A pitch-like payload: semitones from A4. `meters` itself knows no pitch type.
const Note = struct {
    semitones: i32,
};

/// Moves a note by a number of semitones.
const Transpose = struct {
    semitones: i32,

    fn apply(self: Transpose, note: Note) Note {
        return .{ .semitones = note.semitones + self.semitones };
    }
};

/// A primitive of the tests: a linear level. Rejects a negative value.
const Gain = struct {
    value: f64 = 1.0,

    pub const ResolveT = f64;

    pub fn resolve(self: Gain, ctx: Context) error{NegativeGain}!ResolveT {
        _ = ctx;
        if (self.value < 0.0) return error.NegativeGain;
        return self.value;
    }
};

/// A level that cannot be negative: an error union from `apply`.
const Halve = struct {
    fn apply(self: Halve, gain: Gain) error{NegativeGain}!Gain {
        _ = self;
        if (gain.value < 0.0) return error.NegativeGain;
        return .{ .value = gain.value / 2.0 };
    }
};

const Rhythm = inner(.{ .span = Span });
const Notes = inner(.{ .note = Opaque(Note) });
const Gains = inner(.{ .gain = Gain });

// 120 BPM, 44100 Hz: a beat is 22050 frames.
const test_ctx: Context = .{ .bpm = 120, .sample_rate = 44100 };

test "zip pairs layers by name, and the order does not change the type" {
    const Score = inner(.{ .span = Span, .note = Opaque(Note), .gain = Gain });
    const rhythm: Rhythm = .{ .columns = .{ .span = &.{ .{ .beat = 0.0 }, .{ .beat = 1.0 } } }, .extent = 2.0 };
    const notes = Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 7 } });
    const accents = Gains.notate(&.{ .{ .value = 1.0 }, .{ .value = 0.5 } });

    const allocator = std.testing.allocator;
    const score = try (try rhythm.zip(allocator, notes)).zip(allocator, accents);
    const reordered = try (try accents.zip(allocator, notes)).zip(allocator, rhythm);
    comptime std.debug.assert(@TypeOf(score) == Score);
    comptime std.debug.assert(@TypeOf(reordered) == Score);
    comptime std.debug.assert(inner(.{ .gain = Gain, .note = Opaque(Note), .span = Span }) == Score);

    try std.testing.expectEqual(@as(usize, 2), score.count());
    try std.testing.expectEqual(@as(f64, 2.0), score.extent);
}

test "an Opaque column holds bare payloads" {
    comptime std.debug.assert(@FieldType(Notes.Item, "note") == Note);
    comptime std.debug.assert(@FieldType(Notes.Columns, "note") == []const Note);
    comptime std.debug.assert(@FieldType(Notes.Resolved, "note") == Note);

    // Any payload type works, such as a drum voice.
    const Drum = enum { kick, snare };
    const Hits = inner(.{ .drum = Opaque(Drum) });
    comptime std.debug.assert(@FieldType(Hits.Resolved, "drum") == Drum);
}

test "zip returns an error for different counts" {
    const allocator = std.testing.allocator;
    const rhythm: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 1.0 } } } };
    const notes = Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 7 }, .{ .semitones = 12 } });
    try std.testing.expectError(error.MismatchedCount, rhythm.zip(allocator, notes));
    try std.testing.expectError(error.MismatchedCount, notes.zip(allocator, rhythm));
}

test "zip broadcasts a layer of one element that is not placed in time, on either side" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cell: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 0.5 } } }, .extent = 1.0 };
    const rhythm = try cell.repeat(allocator, 2);
    const e2 = Notes.notate(&.{.{ .semitones = -29 }});

    const melody = try rhythm.zip(allocator, e2);
    const reordered = try e2.zip(allocator, rhythm);
    comptime std.debug.assert(@TypeOf(melody) == @TypeOf(reordered));
    try std.testing.expectEqualDeep(melody, reordered);

    try std.testing.expectEqual(@as(usize, 4), melody.count());
    for (melody.columns.note) |note| try std.testing.expectEqual(@as(i32, -29), note.semitones);
    try std.testing.expectEqual(rhythm.columns.span, melody.columns.span);
}

test "a broadcast keeps the extent and origins of the other layer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cell: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 0.5 } } }, .extent = 1.0 };
    const rhythm = try cell.repeat(allocator, 2);
    const loud = Gains.notate(&.{.{ .value = 0.8 }});

    for ([_]@TypeOf(try rhythm.zip(allocator, loud)){ try rhythm.zip(allocator, loud), try loud.zip(allocator, rhythm) }) |accented| {
        try std.testing.expectEqual(@as(f64, 2.0), accented.extent);
        try std.testing.expectEqualSlices(f64, &.{ 0, 0, 1, 1 }, accented.origins);
    }
}

test "zip does not broadcast a layer of one element placed in time" {
    const allocator = std.testing.allocator;
    const notes = Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 7 } });

    // One chord that lasts two bars, like the ending of a piece.
    const long: Rhythm = .{ .columns = .{ .span = &.{.{ .beats = 8.0 }} }, .extent = 8.0 };
    try std.testing.expectError(error.MismatchedCount, notes.zip(allocator, long));
    try std.testing.expectError(error.MismatchedCount, long.zip(allocator, notes));

    // Placed by its origins alone.
    const late: Rhythm = .{ .columns = .{ .span = &.{.{}} }, .origins = &.{4.0} };
    try std.testing.expectError(error.MismatchedCount, notes.zip(allocator, late));
    try std.testing.expectError(error.MismatchedCount, late.zip(allocator, notes));
}

test "a broadcast onto a layer of no elements gives no elements" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rest = Rhythm.empty(4.0);
    const e2 = Notes.notate(&.{.{ .semitones = -29 }});
    for ([_]@TypeOf(try rest.zip(allocator, e2)){ try rest.zip(allocator, e2), try e2.zip(allocator, rest) }) |silence| {
        try std.testing.expectEqual(@as(usize, 0), silence.count());
        try std.testing.expectEqual(@as(f64, 4.0), silence.extent);
    }

    // A layer of one element placed in time is not broadcast, even onto no elements.
    const long: Notes = .{ .columns = .{ .note = &.{.{ .semitones = -29 }} }, .extent = 8.0 };
    try std.testing.expectError(error.MismatchedCount, rest.zip(allocator, long));
    try std.testing.expectError(error.MismatchedCount, long.zip(allocator, rest));
}

test "zip allocates nothing without a broadcast" {
    const allocator = std.testing.failing_allocator;
    const rhythm: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 1.0 } } }, .extent = 2.0 };
    const notes = Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 7 } });

    const melody = try rhythm.zip(allocator, notes);
    try std.testing.expectEqual(rhythm.columns.span.ptr, melody.columns.span.ptr);
    try std.testing.expectEqual(notes.columns.note.ptr, melody.columns.note.ptr);
}

test "a broadcast returns the error of the allocator" {
    const allocator = std.testing.failing_allocator;
    const notes = Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 7 } });
    const loud = Gains.notate(&.{.{ .value = 0.8 }});
    try std.testing.expectError(error.OutOfMemory, notes.zip(allocator, loud));
    try std.testing.expectError(error.OutOfMemory, loud.zip(allocator, notes));
}

test "a broadcast copies every column of the element" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rhythm: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 1.0 }, .{ .beat = 2.0 } } }, .extent = 3.0 };
    const accented_e2 = try Notes.notate(&.{.{ .semitones = -29 }}).zip(allocator, Gains.notate(&.{.{ .value = 0.8 }}));

    const melody = try rhythm.zip(allocator, accented_e2);
    try std.testing.expectEqual(@as(usize, 3), melody.count());
    for (melody.columns.note, melody.columns.gain) |note, gain| {
        try std.testing.expectEqual(@as(i32, -29), note.semitones);
        try std.testing.expectEqual(@as(f64, 0.8), gain.value);
    }
}

test "a broadcast onto a layer not placed in time is not placed in time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const notes = Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 7 }, .{ .semitones = 12 } });
    const loud = Gains.notate(&.{.{ .value = 0.8 }});

    for ([_]@TypeOf(try notes.zip(allocator, loud)){ try notes.zip(allocator, loud), try loud.zip(allocator, notes) }) |accented| {
        try std.testing.expectEqual(@as(usize, 3), accented.count());
        try std.testing.expectEqual(@as(f64, 0.0), accented.extent);
        try std.testing.expectEqual(@as(usize, 0), accented.origins.len);
    }
}

test "zip keeps the timeline of the layer that is placed in time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cell: Rhythm = .{ .columns = .{ .span = &.{.{}} }, .extent = 1.0 };
    const rhythm = try cell.repeat(allocator, 2);
    const notes = try Notes.notate(&.{.{ .semitones = 0 }}).repeat(allocator, 2);

    const melody = try notes.zip(allocator, rhythm);
    try std.testing.expectEqual(@as(f64, 2.0), melody.extent);
    try std.testing.expectEqualSlices(f64, &.{ 0.0, 1.0 }, melody.origins);
}

test "zip rejects two different timelines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cell: Rhythm = .{ .columns = .{ .span = &.{.{}} }, .extent = 1.0 };
    const accent: Gains = .{ .columns = .{ .gain = &.{.{}} }, .extent = 2.0 };
    try std.testing.expectError(error.MismatchedExtent, cell.zip(allocator, accent));

    // Same extents, different origins.
    const two_cells = try cell.repeat(allocator, 2);
    const late: Gains = .{ .columns = .{ .gain = &.{ .{}, .{} } }, .extent = 2.0, .origins = &.{ 0.0, 0.5 } };
    try std.testing.expectError(error.MismatchedExtent, two_cells.zip(allocator, late));
}

test "concat places the second layer after the extent of the first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A gallop: an eighth and two sixteenths, one beat long.
    const gallop: Rhythm = .{
        .columns = .{ .span = &.{ .{ .beat = 0.0, .beats = 0.5 }, .{ .beat = 0.5, .beats = 0.25 }, .{ .beat = 0.75, .beats = 0.25 } } },
        .extent = 1.0,
    };

    const two = try gallop.concat(allocator, gallop);
    try std.testing.expectEqual(@as(usize, 6), two.count());
    try std.testing.expectEqual(@as(f64, 2.0), two.extent);

    // 120 BPM, 44100 Hz: a beat is 22050 frames, so 0.75 beats is 16537.5, rounded to 16538.
    const resolved = try two.resolve(allocator, test_ctx);
    const starts = [_]usize{ 0, 11025, 16538, 22050, 33075, 38588 };
    for (resolved, starts) |element, start| try std.testing.expectEqual(start, element.span.start);
    try std.testing.expectEqual(@as(usize, 11025), resolved[3].span.length);
}

test "concat of layers that are not placed in time only appends" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const notes = Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 7 } });
    const four = try notes.concat(allocator, notes);
    try std.testing.expectEqual(@as(usize, 4), four.count());
    try std.testing.expectEqual(@as(f64, 0.0), four.extent);
    try std.testing.expectEqual(@as(usize, 0), four.origins.len);
}

test "an empty layer is silence of its extent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const hit: Rhythm = .{ .columns = .{ .span = &.{.{}} }, .extent = 1.0 };
    const late = try Rhythm.empty(3.0).concat(allocator, hit);
    try std.testing.expectEqual(@as(usize, 1), late.count());
    try std.testing.expectEqual(@as(f64, 4.0), late.extent);

    const resolved = try late.resolve(allocator, test_ctx);
    try std.testing.expectEqual(@as(usize, 3 * 22050), resolved[0].span.start);
}

test "repeat concatenates a layer with itself" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cell: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 0.5 } } }, .extent = 1.0 };
    const bar = try cell.repeat(allocator, 4);
    try std.testing.expectEqual(@as(usize, 8), bar.count());
    try std.testing.expectEqual(@as(f64, 4.0), bar.extent);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 1, 1, 2, 2, 3, 3 }, bar.origins);

    const none = try cell.repeat(allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), none.count());
    try std.testing.expectEqual(@as(f64, 0.0), none.extent);
}

test "notate borrows values into a layer not placed in time" {
    const values = [_]Note{ .{ .semitones = 0 }, .{ .semitones = 7 } };
    const notes = Notes.notate(&values);
    try std.testing.expectEqual(@as([*]const Note, &values), notes.columns.note.ptr);
    try std.testing.expectEqual(@as(usize, 2), notes.count());
    try std.testing.expectEqual(@as(f64, 0.0), notes.extent);
    try std.testing.expectEqual(@as(usize, 0), notes.origins.len);
}

test "join gives what concatenating the parts one by one gives" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const loose: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 0.5 } } } };
    const triplet: Rhythm = .{ .columns = .{ .span = &.{.{}} }, .extent = 1.0 / 3.0 };
    const late: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{} } }, .extent = 2.0, .origins = &.{ 0.0, 0.5 } };
    const parts = [_]Rhythm{ loose, triplet, triplet, late, Rhythm.empty(1.0), triplet };

    var folded = Rhythm.empty(0.0);
    for (parts) |part| folded = try folded.concat(allocator, part);
    try std.testing.expectEqualDeep(folded, try Rhythm.join(allocator, &parts));

    // Layers that are not placed in time stay that way.
    const appended = try Rhythm.join(allocator, &.{ loose, loose });
    try std.testing.expectEqual(@as(usize, 4), appended.count());
    try std.testing.expectEqual(@as(usize, 0), appended.origins.len);

    // No parts give an empty layer that lasts no time.
    const none = try Rhythm.join(allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), none.count());
    try std.testing.expectEqual(@as(f64, 0.0), none.extent);
}

test "join adds the extents from left to right" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const triplet: Rhythm = .{ .columns = .{ .span = &.{.{}} }, .extent = 1.0 / 3.0 };

    var extent: f64 = 0.0;
    var origins: [10]f64 = undefined;
    for (&origins) |*origin| {
        origin.* = extent;
        extent += triplet.extent;
    }

    const ten = try triplet.repeat(allocator, 10);
    try std.testing.expectEqual(extent, ten.extent);
    try std.testing.expectEqualSlices(f64, &origins, ten.origins);
}

test "join and repeat allocate each slice once" {
    var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const allocator = counting.allocator();

    const Score = inner(.{ .span = Span, .gain = Gain });
    const gallop: Score = .{
        .columns = .{
            .span = &.{ .{ .beat = 0.0, .beats = 0.5 }, .{ .beat = 0.5, .beats = 0.25 }, .{ .beat = 0.75, .beats = 0.25 } },
            .gain = &.{ .{}, .{ .value = 0.7 }, .{ .value = 0.8 } },
        },
        .extent = 1.0,
    };

    // Two columns and the origins.
    const bar = try gallop.repeat(allocator, 4);
    defer inline for (.{ bar.columns.span, bar.columns.gain, bar.origins }) |slice| allocator.free(slice);
    try std.testing.expectEqual(@as(usize, 3), counting.allocations);

    const phrase = try Score.join(allocator, &.{ bar, gallop, bar, gallop });
    defer inline for (.{ phrase.columns.span, phrase.columns.gain, phrase.origins }) |slice| allocator.free(slice);
    try std.testing.expectEqual(@as(usize, 6), counting.allocations);
}

test "map transforms one column and keeps the others" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rhythm: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 1.0 } } }, .extent = 2.0 };
    const melody = try rhythm.zip(allocator, Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 7 } }));

    // A transform written for the payload type works on an Opaque column as it is.
    const up = try melody.map(allocator, .note, Transpose{ .semitones = 12 });
    try std.testing.expectEqual(@as(i32, 12), up.columns.note[0].semitones);
    try std.testing.expectEqual(@as(i32, 19), up.columns.note[1].semitones);
    try std.testing.expectEqual(melody.columns.span, up.columns.span);
    try std.testing.expectEqual(@as(f64, 2.0), up.extent);
    // The input is not changed.
    try std.testing.expectEqual(@as(i32, 0), melody.columns.note[0].semitones);
}

test "map returns the error of the transform without leaking" {
    const accents = Gains.notate(&.{ .{ .value = 1.0 }, .{ .value = -1.0 } });
    try std.testing.expectError(error.NegativeGain, accents.map(std.testing.allocator, .gain, Halve{}));
    // The error set is declared: the allocator's and the transform's.
    comptime std.debug.assert(Gains.MapError(Halve) == (std.mem.Allocator.Error || error{NegativeGain}));
}

test "resolve returns one named value per column" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rhythm: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = 1.0, .beats = 0.5 } } } };
    const notes = Notes.notate(&.{ .{ .semitones = 0 }, .{ .semitones = 12 } });
    const resolved = try (try rhythm.zip(allocator, notes)).resolve(allocator, test_ctx);

    // 120 BPM, 44100 Hz: a beat is 22050 frames. The payload passes through unchanged.
    try std.testing.expectEqual(@as(usize, 0), resolved[0].span.start);
    try std.testing.expectEqual(@as(usize, 22050), resolved[0].span.length);
    try std.testing.expectEqual(Note{ .semitones = 0 }, resolved[0].note);
    try std.testing.expectEqual(@as(usize, 22050), resolved[1].span.start);
    try std.testing.expectEqual(@as(usize, 11025), resolved[1].span.length);
    try std.testing.expectEqual(Note{ .semitones = 12 }, resolved[1].note);
}

test "resolve declares the errors of every primitive" {
    const Score = inner(.{ .span = Span, .gain = Gain, .note = Opaque(Note) });
    comptime std.debug.assert(Score.ResolveError == (std.mem.Allocator.Error || Span.ResolveError || error{NegativeGain}));
    // A layer of payloads only fails for memory alone.
    comptime std.debug.assert(Notes.ResolveError == std.mem.Allocator.Error);
}

test "resolve returns the first error of a primitive without leaking" {
    // The invalid element comes second, so the slice is already allocated when it is reached;
    // std.testing.allocator fails the test if that slice leaks.
    const allocator = std.testing.allocator;

    const accents = Gains.notate(&.{ .{ .value = 1.0 }, .{ .value = -1.0 } });
    try std.testing.expectError(error.NegativeGain, accents.resolve(allocator, test_ctx));

    const position: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beat = -1.0 } } } };
    try std.testing.expectError(error.InvalidPosition, position.resolve(allocator, test_ctx));

    const duration: Rhythm = .{ .columns = .{ .span = &.{ .{}, .{ .beats = std.math.nan(f64) } } } };
    try std.testing.expectError(error.InvalidDuration, duration.resolve(allocator, test_ctx));

    try std.testing.expectError(error.InvalidBpm, position.resolve(allocator, .{ .bpm = 0, .sample_rate = 44100 }));
}

test "resolve returns an empty slice for an empty layer" {
    const resolved = try Rhythm.empty(4.0).resolve(std.testing.allocator, test_ctx);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqual(@as(usize, 0), resolved.len);
}

test "resolve tiles back-to-back notes across segments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // One beat of 16th notes, repeated over 4 bars of 4/4. A 16th has a fractional frame count at
    // these tempos (5512.5 frames at 120 BPM), so a length rounded on its own would make every
    // other note overlap the next by a frame.
    const beat: Rhythm = .{
        .columns = .{ .span = &.{ .{ .beat = 0.0, .beats = 0.25 }, .{ .beat = 0.25, .beats = 0.25 }, .{ .beat = 0.5, .beats = 0.25 }, .{ .beat = 0.75, .beats = 0.25 } } },
        .extent = 1.0,
    };
    const four_bars = try beat.repeat(allocator, 16);

    inline for (.{ 60, 120, 140, 190, 200 }) |bpm| {
        inline for (.{ 44100, 48000 }) |sample_rate| {
            const resolved = try four_bars.resolve(allocator, .{ .bpm = bpm, .sample_rate = sample_rate });
            for (resolved[0 .. resolved.len - 1], resolved[1..]) |current, next| {
                try std.testing.expectEqual(next.span.start, current.span.start + current.span.length);
            }

            // The lengths add up to the span of the layer: 4 bars = 16 beats.
            var total: usize = 0;
            for (resolved) |element| total += element.span.length;
            const end = try (Span{ .beat = 16.0, .beats = 0.0 }).resolve(.{ .bpm = bpm, .sample_rate = sample_rate });
            try std.testing.expectEqual(end.start, total);
        }
    }
}

test "a layer imports a ZON file" {
    const allocator = std.testing.allocator;
    const Score = inner(.{ .span = Span, .note = Opaque(Note) });
    const score: Score = @import("./test-layer.zon");

    try std.testing.expectEqual(@as(usize, 3), score.count());
    try std.testing.expectEqual(@as(f64, 8.0), score.extent);
    // Omitted fields take their defaults.
    try std.testing.expectEqual(Span{}, score.columns.span[1]);
    try std.testing.expectEqual(Note{ .semitones = -12 }, score.columns.note[2]);

    // 120 BPM, 4/4, 44100 Hz => a beat is 22050 frames
    const resolved = try score.resolve(allocator, test_ctx);
    defer allocator.free(resolved);
    // bar 1 beat 5 = 4 + 5 = 9 beats = 198450 frames, the same as bar 2 beat 1
    try std.testing.expectEqual(@as(usize, 198450), resolved[2].span.start);
    // 0.5 beats = 11025 frames
    try std.testing.expectEqual(@as(usize, 11025), resolved[2].span.length);
}

test {
    std.testing.refAllDecls(@This());
}
