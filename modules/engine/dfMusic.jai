// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The game's music: each level has a stalk song and a fight song, and the game moves between
// them as the fighting starts and stops. Following the original game's code throughout.
//
// A change of state doesn't cut the music. The old song plays on to a "to B" style marker,
// jumps into the matching transition chunk (notes ringing on), plays that until it reaches a
// "start new" marker, then starts the new song sharing the old one's parts, stops the old one a
// quarter second later and jumps the new one to a randomly picked entry point. The markers
// along the way ("from stalk 2,17,32", "fight trans 10") list the measures to pick from.
//
// The song table also names boss songs for five levels, which get loaded, but the original
// never sets the boss state, so they never play.
//
// The triggers run on the audio thread. Everything else takes audio_lock.

Music_State :: enum s32 {
    OFF     :: 0;
    BOSS    :: 1;
    FIGHT   :: 2;
    ENGAGE  :: 3;
    STALK   :: 4;
    EXPLORE :: 5;
}

MUSIC_LEVEL_COUNT :: 14;

// Game ticks, at the original's rate: 3 seconds of fight music per alert, at most 6 ahead.
MUSIC_FIGHT_EXTEND :: 436;

// Once, before anything else (and after imuse_init).
music_init :: () {
    audio_lock();
    defer audio_unlock();
    music = .{};
    music.saved_measure = 1;
    music.saved_beat    = 4;
}

// Loads the level's songs and starts the stalk music. Levels count from 1.
music_start_level :: (level: int) {
    audio_lock();
    defer audio_unlock();
    set_level(level);
    set_state(.STALK);
}

// Loads a stalk and a fight song by name and starts the stalk music, as a level's music starts.
// For tools, and for songs the level table doesn't name.
music_start_songs :: (stalk: string, fight: string) {
    audio_lock();
    defer audio_unlock();
    names: [5] string;
    names[Music_State.STALK - 1] = stalk;
    names[Music_State.FIGHT - 1] = fight;
    load_songs(0, names);
    set_state(.STALK);
}

music_stop :: () {
    audio_lock();
    defer audio_unlock();
    set_state(.OFF);
    none: [5] string;
    load_songs(0, none);
}

music_set_state :: (state: Music_State) {
    audio_lock();
    defer audio_unlock();
    set_state(state);
}

// An alert: an enemy saw the player. Alerts build up a timer: the first sets it 873 ticks
// behind now, each next one within 1166 ticks adds 436, and fight music starts once the timer
// passes now (four alerts in a row), lasting 436 ticks past the latest alert; music_update
// ends it. 'now' is the game's tick count.
music_start_fight :: (now: int) {
    audio_lock();
    defer audio_unlock();
    if now - music.fight_timer < 1166  music.fight_timer += MUSIC_FIGHT_EXTEND;
    else                               music.fight_timer = now - 873;

    if now < music.fight_timer {
        music.fight_ends = now + MUSIC_FIGHT_EXTEND;
        if !music.fight_wanted {
            music.fight_wanted = true;
            set_state(.FIGHT);
        }
    }
}

// Enemies still fighting: extends the fight music if it's on.
music_sustain_fight :: (now: int) {
    if music.fight_wanted  music_start_fight(now);
}

// Call every game tick: when the fight runs out, back to stalking.
music_update :: (now: int) {
    audio_lock();
    defer audio_unlock();
    if !music.fight_ends || now < music.fight_ends return;
    music.fight_ends = 0;
    set_state(.STALK);
    music.fight_wanted = false;
}

Music_Step :: enum u8 {
    NONE;
    WAITING;     // For a "to X" marker in the old song.
    TRANSITION;  // Playing the transition chunk, until "start new".
    ENTERING;    // The new song plays; its first "from ..." marker picks where it continues.
}

Music_Status :: struct {
    level:      int;  // 0 for songs started by name.
    stalk_song: string;
    fight_song: string;
    state:      Music_State;
    old_state:  Music_State;
    step:       Music_Step;
    fight:      bool;  // Fight music wanted, until the fight timer runs out.
    last_transition: int;  // Measures picked, 0 before any.
    last_entry:      int;
}

music_get_status :: () -> Music_Status {
    audio_lock();
    defer audio_unlock();
    s: Music_Status;
    s.level     = music.level;
    s.stalk_song = get_state_song(.STALK);
    s.fight_song = get_state_song(.FIGHT);
    s.state     = music.state;
    s.old_state = music.old_state;
    s.fight     = music.fight_wanted;
    s.last_transition = music.last_transition;
    s.last_entry      = music.last_entry;
    if      imuse_count_triggers(proc = wait_for_transition)  s.step = .WAITING;
    else if imuse_count_triggers(proc = play_transition)      s.step = .TRANSITION;
    else if imuse_count_triggers(proc = enter_new_song)       s.step = .ENTERING;
    return s;
}

