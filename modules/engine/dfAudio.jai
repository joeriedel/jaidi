// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Audio output, as the original's two sound chips: music is one SDL audio stream at the OPL3's
// native rate, filled from SDL's audio thread by the FM driver, with the iMUSE sequencer ticked
// between samples at its original interrupt rate; digital sounds are another, iMUSE's 8-bit
// stereo mix at the Sound Blaster's rate. SDL resamples both to the device and mixes them. A
// third stream plays one sound at a time for the tools, at the file's own rate.
//
// The music callback holds the music stream's lock while it runs, and the digital one takes it
// too. Anything on another thread that touches the FM driver or iMUSE does so between
// audio_lock and audio_unlock.

// Music state is set up even when the device fails, so callers can use it either way.
audio_init :: () -> bool {
    imuse_init();
    init_audio_context();
    if !SDL_InitSubSystem(SDL_INIT_AUDIO) {
        log_error("SDL_InitSubSystem(AUDIO) failed: %", to_string(SDL_GetError()));
        return false;
    }

    spec := SDL_AudioSpec.{format = .S16LE, channels = 2, freq = FM_SAMPLE_RATE};
    music_stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, *spec, fill_music_stream, null);
    if !music_stream {
        log_error("SDL_OpenAudioDeviceStream failed: %", to_string(SDL_GetError()));
        SDL_QuitSubSystem(SDL_INIT_AUDIO);
        return false;
    }
    SDL_ResumeAudioStreamDevice(music_stream);

    digital_spec := SDL_AudioSpec.{format = .U8, channels = 2, freq = IMUSE_DIGITAL_RATE};
    digital_stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, *digital_spec, fill_digital_stream, null);
    if digital_stream  SDL_ResumeAudioStreamDevice(digital_stream);
    else               log_error("No digital sound: SDL_OpenAudioDeviceStream failed: %", to_string(SDL_GetError()));

    sound_spec := SDL_AudioSpec.{format = .U8, channels = 1, freq = 11025};
    sound_stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, *sound_spec, fill_sound_stream, null);
    if sound_stream  SDL_ResumeAudioStreamDevice(sound_stream);
    else             log_error("No sound effects: SDL_OpenAudioDeviceStream failed: %", to_string(SDL_GetError()));
    return true;
}

audio_shutdown :: () {
    if digital_stream {
        SDL_DestroyAudioStream(digital_stream);
        digital_stream = null;
    }
    if sound_stream {
        SDL_DestroyAudioStream(sound_stream);
        sound_stream = null;
        sound_free(*playing.sound);
    }
    if !music_stream return;
    SDL_DestroyAudioStream(music_stream);
    music_stream = null;
    SDL_QuitSubSystem(SDL_INIT_AUDIO);
}

// No-ops when audio failed to start, so callers needn't check.
audio_lock :: () {
    if music_stream SDL_LockAudioStream(music_stream);
}

audio_unlock :: () {
    if music_stream SDL_UnlockAudioStream(music_stream);
}

// Every stream held where it is, music and sounds, and let go again. The callbacks stop with
// them, iMUSE's ticks included, so everything carries on from the same sample.
audio_pause :: (paused: bool) {
    for stream: (*SDL_AudioStream).[music_stream, digital_stream, sound_stream] {
        if !stream continue;
        if paused  SDL_PauseAudioStreamDevice(stream);
        else       SDL_ResumeAudioStreamDevice(stream);
    }
}

// Music and digital sounds played faster (and higher), as a tape wound on: iMUSE ticks by the
// samples made, so the music's timing keeps up. For the tools' fast-forward.
audio_set_speed :: (ratio: float) {
    for stream: (*SDL_AudioStream).[music_stream, digital_stream] {
        if stream  SDL_SetAudioStreamFrequencyRatio(stream, ratio);
    }
}

audio_set_music_volume :: (gain: float) {
    if music_stream SDL_SetAudioStreamGain(music_stream, gain);
}

// Plays a copy of the sound from the start, replacing the one playing. With loop set, a sound
// with a loop region repeats it until stopped; otherwise it plays straight through once.
audio_play_sound :: (sound: Sound, loop := false) {
    if !sound_stream return;
    SDL_LockAudioStream(sound_stream);
    defer SDL_UnlockAudioStream(sound_stream);
    sound_free(*playing.sound);
    playing.sound = sound;
    copy: [..] u8;
    array_add(*copy, ..sound.samples);
    playing.sound.samples = copy;
    playing.position = 0;
    playing.loop = loop && sound.loop_start >= 0;
    playing.active = true;
    SDL_ClearAudioStream(sound_stream);
    spec := SDL_AudioSpec.{format = .U8, channels = 1, freq = sound.rate};
    SDL_SetAudioStreamFormat(sound_stream, *spec, null);
}

