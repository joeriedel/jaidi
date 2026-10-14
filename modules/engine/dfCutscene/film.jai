// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// A loaded film: its objects' command streams, the actors they move and the palettes they
// set. Each cell, every actor moves by its velocities first, then each object whose stream is
// at a timestamp for this cell runs the records up to the next one.

Lfd_Palette :: struct {
    first, last: s32;
    colors: [256] Rgb;      // first..last used.
}

Actor_Kind :: enum u8 { DELT; ANIM; CUSTOM; }

Actor :: struct {
    kind:   Actor_Kind;
    name:   string;
    frames: [..] [] u8;     // DELT data: one for a DELT, the ANIM's cells.

    x, y, x_fract, y_fract: s32;
    x_vel, y_vel, x_vel_fract, y_vel_fract: s32;
    state, state_fract, state_vel, state_vel_fract: s32;
    z: s32;
    visible: bool;
    flip_h: bool;
    flip_v: bool;               // Kept, but nothing draws it.
    frame, frame_vel: Rect;     // Clip rectangle, and how it moves each cell.
    var1, var2: s32;
    jumped: bool;               // Set this cell by POS (or a rewind): don't interpolate.
    spans_screen: bool;         // Some frame of its, shown, reaches both edges of the screen.
    tiled:        bool;         // Its picture is also another's shown with it: tiles of one background.
    cut_at_edge:  bool;         // Some frame of its, shown, has its art cut off at or just past
                                // the screen's left or right edge.
    grown:        bool;         // Drawn larger in a wide view, with what it's shown with (see film_load).
    pillarboxed:  bool;         // Kept to the 4:3 area in a wide view instead (PILLARBOXED_SHOTS).
}

Film_Object :: struct {
    using info: Film_Object_Info;
    offset:  s64;               // Into commands: the next record to run.
    actor:   *Actor;
    palette: *Lfd_Palette;
    sound:   *Cut_Sound;
}

Film :: struct {
    cell_count: s32;
    cell:       s32;
    objects: [..] Film_Object;
    actors:  [..] *Actor;       // Drawing order: larger z first.
    sort:    bool;
    frame_pairs: [..] Frame_Pair;   // In the order they're first shown.
}

// Two frames of an actor shown one after the other, for in-betweens (motion.jai).
Frame_Pair :: struct {
    cell:     s32;          // Where it first happens.
    from, to: [] u8;        // DELTs.
}