// The original's random number generator: two 31-bit shift registers stepped against each
// other. Exposed for tests.
music_pick_random :: (low: int, high: int) -> int {
    r := *music.random;
    if !r.seeded {
        // The original seeds each register with the other one's address, one of them
        // complemented. Those depended on where DOS/4GW loaded the program; these are the
        // addresses the executable is linked at.
        r.seeded = true;
        r.b = 0xFE196;
        r.a = ~cast(u32) 0xFE19A;
    }
    for 1..23 {
        carry := cast(u32) ((r.b & 0x4000_0000 != 0) != (r.a & 0x2000_0000 == 0));
        r.b = (r.b << 1) + carry;
    }
    for 1..37 {
        carry := cast(u32) ((r.a & 0x4000_0000 != 0) != (r.b & 0x2000_0000 == 0));
        r.a = (r.a << 1) + carry;
    }
    mix := cast(int) cast,trunc(u16) (r.a + r.b);
    return (((high - low + 1) * mix) >> 16) + low;
}

#scope_file

// Per level: boss, fight, engage, stalk and explore songs. Only fight and stalk ever play.
LEVEL_SONGS : [MUSIC_LEVEL_COUNT][5] string : .[
    .["",        "fight-01", "", "stalk-01", ""],
    .["",        "fight-02", "", "stalk-02", ""],
    .["",        "fight-03", "", "stalk-03", ""],
    .["",        "fight-04", "", "stalk-04", ""],
    .["boss-05", "fight-05", "", "stalk-05", ""],
    .["",        "fight-06", "", "stalk-06", ""],
    .["",        "fight-07", "", "stalk-07", ""],
    .["boss-08", "fight-08", "", "stalk-08", ""],
    .["",        "fight-09", "", "stalk-09", ""],
    .["boss-10", "fight-10", "", "stalk-10", ""],
    .["boss-11", "fight-11", "", "stalk-11", ""],
    .["",        "fight-12", "", "stalk-12", ""],
    .["",        "fight-13", "", "stalk-13", ""],
    .["boss-14", "fight-14", "", "stalk-14", ""],
];

music: struct {
    level:     int;
    songs:     [5] [SONG_NAME_MAX] u8;  // Per state from boss to explore, empty for none.
    song_name_counts: [5] int;
    state:     Music_State;
    old_state: Music_State;
    old_song:  Imuse_Song;
    new_song:  Imuse_Song;

    transition_chunk: int;  // 0 for chunk 2 ("to B"), 1 for chunk 3...
    saved_measure:    int;
    saved_beat:       int;
    last_entries:     [6] int;  // Per state, so an entry point doesn't repeat right away.

    fight_timer:  int;
    fight_ends:   int;  // Game tick to fall back to stalking, or 0.
    fight_wanted: bool;

    numbers: [32] u8;  // Measures read from a marker, zero-terminated.

    random: struct {
        seeded: bool;
        a, b:   u32;
    };

    // For tools.
    last_transition: int;
    last_entry:      int;
};

SONG_NAME_MAX :: 12;

get_state_song :: (state: Music_State) -> string {
    if state == .OFF return "";
    i := cast(int) state - 1;
    return .{music.song_name_counts[i], music.songs[i].data};
}

set_level :: (level: int) {
    if level < 0 || level > MUSIC_LEVEL_COUNT || level == music.level return;
    names: [5] string;
    if level  names = LEVEL_SONGS[level - 1];
    load_songs(level, names);
}

load_songs :: (level: int, names: [5] string) {
    music.level = level;
    imuse_stop_all();
    imuse_unload_all();
    music.state = .OFF;
    for name, i: names {
        n := min(name.count, SONG_NAME_MAX);
        memcpy(music.songs[i].data, name.data, n);
        music.song_name_counts[i] = n;
        if n  imuse_load_midi(get_state_song(cast(Music_State) (i + 1)));
    }
}

// A new state doesn't change the song right away: the current one carries on to its next
// transition point (see wait_for_transition). With a trigger already set, the transition in
// progress continues and picks up the new state when it gets there.
set_state :: (state: Music_State) {
    if !get_state_song(.STALK) || state == music.state return;  // No music loaded, or no change.
    if state == .OFF {
        music.state = state;
        imuse_stop_all();
        return;
    }

    song := imuse_find_midi(get_state_song(state));
    if !song {
        log_error("No music for state %.", state);
        return;
    }
    if music.state == .OFF {
        imuse_play(song, 64);
    } else if !imuse_count_triggers() {
        music.old_song = imuse_find_midi(get_state_song(music.state));
        imuse_set_trigger(music.old_song, 0, wait_for_transition);
    }
    music.old_state = music.state;
    music.state = state;
}

