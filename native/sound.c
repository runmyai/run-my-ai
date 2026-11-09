// The app's sound player (lib/system/chime.dart calls it): plays one audio file at a time, the same way on every
// system, with miniaudio (WAV, MP3, FLAC) and stb_vorbis (OGG), both in third_party/ (public domain / MIT-0).
// The sound device is only open while a sound plays: the app stops it (sound_idle) once the sound has ended.

#define STB_VORBIS_HEADER_ONLY
#include "third_party/stb_vorbis.c"

#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include "third_party/miniaudio.h"

#undef STB_VORBIS_HEADER_ONLY
#include "third_party/stb_vorbis.c"

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

static ma_engine engine;
static int engine_ready = 0;
static ma_sound sound;
static int sound_ready = 0;

static void drop_sound(void) {
    if (sound_ready) {
        ma_sound_uninit(&sound);
        sound_ready = 0;
    }
}

// Whether the file can be played (it opens and decodes): 1, or 0.
EXPORT int sound_check(const char* path) {
    ma_decoder decoder;
    if (ma_decoder_init_file(path, NULL, &decoder) != MA_SUCCESS) return 0;
    ma_uint64 frames = 0;
    float buffer[256];
    // (Its first few samples decode.)
    int ok = ma_decoder_read_pcm_frames(&decoder, buffer, 256 / decoder.outputChannels, &frames) == MA_SUCCESS;
    ma_decoder_uninit(&decoder);
    return ok;
}

// Plays the file from its start, in place of any sound still playing: 1, or 0 when it cannot be played.
EXPORT int sound_play(const char* path) {
    if (!engine_ready) {
        ma_engine_config config = ma_engine_config_init();
        config.noAutoStart = MA_TRUE;
        if (ma_engine_init(&config, &engine) != MA_SUCCESS) return 0;
        engine_ready = 1;
    }
    drop_sound();
    // Long files are read while they play, not all at once.
    if (ma_sound_init_from_file(&engine, path, MA_SOUND_FLAG_STREAM, NULL, NULL, &sound) != MA_SUCCESS) return 0;
    sound_ready = 1;
    if (ma_engine_start(&engine) != MA_SUCCESS || ma_sound_start(&sound) != MA_SUCCESS) {
        drop_sound();
        return 0;
    }
    return 1;
}

#if defined(_WIN32)
// The same two for Windows, with the path as Windows' own (UTF-16) text, so any file name works.
EXPORT int sound_check_w(const wchar_t* path) {
    ma_decoder decoder;
    if (ma_decoder_init_file_w(path, NULL, &decoder) != MA_SUCCESS) return 0;
    ma_uint64 frames = 0;
    float buffer[256];
    int ok = ma_decoder_read_pcm_frames(&decoder, buffer, 256 / decoder.outputChannels, &frames) == MA_SUCCESS;
    ma_decoder_uninit(&decoder);
    return ok;
}

EXPORT int sound_play_w(const wchar_t* path) {
    if (!engine_ready) {
        ma_engine_config config = ma_engine_config_init();
        config.noAutoStart = MA_TRUE;
        if (ma_engine_init(&config, &engine) != MA_SUCCESS) return 0;
        engine_ready = 1;
    }
    drop_sound();
    if (ma_sound_init_from_file_w(&engine, path, MA_SOUND_FLAG_STREAM, NULL, NULL, &sound) != MA_SUCCESS) return 0;
    sound_ready = 1;
    if (ma_engine_start(&engine) != MA_SUCCESS || ma_sound_start(&sound) != MA_SUCCESS) {
        drop_sound();
        return 0;
    }
    return 1;
}
#endif

// A sound is still playing: 1, or 0.
EXPORT int sound_playing(void) { return sound_ready && ma_sound_is_playing(&sound) && !ma_sound_at_end(&sound); }

// Stops the sound (if any) and closes the sound device.
EXPORT void sound_stop(void) {
    drop_sound();
    if (engine_ready) ma_engine_stop(&engine);
}
