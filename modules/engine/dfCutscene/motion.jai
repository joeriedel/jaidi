// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// In-betweens for ANIMs whose whole picture moves from one frame to the next. Many cutscene
// ANIMs are rendered camera moves (something zooming toward the viewer, rising into view,
// flying past), where each frame is the one before zoomed and shifted. For two frames of an actor
// shown one after the other, the zoom and shift taking the first's picture onto the second's
// (p to zoom p + shift, in the actor's own pixels) are fitted; the smooth path then draws both
// carried part of the way toward each other and blended. A pair the fit doesn't explain well is
// crossfaded in place, which for neighbouring frames of one ANIM is far smoother than a step.
//
// Which pairs a scene shows is known when its film loads (study_actor plays each actor through
// the film), so they're all fitted then, in the order they'll be shown; or before a cutscene
// starts, for every scene it chains to (cutscene_prepare_fits). Fits take some milliseconds
// each, so they run on a thread that lives from cutscene_init to cutscene_shutdown, and a pair
// playback reaches before its fit is in holds. A pair is known by its LFD and the two DELTs'
// offsets in it, which hold however often the LFD is opened, so a fit is made once and kept
// until shutdown: a few numbers each. The frames go to the thread decoded, in a batch per film,
// freed when its last fit is done.
//
// The thread also builds the text crawl's distance field (build_crawl_field), about a second
// in the unoptimized build, queued with its scene's fits so it's ready when the crawl starts;
// the crawl waits for it if not. It's kept, by LFD and DELT like a fit, until shutdown.

// Fixed-step runs (screenshots, the diff) would outrun the fits; waiting for them, they come
// out the same every time.
cutscene_set_waiting_for_fits :: (waiting: bool) {
    fitter.waiting = waiting;
}

// The scene's in-between fits: how many are done, how many of those are warped (the rest are
// crossfaded), and how many there are.
cutscene_get_fit_progress :: () -> done: int, used: int, total: int {
    collect_motions();
    if !cut.archive return 0, 0, 0;
    done, used: int;
    for cut.film.frame_pairs {
        m := find_motion(cut.archive, it.from, it.to);
        if !m continue;
        if m.fitted  done += 1;
        if m.good    used += 1;
    }
    return done, used, cut.film.frame_pairs.count;
}

// Fits for every scene the cutscene starting at 'first' chains to, so it can play with all its
// in-betweens from the start, in place of any still waiting for another. Loads each film
// without its sounds.
cutscene_prepare_fits :: (first: s32) {
    if !fitter.started return;
    cutscene_drop_fits();
    seen: [..] s32;
    seen.allocator = temp;
    id := first;
    while id > 0 && !array_find(seen, id) {
        array_add(*seen, id);
        entry := find_scene(id);
        if !entry break;
        archive, ok := archive_open(get_scene_archive_path(entry));
        if ok {
            film: Film;
            if film_load(*film, archive, entry.film, load_sounds = false) {
                queue_film_motions(*film, archive);
                actor := get_crawl_actor(entry, *film);
                if actor  queue_crawl_field(archive, actor);
            }
            film_free(*film);
            archive_close(archive);
        }
        id = entry.next;
    }
}

// How many of the fits for the cutscene starting at 'first' are done, of how many; after
// cutscene_prepare_fits.
cutscene_get_prepared_fits :: (first: s32) -> done: int, total: int {
    collect_motions();
    done, total: int;
    seen: [..] s32;
    seen.allocator = temp;
    id := first;
    while id > 0 && !array_find(seen, id) {
        array_add(*seen, id);
        entry := find_scene(id);
        if !entry break;
        path := get_scene_archive_path(entry);
        for motions.list  if it.lfd == path {
            total += 1;
            if it.fitted  done += 1;
        }
        for motions.fields  if it.lfd == path {
            total += 1;
            if it.built  done += 1;
        }
        id = entry.next;
    }
    return done, total;
}

// Fits not started yet are dropped (the one under way finishes); a pair dropped is queued again
// when a film needs it.
cutscene_drop_fits :: () {
    f := *fitter;
    if !f.started return;
    lock(*f.mutex);
    for f.jobs  drop_job(it);
    array_reset_keeping_memory(*f.jobs);
    unlock(*f.mutex);
}

#scope_module

Motion :: struct {
    lfd:      string;       // The LFD's path,
    from, to: s64;          // and the DELTs' offsets in it.
    queued:   bool;         // With the thread, or done.
    fitted:   bool;
    good:     bool;         // Warped by the fit; otherwise crossfaded,
    held:     bool;         // or neither: shown as the original shows it.
    zoom:     float = 1;
    shift:    Vector2;
    residual: float;        // What the fit leaves unexplained, 0 to 1.
}

