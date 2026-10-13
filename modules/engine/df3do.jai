// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// 3DO: the game's 3D objects, a text format converted from 3D Studio.
//
// Parsed the way DARK.EXE reads it: line by line, skipping blank and comment lines, each list
// running until a line that doesn't match its pattern, which is then read as the next
// section's header. Counts in the headers are not trusted. Each object holds either triangles
// or quads. Positions are rounded to 16.16 fixed point, as the original stores them.

Shading :: enum u8 {
    FLAT;       // One color, lit per polygon.
    GOURAUD;    // One color, lit per vertex.
    TEXTURE;    // Textured, lit per polygon.
    GOURTEX;    // Textured, lit per vertex.
    PLANE;      // Textured like a floor: projected in world x/z, not by texture coordinates.
}

Model_Polygon :: struct {
    count:   s32;               // 3 or 4.
    indices: [4] s32;           // Into Model.vertices.
    color:   u8;                // Palette index, for the untextured shadings.
    shading: Shading;
    texture: s32 = -1;          // Into Model.textures; -1 for none.
    uvs:     [4] Vector2;       // In texels of the texture, for TEXTURE and GOURTEX.
    normal:  Vector3;
}

Model :: struct {
    name:     string;
    textures: [..] string;      // BM names; empty for "<NoTexture>".
    vertices: [..] Vector3;     // World units; y is down, as in the game.
    vertex_normals: [..] Vector3;   // Only for vertex-lit models.
    polygons: [..] Model_Polygon;
    radius:   float;            // Largest vertex distance from the origin.

    vertex_lit:    bool;        // Some polygon is GOURAUD or GOURTEX.
    draw_vertices: bool;        // VERTEX shading anywhere: the model is drawn as points only.
}

// The original's limits; files over them fail to load.
MODEL_MAX_VERTICES :: 500;
MODEL_MAX_POLYGONS :: 400;

model_free :: (model: *Model) {
    free(model.name);
    for model.textures free(it);
    array_free(model.textures);
    array_free(model.vertices);
    array_free(model.vertex_normals);
    array_free(model.polygons);
    model.* = .{};
}

// Texture sizes are needed for the texture coordinates, so the caller passes a procedure that
// looks them up by BM name (width, height, found). Missing textures fall back to 64x64 here;
// the game draws DEFAULT.BM for them.
model_parse :: (text: string, get_texture_size: (name: string) -> (s32, s32, bool)) -> Model, bool {
    model: Model;
    ok := parse_model(*model, text, get_texture_size);
    if !ok model_free(*model);
    return model, ok;
}

#scope_file

Reader :: struct {
    text: string;
    line: string;               // The current line, already trimmed.
}

// The next line that isn't blank or a comment. Comments after content on a line stay; the
// patterns stop matching before them.
next_line :: (r: *Reader) -> bool {
    while r.text {
        _, line, rest := split_from_left(r.text, #char "\n");
        r.text = rest;
        line = trim(line);
        if line && line[0] != #char "#" {
            r.line = line;
            return true;
        }
    }
    r.line = "";
    return false;
}

// Matches a line against keyword tokens and numbers, the way the original's sscanf patterns
// do: "VERTICES" then an integer. Returns the remaining tokens.
Tokens :: struct {
    items: [16] string;
    count: int;
}

