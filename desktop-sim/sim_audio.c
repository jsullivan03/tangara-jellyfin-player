#include "sim_audio.h"

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <SDL2/SDL.h>
#include <lauxlib.h>

#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_SIMD
#include "dr_flac.h"

#define ANALYSIS_SAMPLE_CAPACITY 8192
#define DECODE_FRAME_CAPACITY 4096

typedef struct {
    drflac *decoder;
    SDL_AudioDeviceID device;
    SDL_mutex *mutex;
    bool audio_subsystem;
    bool opened;
    bool audible;
    bool playing;
    bool ended;
    bool end_reported;
    unsigned int channels;
    unsigned int sample_rate;
    uint64_t total_frames;
    uint64_t consumed_frames;
    uint64_t silent_ticks;
    uint64_t main_thread_id;
    uint64_t callback_thread_id;
    uint64_t callback_count;
    uint64_t underrun_count;
    float volume;
    int16_t analysis_pcm[ANALYSIS_SAMPLE_CAPACITY];
    size_t analysis_samples;
    uint64_t analysis_frame_start;
    float peak;
    float rms;
    char error[256];
} sim_audio_state;

static sim_audio_state state;

static void copy_error(const char *message)
{
    SDL_strlcpy(
        state.error,
        message != NULL ? message : "",
        sizeof(state.error)
    );
}

static void lock_state(void)
{
    if (state.mutex != NULL) {
        SDL_LockMutex(state.mutex);
    }
}

static void unlock_state(void)
{
    if (state.mutex != NULL) {
        SDL_UnlockMutex(state.mutex);
    }
}

static void update_analysis(
    const int16_t *pcm,
    uint64_t frame_start,
    size_t frames
)
{
    size_t samples = frames * state.channels;

    if (samples > ANALYSIS_SAMPLE_CAPACITY) {
        size_t drop = samples - ANALYSIS_SAMPLE_CAPACITY;
        pcm += drop;
        samples = ANALYSIS_SAMPLE_CAPACITY;
        frame_start += drop / state.channels;
    }

    double squares = 0.0;
    int peak = 0;

    for (size_t index = 0; index < samples; ++index) {
        int value = pcm[index];
        int magnitude = value < 0 ? -value : value;

        if (magnitude > peak) {
            peak = magnitude;
        }

        squares += (double)value * (double)value;
    }

    if (samples > 0) {
        memcpy(
            state.analysis_pcm,
            pcm,
            samples * sizeof(int16_t)
        );
        state.peak = (float)peak / 32768.0f;
        state.rms =
            (float)(sqrt(squares / samples) / 32768.0);
    } else {
        state.peak = 0.0f;
        state.rms = 0.0f;
    }

    state.analysis_samples = samples;
    state.analysis_frame_start = frame_start;
}

static uint64_t decode_frames(
    int16_t *pcm,
    uint64_t requested
)
{
    if (state.decoder == NULL || requested == 0) {
        return 0;
    }

    uint64_t frame_start = state.consumed_frames;
    uint64_t read = drflac_read_pcm_frames_s16(
        state.decoder,
        requested,
        pcm
    );

    if (read > 0) {
        update_analysis(pcm, frame_start, (size_t)read);
        state.consumed_frames += read;
    }

    if (read < requested ||
        state.consumed_frames >= state.total_frames) {
        state.ended = true;
        state.playing = false;
    }

    return read;
}