start_fitter :: () {
    f := *fitter;
    if f.started return;
    init(*f.mutex);
    init(*f.wake);
    thread_init(*f.thread, run_fitter);
    thread_start(*f.thread);
    f.started = true;
}

stop_fitter :: () {
    f := *fitter;
    if !f.started return;
    lock(*f.mutex);
    f.quitting = true;
    unlock(*f.mutex);
    signal(*f.wake);
    thread_is_done(*f.thread, -1);
    thread_deinit(*f.thread);
    for f.jobs  drop_job(it);
    array_free(f.jobs);
    array_free(f.results);
    for f.field_results  array_free(it.values);
    array_free(f.field_results);
    for motions.fields {
        free(it.lfd);
        array_free(it.values);
    }
    array_free(motions.fields);
    destroy(*f.mutex);
    destroy(*f.wake);
    for motions.list  free(it.lfd);
    array_free(motions.list);
    waiting := f.waiting;
    f.* = .{};
    f.waiting = waiting;
    motions = .{};
}

// Fits for the film's pairs not fitted or queued already. 'archive' is the film's LFD.
queue_film_motions :: (film: *Film, archive: *Archive) {
    if !fitter.started return;
    batch: *Motion_Batch;
    jobs: [..] Motion_Job;
    jobs.allocator = temp;
    for film.frame_pairs {
        m := find_motion(archive, it.from, it.to);
        if m && m.queued continue;
        if !m {
            m = array_add(*motions.list);
            m.* = .{lfd = copy_string(archive.path), from = get_offset(archive, it.from), to = get_offset(archive, it.to)};
        }
        m.queued = true;
        if !batch {
            batch = New(Motion_Batch);
            batch.palette = get_film_palette(film);
        }
        index := m - motions.list.data;
        array_add(*jobs, .{batch = batch, motion = index, from = add_batch_frame(batch, it.from), to = add_batch_frame(batch, it.to)});
    }
    if !jobs.count return;
    batch.jobs_left = jobs.count;
    batch.job_count = jobs.count;
    f := *fitter;
    lock(*f.mutex);
    array_add(*f.jobs, ..jobs);
    unlock(*f.mutex);
    signal(*f.wake);
}

// The fit for two frames of the scene playing shown one after the other, null if it doesn't
// show them so.
get_motion :: (from: *u8, to: *u8) -> *Motion {
    if !cut.archive return null;
    m := find_motion(cut.archive, .{1, from}, .{1, to});
    while m && fitter.waiting && !m.fitted {
        sleep_milliseconds(1);
        collect_motions();
    }
    return m;
}

// The crawl's distance field, if it's queued or built; then queued if it isn't.
queue_crawl_field :: (archive: *Archive, actor: *Actor) {
    if !fitter.started || !actor.frames.count return;
    delt := get_offset(archive, actor.frames[0]);
    field := find_crawl_field(archive.path, delt);
    if field && (field.queued || field.built) return;
    crawl: Crawl;
    open_crawl(*crawl, actor);
    queue_crawl_field(archive.path, delt, crawl);
}

// The crawl's distance field, waiting for the thread to build it if it hasn't; built here if
// there's no thread.
get_crawl_field :: (archive: *Archive, crawl: *Crawl) -> values: [] u16, width: s32, height: s32 {
    delt := get_offset(archive, crawl.actor.frames[0]);
    field := find_crawl_field(archive.path, delt);
    if !fitter.started {
        if !field {
            field = array_add(*motions.fields);
            field.lfd, field.delt = copy_string(archive.path), delt;
            field.values, field.width, field.height = build_crawl_field(crawl);
            field.built = true;
        }
        return field.values, field.width, field.height;
    }
    if !field || (!field.queued && !field.built) {
        copy := crawl.*;
        copy.bitmap = array_copy(crawl.bitmap);
        queue_crawl_field(archive.path, delt, copy);
        field = find_crawl_field(archive.path, delt);
    }
    while !field.built {
        sleep_milliseconds(1);
        collect_motions();
    }
    return field.values, field.width, field.height;
}

