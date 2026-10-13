// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The two text files that tie cutscenes together: CUTSCENE.LST lists the scenes (which LFD and
// FILM, how fast, what comes next, which music sequence starts), and CUTMUSE.TXT lists each
// music sequence's cue points.

Cutscene_Entry :: struct {
    id:      s32;
    archive: string;        // "logo.lfd"
    film:    string;        // "logo"
    speed:   s32;           // Frames per second, nominally; see FRAME_DELAYS.
    next:    s32;           // Scene after this one ends, or the space bar; 0 ends the cutscene.
    skip:    s32;           // Scene Esc or Enter goes to; 0 ends the cutscene.
    music:   s32;           // CUTMUSE.TXT sequence to start, 0 to keep the current one.
    volume:  s32;           // Music volume in percent of the player's setting.
}

Music_Cue :: struct {
    song: string;
    // From the line after the cue: chunk letters or a command character, and measures.
    from_chunk: u8;
    from_measure: s32;
    to_chunk: u8;
    to_measure: s32;
}

Music_Sequence :: struct {
    id:   s32;
    cues: [..] Music_Cue;   // Cue 1 is cues[0].
}

// "CUT 1.0", "CUTS <count>", then a line per scene:
//   <id>: <archive.lfd> <film> <speed> <next> <skip> <music> <volume>
// '#' starts a comment. Lines that don't read are skipped, as the original logs and skips them.
cutscene_list_parse :: (text: string) -> [..] Cutscene_Entry {
    entries: [..] Cutscene_Entry;
    for raw: split(text, "\n",, temp) {
        line := trim(cut_comment(raw, "#"));
        if !line || begins_with(line, "CUT") continue;
        colon := find_index_from_left(line, #char ":");
        if colon < 0 continue;

        entry: Cutscene_Entry;
        ok: bool;
        entry.id, ok = string_to_int(trim(slice(line, 0, colon)), T = s32);
        if !ok continue;
        values := split_words(slice(line, colon + 1, line.count - colon - 1));
        if values.count < 7 continue;
        numbers: [5] s32;
        for i: 0..4 {
            numbers[i], ok = string_to_int(values[2 + i], T = s32);
            if !ok break;
        }
        if !ok continue;
        entry.archive = copy_string(values[0]);
        entry.film    = copy_string(values[1]);
        entry.speed, entry.next, entry.skip, entry.music, entry.volume = numbers[0], numbers[1], numbers[2], numbers[3], numbers[4];
        array_add(*entries, entry);
    }
    return entries;
}

cutscene_list_free :: (entries: *[..] Cutscene_Entry) {
    free_entries(entries);
}

// "SEQUENCE: <n>" starts a sequence; each "CUE: <song>" line is followed by a line of four
// values: <chunk or command> <measure> <chunk> <measure>. "//" and '#' start comments.
cutmuse_parse :: (text: string) -> [..] Music_Sequence {
    sequences: [..] Music_Sequence;
    current: *Music_Sequence;
    pending: *Music_Cue;
    for raw: split(text, "\n",, temp) {
        line := trim(cut_comment(cut_comment(raw, "//"), "#"));
        if !line continue;
        if begins_with(line, "SEQUENCE:") {
            current = array_add(*sequences);
            current.id = xx string_to_int(trim(slice(line, 9, line.count - 9)));
            pending = null;
        } else if begins_with(line, "CUE:") {
            if !current continue;
            pending = array_add(*current.cues);
            pending.song = copy_string(trim(slice(line, 4, line.count - 4)));
        } else if pending {
            words := split_words(line);
            parts: [4] string;
            for words  if it_index < 4  parts[it_index] = it;
            pending.from_chunk   = ifx parts[0] then parts[0][0] else #char "0";
            pending.from_measure = xx string_to_int(parts[1]);
            pending.to_chunk     = ifx parts[2] then parts[2][0] else #char "0";
            pending.to_measure   = xx string_to_int(parts[3]);
            pending = null;
        }
    }
    return sequences;
}

cutmuse_free :: (sequences: *[..] Music_Sequence) {
    for * sequences.* {
        for cue: it.cues  free(cue.song);
        array_free(it.cues);
    }
    array_reset(sequences);
}

#scope_file

// Words separated by spaces or tabs, in temporary storage.
split_words :: (line: string) -> [..] string {
    words: [..] string;
    words.allocator = temp;
    rest := line;
    while true {
        while rest && (rest[0] == #char " " || rest[0] == #char "\t" || rest[0] == #char "\r")  advance(*rest);
        if !rest break;
        count := 0;
        while count < rest.count && rest[count] != #char " " && rest[count] != #char "\t" && rest[count] != #char "\r"  count += 1;
        array_add(*words, slice(rest, 0, count));
        advance(*rest, count);
    }
    return words;
}

cut_comment :: (line: string, marker: string) -> string {
    at := find_index_from_left(line, marker);
    if at < 0 return line;
    return slice(line, 0, at);
}

free_entry :: (entry: *Cutscene_Entry) {
    free(entry.archive);
    free(entry.film);
}

free_entries :: (entries: *[..] Cutscene_Entry) {
    for * entries.*  free_entry(it);
    array_reset(entries);
}

#import "Basic";
#import "String";