// Without sounds, only to look at the film: its sounds aren't registered with the player.
film_load :: (film: *Film, archive: *Archive, name: string, load_sounds := true) -> bool {
    film_free(film);
    entry := archive_find(archive, tprint("%.FILM", name));
    if !entry return false;
    info, ok := film_parse(entry.data);
    if !ok return false;
    defer film_info_free(*info);
    film.cell_count = info.cell_count;

    for info.objects {
        object := array_add(*film.objects);
        object.info = it;
        if it.block == {
          case .ACTOR;
            actor := New(Actor);
            actor.name = it.name;
            object.actor = actor;
            add_actor(film, actor);
            if it.type == {
              case "DELT";
                actor.kind = .DELT;
                data := find_resource(archive, it.name, "DELT");
                if !is_valid_delt(data) return false;
                array_add(*actor.frames, data);
              case "ANIM";
                actor.kind = .ANIM;
                if !read_anim(actor, find_resource(archive, it.name, "ANIM")) return false;
              case;
                actor.kind = .CUSTOM;
            }
          case .PALETTE;
            object.palette = New(Lfd_Palette);
            if !read_pltt(object.palette, find_resource(archive, it.name, "PLTT")) return false;
          case .SOUND;
            if !load_sounds continue;
            object.sound = load_sound(archive, it.name);
            if !object.sound return false;
        }
    }
    // Per actor, in film.actors' order: the cells it's shown in, where on the screen, and the
    // first it spans the screen in.
    shown := NewArray(film.actors.count, [] bool,, temp);
    places := NewArray(film.actors.count, [] Rect,, temp);
    spans_cell := NewArray(film.actors.count, s32,, temp);
    for * film.objects {
        if !it.actor || it.actor.kind == .CUSTOM continue;
        found, i := array_find(film.actors, it.actor);
        shown[i], places[i], spans_cell[i] = study_actor(film, it);
    }
    // Tiles of one background, scrolled and leapfrogged by the film, are shown together; a copy
    // of a picture never shown alongside it is not a tile (`tubecomp`'s planet has one never
    // shown at all).
    for i: 0..film.actors.count-1  for j: 0..film.actors.count-1 {
        a, b := film.actors[i], film.actors[j];
        if i == j || !a.frames.count || !b.frames.count || a.frames[0].data != b.frames[0].data continue;
        if is_shown_together(shown[i], shown[j])  a.tiled = true;
    }
    // In a wide view, actors shown together are drawn larger together, about the screen's
    // middle, when one of them spans the screen or has its art cut off by its edge: so patches
    // stay on what they're drawn over, and what moves over a background keeps its size against
    // it. So is an actor that takes another's place from one cell to the next (the general
    // turning to bow, a frame of its own), unless it covers the screen's width: the background
    // of a new shot. Growing actors one by one parted a talking head from its body; growing whole films
    // grew shots that needed none. Star fields (which wrap instead), told by the palette set
    // when they first span the screen, and background tiles don't join others; tiles that
    // aren't star fields grow with the shot they're in (below).
    star := NewArray(film.actors.count, bool,, temp);
    for film.actors  if it.spans_screen && it.frames.count {
        palette := get_film_palette_at(film, spans_cell[it_index]);
        star[it_index] = is_star_actor(it.frames[0], *palette);
    }
    group := NewArray(film.actors.count, s64,, temp);
    for * group  it.* = it_index;
    is_apart :: (i: s64) -> bool #expand { return star[i] || is_background_tile(film.actors[i]) || !film.actors[i].frames.count; }
    for cell: 0..film.cell_count-1 {
        first := -1;
        for film.actors {
            if !shown[it_index].count || !shown[it_index][cell] || is_apart(it_index) continue;
            if first < 0  first = it_index;
            else join_groups(group, first, it_index);
        }
        if cell == 0 continue;
        for i: 0..film.actors.count-1 {
            if !shown[i].count || !shown[i][cell - 1] || shown[i][cell] || is_apart(i) continue;
            for j: 0..film.actors.count-1 {
                if !shown[j].count || !shown[j][cell] || shown[j][cell - 1] || is_apart(j) continue;
                place := places[j][cell];
                if place.left <= 0 && place.right >= CANVAS_WIDTH continue;
                if !is_empty(get_intersection(places[i][cell - 1], place))  join_groups(group, i, j);
            }
        }
    }
    grows := NewArray(film.actors.count, bool,, temp);
    for film.actors  if !is_apart(it_index) && (it.spans_screen || it.cut_at_edge)  grows[find_group(group, it_index)] = true;
    for film.actors  it.grown = !is_apart(it_index) && grows[find_group(group, it_index)];
    // A background the film pans by tiles (madine1's hall behind Kyle) grows with the actors
    // shown on it, or they'd be larger than the room around them. Star fields wrap instead,
    // told apart as they're drawn.
    for tile, i: film.actors {
        if !is_background_tile(tile) || star[i] || !shown[i].count continue;
        for cell: 0..film.cell_count-1 {
            if !shown[i][cell] continue;
            for film.actors  if it.grown && shown[it_index].count && shown[it_index][cell]  tile.grown = true;
            if tile.grown break;
        }
    }
    for shot: PILLARBOXED_SHOTS  if equal_nocase(shot.film, name) {
        root := -1;
        if shot.actor {
            for film.actors  if equal_nocase(it.name, shot.actor) { root = find_group(group, it_index); break; }
            if root < 0 continue;
        }
        for film.actors {
            if root >= 0 && (is_apart(it_index) || find_group(group, it_index) != root) continue;
            it.pillarboxed = true;
            it.grown = false;
        }
    }
    quick_sort(film.frame_pairs, (a: Frame_Pair, b: Frame_Pair) -> s32 { return a.cell - b.cell; });
    return true;
}

film_free :: (film: *Film) {
    for film.actors { array_free(it.frames); free(it); }
    array_free(film.actors);
    for film.objects  if it.palette  free(it.palette);
    array_free(film.objects);
    array_free(film.frame_pairs);
    film.* = .{};
}

film_find_actor :: (film: *Film, kind: Actor_Kind, name: string) -> *Actor {
    for film.actors  if it.kind == kind && equal_nocase(it.name, name)  return it;
    return null;
}

