// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Two square rooms side by side, joined by an adjoin, the second's floor a step up.
TWO_ROOMS :: #string END
LEV 2.1
# A comment line.
LEVELNAME TEST
PALETTE test.pal
MUSIC TEST.GMD
PARALLAX 1024.0000 512.0000
TEXTURES 2
  TEXTURE: WALL.BM   # 0
  TEXTURE: <NoTexture>
NUMSECTORS 2
SECTOR 0
  NAME     first
  AMBIENT  20
  FLOOR TEXTURE     0   1.50   -0.25  2
  FLOOR ALTITUDE     0.00
  CEILING TEXTURE   0    0.00    0.00  2
  CEILING ALTITUDE -12.00
  SECOND ALTITUDE   0.00
  FLAGS 9 0 0
  LAYER 1
  VERTICES 4
    X: 0.00  Z: 0.00
    X: 0.00  Z: 10.00
    X: 10.00 Z: 10.00
    X: 10.00 Z: 0.00
  WALLS 4
    WALL LEFT: 0 RIGHT: 1 MID: 0 0.00 0.00 0 TOP: 0 0.00 0.00 0 BOT: 0 0.00 0.00 0 SIGN: -1 0.00 0.00 ADJOIN: -1 MIRROR: -1 WALK: -1 FLAGS: 0 0 0 LIGHT: 0
    WALL LEFT: 1 RIGHT: 2 MID: 0 0.00 0.00 0 TOP: 0 0.00 0.00 0 BOT: 0 0.00 0.00 0 SIGN: -1 0.00 0.00 ADJOIN: -1 MIRROR: -1 WALK: -1 FLAGS: 0 0 0 LIGHT: 65534
    WALL LEFT: 2 RIGHT: 3 MID: 0 0.50 0.00 0 TOP: 0 0.00 0.00 0 BOT: 0 0.00 0.00 0 SIGN: 0 1.00 -2.00 ADJOIN: 1 MIRROR: 0 WALK: 1 FLAGS: 1 0 2 LIGHT: 3
    WALL LEFT: 3 RIGHT: 0 MID: 0 0.00 0.00 0 TOP: 0 0.00 0.00 0 BOT: 0 0.00 0.00 0 SIGN: -1 0.00 0.00 ADJOIN: -1 MIRROR: -1 WALK: -1 FLAGS: 0 0 0 LIGHT: 0
SECTOR 1
  NAME
  AMBIENT  31
  FLOOR TEXTURE     0   0.00    0.00  2
  FLOOR ALTITUDE    -2.00
  CEILING TEXTURE   0    0.00    0.00  2
  CEILING ALTITUDE -12.00
  SECOND ALTITUDE   0.00
  FLAGS 0 0 0
  LAYER 1
  VERTICES 4
    X: 10.00 Z: 0.00
    X: 10.00 Z: 10.00
    X: 20.00 Z: 10.00
    X: 20.00 Z: 0.00
  WALLS 4
    WALL LEFT: 0 RIGHT: 1 MID: 0 0.00 0.00 0 TOP: 0 0.00 0.00 0 BOT: 0 0.00 0.00 0 SIGN: -1 0.00 0.00 ADJOIN: 0 MIRROR: 2 WALK: 0 FLAGS: 0 0 0 LIGHT: 0
    WALL LEFT: 1 RIGHT: 2 MID: 0 0.00 0.00 0 TOP: 0 0.00 0.00 0 BOT: 0 0.00 0.00 0 SIGN: -1 0.00 0.00 ADJOIN: 0 MIRROR: 7 WALK: 0 FLAGS: 0 0 0 LIGHT: 0
    WALL LEFT: 2 RIGHT: 3 MID: 0 0.00 0.00 0 TOP: 0 0.00 0.00 0 BOT: 0 0.00 0.00 0 SIGN: -1 0.00 0.00 ADJOIN: -1 MIRROR: -1 WALK: -1 FLAGS: 0 0 0 LIGHT: 0
    WALL LEFT: 3 RIGHT: 0 MID: 0 0.00 0.00 0 TOP: 0 0.00 0.00 0 BOT: 0 0.00 0.00 0 SIGN: -1 0.00 0.00 ADJOIN: -1 MIRROR: -1 WALK: -1 FLAGS: 0 0 0 LIGHT: 0
END