// Fits and fields that have come in.
collect_motions :: () {
    f := *fitter;
    if !f.started return;
    lock(*f.mutex);
    results := f.results;
    empty: [..] Motion_Result;
    f.results = empty;
    field_results := f.field_results;
    no_fields: [..] Field_Result;
    f.field_results = no_fields;
    unlock(*f.mutex);
    defer array_free(results);
    defer array_free(field_results);
    for results {
        m := *motions.list[it.motion];
        m.queued, m.fitted, m.good, m.held, m.zoom, m.shift, m.residual = true, true, it.good, it.held, it.zoom, it.shift, it.residual;
    }
    for field_results {
        field := *motions.fields[it.field];
        field.built, field.values, field.width, field.height = true, it.values, it.width, it.height;
    }
}

// The film's first palette; the screen's if it has none. Only brightness is used, to compare
// frames, so a fade's palette makes no odds.
get_film_palette :: (film: *Film) -> Palette {
    for film.objects  if it.palette  return widen_palette(it.palette.colors);
    return widen_palette(cut.palette.screen);
}

#scope_file

// Every pair fitted or queued, and crawl field built or queued, on the main thread.
motions: struct {
    list:   [..] Motion;
    fields: [..] Crawl_Field;
};

Crawl_Field :: struct {
    lfd:    string;         // The LFD's path,
    delt:   s64;            // and the crawl's DELT's offset in it.
    queued: bool;
    built:  bool;
    values: [] u16;
    width, height: s32;
}

Field_Result :: struct {
    field:  s64;
    values: [] u16;
    width, height: s32;
}

// A film's frames, decoded, for the thread.
Motion_Batch :: struct {
    palette:   Palette;
    frames:    [..] Batch_Frame;
    jobs_left: int;         // Under the mutex.
    job_count: int;
    fits:      [..] Pair_Fit;   // The thread's, as they're made.
}

Pair_Fit :: struct {
    motion:   s64;
    from, to: s32;          // Frames in the batch.
    zoom:     float = 1;
    shift:    Vector2;
    residual: float;
    still:    float;        // What holding still leaves.
    good:     bool;
    held:     bool;
}

Batch_Frame :: struct {
    delt:   *u8;
    extent: Rect;
    pixels: [] u8;
    drawn:  [] bool;
}

Motion_Job :: struct {
    batch:    *Motion_Batch;
    motion:   s64;          // Its place in motions.list.
    from, to: s32;          // Frames in the batch.
    field:    s64 = -1;     // Or a crawl field to build, its place in motions.fields,
    crawl:    Crawl;        // from this, whose bitmap the job owns.
}

Motion_Result :: struct {
    motion:   s64;
    good:     bool;
    held:     bool;
    zoom:     float;
    shift:    Vector2;
    residual: float;
}

fitter: struct {
    started:  bool;
    quitting: bool;
    waiting:  bool;         // Fixed-step runs: drawing waits for the fits it needs.
    thread:   Thread;
    mutex:    Mutex;
    wake:     Semaphore;
    jobs:     [..] Motion_Job;
    results:  [..] Motion_Result;
    field_results: [..] Field_Result;
};

find_crawl_field :: (lfd: string, delt: s64) -> *Crawl_Field {
    for * motions.fields  if it.delt == delt && it.lfd == lfd  return it;
    return null;
}

// Takes the crawl's bitmap.
queue_crawl_field :: (lfd: string, delt: s64, crawl: Crawl) {
    field := find_crawl_field(lfd, delt);
    if !field {
        field = array_add(*motions.fields);
        field.lfd, field.delt = copy_string(lfd), delt;
    }
    field.queued = true;
    job := Motion_Job.{field = field - motions.fields.data, crawl = crawl};
    f := *fitter;
    lock(*f.mutex);
    array_add(*f.jobs, job);
    unlock(*f.mutex);
    signal(*f.wake);
}

// Under the mutex.
drop_job :: (job: Motion_Job) {
    if job.field >= 0 {
        motions.fields[job.field].queued = false;
        array_free(job.crawl.bitmap);
        return;
    }
    motions.list[job.motion].queued = false;
    release_batch(job.batch);
}

find_motion :: (archive: *Archive, from: [] u8, to: [] u8) -> *Motion {
    a, b := get_offset(archive, from), get_offset(archive, to);
    for * motions.list  if it.from == a && it.to == b && it.lfd == archive.path  return it;
    return null;
}

get_offset :: (archive: *Archive, data: [] u8) -> s64 {
    return data.data - archive.bytes.data;
}

