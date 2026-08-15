local audio = require("sim_audio")
local lvgl = require("lvgl")
local path =
    "desktop-sim/sd/jellyfin-library-ui/" ..
    "Music/Masayoshi Takanaka/Brasilian Skies/" ..
    "05 Star Wars Samba.flac"

local opened = audio.open(path)
assert(opened.ok, opened.error)

print(string.format(
    "Desktop audio probe: mode=%s rate=%d channels=%d duration=%.3f%s",
    opened.mode,
    opened.sample_rate,
    opened.channels,
    opened.duration,
    opened.error and (" fallback=" .. opened.error) or ""
))

audio.set_volume(50)
assert(audio.play())

local ticks = 0

lvgl.Timer {
    period = 100,
    cb = function()
        ticks = ticks + 1
        local status = audio.poll()

        if ticks >= 20 then
            local tap = audio.analysis()
            assert(status.position > 1.5)
            assert(tap.frame_count > 0)
            assert(tap.peak > 0)
            assert(tap.rms > 0)
            assert(status.callback_count > 0)
            assert(status.callback_thread_id > 0)
            assert(status.callback_thread_id ~=
                status.main_thread_id)
            assert(status.underrun_count == 0)
            print(string.format(
                "Desktop audio produced: mode=%s frames=%d " ..
                    "position=%.3f peak=%.4f rms=%.4f " ..
                    "main_thread=%d callback_thread=%d callbacks=%d " ..
                    "underruns=%d",
                status.mode,
                status.consumed_frames,
                status.position,
                tap.peak,
                tap.rms,
                status.main_thread_id,
                status.callback_thread_id,
                status.callback_count,
                status.underrun_count
            ))
            audio.close()
            os.exit(0)
        end
    end,
}