level_parses_sectors_and_walls :: () {
    level, ok := lev_parse(TWO_ROOMS);
    defer level_free(*level);
    if !check(ok, "LEV rejected")  return;
    check(level.palette == "TEST.PAL" && level.music == "TEST.GMD", "palette % music %", level.palette, level.music);
    check(level.parallax[0] == 1024 * FIXED_ONE && level.parallax[1] == 512 * FIXED_ONE, "parallax %", level.parallax);
    check(level.textures.count == 2 && level.textures[0] == "WALL.BM" && level.textures[1] == "", "textures %", level.textures);
    if !check(level.sectors.count == 2, "% sectors", level.sectors.count)  return;

    a := *level.sectors[0];
    check(a.name == "first" && a.ambient == 20 * FIXED_ONE && a.flags[0] == 9, "sector 0 % % %", a.name, a.ambient, a.flags[0]);
    check(a.floor.offset.x == 0x18000 && a.floor.offset.z == -0x4000 && a.ceiling.altitude == -12 * FIXED_ONE, "flats % %", a.floor, a.ceiling);
    check(a.vertices.count == 4 && a.walls.count == 4, "% vertices, % walls", a.vertices.count, a.walls.count);
    check(a.bounds_min.x == 0 && a.bounds_max.z == 10 * FIXED_ONE, "bounds % %", a.bounds_min, a.bounds_max);
    // Flags 9: a sky (exterior), so collision takes the ceiling 100 units up.
    check(a.col_ceiling == -112 * FIXED_ONE && a.col_floor == 0 && a.col_second == 0, "collision heights % % %", a.col_floor, a.col_ceiling, a.col_second);
    // The first wall runs from (0, 0) to (0, 10): along +z, angle 0; the second along +x.
    w0, w1 := *a.walls[0], *a.walls[1];
    check(w0.direction.x == 0 && w0.direction.z == FIXED_ONE && w0.length == 10 * FIXED_ONE && w0.angle == 0, "wall 0: % % %", w0.direction, w0.length, w0.angle);
    check(w1.direction.x == FIXED_ONE && w1.direction.z == 0 && w1.angle == 4096, "wall 1: % %", w1.direction, w1.angle);
    check(a.walls[1].light == -2 * FIXED_ONE, "light 65534 read as %", a.walls[1].light);
    w := *a.walls[2];
    check(w.adjoin == 1 && w.mirror == 0 && w.flags[0] == WALL_MASKED, "adjoin % mirror % flags %", w.adjoin, w.mirror, w.flags[0]);
    check(w.mid.offset.x == 4 * FIXED_ONE && w.sign.texture == 0 && w.sign.offset.x == 8 * FIXED_ONE && w.sign.offset.z == -16 * FIXED_ONE, "offsets in texels: mid % sign %", w.mid, w.sign);

    // The second room's mirror 7 doesn't exist: that adjoin is dropped. The good pair shares
    // its solid bit.
    b := *level.sectors[1];
    check(b.name == "" && b.walls[1].adjoin == -1, "name '%', bad adjoin kept as %", b.name, b.walls[1].adjoin);
    check(b.walls[0].flags[2] == 2, "shared flags %", b.walls[0].flags[2]);

    at :: (x: s32, y: s32, z: s32) -> Fixed3 { return .{x * FIXED_ONE, y * FIXED_ONE, z * FIXED_ONE}; }
    check(level_find_sector(*level, at(5, -1, 5)) == 0, "point in the first room");
    check(level_find_sector(*level, at(15, -3, 5)) == 1, "point in the second room");
    check(level_find_sector(*level, at(15, -1, 5)) == -1, "point under the second room's floor");
    check(level_find_sector(*level, at(10, -1, 5)) == 0, "point on the shared edge, at a height only the first room has");
    check(level_find_sector(*level, at(10, -1, 10)) == 0, "a corner counts as inside");
    check(level_find_sector(*level, at(10, -3, 5)) == 0, "both rooms hold the edge: the first, as large, wins");
} @test

// Numbers are read as a float and kept times 65536, truncated: -0.3 as a float is just past
// -0.3, so -19660.8 becomes -19660, not -19661.
level_numbers_truncate :: () {
    level, ok := lev_parse(replace(TWO_ROOMS, "FLOOR ALTITUDE     0.00", "FLOOR ALTITUDE     -0.30",, temp));
    defer level_free(*level);
    if !check(ok, "LEV rejected")  return;
    check(level.sectors[0].floor.altitude == -19660, "-0.3 read as %", level.sectors[0].floor.altitude);
} @test