// Back to cell 0: every actor hidden at the origin, the palette to come starting black, then
// cell 0's records.
film_rewind :: (film: *Film) {
    film.cell = 0;
    cut.palette.dest   = cut.palette.screen;
    cut.palette.source = cut.palette.screen;
    for * cut.palette.dest  it.* = .{};
    for * object: film.objects {
        object.offset = 0;
        a := object.actor;
        if a {
            a.frame = CANVAS_RECT;
            a.x, a.y, a.x_fract, a.y_fract = 0, 0, 0, 0;
            a.x_vel, a.y_vel, a.x_vel_fract, a.y_vel_fract = 0, 0, 0, 0;
            a.state, a.state_fract = 0, 0;
            a.state_vel, a.state_vel_fract = 0, 0;
            set_actor_z(film, a, 0);
            a.flip_h, a.flip_v = false, false;
            a.visible = false;
            a.var1, a.var2 = 0, 0;
            a.jumped = true;
            // The frame velocity stays: the original doesn't reset it.
        }
        if object.sound  rewind_sound(object.sound);
        if is_at_cell(film, object)  run_cell(film, object);
    }
    resolve_palette();
    film.cell += 1;
}

film_step :: (film: *Film) {
    if film.cell >= film.cell_count return;
    fading := is_fade_active();
    if !fading {
        cut.palette.dest   = cut.palette.screen;
        cut.palette.source = cut.palette.screen;
    }
    for film.actors  it.jumped = false;
    for * object: film.objects {
        if object.actor  update_actor(object.actor);
        if is_at_cell(film, object)  run_cell(film, object);
    }
    if !fading  resolve_palette();
    film.cell += 1;
}

// A custom actor's VAR1 is the music cue, sent every frame; the music ignores repeats.
film_send_cues :: (film: *Film) {
    for film.actors  if it.kind == .CUSTOM && it.var1  set_music_cue(max(it.var1, 0));
}

// The music cues the film sends in its cells before 'cells', as film_send_cues sends them
// after each, read from its custom actors' records; added to 'cues' unless repeats.
film_list_cues :: (film: *Film, cells: s32, cues: *[..] s32) {
    Custom :: struct { object: *Film_Object; at: s64; var1: s32; }
    customs: [..] Custom;
    customs.allocator = temp;
    for * film.objects  if it.actor && it.actor.kind == .CUSTOM  array_add(*customs, .{object = it});
    for cell: 0..min(cells, film.cell_count)-1 {
        for * c: customs {
            length, op, args := film_read_command(c.object.commands, c.at);
            if op != .TIMESTAMP || film_get_arg(args, 0) != cell continue;
            c.at += length;
            while true {
                length=, op=, args= = film_read_command(c.object.commands, c.at);
                if op == .TIMESTAMP || op == .END break;
                if op == .VAR1  c.var1 = film_get_arg(args, 0);
                c.at += length;
            }
        }
        for customs {
            if !it.var1 continue;
            cue := max(it.var1, 0);
            if !cues.count || cues.*[cues.count - 1] != cue  array_add(cues, cue);
        }
    }
}

// Larger z first, so smaller z draws on top; equal z keeps its order.
film_sort_actors :: (film: *Film) {
    if !film.sort return;
    film.sort = false;
    for i: 1..film.actors.count-1 {
        a := film.actors[i];
        j := i;
        while j > 0 && film.actors[j - 1].z < a.z {
            film.actors[j] = film.actors[j - 1];
            j -= 1;
        }
        film.actors[j] = a;
    }
}

film_draw :: (film: *Film) {
    for a: film.actors {
        if !a.visible || a.kind == .CUSTOM continue;
        clip := get_intersection(a.frame, CANVAS_RECT);
        if is_empty(clip) continue;
        if cut.crawl.actor == a {
            emit(.{kind = .CRAWL, crawl_offset = get_crawl_offset(*cut.crawl, a), actor = a});
            continue;
        }
        if a.state < 0 || a.state >= a.frames.count continue;
        delt := a.frames[a.state];
        mirror: s32;
        if a.flip_h {
            left, top, right, bottom := get_delt_bounds(delt);
            // The original's bounds are right and bottom exclusive: right + 1 + left - 1.
            mirror = right + left;
        }
        emit(.{kind = .DELT, delt = delt, x = a.x, y = a.y, clip = clip, flip = a.flip_h, mirror = mirror, actor = a, x_fract = a.x_fract, y_fract = a.y_fract, jumped = a.jumped});
    }
}

#scope_file

find_resource :: (archive: *Archive, name: string, type: string) -> [] u8 {
    entry := archive_find(archive, tprint("%.%", name, type));
    if !entry return .[];
    return entry.data;
}