run_fitter :: (thread: *Thread) -> s64 {
    f := *fitter;
    while true {
        wait_for(*f.wake);
        while true {
            lock(*f.mutex);
            if f.quitting {
                unlock(*f.mutex);
                return 0;
            }
            if !f.jobs.count {
                unlock(*f.mutex);
                break;
            }
            job := f.jobs[0];
            array_ordered_remove_by_index(*f.jobs, 0);
            unlock(*f.mutex);

            if job.field >= 0 {
                values, width, height := build_crawl_field(*job.crawl);
                array_free(job.crawl.bitmap);
                reset_temporary_storage();
                lock(*f.mutex);
                array_add(*f.field_results, .{field = job.field, values = values, width = width, height = height});
                unlock(*f.mutex);
                continue;
            }

            batch := job.batch;
            from, to := *batch.frames[job.from], *batch.frames[job.to];
            fit := array_add(*batch.fits);
            fit.* = .{motion = job.motion, from = job.from, to = job.to, still = 1};
            if !is_empty(from.extent) && !is_empty(to.extent) {
                fa := make_field(from, *batch.palette);
                fb := make_field(to, *batch.palette);
                fit_motion(fit, *fa, *fb);
            }
            // The film's last: its sequences agreed and judged, and all its fits sent, so
            // none is drawn one way and then another.
            results: [..] Motion_Result;
            results.allocator = temp;
            if batch.fits.count == batch.job_count {
                make_fits_agree(batch);
                hold_degenerate_sequences(batch);
                for * batch.fits  array_add(*results, get_result(it));
            }
            lock(*f.mutex);
            array_add(*f.results, ..results);
            release_batch(batch);
            unlock(*f.mutex);
            reset_temporary_storage();
        }
    }
    return 0;
}

// Under the mutex. A batch whose last fits were dropped sends the ones made, as they are.
release_batch :: (batch: *Motion_Batch) {
    batch.jobs_left -= 1;
    if batch.jobs_left > 0 return;
    if batch.fits.count < batch.job_count  for * batch.fits  array_add(*fitter.results, get_result(it));
    for batch.frames {
        array_free(it.pixels);
        array_free(it.drawn);
    }
    array_free(batch.frames);
    array_free(batch.fits);
    free(batch);
}

add_batch_frame :: (batch: *Motion_Batch, delt: [] u8) -> s32 {
    for batch.frames  if it.delt == delt.data  return xx it_index;
    frame := array_add(*batch.frames);
    frame.delt = delt.data;
    frame.extent = get_delt_extent(delt);
    e := frame.extent;
    if !is_empty(e) {
        width, height := e.right - e.left, e.bottom - e.top;
        frame.pixels = NewArray(width * height, u8);
        frame.drawn  = NewArray(width * height, bool);
        draw_delt(frame.pixels, delt, -e.left, -e.top, .{0, 0, width, height}, width = width, drawn = frame.drawn);
    }
    return xx (batch.frames.count - 1);
}


// Fitted well enough to warp by: what's left unexplained, as a share of both pictures'
// energy, against what holding still leaves. Not an amount on its own: resampling alone leaves
// a good deal of a picture a few pixels across, however well it's fitted.
MOTION_GOOD_GAIN :: 0.75;

// A frame as brightness, for fitting: drawn pixels count for something even when dark, so the
// outline matters as well as the picture.
Field :: struct {
    values:    [] float;
    width:     s32;
    height:    s32;
    left, top: float;       // Texel 0's corner, in the actor's pixels.
    // Edges where the picture was cut off (by the screen's edge, as a planet rising into view
    // is), not its outline: what lies past them is unknown rather than empty, or the fit takes
    // what comes into view through them for growth.
    cut_left, cut_top, cut_right, cut_bottom: bool;
}


get_result :: (fit: *Pair_Fit) -> Motion_Result {
    return .{motion = fit.motion, good = fit.good, held = fit.held, zoom = fit.zoom, shift = fit.shift, residual = fit.residual};
}

// Pairs in a sequence (each one's second frame the next one's first) mostly share their motion,
// a camera's move easing along. Where several motions explain a pair about as well, as rising
// past the screen's edge and growing about a point below it do for a curved edge cut by the
// screen, each pair choosing on its own flips between them, and the in-betweens stutter. So
// each pair takes, of its own motion and its neighbours', the one nearest its neighbours' that
// explains it nearly as well as its own. A few rounds, each from the last's, since an outlier's
// neighbours pull their own targets off. Returns the fits that changed.
make_fits_agree :: (batch: *Motion_Batch) -> [] int {
    ROUNDS :: 3;
    changed: [..] int;
    changed.allocator = temp;
    for 1..ROUNDS {
        if !agree_fits_once(batch, *changed) break;
    }
    return changed;
}