level_rejects_damage :: () {
    _, ok := lev_parse("");
    check(!ok, "accepted nothing");
    broken := replace(TWO_ROOMS, "LEFT: 2 RIGHT: 3", "LEFT: 2 RIGHT: 9",, temp);
    _, ok = lev_parse(broken);
    check(!ok, "accepted a wall to a vertex that isn't there");
    short := replace(TWO_ROOMS, "NUMSECTORS 2", "NUMSECTORS 3",, temp);
    _, ok = lev_parse(short);
    check(!ok, "accepted fewer sectors than counted");
} @test

OBJECTS_TEXT :: #string END
O 1.1
/* A block comment
   over two lines. */
LEVELNAME TEST
PODS 1
    POD: DEFAULT.3DO
SPRS 1
    SPR: OFFCFIN.WAX
FMES 0
SOUNDS 0
OBJECTS 4
    CLASS: SPIRIT     DATA: 0   X: 5.00 Y: -3.00 Z: 5.00 PCH: 0.00   YAW: 90.00 ROL: 0.00   DIFF: 1
        SEQ
            LOGIC:     PLAYER
            EYE:       TRUE
        SEQEND
    // A comment.
    CLASS: SPRITE     DATA: 0   X: 15.00 Y: -2.00 Z: 5.00 PCH: 0.00   YAW: 270.00 ROL: 0.00   DIFF: 3
    CLASS: 3D         DATA: 0   X: 6.00 Y: 0.00 Z: 4.00 PCH: 0.00   YAW: 0.00 ROL: 0.00   DIFF: -2
        SEQ
            LOGIC:     UPDATE
            D_YAW:     50
        SEQEND
    CLASS: SPRITE     DATA: 0   X: 1.00 Y: 0.00 Z: 1.00 PCH: 0.00   YAW: 0.00 ROL: 0.00   DIFF: 1
        SEQ
            INTERVAL:  5
            LOGIC:     GENERATOR STORM1
            max_alive: 3
            MASTER:
            LOGIC:     ANIM
            DELAY:     2
        SEQEND
END

objects_parse :: () {
    objects, ok := o_parse(OBJECTS_TEXT);
    defer level_objects_free(*objects);
    if !check(ok, "O rejected")  return;
    check(objects.pods.count == 1 && objects.pods[0] == "DEFAULT.3DO" && objects.sprites[0] == "OFFCFIN.WAX", "pods % sprites %", objects.pods, objects.sprites);
    if !check(objects.objects.count == 4, "% objects", objects.objects.count)  return;
    player := *objects.objects[0];
    check(player.class == .SPIRIT && has_logic(player, "PLAYER") && player.eye && player.yaw == 4095, "player % % % %", player.class, player.logics, player.eye, player.yaw);
    sprite := *objects.objects[1];
    check(sprite.class == .SPRITE && sprite.position.x == 15 * FIXED_ONE && sprite.difficulty == 3 && !sprite.logics, "sprite % % % %", sprite.class, sprite.position, sprite.difficulty, sprite.logics);
    model := *objects.objects[2];
    check(model.class == .MODEL && has_logic(model, "UPDATE"), "model % %", model.class, model.logics);
    check(model.params.count == 1 && model.params[0].key == "D_YAW:" && model.params[0].value == "50" && model.params[0].logic == 0, "model params %", model.params);
    generator := *objects.objects[3];
    check(has_logic(generator, "GENERATOR") && generator.logics[0] == "GENERATOR STORM1", "generator %", generator.logics);
    // Each line goes with the logic before it: the first with none, the last with ANIM.
    if check(generator.params.count == 4, "generator params %", generator.params) {
        p := generator.params;
        check(p[0].key == "INTERVAL:" && p[0].logic == -1, "before LOGIC: %", p[0]);
        check(p[1].key == "MAX_ALIVE:" && p[1].value == "3" && p[1].logic == 0, "MAX_ALIVE: %", p[1]);
        check(p[2].key == "MASTER:" && p[2].value == "" && p[2].logic == 0, "MASTER: %", p[2]);
        check(p[3].key == "DELAY:" && p[3].logic == 1, "after ANIM: %", p[3]);
    }

    // DIFF 3 only on hard, -2 up to medium.
    check(!is_object_in_difficulty(sprite, 2) && is_object_in_difficulty(sprite, 3), "DIFF 3");
    check(is_object_in_difficulty(model, 2) && !is_object_in_difficulty(model, 3), "DIFF -2");
    check(is_object_in_difficulty(player, 1), "DIFF 1");
} @test

