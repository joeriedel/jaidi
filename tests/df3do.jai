// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

CUBE_ISH :: #string END
3DO 1.2
# A comment
3DONAME test
OBJECTS 2
VERTICES 7
POLYGONS 3
PALETTE DEFAULT.PAL

TEXTURES 1
 TEXTURE: WALL.BM

OBJECT "flat"
TEXTURE -1
VERTICES 3
  0:  0.000  0.000  0.000
  1:  1.000  0.000  0.000   # trailing comment
  2:  0.000  1.0000001  0.000
TRIANGLES 1
  0:  0  1  2  12  FLAT

OBJECT "textured"
TEXTURE 0
VERTICES 4
  0: 0 0 0
  1: 1 0 0
  2: 1 1 0
  3: 0 1 0
QUADS 2
  0: 0 1 2 3  5  TEXTURE
  1: 3 2 1 0  5  GOURAUD
TEXTURE VERTICES 2
  0: 0.0 0.0
  1: 0.5 1.0
TEXTURE QUADS 2
  0: 0 1 1 0
  1: 1 1 1 1
END

model_parses :: () {
    model, ok := model_parse(CUBE_ISH, (name: string) -> s32, s32, bool { return 32, 16, name == "WALL.BM"; });
    defer model_free(*model);
    if !check(ok, "model rejected")  return;
    check(model.name == "test", "name '%'", model.name);
    check(model.vertices.count == 7 && model.polygons.count == 3, "% vertices, % polygons", model.vertices.count, model.polygons.count);
    check(model.vertices[2].y == 1.0, "vertex not rounded to 16.16: %", model.vertices[2].y);

    flat := model.polygons[0];
    check(flat.count == 3 && flat.color == 12 && flat.shading == .FLAT && flat.texture == -1, "flat polygon %", flat);
    // (v0 - v1) x (v2 - v1) for a counter-clockwise triangle in x/y points down z.
    check(flat.normal.z < -0.99, "normal %", flat.normal);

    quad := model.polygons[1];
    check(quad.count == 4 && quad.indices[0] == 3 && quad.indices[3] == 6, "object vertex indices not offset: %", quad.indices);
    check(quad.texture == 0 && quad.shading == .TEXTURE, "textured quad %", quad);
    // Texture vertex (1, 1): v counts up from the texture's bottom row, so the top, row 0.
    check(quad.uvs[1].x == 16 && quad.uvs[1].y == 0, "uvs not scaled to texels: %", quad.uvs);
    check(model.polygons[2].shading == .GOURAUD && model.vertex_lit, "gouraud not vertex lit");
    check(model.vertex_normals.count == 7, "% vertex normals", model.vertex_normals.count);
} @test

model_rejects_bad_shading :: () {
    bad := replace(CUBE_ISH, "FLAT", "SHINY");
    _, ok := model_parse(bad, (name: string) -> s32, s32, bool { return 0, 0, false; });
    check(!ok, "accepted an unknown shading");
} @test

retail_models_parse :: () {
    skip_without_dark();
    gob_unmount_all();
    defer gob_unmount_all();
    if !check(gob_mount_retail(find_dark_data_dir()), "couldn't mount the retail GOBs")  return;

    count := 0;
    textured := 0;
    for mounted_gobs[0].entries {
        if path_extension(it.name) != "3DO" continue;
        model, ok := model_parse(cast(string) it.data, get_bm_size);
        check(ok && (model.polygons.count > 0 || model.draw_vertices), "% failed", it.name);
        for p: model.polygons  if p.texture >= 0 { textured += 1; break; }
        model_free(*model);
        count += 1;
    }
    check(count == 28, "% models", count);
    check(textured > 0, "no textured models");
} @test

#scope_file

get_bm_size :: (name: string) -> s32, s32, bool {
    data, found := gob_find(name);
    if !found return 0, 0, false;
    texture, ok := bm_parse(data);
    defer texture_free(*texture);
    if !ok return 0, 0, false;
    return texture.frames[0].width, texture.frames[0].height, true;
}

#import "Basic";
#import "String";
#import "engine/dfArchive";
#import "engine/dfImage";
#import "engine/df3do";