// Returns whether any fit changed; adds them to 'changed'.
agree_fits_once :: (batch: *Motion_Batch, changed: *[..] int) -> bool {
    NEARLY :: 1.1;
    fits := batch.fits;
    original := array_copy(fits,, temp);
    any := false;
    for * fit, i: fits {
        before, after := -1, -1;
        for original {
            if it.to == fit.from && it_index != i  before = it_index;
            if it.from == fit.to && it_index != i  after = it_index;
        }
        if before < 0 && after < 0 continue;
        a, b := *batch.frames[fit.from], *batch.frames[fit.to];
        if is_empty(a.extent) || is_empty(b.extent) continue;

        // The neighbours' motion, as where it takes the first frame's middle and how much it
        // zooms; nearness is measured on that point and the frame's size.
        middle := Vector2.{(a.extent.left + a.extent.right) / 2.0, (a.extent.top + a.extent.bottom) / 2.0};
        reach := Vector2.{xx (a.extent.right - a.extent.left), xx (a.extent.bottom - a.extent.top)};
        size := length(reach) / 2;
        get_distance :: (z1: float, s1: Vector2, z2: float, s2: Vector2) -> float #expand {
            return length((middle * z1 + s1) - (middle * z2 + s2)) + abs(z1 - z2) * size;
        }
        target_zoom, target_shift, count := 0.0, Vector2.{}, 0;
        for n: int.[before, after]  if n >= 0 {
            target_zoom += original[n].zoom;
            target_shift += original[n].shift;
            count += 1;
        }
        target_zoom /= count;
        target_shift /= cast(float) count;

        fa := make_field(a, *batch.palette);
        fb := make_field(b, *batch.palette);
        own := get_error(*fa, *fb, original[i].zoom, original[i].shift, 2);
        best := -1;
        best_distance := get_distance(original[i].zoom, original[i].shift, target_zoom, target_shift);
        for n: int.[before, after]  if n >= 0 {
            e := get_error(*fa, *fb, original[n].zoom, original[n].shift, 2);
            if e > own * NEARLY continue;
            d := get_distance(original[n].zoom, original[n].shift, target_zoom, target_shift);
            if d < best_distance  best, best_distance = n, d;
        }
        if best < 0 continue;
        fit.zoom, fit.shift = original[best].zoom, original[best].shift;
        fit.residual = get_error(*fa, *fb, fit.zoom, fit.shift, 1);
        fit.good = is_good_fit(fit.residual, fit.still);
        array_add_if_unique(changed, i);
        any = true;
    }
    return any;
}

// Where no motion explains an ANIM's changes (kflyby's pods dropping from the Arc Hammer: every
// fit leaving 0.24 to 0.77 of the pictures' energy, its shifts and zooms swinging wildly), the
// original's frames are shown as they are, without in-betweens: warping the few pairs that
// happen to fit better than holding still, between crossfaded ones, made a mess. Judged a whole
// sequence (one actor's frames following one another) at a time, by its median, so a sequence
// doesn't alternate; a pair leaving more than DEGENERATE_PAIR on its own is a cut. Good fits
// leave 0.002 to 0.07; a sprite a few pixels across, up to about 0.2.
DEGENERATE_SEQUENCE :: 0.25;
DEGENERATE_PAIR     :: 0.5;