level_list_parses :: () {
    list, ok := lvl_parse("LEVELS 2\nSecret Base,        SECBASE,   L:\\LEVELS\\SECBASE\;L:\\LEVELS\;\nTalay: Tak Base,  TALAY, L:\\LEVELS\\\n// Comments after.\n");
    defer level_list_free(*list);
    if !check(ok && list.count == 2, "% levels", list.count)  return;
    check(list[0].title == "Secret Base" && list[0].name == "SECBASE", "first % %", list[0].title, list[0].name);
    check(list[1].title == "Talay: Tak Base" && list[1].name == "TALAY", "second % %", list[1].title, list[1].name);
} @test

retail_levels_parse :: () {
    skip_without_dark();
    gob_unmount_all();
    defer gob_unmount_all();
    if !check(gob_mount_retail(find_dark_data_dir()), "couldn't mount the retail GOBs")  return;

    text, found := gob_find("JEDI.LVL");
    if !check(found, "no JEDI.LVL")  return;
    list, ok := lvl_parse(cast(string) text);
    defer level_list_free(*list);
    if !check(ok && list.count == 14, "% levels", list.count)  return;
    check(list[0].name == "SECBASE" && list[13].name == "ARC", "levels from % to %", list[0].name, list[13].name);

    for entry: list {
        lev, lev_found := gob_find(tprint("%.LEV", entry.name));
        if !check(lev_found, "no %.LEV", entry.name)  continue;
        level, level_ok := lev_parse(cast(string) lev);
        defer level_free(*level);
        if !check(level_ok, "%.LEV failed", entry.name)  continue;

        // Every adjoin kept leads to a wall that adjoins back to its sector. (A few walls
        // adjoin one that leads back to a neighbour of theirs: DTENTION, FUELSTAT,
        // EXECUTOR.)
        for sector, s: level.sectors  for wall, w: sector.walls {
            if wall.adjoin < 0 continue;
            check(wall.mirror >= 0 && wall.mirror < level.sectors[wall.adjoin].walls.count, "% sector % wall %: no mirror", entry.name, s, w);
        }

        o, o_found := gob_find(tprint("%.O", entry.name));
        if !check(o_found, "no %.O", entry.name)  continue;
        objects, objects_ok := o_parse(cast(string) o);
        defer level_objects_free(*objects);
        if !check(objects_ok, "%.O failed", entry.name)  continue;
        starts := 0;
        for * objects.objects {
            if !has_logic(it, "PLAYER") continue;
            starts += 1;
            check(level_find_sector(*level, it.position) >= 0, "% start outside every sector", entry.name);
        }
        check(starts == 1, "% has % player starts", entry.name, starts);

        if entry.name == "SECBASE" {
            check(level.sectors.count == 218 && level.textures.count == 95, "SECBASE: % sectors, % textures", level.sectors.count, level.textures.count);
            check(objects.objects.count == 168, "SECBASE: % objects", objects.objects.count);
        }

        // Every level has goals, each one named once.
        gol, gol_found := gob_find(tprint("%.GOL", entry.name));
        if !check(gol_found, "no %.GOL", entry.name)  continue;
        goals, goals_ok := gol_parse(cast(string) gol);
        if !check(goals_ok, "%.GOL failed", entry.name)  continue;
        named := 0;
        for goals.by_item     if it >= 0  named += 1;
        for goals.by_trigger  if it >= 0  named += 1;
        check(named > 0, "% has no goals", entry.name);
        if entry.name == "SECBASE"  check(goals.by_item[0] == 0 && goals.by_trigger[1] == 1 && named == 2, "SECBASE's goals: %", goals);
    }
} @test

goals_parse :: () {
    goals, ok := gol_parse("GOL 1.0\r\n  GOAL: 0\tITEM:\t4\t# a comment\r\nGOAL: 2 TRIG: 9\nGOAL: 1 TRIG: 10\nGOAL: 3 KEY: 1\nGOAL: x ITEM: 1\n\x1a");
    if !check(ok, "rejected") return;
    check(goals.by_item[4] == 0 && goals.by_trigger[9] == 2, "goals %", goals);
    named := 0;
    for goals.by_item     if it >= 0  named += 1;
    for goals.by_trigger  if it >= 0  named += 1;
    check(named == 2, "% goals named: out-of-range and unknown lines kept", named);
    _, ok = gol_parse("GOL 1.1\nGOAL: 0 ITEM: 0\n");
    check(!ok, "accepted version 1.1");
} @test

#import "Basic";
#import "Math";
#import "String";
#import "engine/dfArchive";
#import "engine/dfLevel";
#import "engine/dfFixed";
