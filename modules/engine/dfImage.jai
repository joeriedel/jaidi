// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The game's 8-bit graphics: palettes (PAL, and PLTT from the LFDs), colormaps (CMP), textures
// (BM), sprites (FME, WAX) and the HUD fonts (FNT).
//
// Images stay as palette indices. The original draws everything through the level's colormap
// and palette at draw time (light level, distance fade, headlight, palette effects), so
// nothing here turns pixels into colors; that is the renderer's job.
//
// The files store pixels in columns, bottom to top. Images here are rows, top to bottom, the
// way textures are uploaded.

Image :: struct {
    width, height: s32;
    pixels: [] u8;              // width * height palette indices, top row first.
}

image_free :: (image: *Image) {
    array_free(image.pixels);
    image.* = .{};
}

// 8 bits per channel.
Color :: struct { r, g, b: u8; }

Palette :: struct {
    colors: [256] Color;
}

LIGHT_LEVELS     :: 32;
LIGHT_RAMP_COUNT :: 128;

// Light level 31 is full light; above that the renderer skips the colormap. Light level 0 is
// the darkest.
Colormap :: struct {
    levels: [LIGHT_LEVELS][256] u8;

    // Headlight and weapon-flash falloff by distance (0 is next to the camera), as light levels
    // to subtract from full.
    light_ramp: [LIGHT_RAMP_COUNT] u8;
}

// PAL: 256 RGB entries of 6-bit VGA DAC values.
pal_parse :: (data: [] u8) -> Palette, bool {
    palette: Palette;
    if data.count < 768 return palette, false;
    for * palette.colors {
        it.r = expand_6_bit(data[it_index * 3]);
        it.g = expand_6_bit(data[it_index * 3 + 1]);
        it.b = expand_6_bit(data[it_index * 3 + 2]);
    }
    return palette, true;
}

// PLTT (LFD): first and last index, then the RGB entries between them. Updates only that range.
pltt_apply :: (palette: *Palette, data: [] u8) -> bool {
    if data.count < 2 return false;
    first: s64 = data[0];
    last:  s64 = data[1];
    if last < first || 2 + (last - first + 1) * 3 > data.count return false;
    for i: first..last {
        at := 2 + (i - first) * 3;
        palette.colors[i] = .{data[at], data[at + 1], data[at + 2]};
    }
    return true;
}

// A 6-bit VGA DAC value widened to 8 bits, the top bits repeated in the low ones.
expand_6_bit :: (v: u8) -> u8 {
    v &= 63;
    return (v << 2) | (v >> 4);
}

// CMP: 32 rows of 256 indices, darkest first, then the 128-byte light ramp.
cmp_parse :: (data: [] u8) -> Colormap, bool {
    colormap: Colormap;
    if data.count < size_of(Colormap) return colormap, false;
    memcpy(*colormap, data.data, size_of(Colormap));
    return colormap, true;
}

// BM -------------------------------------------------------------------------------------------

Texture :: struct {
    frames: [..] Image;

    // Frames per second for an animated texture; 0 for a switch, whose frames are its states.
    frame_rate:  u8;
    animated:    bool;          // More than one frame.
    transparent: bool;          // Index 0 is see-through (masked mid textures, HUD, weapons).
}

texture_free :: (texture: *Texture) {
    for * texture.frames image_free(it);
    array_free(texture.frames);
    texture.* = .{};
}

// A BM is one image, or an animated texture: a container whose header claims a 1-pixel-wide
// image (width field -2), holding a frame rate, the byte 2, and offsets to frames with their
// own 28-byte headers.
bm_parse :: (data: [] u8) -> Texture, bool {
    texture: Texture;
    ok := parse_bm(*texture, data);
    if !ok texture_free(*texture);
    return texture, ok;
}

// FME and WAX -----------------------------------------------------------------------------------

// A cell is a sprite picture. Index 0 is always transparent.
Sprite_Frame :: struct {
    cell:     s32;              // Index into the sprite's cells.
    insert_x: s32;              // Offset of the cell's left edge from the object, in pixels.
    insert_y: s32;              // Offset of the cell's top edge from the object, in pixels.
    flip:     bool;             // Drawn mirrored left to right.
}

