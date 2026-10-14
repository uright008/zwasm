//! Zig 0.18 type-reflection compatibility helpers.
//!
//! `std.meta.fields` is gone; for enums the old (name, value) view has to be
//! rebuilt from `@typeInfo(E).@"enum".field_names` / `field_values`.

/// One entry of an enum's field list, shaped like the old `std.meta.fields` item.
pub const EnumField = struct { name: [:0]const u8, value: comptime_int };

pub fn enumFields(comptime E: type) [@typeInfo(E).@"enum".field_names.len]EnumField {
    const info = @typeInfo(E).@"enum";
    var out: [info.field_names.len]EnumField = undefined;
    for (info.field_names, info.field_values, 0..) |n, v, i| out[i] = .{ .name = n, .value = v };
    return out;
}