// A count, then each cell's size and DELT.
read_anim :: (actor: *Actor, data: [] u8) -> bool {
    if data.count < 2 return false;
    count := get_s16(data, 0);
    at := 2;
    for 0..count-1 {
        if at + 4 > data.count return false;
        size := get_s32(data, at);
        at += 4;
        if size < 0 || at + size > data.count return false;
        cell := array_view(data, at, size);
        if !is_valid_delt(cell) return false;
        array_add(*actor.frames, cell);
        at += size;
    }
    return true;
}

// First and last index, then 8-bit RGB triples, cut to the DAC's 6 bits. Cycling ranges
// follow; no cutscene uses them.
read_pltt :: (palette: *Lfd_Palette, data: [] u8) -> bool {
    if data.count < 2 return false;
    palette.first = data[0];
    palette.last  = data[1];
    if palette.last < palette.first || 2 + (palette.last - palette.first + 1) * 3 > data.count return false;
    for i: palette.first..palette.last {
        at := 2 + (i - palette.first) * 3;
        palette.colors[i] = .{data[at] >> 2, data[at + 1] >> 2, data[at + 2] >> 2};
    }
    return true;
}

// Kept in order by insertion: larger z first, a new actor after those of its z or larger.
add_actor :: (film: *Film, actor: *Actor) {
    at := 0;
    while at < film.actors.count && actor.z < film.actors[at].z  at += 1;
    array_insert_at(*film.actors, actor, at);
}

set_actor_z :: (film: *Film, a: *Actor, z: s32) {
    a.z = z;
    film.sort = true;
}

is_at_cell :: (film: *Film, object: *Film_Object) -> bool {
    length, op, args := film_read_command(object.commands, object.offset);
    return op == .TIMESTAMP && film_get_arg(args, 0) == film.cell;
}

// Runs the records after the timestamp, up to the next timestamp or the end.
run_cell :: (film: *Film, object: *Film_Object) {
    length := film_read_command(object.commands, object.offset);
    object.offset += length;
    while true {
        length=, op, args := film_read_command(object.commands, object.offset);
        if op == .TIMESTAMP || op == .END break;
        if object.block == {
            case .ACTOR;   run_actor_command(film, object.actor, op, args);
            case .VIEW;    run_view_command(op, args);
            case .PALETTE; if op == .PALETTE_SET  set_dest_palette(object.palette);
            case .SOUND;   run_sound_command(object.sound, op, args);
        }
        object.offset += length;
    }
}

// Shots of people in a room, where growing to a wide view's edges would cut off their heads
// (madine1's Mohc and Vader): kept to the 4:3 area instead, between bars. A shot is the actors
// shown together with the one named, usually its background; none named, the whole film. Told
// by eye: the art can't tell a head near the top from a ship's hull, which grows well.
Pillarboxed_Shot :: struct { film: string; actor: string; }
PILLARBOXED_SHOTS :: Pillarboxed_Shot.[
    .{"madine1", "hall2x"},         // Mohc, Vader and Kyle; not the hall before.
    .{"award2", ""},
    .{"pit", ""},                   // Its subtitles, at the bottom, would be cut off.
];

// A tile of a background the film scrolls itself (kflyby's star fields): its picture shown by
// other actors shown with it, and covering the screen or cut by its edge. Patches can share a picture too
// (the general's eyes), and grow with the rest.
is_background_tile :: (actor: *Actor) -> bool {
    return actor.tiled && (actor.spans_screen || actor.cut_at_edge);
}