hold_degenerate_sequences :: (batch: *Motion_Batch) {
    fits := batch.fits;
    // Sequences: pairs joined by a frame, one's second the other's first.
    sequence := NewArray(fits.count, int,, temp);
    for * sequence  it.* = it_index;
    get_root :: (i: int) -> int #expand {
        while sequence[i] != i  i = sequence[i];
        return i;
    }
    for i: 0..fits.count-1  for j: 0..fits.count-1 {
        if fits[i].to != fits[j].from continue;
        ri, rj := get_root(i), get_root(j);
        if ri != rj  sequence[rj] = ri;
    }
    for root: 0..fits.count-1 {
        if get_root(root) != root continue;
        residuals: [..] float;
        residuals.allocator = temp;
        for fits  if get_root(it_index) == root  array_add(*residuals, it.residual);
        quick_sort(residuals, (a: float, b: float) -> int { return ifx a < b then -1 else ifx a > b then 1 else 0; });
        if residuals[residuals.count / 2] <= DEGENERATE_SEQUENCE continue;
        for * fits  if get_root(it_index) == root  it.held = true;
    }
    for * fits  if it.residual > DEGENERATE_PAIR  it.held = true;

    // An in-between can be poor even so, showing what moves twice: a warp better than holding
    // still that leaves much unexplained (gromas1's ship turning on its asteroid while the
    // camera moves, which a zoom and shift can't follow), or a crossfade between frames that
    // differ much (robotx's ship coming at the camera). Such pairs of a picture large enough for
    // it to show are held as the original's frames. A pair between two held ones in its
    // sequence is held too, so a run steps through rather than alternating.
    poor := NewArray(fits.count, bool,, temp);
    for fits {
        a, b := batch.frames[it.from].extent, batch.frames[it.to].extent;
        size := max(a.right - a.left, a.bottom - a.top, b.right - b.left, b.bottom - b.top);
        left := ifx it.good then it.residual else it.still;
        poor[it_index] = !it.held && left > POOR_FIT && size > POOR_FIT_SIZE;
    }
    for * fit, i: fits {
        held := poor[i];
        if !held && !fit.held {
            before, after := false, false;
            for fits {
                if it.to == fit.from && it_index != i && poor[it_index]  before = true;
                if it.from == fit.to && it_index != i && poor[it_index]  after = true;
            }
            held = before && after;
        }
        if held  fit.held = true;
    }

    // A camera move a zoom and shift follow well overall can still carry along a small thing
    // moving its own way, which then slides back at every step (gromas1's ship over its
    // asteroid): seen in the worst explained block of the picture. Where that shows in over a
    // quarter of a sequence's warped pairs, the whole sequence is held, rather than some.
    local_poor := NewArray(fits.count, bool,, temp);
    for fits {
        if !it.good || it.held continue;
        from, to := *batch.frames[it.from], *batch.frames[it.to];
        a, b := from.extent, to.extent;
        if max(a.right - a.left, a.bottom - a.top, b.right - b.left, b.bottom - b.top) <= POOR_FIT_SIZE continue;
        fa := make_field(from, *batch.palette);
        fb := make_field(to, *batch.palette);
        local_poor[it_index] = get_worst_block_error(*fa, *fb, it.zoom, it.shift) > POOR_BLOCK;
    }
    for root: 0..fits.count-1 {
        if get_root(root) != root continue;
        warped, poor_count := 0, 0;
        for fits  if get_root(it_index) == root && it.good && !it.held {
            warped += 1;
            if local_poor[it_index]  poor_count += 1;
        }
        if !warped || poor_count * 4 <= warped continue;
        for * fits  if get_root(it_index) == root  it.held = true;
    }
}

// Good fits leave 0.002 to 0.07, gromas1's doubled ship 0.12 to 0.43; talking heads'
// crossfades change 0.001, robotx's ship 0.1 to 0.28. In pixels, the larger side of either
// frame: a sprite a few pixels across leaves up to about 0.2 fitted well.
POOR_FIT      :: 0.1;
POOR_FIT_SIZE :: 40;
// A block a fit leaves nearly all unexplained (of 1); good camera moves' worst blocks mostly
// stay under 0.2.
POOR_BLOCK    :: 0.9;

// Not when holding still couldn't be compared either: then nothing was measured.
is_good_fit :: (residual: float, still: float) -> bool {
    return still < 1 && residual < still * MOTION_GOOD_GAIN;
}

fit_motion :: (m: *Pair_Fit, fa: *Field, fb: *Field) {
    center_a, spread_a, total_a := get_moments(fa);
    center_b, spread_b, total_b := get_moments(fb);
    if total_a <= 0 || total_b <= 0 return;

    // Coarse to fine, from the pictures' middles and sizes, and from the middles alone in case
    // parts coming into or going out of the frame throw the sizes off.
    levels: [MOTION_LEVELS] Level;
    for * levels {
        factor := cast(s32) 1 << it_index;
        it.factor = factor;
        it.a = ifx factor == 1 then fa.* else shrink_field(fa, factor);
        it.b = ifx factor == 1 then fb.* else shrink_field(fb, factor);
    }
    coarse := *levels[MOTION_LEVELS - 1];
    zoom := clamp(spread_b / spread_a, 0.5, 2);
    starts := Motion.[
        .{zoom = zoom, shift = center_b - center_a * zoom},
        .{zoom = 1, shift = center_b - center_a},
        // The best plain shift on the smallest level: middles and sizes mislead when parts
        // come into view through a cut, as a planet rising past the screen's edge does.
        .{zoom = 1, shift = find_best_shift(coarse) * cast(float) coarse.factor},
    ];
    // Thin outlines make for narrow valleys that a slope-following fit overshoots, so it's a
    // search: wide on the smallest level, then a little around the answer on each larger one.
    best := FLOAT32_MAX;
    for starts {
        z, s, e := search_motion(*coarse.a, *coarse.b, it.zoom, it.shift / cast(float) coarse.factor, .[0.04, 1, 1], 1);
        if e < best  best, m.zoom, m.shift = e, z, s * cast(float) coarse.factor;
    }
    for < 1..MOTION_LEVELS - 2 {
        level := *levels[it];
        z, s := search_motion(*level.a, *level.b, m.zoom, m.shift / cast(float) level.factor, .[0.01, 0.5, 0.5], 2);
        m.zoom, m.shift = z, s * cast(float) level.factor;
    }
    m.residual = get_error(fa, fb, m.zoom, m.shift, 1);
    m.still = get_error(fa, fb, 1, .{}, 1);
    m.good = is_good_fit(m.residual, m.still);
}