split_tokens :: (line: string) -> Tokens {
    t: Tokens;
    s := line;
    while s && t.count < t.items.count {
        while s && (s[0] == #char " " || s[0] == #char "\t" || s[0] == #char "\r")  advance(*s);
        if !s break;
        start := s;
        while s && s[0] != #char " " && s[0] != #char "\t" && s[0] != #char "\r"  advance(*s);
        token := start;
        token.count = start.count - s.count;
        if token[0] == #char "#" break;
        t.items[t.count] = token;
        t.count += 1;
    }
    return t;
}

// "<keyword...> <int>"
match_count :: (line: string, keyword: string) -> int, bool {
    if !begins_with_nocase(line, keyword) return 0, false;
    rest := trim(advance(line, keyword.count));
    if !rest || (rest[0] != #char "-" && !is_digit(rest[0])) return 0, false;
    value, ok := string_to_int(split_tokens(rest).items[0]);
    return value, ok;
}

// "<int>:" then numbers.
match_numbered :: (line: string) -> Tokens, bool {
    t := split_tokens(line);
    if t.count < 1 return t, false;
    first := t.items[0];
    if first && first[first.count - 1] == #char ":"  first.count -= 1;
    else if t.count > 1 && t.items[1] == ":" {
        // "0 : ..." isn't what the files hold, but sscanf's "%d:" would not match it either.
        return t, false;
    }
    _, ok := string_to_int(first);
    if !ok return t, false;
    for 0..t.count-2  t.items[it] = t.items[it + 1];
    t.count -= 1;
    return t, true;
}

to_fixed :: (s: string) -> float, bool {
    f, ok := string_to_float(s);
    if !ok return 0, false;
    // Stored as round(f * 65536) in 16.16.
    return cast(float) (cast(float64) round_half_away(cast(float64) f * 65536.0) / 65536.0), true;
}

round_half_away :: (x: float64) -> float64 {
    return ifx x < 0 then -floor(-x + 0.5) else floor(x + 0.5);
}

parse_model :: (model: *Model, text: string, get_texture_size: (string) -> (s32, s32, bool)) -> bool {
    r := Reader.{text = text};

    if !next_line(*r) || !begins_with(r.line, "3DO") return false;
    version, ok := string_to_float(trim(advance(r.line, 3)));
    if !ok || version < 1.2 - 0.0001 return false;

    // 3DONAME, OBJECTS, VERTICES, POLYGONS, PALETTE: read in that order.
    if !next_line(*r) || !begins_with_nocase(r.line, "3DONAME") return false;
    model.name = copy_string(trim(advance(r.line, 7)));
    if !next_line(*r) return false;
    object_count, ok_objects := match_count(r.line, "OBJECTS");
    if !ok_objects return false;
    if !next_line(*r) return false;
    vertex_count, ok_vertices := match_count(r.line, "VERTICES");
    if !ok_vertices || vertex_count > MODEL_MAX_VERTICES return false;
    if !next_line(*r) return false;
    polygon_count, ok_polygons := match_count(r.line, "POLYGONS");
    if !ok_polygons || polygon_count > MODEL_MAX_POLYGONS return false;
    if !next_line(*r) || !begins_with_nocase(r.line, "PALETTE") return false;

    if !next_line(*r) return false;
    texture_count, ok_textures := match_count(r.line, "TEXTURES");
    if !ok_textures return false;
    if texture_count > 0 {
        while next_line(*r) {
            if !begins_with_nocase(r.line, "TEXTURE:") break;
            name := split_tokens(trim(advance(r.line, 8))).items[0];
            array_add(*model.textures, ifx name == "<NoTexture>" then "" else copy_string(name));
        }
    } else {
        next_line(*r);
    }

    // Texture coordinates live in one table that each object's TEXTURE VERTICES refill.
    texture_vertices: [..] Vector2;
    defer array_free(texture_vertices);

    // The count can be more than the objects there are (_8X32.3DO says 8 and has 6); the game
    // passes over the missing ones.
    for 0..object_count-1 {
        if !begins_with_nocase(r.line, "OBJECT") continue;
        if !next_line(*r) return false;
        texture_index, ok_texture := match_count(r.line, "TEXTURE");
        if !ok_texture return false;
        if texture_index >= model.textures.count return false;
        texture_name := ifx texture_index >= 0 then model.textures[texture_index] else "";
        has_texture := texture_name != "";

        if !next_line(*r) return false;
        _, ok_header := match_count(r.line, "VERTICES");
        if !ok_header return false;

        first_vertex := model.vertices.count;
        while next_line(*r) {
            t, numbered := match_numbered(r.line);
            if !numbered || t.count < 3 break;
            x, ok_x := to_fixed(t.items[0]);
            y, ok_y := to_fixed(t.items[1]);
            z, ok_z := to_fixed(t.items[2]);
            if !ok_x || !ok_y || !ok_z break;
            if model.vertices.count >= MODEL_MAX_VERTICES return false;
            array_add(*model.vertices, .{x, y, z});
        }

        _, triangle_list := match_count(r.line, "TRIANGLES");
        _, quad_list     := match_count(r.line, "QUADS");
        if !triangle_list && !quad_list return false;
        corners := ifx triangle_list then 3 else 4;

        first_polygon := model.polygons.count;
        while next_line(*r) {
            t, numbered := match_numbered(r.line);
            if !numbered || t.count < corners + 2 break;
            p: Model_Polygon;
            p.count = xx corners;
            valid := true;
            for c: 0..corners-1 {
                index, ok_index := string_to_int(t.items[c]);
                index += first_vertex;
                if !ok_index || index < 0 || index >= model.vertices.count  valid = false;
                p.indices[c] = xx index;
            }
            color, ok_color := string_to_int(t.items[corners]);
            if !valid || !ok_color break;
            p.color = cast,trunc(u8) color;
            p.texture = xx ifx has_texture then texture_index else -1;

            shading := t.items[corners + 1];
            if      equal_nocase(shading, "FLAT")    p.shading = .FLAT;
            else if equal_nocase(shading, "VERTEX")  model.draw_vertices = true;
            else if equal_nocase(shading, "TEXTURE") p.shading = .TEXTURE;
            else if equal_nocase(shading, "GOURAUD") { p.shading = .GOURAUD; model.vertex_lit = true; }
            else if equal_nocase(shading, "GOURTEX") { p.shading = .GOURTEX; model.vertex_lit = true; }
            else if equal_nocase(shading, "PLANE")   p.shading = .PLANE;
            else return false;

            if model.polygons.count >= MODEL_MAX_POLYGONS return false;
            array_add(*model.polygons, p);
        }

        if !has_texture continue;

        // Texture vertices, then texture polygons matched one to one, in order, with this
        // object's polygons, whatever their shading.
        _, ok_texture_vertices := match_count(r.line, "TEXTURE VERTICES");
        if !ok_texture_vertices return false;
        array_reset_keeping_memory(*texture_vertices);
        while next_line(*r) {
            t, numbered := match_numbered(r.line);
            if !numbered || t.count < 2 break;
            u, ok_u := to_fixed(t.items[0]);
            v, ok_v := to_fixed(t.items[1]);
            if !ok_u || !ok_v break;
            array_add(*texture_vertices, .{u, v});
        }

        width, height, found := get_texture_size(texture_name);
        if !found { width = 64; height = 64; }

        _, triangles := match_count(r.line, "TEXTURE TRIANGLES");
        _, quads     := match_count(r.line, "TEXTURE QUADS");
        if !triangles && !quads return false;
        texture_corners := ifx triangles then 3 else 4;

        polygon := first_polygon;
        while next_line(*r) {
            t, numbered := match_numbered(r.line);
            if !numbered || t.count < texture_corners break;
            if polygon < model.polygons.count {
                p := *model.polygons[polygon];
                for c: 0..texture_corners-1 {
                    index, ok_index := string_to_int(t.items[c]);
                    if ok_index && index >= 0 && index < texture_vertices.count {
                        tv := texture_vertices[index];
                        // The file's v counts up from the texture's bottom row.
                        p.uvs[c] = .{tv.x * width, (1 - tv.y) * height};
                    }
                }
            }
            polygon += 1;
        }
    }

    compute_normals(model);
    return model.polygons.count > 0 || model.draw_vertices;
}

// Polygon normals from the first three corners: (v0 - v1) x (v2 - v1), normalized. Vertex
// normals, for vertex-lit models, average the normals of the polygons using the vertex.
compute_normals :: (model: *Model) {
    for * p: model.polygons {
        v0 := model.vertices[p.indices[0]];
        v1 := model.vertices[p.indices[1]];
        v2 := model.vertices[p.indices[2]];
        p.normal = unit_vector(cross(v0 - v1, v2 - v1));
    }
    for model.vertices  model.radius = max(model.radius, length(it));

    if !model.vertex_lit return;
    array_resize(*model.vertex_normals, model.vertices.count);
    for v: 0..model.vertices.count-1 {
        sum: Vector3;
        n := 0;
        for p: model.polygons {
            for c: 0..p.count-1 {
                if p.indices[c] == v {
                    sum += p.normal;
                    n += 1;
                    break;
                }
            }
        }
        model.vertex_normals[v] = ifx n && length(sum) > 0 then unit_vector(sum) else .{};
    }
}

#import "Basic";
#import "Math";
#import "String";