Wax_View :: struct {
    frames: [..] Sprite_Frame;
}

Wax_Action :: struct {
    world_width, world_height: s32;    // 16.16 scale for the cells' size in the world.
    frame_rate: s32;                    // Frames per second.
    views: [..] Wax_View;               // Up to 32 views around the object, the first facing the camera.
}

// An FME is a sprite with one action, one view and one frame.
Sprite :: struct {
    actions: [..] Wax_Action;
    cells:   [..] Image;
}

sprite_free :: (sprite: *Sprite) {
    for * action: sprite.actions {
        for * action.views array_free(it.frames);
        array_free(action.views);
    }
    array_free(sprite.actions);
    for * sprite.cells image_free(it);
    array_free(sprite.cells);
    sprite.* = .{};
}

// One pixel of an FME is a tenth of a world unit. WAX cells are scaled by their action's world
// width and height on top of that (16.16, 0x10000 being the FME scale).
FME_WORLD_SCALE :: 0x10000;

fme_parse :: (data: [] u8) -> Sprite, bool {
    sprite: Sprite;
    ok := parse_fme(*sprite, data);
    if !ok sprite_free(*sprite);
    return sprite, ok;
}

wax_parse :: (data: [] u8) -> Sprite, bool {
    sprite: Sprite;
    ok := parse_wax(*sprite, data);
    if !ok sprite_free(*sprite);
    return sprite, ok;
}

// FNT ------------------------------------------------------------------------------------------

Font :: struct {
    height: s32;
    spacing: s32;               // Added to a glyph's width to advance.
    space_width: s32;           // How far a space advances.
    line_gap: s32;              // Added to the height for a new line.
    first:  u8;                 // Character code of glyphs[0].
    glyphs: [..] Image;         // Index 0 is transparent.
}

font_free :: (font: *Font) {
    for * font.glyphs image_free(it);
    array_free(font.glyphs);
    font.* = .{};
}

fnt_parse :: (data: [] u8) -> Font, bool {
    font: Font;
    ok := parse_fnt(*font, data);
    if !ok font_free(*font);
    return font, ok;
}

#scope_file

BM_MAGIC        :: "BM \x1E";
BM_HEADER_SIZE  :: 32;
BM_FRAME_HEADER :: 28;
BM_ANIMATED     :: -2;
BM_TRANSPARENT  :: 0x08;

parse_bm :: (texture: *Texture, data: [] u8) -> bool {
    if data.count < BM_HEADER_SIZE || !has_bytes(data, 0, BM_MAGIC) return false;
    width  := get_u16(data, 4);
    height := get_u16(data, 6);
    marker := get_s16(data, 8);
    count  := get_u16(data, 10);
    flags  := data[12];
    compression := data[14];
    texture.transparent = (flags & BM_TRANSPARENT) != 0;

    if marker == BM_ANIMATED {
        // The container's image is the rest of the file: frame rate, 2, then the offsets.
        base :: BM_HEADER_SIZE + 2;
        if data.count < base || data[BM_HEADER_SIZE + 1] != 2 return false;
        if count > (data.count - base) / 4 return false;
        texture.frame_rate = data[BM_HEADER_SIZE];
        texture.animated   = true;
        for i: 0..count-1 {
            at := base + get_s32(data, base + i * 4);
            if at < base || at + BM_FRAME_HEADER > data.count return false;
            w := get_u16(data, at);
            h := get_u16(data, at + 2);
            if at + BM_FRAME_HEADER + w * h > data.count return false;
            // Each frame has its own flags; the renderer reads them from the current frame.
            if i == 0  texture.transparent = (data[at + 0x18] & BM_TRANSPARENT) != 0;
            frame := array_add(*texture.frames);
            read_columns(frame, w, h, array_view(data, at + BM_FRAME_HEADER, w * h));
        }
        return true;
    }

    frame := array_add(*texture.frames);
    if compression == 0 {
        if BM_HEADER_SIZE + width * height > data.count return false;
        read_columns(frame, width, height, array_view(data, BM_HEADER_SIZE, width * height));
        return true;
    }

    // Compressed (the demo has some; the retail data none): the columns, then a table of each
    // column's offset from the end of the header.
    if compression > 2 return false;
    packed_size: s64 = get_s32(data, 16);
    table := BM_HEADER_SIZE + packed_size;
    if packed_size < 0 || table + width * 4 > data.count return false;
    alloc_image(frame, width, height);
    packed := array_view(data, BM_HEADER_SIZE, packed_size);
    for x: 0..width-1 {
        column := get_s32(data, table + x * 4);
        if !unpack_column(frame, x, packed, column, compression == 1) return false;
    }
    return true;
}