audio_stop_sound :: () {
    if !sound_stream return;
    SDL_LockAudioStream(sound_stream);
    playing.active = false;
    SDL_ClearAudioStream(sound_stream);
    SDL_UnlockAudioStream(sound_stream);
}

// The sample the effects stream has reached, and whether it is still playing. The position runs
// a little ahead of what is heard, by the stream's buffering.
audio_get_sound_position :: () -> s64, bool {
    if !sound_stream return 0, false;
    SDL_LockAudioStream(sound_stream);
    defer SDL_UnlockAudioStream(sound_stream);
    queued := SDL_GetAudioStreamQueued(sound_stream);
    return playing.position, playing.active || queued > 0;
}

#scope_file

music_stream:   *SDL_AudioStream;
digital_stream: *SDL_AudioStream;
sound_stream:   *SDL_AudioStream;

playing: struct {
    sound:    Sound;
    position: s64;
    loop:     bool;
    active:   bool;
};

// Time to the next iMUSE interrupt, in millionths of a sample, so that an interrupt period
// (IMUSE_TICK_US, at FM_SAMPLE_RATE) is a whole number of units and the clock never drifts.
until_tick: int;

// SDL calls the stream callback on its own audio thread, which Jai knows nothing about, so the
// callback brings its own context, with its own temporary storage, reset after every call.
audio_context: #Context;
audio_temporary_storage: Temporary_Storage;
audio_temporary_storage_data: [16 * 1024] u8 #align 64;

init_audio_context :: () {
    audio_context.allocator        = context.allocator;
    audio_context.logger           = context.logger;
    audio_context.logger_data      = context.logger_data;
    audio_context.assertion_failed = context.assertion_failed;
    audio_temporary_storage.data = audio_temporary_storage_data.data;
    audio_temporary_storage.size = audio_temporary_storage_data.count;
    audio_context.temporary_storage = *audio_temporary_storage;
}

fill_music_stream :: (userdata: *void, stream: *SDL_AudioStream, additional_amount: s32, total_amount: s32) #c_call {
    push_context audio_context {
        defer reset_temporary_storage();
        FRAME_BYTES :: 2 * size_of(s16);
        buffer: [1024] s16;
        frames := cast(int) additional_amount / FRAME_BYTES;
        while frames > 0 {
            if until_tick <= 0 {
                imuse_tick();
                until_tick += FM_SAMPLE_RATE * IMUSE_TICK_US;
            }
            frames_to_tick := (until_tick + 999_999) / 1_000_000;
            n := min(frames, frames_to_tick, buffer.count / 2);
            fm_generate(array_view(buffer, 0, n * 2));
            until_tick -= n * 1_000_000;
            SDL_PutAudioStreamData(stream, buffer.data, xx (n * FRAME_BYTES));
            frames -= n;
        }
    }
}

// iMUSE's state belongs to the music stream's lock.
fill_digital_stream :: (userdata: *void, stream: *SDL_AudioStream, additional_amount: s32, total_amount: s32) #c_call {
    push_context audio_context {
        defer reset_temporary_storage();
        buffer: [IMUSE_DIGITAL_FRAMES * 2] u8;
        left := cast(int) additional_amount;
        while left > 0 {
            n := min(left, buffer.count);
            SDL_LockAudioStream(music_stream);
            imuse_mix_digital(array_view(buffer, 0, n));
            SDL_UnlockAudioStream(music_stream);
            SDL_PutAudioStreamData(stream, buffer.data, xx n);
            left -= n;
        }
    }
}

// Runs on SDL's audio thread with the stream locked. Plain copies only: no context needed.
fill_sound_stream :: (userdata: *void, stream: *SDL_AudioStream, additional_amount: s32, total_amount: s32) #c_call {
    if !playing.active return;
    sound := *playing.sound;
    wanted := cast(s64) additional_amount;
    while wanted > 0 && playing.active {
        end := ifx playing.loop then sound.loop_end else sound.samples.count;
        n := end - playing.position;
        if n > wanted  n = wanted;
        if n > 0 {
            SDL_PutAudioStreamData(stream, sound.samples.data + playing.position, xx n);
            playing.position += n;
            wanted -= n;
        }
        if playing.position >= end {
            if playing.loop  playing.position = sound.loop_start;
            else             playing.active = false;
        }
    }
}

#import "Basic";
#import "engine/dfVoc";
#import "engine/dfFm";
#import "engine/dfIMuse";
#import "engine/vendor/SDL3";