// Plays the actor's own records through the film on a copy (positions, velocities, frames,
// clips, visibility, nothing else): whether it ever spans the screen's width or is cut off by
// its edge, which cells it's shown in, and which of its frames are shown one after the other
// (but not flipped, which in-betweens leave alone).
study_actor :: (film: *Film, object: *Film_Object) -> shown: [] bool, places: [] Rect, spans_cell: s32 {
    shown := NewArray(film.cell_count, bool,, temp);
    places := NewArray(film.cell_count, Rect,, temp);
    spans_cell: s32 = -1;
    a := object.actor.*;
    a.frame = CANVAS_RECT;
    extents := NewArray(a.frames.count, Rect,, temp);
    for a.frames  extents[it_index] = get_delt_extent(it);
    // Each frame's first and last columns, once looked at: an actor at the screen's edge for
    // a whole film (a star field, the crawl) would decode the same frame every cell.
    checked := NewArray(a.frames.count, [2] bool,, temp);
    spans := false;
    cut := false;
    last: s32 = -1;         // The frame shown the cell before, if any.
    last_flipped: bool;
    at: s64;
    for cell: 0..film.cell_count-1 {
        if cell > 0  update_actor(*a);
        length, op, args := film_read_command(object.commands, at);
        if op == .TIMESTAMP && film_get_arg(args, 0) == cell {
            at += length;
            while true {
                length=, op=, args= = film_read_command(object.commands, at);
                if op == .TIMESTAMP || op == .END break;
                run_actor_command(film, *a, op, args);
                at += length;
            }
        }
        if !a.visible || a.state < 0 || a.state >= a.frames.count || is_empty(extents[a.state]) {
            last = -1;
            continue;
        }
        if last >= 0 && last != a.state && !last_flipped && !a.flip_h  add_frame_pair(film, cell, a.frames[last], a.frames[a.state]);
        last, last_flipped = a.state, a.flip_h;
        e := extents[a.state];
        left := a.x + e.left;
        if a.flip_h {
            bounds_left, top, bounds_right := get_delt_bounds(a.frames[a.state]);
            left = bounds_right + bounds_left + a.x - (e.right - 1);
        }
        right := left + e.right - e.left;
        top := a.y + e.top;
        bottom := top + e.bottom - e.top;
        clip := get_intersection(a.frame, CANVAS_RECT);
        places[cell] = get_intersection(.{left, top, right, bottom}, clip);
        shown[cell] = !is_empty(places[cell]);
        if !spans && max(left, clip.left) <= 0 && min(right, clip.right) >= CANVAS_WIDTH {
            spans = true;
            spans_cell = cell;
        }
        // Art reaching the screen's edge or past it, cut off there: rendered only a little
        // way past the screen, if at all (General Mohc's back views go 23 pixels past it).
        // Flipped, the frame's right column is on the screen's left.
        last_column := e.right - e.left - 1;
        check_column :: (is_last: bool) #expand {
            k := cast(s64) is_last;
            if !checked[a.state][k] {
                checked[a.state][k] = true;
                cut = is_cut_column(a.frames[a.state], e, ifx is_last then last_column else 0);
            }
        }
        if !cut && left <= 0              check_column(a.flip_h);
        if !cut && right >= CANVAS_WIDTH  check_column(!a.flip_h);
    }
    object.actor.spans_screen = spans;
    object.actor.cut_at_edge = cut;
    return shown, places, spans_cell;
}

is_shown_together :: (a: [] bool, b: [] bool) -> bool {
    for a  if it && b[it_index]  return true;
    return false;
}

find_group :: (group: [] s64, i: s64) -> s64 {
    while group[i] != i  i = group[i];
    return i;
}

join_groups :: (group: [] s64, a: s64, b: s64) {
    group[find_group(group, b)] = find_group(group, a);
}

// The palette the film has set by the given cell, its palettes' records played cell by cell
// from the first palette's colors (what the screen holds before the film is unknown here).
get_film_palette_at :: (film: *Film, cell: s32) -> Palette {
    colors: [256] Rgb;
    for film.objects  if it.palette { colors = it.palette.colors; break; }
    offsets := NewArray(film.objects.count, s64,, temp);
    for c: 0..cell  for * object, i: film.objects {
        if !object.palette continue;
        length, op, args := film_read_command(object.commands, offsets[i]);
        if op != .TIMESTAMP || film_get_arg(args, 0) != c continue;
        offsets[i] += length;
        while true {
            length=, op=, args= = film_read_command(object.commands, offsets[i]);
            if op == .TIMESTAMP || op == .END break;
            if op == .PALETTE_SET  for object.palette.first..object.palette.last  colors[it] = object.palette.colors[it];
            offsets[i] += length;
        }
    }
    return widen_palette(colors);
}

is_star_actor :: (delt: [] u8, palette: *Palette) -> bool {
    e := get_delt_extent(delt);
    if is_empty(e) return false;
    width, height := e.right - e.left, e.bottom - e.top;
    pixels := NewArray(width * height, u8,, temp);
    drawn := NewArray(width * height, bool,, temp);
    draw_delt(pixels, delt, -e.left, -e.top, .{0, 0, width, height}, width = width, drawn = drawn);
    return is_star_field(e, pixels, drawn, palette);
}