static void SDLCALL audio_callback(
    void *userdata,
    Uint8 *stream,
    int length
)
{
    (void)userdata;
    memset(stream, 0, (size_t)length);

    lock_state();
    state.callback_thread_id =
        (uint64_t)SDL_ThreadID();
    state.callback_count += 1;

    if (!state.opened || !state.audible ||
        !state.playing || state.ended ||
        state.channels == 0) {
        unlock_state();
        return;
    }

    int16_t decoded[
        DECODE_FRAME_CAPACITY * 2
    ];
    size_t requested_frames =
        (size_t)length /
        (sizeof(int16_t) * state.channels);
    size_t completed = 0;

    while (completed < requested_frames) {
        size_t chunk = requested_frames - completed;

        if (chunk > DECODE_FRAME_CAPACITY) {
            chunk = DECODE_FRAME_CAPACITY;
        }

        uint64_t expected_end =
            state.consumed_frames + chunk;
        uint64_t read =
            decode_frames(decoded, chunk);

        if (read < chunk &&
            expected_end < state.total_frames) {
            state.underrun_count += 1;
        }

        for (uint64_t index = 0;
             index < read * state.channels;
             ++index) {
            float sample = decoded[index] * state.volume;

            if (sample > 32767.0f) {
                sample = 32767.0f;
            } else if (sample < -32768.0f) {
                sample = -32768.0f;
            }

            ((int16_t *)stream)[
                completed * state.channels + index
            ] = (int16_t)sample;
        }

        completed += (size_t)read;

        if (read < chunk) {
            break;
        }
    }

    unlock_state();
}

static void stop_output(void)
{
    lock_state();
    SDL_AudioDeviceID device = state.device;
    state.device = 0;
    state.audible = false;
    unlock_state();

    if (device != 0) {
        SDL_PauseAudioDevice(device, 1);
        SDL_CloseAudioDevice(device);
    }
}

static void close_locked(void)
{

    if (state.decoder != NULL) {
        drflac_close(state.decoder);
        state.decoder = NULL;
    }

    state.opened = false;
    state.audible = false;
    state.playing = false;
    state.ended = false;
    state.end_reported = false;
    state.channels = 0;
    state.sample_rate = 0;
    state.total_frames = 0;
    state.consumed_frames = 0;
    state.analysis_samples = 0;
    state.callback_thread_id = 0;
    state.callback_count = 0;
    state.underrun_count = 0;
    state.peak = 0.0f;
    state.rms = 0.0f;
}

static void push_status(lua_State *L)
{
    lua_newtable(L);

    lua_pushboolean(L, state.opened);
    lua_setfield(L, -2, "ok");
    lua_pushstring(
        L,
        state.audible ? "audible" : "silent"
    );
    lua_setfield(L, -2, "mode");
    lua_pushboolean(L, state.playing);
    lua_setfield(L, -2, "playing");
    lua_pushboolean(L, state.ended);
    lua_setfield(L, -2, "ended");
    lua_pushinteger(L, state.sample_rate);
    lua_setfield(L, -2, "sample_rate");
    lua_pushinteger(L, state.channels);
    lua_setfield(L, -2, "channels");
    lua_pushinteger(L, (lua_Integer)state.total_frames);
    lua_setfield(L, -2, "total_frames");
    lua_pushinteger(L, (lua_Integer)state.consumed_frames);
    lua_setfield(L, -2, "consumed_frames");
    lua_pushinteger(L, (lua_Integer)state.main_thread_id);
    lua_setfield(L, -2, "main_thread_id");
    lua_pushinteger(L, (lua_Integer)state.callback_thread_id);
    lua_setfield(L, -2, "callback_thread_id");
    lua_pushinteger(L, (lua_Integer)state.callback_count);
    lua_setfield(L, -2, "callback_count");
    lua_pushinteger(L, (lua_Integer)state.underrun_count);
    lua_setfield(L, -2, "underrun_count");
    lua_pushinteger(L, (lua_Integer)state.device);
    lua_setfield(L, -2, "device_id");
    lua_pushnumber(L, state.volume);
    lua_setfield(L, -2, "volume");

    double position = state.sample_rate > 0 ?
        (double)state.consumed_frames /
            state.sample_rate : 0.0;
    double duration = state.sample_rate > 0 ?
        (double)state.total_frames /
            state.sample_rate : 0.0;

    lua_pushnumber(L, position);
    lua_setfield(L, -2, "position");
    lua_pushnumber(L, duration);
    lua_setfield(L, -2, "duration");

    if (state.error[0] != '\0') {
        lua_pushstring(L, state.error);
        lua_setfield(L, -2, "error");
    }
}