MOTION_LEVELS :: 4;

// Every whole-texel shift within reach, on a small level.
find_best_shift :: (level: *Level) -> Vector2 {
    REACH :: 6;
    best := FLOAT32_MAX;
    shift: Vector2;
    for y: -REACH..REACH  for x: -REACH..REACH {
        e := get_error(*level.a, *level.b, 1, .{xx x, xx y}, 1);
        if e < best  best, shift = e, .{xx x, xx y};
    }
    return shift;
}

// A pattern search: each parameter nudged either way while that helps, the nudges halved when
// nothing does, down to a twentieth of a texel.
search_motion :: (a: *Field, b: *Field, zoom: float, shift: Vector2, first_steps: [3] float, sampling: s32) -> float, Vector2, float {
    params := float.[zoom, shift.x, shift.y];
    steps := first_steps;
    best := get_error(a, b, params[0], .{params[1], params[2]}, sampling);
    for 1..200 {
        improved := false;
        for k: 0..2  for sign: float.[-1, 1] {
            trial := params;
            trial[k] += sign * steps[k];
            if trial[0] < 0.5 || trial[0] > 2 continue;
            e := get_error(a, b, trial[0], .{trial[1], trial[2]}, sampling);
            if e < best  best, params, improved = e, trial, true;
        }
        if improved continue;
        for * steps  it.* *= 0.5;
        if steps[1] < 0.05 break;
    }
    return params[0], .{params[1], params[2]}, best;
}

// The two frames, shrunk by 'factor'.
Level :: struct {
    factor: s32;
    a, b:   Field;
}

// Averaged in blocks of factor x factor; coordinates shrink with it.
shrink_field :: (f: *Field, factor: s32) -> Field {
    s: Field;
    s.width  = (f.width + factor - 1) / factor;
    s.height = (f.height + factor - 1) / factor;
    s.left, s.top = f.left / factor, f.top / factor;
    s.cut_left, s.cut_top, s.cut_right, s.cut_bottom = f.cut_left, f.cut_top, f.cut_right, f.cut_bottom;
    s.values = NewArray(s.width * s.height, float,, temp);
    for y: 0..f.height-1  for x: 0..f.width-1 {
        s.values[(y / factor) * s.width + x / factor] += f.values[y * f.width + x];
    }
    for * s.values  it.* /= cast(float) (factor * factor);
    return s;
}

make_field :: (t: *Batch_Frame, palette: *Palette) -> Field {
    e := t.extent;
    f: Field;
    f.width, f.height = e.right - e.left, e.bottom - e.top;
    f.left, f.top = xx e.left, xx e.top;
    f.values = NewArray(t.pixels.count, float,, temp);
    for t.pixels {
        if !t.drawn[it_index] continue;
        c := palette.colors[it];
        f.values[it_index] = 0.25 + 0.75 * (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255;
    }
    is_drawn :: (x: s32, y: s32) -> bool #expand { return t.drawn[y * f.width + x]; }
    count_drawn_row :: (y: s32) -> s32 #expand {
        n: s32;
        for x: 0..f.width-1  if is_drawn(x, y)  n += 1;
        return n;
    }
    count_drawn_column :: (x: s32) -> s32 #expand {
        n: s32;
        for y: 0..f.height-1  if is_drawn(x, y)  n += 1;
        return n;
    }
    // A cut when the picture runs along over half the edge; an outline only touches its edges
    // here and there.
    f.cut_top    = count_drawn_row(0) * 2              > f.width;
    f.cut_bottom = count_drawn_row(f.height - 1) * 2   > f.width;
    f.cut_left   = count_drawn_column(0) * 2           > f.height;
    f.cut_right  = count_drawn_column(f.width - 1) * 2 > f.height;
    return f;
}