// FME: 32-byte frame header (insert x, insert y, flip, cell offset), then the cell.
FRAME_SIZE       :: 32;
CELL_HEADER_SIZE :: 24;

parse_fme :: (sprite: *Sprite, data: [] u8) -> bool {
    if data.count < FRAME_SIZE return false;
    action := array_add(*sprite.actions);
    action.world_width  = FME_WORLD_SCALE;
    action.world_height = FME_WORLD_SCALE;
    view := array_add(*action.views);
    cells: Cell_Table;
    defer array_free(cells.offsets);
    frame, ok := read_frame(sprite, *cells, data, 0);
    if !ok return false;
    array_add(*view.frames, frame);
    return true;
}

// WAX: a header with 32 action offsets; each action has its world size, frame rate and 32 view
// offsets; each view 32 frame offsets. Offsets are from the start of the file. The game stops
// at the first null offset in each list, so later entries never show. Views and actions share
// frames and cells freely.
WAX_HEADER_SIZE :: 32;
WAX_ACTION_SIZE :: 28;
WAX_VIEW_SIZE   :: 16;
WAX_MAX         :: 32;

parse_wax :: (sprite: *Sprite, data: [] u8) -> bool {
    if data.count < WAX_HEADER_SIZE + WAX_MAX * 4 return false;
    cells: Cell_Table;
    defer array_free(cells.offsets);

    for a: 0..WAX_MAX-1 {
        action_at: s64 = get_s32(data, WAX_HEADER_SIZE + a * 4);
        if !action_at break;
        if action_at < 0 || action_at + WAX_ACTION_SIZE + WAX_MAX * 4 > data.count return false;

        action := array_add(*sprite.actions);
        action.world_width  = get_s32(data, action_at);
        action.world_height = get_s32(data, action_at + 4);
        action.frame_rate   = get_s32(data, action_at + 8);

        for v: 0..WAX_MAX-1 {
            view_at: s64 = get_s32(data, action_at + WAX_ACTION_SIZE + v * 4);
            if !view_at break;
            if view_at < 0 || view_at + WAX_VIEW_SIZE + WAX_MAX * 4 > data.count return false;

            view := array_add(*action.views);
            for f: 0..WAX_MAX-1 {
                frame_at: s64 = get_s32(data, view_at + WAX_VIEW_SIZE + f * 4);
                if !frame_at break;
                frame, ok := read_frame(sprite, *cells, data, frame_at);
                if !ok return false;
                array_add(*view.frames, frame);
            }
        }
    }
    return sprite.actions.count > 0;
}

// Cells already decoded, by file offset.
Cell_Table :: struct {
    offsets: [..] s64;
}

read_frame :: (sprite: *Sprite, cells: *Cell_Table, data: [] u8, at: s64) -> Sprite_Frame, bool {
    frame: Sprite_Frame;
    if at < 0 || at + FRAME_SIZE > data.count return frame, false;
    frame.insert_x = get_s32(data, at);
    frame.insert_y = get_s32(data, at + 4);
    frame.flip     = get_s32(data, at + 8) != 0;
    cell_at: s64   = get_s32(data, at + 12);

    for cells.offsets if it == cell_at {
        frame.cell = xx it_index;
        return frame, true;
    }
    cell: Image;
    if !read_cell(*cell, data, cell_at) return frame, false;
    frame.cell = xx sprite.cells.count;
    array_add(*sprite.cells, cell);
    array_add(*cells.offsets, cell_at);
    return frame, true;
}

