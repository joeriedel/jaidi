// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// What the debug panel shows of the world that the rest of the API doesn't give.

// Something that fights: an actor, or one of the enemies with logic of their own.
World_Mob :: struct {
    object:   s32;
    kind:     string;
    art:      string;   // Its WAX, FME or 3DO.
    position: Fixed3;
    sector:   s32;
    hp:       Fixed;
    state:    string;
}

// Every one alive, in temporary storage.
world_list_mobs :: () -> [..] World_Mob {
    mobs: [..] World_Mob;
    mobs.allocator = temp;
    add :: (mobs: *[..] World_Mob, object: s32, kind: string, hp: Fixed, state: string) {
        if object < 0 || object >= world.objects.count return;
        o := world.objects[object];
        if !o || !o.used return;
        array_add(mobs, .{object, kind, get_object_art_name(o), o.position, o.sector, hp, state});
    }
    for world.actors {
        if !it continue;
        state: string;
        if      it.flags & ACTOR_SEES_PLAYER  state = "sees player";
        else if it.flags & ACTOR_IDLE         state = "idle";
        else                                  state = "alerted";
        if it.flags & ACTOR_MOVING  state = tprint("%, moving", state);
        add(*mobs, it.object, "actor", world_get_actor_hp(it), state);
    }
    for world.turrets        if it  add(*mobs, it.object, "turret",       it.hp, tprint("%", it.state));
    for world.mousebots      if it  add(*mobs, it.object, "mousebot",     it.hp, tprint("%", it.state));
    for world.welders        if it  add(*mobs, it.object, "welder",       it.hp, tprint("%", it.state));
    for world.dark_troopers  if it  add(*mobs, it.object, "dark trooper", it.hp, tprint("%", it.state));
    for world.boba_fetts     if it  add(*mobs, it.object, "Boba Fett",    it.hp, tprint("%", it.state));
    for world.kell_dragons   if it  add(*mobs, it.object, "kell dragon",  it.hp, tprint("%", it.state));
    return mobs;
}

// The name of the art an object shows, or its class when it shows none.
world_get_object_art_name :: (object: s32) -> string {
    if object < 0 || object >= world.objects.count || !world.objects[object] return "";
    return get_object_art_name(world.objects[object]);
}

#scope_file

get_object_art_name :: (o: *Object) -> string {
    names: [] string;
    if o.class == {
        case .SPRITE; names = world.level_objects.sprites;
        case .FRAME;  names = world.level_objects.frames;
        case .MODEL;  names = world.level_objects.pods;
    }
    if o.data >= 0 && o.data < names.count return names[o.data];
    return tprint("%", o.class);
}