get_moments :: (f: *Field) -> center: Vector2, spread: float, total: float {
    total: float;
    sum: Vector2;
    for y: 0..f.height-1  for x: 0..f.width-1 {
        v := f.values[y * f.width + x];
        total += v;
        sum += Vector2.{f.left + x + 0.5, f.top + y + 0.5} * v;
    }
    if total <= 0 return .{}, 0, 0;
    center := sum / total;
    spread: float;
    for y: 0..f.height-1  for x: 0..f.width-1 {
        d := Vector2.{f.left + x + 0.5, f.top + y + 0.5} - center;
        spread += (d.x * d.x + d.y * d.y) * f.values[y * f.width + x];
    }
    return center, sqrt(spread / total), total;
}

// Each picture against the other carried onto it, over both pictures' texels, every
// 'sampling'th across and down; as a share of their energy. Texels carried past a cut aren't
// compared; when that's half of them or more, the motion isn't borne out and counts as the
// worst (else the search would push the pictures out through their cuts).
get_error :: (a: *Field, b: *Field, zoom: float, shift: Vector2, sampling: s32) -> float {
    error, energy: float;
    visited, skipped: s32;
    y: s32;
    while y < b.height {
        x: s32;
        while x < b.width {
            vb := b.values[y * b.width + x];
            ax, ay := (b.left + x + 0.5 - shift.x) / zoom, (b.top + y + 0.5 - shift.y) / zoom;
            visited += 1;
            if is_past_cut(a, ax, ay) {
                skipped += 1;
                x += sampling;
                continue;
            }
            va := sample_field(a, ax, ay);
            error += (vb - va) * (vb - va);
            energy += vb * vb + va * va;
            x += sampling;
        }
        y += sampling;
    }
    y = 0;
    while y < a.height {
        x: s32;
        while x < a.width {
            va := a.values[y * a.width + x];
            bx, by := (a.left + x + 0.5) * zoom + shift.x, (a.top + y + 0.5) * zoom + shift.y;
            visited += 1;
            if is_past_cut(b, bx, by) {
                skipped += 1;
                x += sampling;
                continue;
            }
            vb := sample_field(b, bx, by);
            error += (vb - va) * (vb - va);
            energy += vb * vb + va * va;
            x += sampling;
        }
        y += sampling;
    }
    if skipped * 2 >= visited return 1;
    return error / max(energy, 0.000001);
}

// The worst explained part of the second frame: of its blocks of BLOCK texels with a quarter
// of the average block's energy or more, the largest share the motion leaves unexplained.
get_worst_block_error :: (a: *Field, b: *Field, zoom: float, shift: Vector2) -> float {
    BLOCK :: 16;
    across := (b.width + BLOCK - 1) / BLOCK;
    down := (b.height + BLOCK - 1) / BLOCK;
    error := NewArray(across * down, float,, temp);
    energy := NewArray(across * down, float,, temp);
    for y: 0..b.height-1  for x: 0..b.width-1 {
        ax, ay := (b.left + x + 0.5 - shift.x) / zoom, (b.top + y + 0.5 - shift.y) / zoom;
        if is_past_cut(a, ax, ay) continue;
        vb := b.values[y * b.width + x];
        va := sample_field(a, ax, ay);
        i := (y / BLOCK) * across + x / BLOCK;
        error[i] += (vb - va) * (vb - va);
        energy[i] += vb * vb + va * va;
    }
    total: float;
    count: s32;
    for energy  if it > 0 { total += it; count += 1; }
    if !count return 0;
    least := total / count / 4;
    worst: float;
    for energy  if it >= least  worst = max(worst, error[it_index] / it);
    return worst;
}

is_past_cut :: (f: *Field, x: float, y: float) -> bool {
    u, v := x - f.left, y - f.top;
    return (f.cut_left && u < 0) || (f.cut_right && u > xx f.width) || (f.cut_top && v < 0) || (f.cut_bottom && v > xx f.height);
}

// Bilinear, nothing outside.
sample_field :: (f: *Field, x: float, y: float) -> float {
    u := x - f.left - 0.5;
    v := y - f.top - 0.5;
    if u <= -1 || v <= -1 || u >= cast(float) f.width || v >= cast(float) f.height return 0;
    x0 := cast(s32) floor(u);
    y0 := cast(s32) floor(v);
    fx := u - x0;
    fy := v - y0;
    get :: (x: s32, y: s32) -> float #expand {
        if x < 0 || y < 0 || x >= f.width || y >= f.height return 0;
        return f.values[y * f.width + x];
    }
    top    := lerp(get(x0, y0),     get(x0 + 1, y0),     fx);
    bottom := lerp(get(x0, y0 + 1), get(x0 + 1, y0 + 1), fx);
    return lerp(top, bottom, fy);
}

#import "Thread";
#import "Sort";