static int lua_audio_open(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    const char *mode = getenv("TANGARA_SIM_AUDIO_MODE");
    bool force_silent =
        mode != NULL && strcmp(mode, "silent") == 0;

    if (state.mutex == NULL) {
        state.mutex = SDL_CreateMutex();
    }

    stop_output();
    lock_state();
    close_locked();
    copy_error("");

    state.decoder = drflac_open_file(path, NULL);

    if (state.decoder == NULL) {
        copy_error("dr_flac could not open the local file");
        push_status(L);
        unlock_state();
        return 1;
    }

    state.channels = state.decoder->channels;
    state.sample_rate = state.decoder->sampleRate;
    state.total_frames = state.decoder->totalPCMFrameCount;
    state.volume = 1.0f;
    state.opened = true;
    state.silent_ticks = SDL_GetTicks64();
    unsigned int channels = state.channels;
    unsigned int sample_rate = state.sample_rate;
    unlock_state();

    SDL_AudioDeviceID opened_device = 0;
    char output_error[256] = "";

    if (!force_silent) {
        if (!state.audio_subsystem) {
            state.audio_subsystem =
                SDL_InitSubSystem(SDL_INIT_AUDIO) == 0;
        }

        if (state.audio_subsystem &&
            channels > 0 &&
            channels <= 2) {
            SDL_AudioSpec desired;
            SDL_AudioSpec obtained;

            SDL_zero(desired);
            desired.freq = (int)sample_rate;
            desired.format = AUDIO_S16SYS;
            desired.channels = (Uint8)channels;
            desired.samples = 1024;
            desired.callback = audio_callback;

            opened_device = SDL_OpenAudioDevice(
                NULL,
                0,
                &desired,
                &obtained,
                0
            );

            if (opened_device == 0) {
                SDL_strlcpy(
                    output_error,
                    SDL_GetError(),
                    sizeof(output_error)
                );
            }
        } else if (!state.audio_subsystem) {
            SDL_strlcpy(
                output_error,
                SDL_GetError(),
                sizeof(output_error)
            );
        } else {
            SDL_strlcpy(
                output_error,
                "desktop output supports mono or stereo FLAC",
                sizeof(output_error)
            );
        }
    }

    lock_state();
    state.device = opened_device;
    state.audible = opened_device != 0;

    if (output_error[0] != '\0') {
        copy_error(output_error);
    }

    push_status(L);
    unlock_state();
    return 1;
}

static int lua_audio_play(lua_State *L)
{
    lock_state();

    if (state.opened && !state.ended) {
        state.playing = true;
        state.silent_ticks = SDL_GetTicks64();

    }

    bool playing = state.playing;
    SDL_AudioDeviceID device = state.device;
    bool audible = state.audible;
    unlock_state();

    if (playing && audible && device != 0) {
        SDL_PauseAudioDevice(device, 0);
    }

    lua_pushboolean(L, playing);
    return 1;
}

static int lua_audio_pause(lua_State *L)
{
    lock_state();
    state.playing = false;
    SDL_AudioDeviceID device = state.device;
    bool audible = state.audible;
    bool opened = state.opened;
    unlock_state();

    if (audible && device != 0) {
        SDL_PauseAudioDevice(device, 1);
    }

    lua_pushboolean(L, opened);
    return 1;
}

static int lua_audio_seek(lua_State *L)
{
    double seconds = luaL_checknumber(L, 1);

    if (seconds < 0.0) {
        seconds = 0.0;
    }

    SDL_AudioDeviceID device = state.device;

    if (device != 0) {
        SDL_LockAudioDevice(device);
    }

    lock_state();
    uint64_t target =
        (uint64_t)(seconds * state.sample_rate);

    if (target > state.total_frames) {
        target = state.total_frames;
    }

    bool ok = state.decoder != NULL &&
        drflac_seek_to_pcm_frame(
            state.decoder,
            target
        ) == DRFLAC_TRUE;

    if (ok) {
        state.consumed_frames = target;
        state.ended = target >= state.total_frames;
        state.end_reported = false;
        state.analysis_samples = 0;
        state.silent_ticks = SDL_GetTicks64();
    }

    unlock_state();

    if (device != 0) {
        SDL_UnlockAudioDevice(device);
    }

    lua_pushboolean(L, ok);
    return 1;
}