// A cell header (width, height, compressed, data size, column offset, unused), then its columns.
// Compressed cells start with a table of column offsets from the cell header, and code runs of
// transparent pixels.
read_cell :: (cell: *Image, data: [] u8, at: s64) -> bool {
    if at < 0 || at + CELL_HEADER_SIZE > data.count return false;
    width  := get_s32(data, at);
    height := get_s32(data, at + 4);
    compressed := get_s32(data, at + 8);
    if width < 0 || height < 0 || width > 4096 || height > 4096 return false;

    pixels := at + CELL_HEADER_SIZE;
    if compressed != 1 {
        if pixels + width * height > data.count return false;
        read_columns(cell, width, height, array_view(data, pixels, width * height));
        return true;
    }

    if pixels + width * 4 > data.count return false;
    alloc_image(cell, width, height);
    whole := array_view(data, at, data.count - at);
    for x: 0..width-1 {
        column := get_s32(data, pixels + x * 4);
        if !unpack_column(cell, x, whole, column, false) return false;
    }
    return true;
}

// FNT: "FNT\x15", height, an unused byte, the data size, the first and last character, 22 bytes
// of padding, then each glyph: its width and its columns.
FNT_HEADER_SIZE :: 32;

parse_fnt :: (font: *Font, data: [] u8) -> bool {
    if data.count < FNT_HEADER_SIZE || !has_bytes(data, 0, "FNT\x15") return false;
    // As DARK.EXE reads the header (0x4d9d3): height, spacing, the space's width, the line
    // gap, then the first and last character.
    font.height = data[4];
    font.spacing = data[5];
    font.space_width = data[6];
    font.line_gap = data[7];
    font.first  = data[8];
    last := data[9];
    if last < font.first return false;

    at := FNT_HEADER_SIZE;
    for font.first..last {
        if at >= data.count return false;
        width: s32 = data[at];
        at += 1;
        if at + width * font.height > data.count return false;
        glyph := array_add(*font.glyphs);
        read_columns(glyph, width, font.height, array_view(data, at, width * font.height));
        at += width * font.height;
    }
    return true;
}

alloc_image :: (image: *Image, width: s32, height: s32) {
    image.width  = width;
    image.height = height;
    image.pixels = NewArray(width * height, u8);
}

// Columns, bottom to top, into rows, top to bottom.
read_columns :: (image: *Image, width: s32, height: s32, columns: [] u8) {
    alloc_image(image, width, height);
    for x: 0..width-1 {
        for y: 0..height-1  image.pixels[(height - 1 - y) * width + x] = columns[x * height + y];
    }
}

// One run-length coded column, bottom to top. A byte with bit 7 clear copies that many bytes;
// with it set, the low 7 bits count either repeats of the next byte (BM type 1) or transparent
// pixels (BM type 2, sprite cells). The original runs until the count comes out exactly at
// the column's height; damaged data stops at the end of the column or the buffer instead.
unpack_column :: (image: *Image, x: s64, packed: [] u8, at: s64, repeats: bool) -> bool {
    if at < 0 return false;
    y := 0;
    while y < image.height {
        if at >= packed.count return false;
        code := packed[at];
        at += 1;
        count: s64 = code & 0x7F;
        if count > image.height - y  count = image.height - y;
        if code & 0x80 {
            value: u8 = 0;
            if repeats {
                if at >= packed.count return false;
                value = packed[at];
                at += 1;
            }
            for 0..count-1  image.pixels[(image.height - 1 - y - it) * image.width + x] = value;
        } else {
            if at + count > packed.count return false;
            for 0..count-1  image.pixels[(image.height - 1 - y - it) * image.width + x] = packed[at + it];
            at += code;
        }
        y += count;
    }
    return true;
}

has_bytes :: (data: [] u8, at: s64, tag: string) -> bool {
    if at + tag.count > data.count return false;
    return memcmp(data.data + at, tag.data, tag.count) == 0;
}

get_u16 :: (data: [] u8, at: s64) -> s32 {
    return (cast(s32) data[at]) | ((cast(s32) data[at + 1]) << 8);
}

get_s16 :: (data: [] u8, at: s64) -> s32 {
    return cast(s32) cast,trunc(s16) get_u16(data, at);
}

get_s32 :: (data: [] u8, at: s64) -> s32 {
    v := (cast(u32) data[at]) | ((cast(u32) data[at + 1]) << 8) | ((cast(u32) data[at + 2]) << 16) | ((cast(u32) data[at + 3]) << 24);
    return cast,no_check(s32) v;
}

#import "Basic";