// In the old song: "to B" jumps into transition chunk 2, "to C" into 3... "to Bslow" marks a
// transition only for moving to a calmer state. It's matched where it is, right after the
// letter: "to C slow" counts as a plain "to C", as in the original.
wait_for_transition :: (song: Imuse_Song, marker: Imuse_Marker) {
    text := marker.text;
    if marker.id != MARKER_TEXT || !begins_with(text, "to ") || text.count < 4  return;

    slow := text.count >= 8 && slice(text, 4, 4) == "slow";
    calmer := music.state > music.old_state && music.state != .FIGHT;
    skip: bool;
    if slow  skip = !calmer;
    else     skip = calmer || music.state == music.old_state;
    if skip {
        imuse_set_trigger(music.old_song, 0, wait_for_transition);
        return;
    }

    _, music.saved_measure, music.saved_beat = imuse_get_position(music.old_song);
    letter := cast(int) text[3];
    music.transition_chunk = letter - #char "A";
    imuse_jump(music.old_song, letter - #char "@", 1, 1, 0, sustain = true);
    imuse_set_trigger(music.old_song, 0, play_transition);
}

// In the transition chunk: "stalk trans 10" picks a measure to continue from, for the state
// being moved to; "start new" brings in the new song.
play_transition :: (song: Imuse_Song, marker: Imuse_Marker) {
    measures := read_marker_measures(marker);
    if measures {
        pick := measures[music_pick_random(0, measures.count - 1)];
        music.last_transition = pick;
        imuse_jump(music.old_song, music.transition_chunk + 1, pick - 1, 4, 300, sustain = true);
        imuse_set_trigger(music.old_song, 0, play_transition);
    } else if marker.id == MARKER_TEXT && marker.text == "start new" {
        music.new_song = imuse_find_midi(get_state_song(music.state));
        if music.old_song == music.new_song {
            // Back to the same song: return to where it left.
            imuse_jump(music.new_song, 1, music.saved_measure, music.saved_beat, 300, sustain = true);
        } else {
            imuse_stop(music.old_song, 15);
            imuse_play(music.new_song, 64);
            imuse_share_parts(music.old_song, music.new_song);
            imuse_set_trigger(music.new_song, 0, enter_new_song);
        }
    } else {
        imuse_set_trigger(music.old_song, 0, play_transition);
    }
}

// In the new song: "from stalk 2,17,32" picks the measure to continue from, avoiding the last
// one picked for this state (with two tries); "clear callback" ends the wait.
enter_new_song :: (song: Imuse_Song, marker: Imuse_Marker) {
    measures := read_marker_measures(marker);
    if measures {
        last := music.last_entries[music.state];
        pick := measures[music_pick_random(0, measures.count - 1)];
        if pick == last  pick = measures[music_pick_random(0, measures.count - 1)];
        if pick == last  pick = measures[music_pick_random(0, measures.count - 1)];
        music.last_entries[music.state] = pick;
        music.last_entry = pick;
        imuse_jump(music.new_song, 1, pick - 1, 4, 400, sustain = false);
    } else if !(marker.id == MARKER_TEXT && marker.text == "clear callback") {
        imuse_set_trigger(music.new_song, 0, enter_new_song);
    }
}

// The measures a marker lists for the current move: "from <old state> ..." or "<new state>
// ..." ("boss trans ..." for boss), or none. Numbers are read past any other characters and
// kept to a byte each, as in the original.
read_marker_measures :: (marker: Imuse_Marker) -> [] u8 {
    if marker.id != MARKER_TEXT return .[];
    text := marker.text;

    state := music.state;
    if begins_with(text, "from ") {
        advance(*text, 5);
        state = music.old_state;
    }
    from := state != music.state;

    prefix: string;
    if state == {
        case .BOSS;    prefix = "boss ";
        case .FIGHT;   prefix = "fight ";
        case .ENGAGE;  prefix = "engage ";
        case .STALK;   prefix = "stalk ";
        case .EXPLORE; prefix = "explore ";
        case;          return .[];
    }
    if !begins_with(text, prefix) return .[];
    advance(*text, prefix.count);
    if state == .BOSS && !from  advance(*text, min(text.count, "trans ".count));

    count := 0;
    while count < music.numbers.count - 1 {
        number := read_number(*text);
        music.numbers[count] = cast,trunc(u8) number;
        if !music.numbers[count] break;
        count += 1;
    }
    return array_view(music.numbers, 0, count);
}

// The next run of digits, or 0 at the end.
read_number :: (text: *string) -> int {
    while text.count && !is_digit(text.*[0])  advance(text);
    number := 0;
    while text.count && is_digit(text.*[0]) {
        number = number * 10 + text.*[0] - #char "0";
        advance(text);
    }
    return number;
}

#import "Basic";
#import "String";
#import "engine/dfAudio";
#import "engine/dfIMuse";