static void silent_advance(uint64_t frames)
{
    int16_t pcm[DECODE_FRAME_CAPACITY * 2];

    while (frames > 0 && state.playing && !state.ended) {
        uint64_t chunk = frames;

        if (chunk > DECODE_FRAME_CAPACITY) {
            chunk = DECODE_FRAME_CAPACITY;
        }

        uint64_t read = decode_frames(pcm, chunk);

        if (read < chunk) {
            break;
        }

        frames -= read;
    }
}

static int lua_audio_poll(lua_State *L)
{
    lock_state();

    if (state.opened && !state.audible &&
        state.playing && !state.ended) {
        uint64_t now = SDL_GetTicks64();
        uint64_t elapsed = now - state.silent_ticks;
        uint64_t frames =
            elapsed * state.sample_rate / 1000;

        if (frames > 0) {
            state.silent_ticks +=
                frames * 1000 /
                state.sample_rate;
            silent_advance(frames);
        }
    }

    push_status(L);
    unlock_state();
    return 1;
}

static int lua_audio_pump(lua_State *L)
{
    uint64_t frames =
        (uint64_t)luaL_checkinteger(L, 1);

    lock_state();

    if (state.opened && !state.audible &&
        state.playing && !state.ended) {
        silent_advance(frames);
    }

    push_status(L);
    unlock_state();
    return 1;
}

static int lua_audio_set_volume(lua_State *L)
{
    double value = luaL_checknumber(L, 1);

    if (value > 1.0) {
        value /= 100.0;
    }

    if (value < 0.0) {
        value = 0.0;
    } else if (value > 1.0) {
        value = 1.0;
    }

    lock_state();
    state.volume = (float)value;
    unlock_state();
    lua_pushnumber(L, value);
    return 1;
}

static int lua_audio_analysis(lua_State *L)
{
    lock_state();
    lua_newtable(L);
    lua_pushinteger(L, state.sample_rate);
    lua_setfield(L, -2, "sample_rate");
    lua_pushinteger(L, state.channels);
    lua_setfield(L, -2, "channels");
    lua_pushnumber(
        L,
        state.sample_rate > 0 ?
            (double)state.analysis_frame_start /
                state.sample_rate : 0.0
    );
    lua_setfield(L, -2, "timestamp");
    lua_pushnumber(L, state.peak);
    lua_setfield(L, -2, "peak");
    lua_pushnumber(L, state.rms);
    lua_setfield(L, -2, "rms");
    lua_pushinteger(
        L,
        state.channels > 0 ?
            (lua_Integer)(
                state.analysis_samples /
                state.channels
            ) : 0
    );
    lua_setfield(L, -2, "frame_count");
    lua_pushlstring(
        L,
        (const char *)state.analysis_pcm,
        state.analysis_samples * sizeof(int16_t)
    );
    lua_setfield(L, -2, "pcm_s16le");
    unlock_state();
    return 1;
}

static int lua_audio_close(lua_State *L)
{
    stop_output();
    lock_state();
    close_locked();
    unlock_state();
    return 0;
}

static const luaL_Reg functions[] = {
    {"open", lua_audio_open},
    {"play", lua_audio_play},
    {"pause", lua_audio_pause},
    {"seek", lua_audio_seek},
    {"poll", lua_audio_poll},
    {"pump", lua_audio_pump},
    {"set_volume", lua_audio_set_volume},
    {"analysis", lua_audio_analysis},
    {"close", lua_audio_close},
    {NULL, NULL},
};

int luaopen_sim_audio(lua_State *L)
{
    state.main_thread_id =
        (uint64_t)SDL_ThreadID();
    luaL_newlib(L, functions);
    return 1;
}

void sim_audio_shutdown(void)
{
    stop_output();
    lock_state();
    close_locked();
    unlock_state();

    if (state.mutex != NULL) {
        SDL_DestroyMutex(state.mutex);
        state.mutex = NULL;
    }

    if (state.audio_subsystem) {
        SDL_QuitSubSystem(SDL_INIT_AUDIO);
        state.audio_subsystem = false;
    }
}