// Whether a frame's outermost column (counted from its extent's left) is a cut: one unbroken
// run of drawn pixels at least 6 long and a tenth of the frame's height. A rounded outline only
// touches its outermost column at a tip, 1 to 5 pixels in the retail cutscenes; cuts run 13 and
// up (a shoulder, a hull, a planet's limb).
is_cut_column :: (delt: [] u8, e: Rect, column: s32) -> bool {
    width, height := e.right - e.left, e.bottom - e.top;
    pixels := NewArray(width * height, u8,, temp);
    drawn := NewArray(width * height, bool,, temp);
    draw_delt(pixels, delt, -e.left, -e.top, .{0, 0, width, height}, width = width, drawn = drawn);
    run, longest := 0, 0;
    for y: 0..height-1 {
        run = ifx drawn[y * width + column] then run + 1 else 0;
        longest = max(longest, run);
    }
    return longest >= max(6, height / 10);
}

add_frame_pair :: (film: *Film, cell: s32, from: [] u8, to: [] u8) {
    for film.frame_pairs  if it.from.data == from.data && it.to.data == to.data  return;
    array_add(*film.frame_pairs, .{cell, from, to});
}

run_actor_command :: (film: *Film, a: *Actor, op: Film_Op, args: [] u8) {
    arg :: (i: s64) -> s32 #expand { return film_get_arg(args, i); }
    if op == {
        case .POS;    a.x, a.y, a.x_fract, a.y_fract = arg(0), arg(1), arg(2), arg(3); a.jumped = true;
        case .VEL;    a.x_vel, a.y_vel, a.x_vel_fract, a.y_vel_fract = arg(0), arg(1), arg(2), arg(3);
        case .Z;      set_actor_z(film, a, arg(0));
        case .STATE;  a.state, a.state_fract = arg(0), arg(1);
        case .STATEV; a.state_vel, a.state_vel_fract = arg(0), arg(1);
        case .VAR1;   a.var1 = arg(0);
        case .VAR2;   a.var2 = arg(0);
        case .CLIP;   a.frame = .{arg(0), arg(1), arg(2), arg(3)};
        case .CLIPV;  a.frame_vel = .{arg(0), arg(1), arg(2), arg(3)};
        case .SHOW;   a.visible = arg(0) != 0;
        case .FLIP;   a.flip_h, a.flip_v = arg(0) != 0, arg(1) != 0;
    }
}

run_view_command :: (op: Film_Op, args: [] u8) {
    if op == {
      case .SETRGB;
        // Bytes, not words.
        if args.count < 5 return;
        set_dest_color(args[0], args[1], .{args[2], args[3], args[4]});
      case .DEFPAL;
        // There's no default palette for cutscene films; this only clears.
        set_dest_color(0, 255, .{});
      case .FADE;
        set_film_fade(cast(Fade_Type) film_get_arg(args, 0), cast(Color_Fade) film_get_arg(args, 1));
    }
}

set_dest_palette :: (palette: *Lfd_Palette) {
    for i: palette.first..palette.last  cut.palette.dest[i] = palette.colors[i];
}

set_dest_color :: (first: s32, last: s32, color: Rgb) {
    for i: first..min(last, 255)  cut.palette.dest[i] = color;
}

// Moves by the velocities, 1/256 pixel fractions carried over; the same for the frame state
// (an ANIM's cell), which wraps around the cells. Divisions round toward zero, as in C.
update_actor :: (a: *Actor) {
    a.x_fract += a.x_vel_fract;
    a.y_fract += a.y_vel_fract;
    a.x += a.x_vel + a.x_fract / 256;
    a.y += a.y_vel + a.y_fract / 256;
    while a.x_fract >=  256  a.x_fract -= 256;
    while a.y_fract >=  256  a.y_fract -= 256;
    while a.x_fract <= -256  a.x_fract += 256;
    while a.y_fract <= -256  a.y_fract += 256;

    a.frame.left   += a.frame_vel.left;
    a.frame.top    += a.frame_vel.top;
    a.frame.right  += a.frame_vel.right;
    a.frame.bottom += a.frame_vel.bottom;

    if a.kind != .ANIM return;
    a.state_fract += a.state_vel_fract;
    a.state += a.state_vel + a.state_fract / 256;
    while a.state_fract >=  256  a.state_fract -= 256;
    while a.state_fract <= -256  a.state_fract += 256;
    count := cast(s32) a.frames.count;
    if count {
        while a.state < 0      a.state += count;
        while a.state >= count a.state -= count;
    } else {
        a.state = 0;
    }
}

#import "Basic";
#import "Sort";
#import "String";
#import "engine/dfArchive";
