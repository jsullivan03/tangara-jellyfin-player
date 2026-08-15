local audio = require("sim_audio")

local path =
    "desktop-sim/sd/jellyfin-library-ui/" ..
    "Music/Masayoshi Takanaka/Brasilian Skies/" ..
    "05 Star Wars Samba.flac"

local file = assert(io.open(path, "rb"))
local size = assert(file:seek("end"))
file:close()

assert(size == 25130793, "unexpected live FLAC size")

local opened = audio.open(path)
assert(opened.ok, opened.error)
assert(opened.mode == "silent",
    "automated audio test did not select the silent backend")
assert(opened.sample_rate > 0)
assert(opened.channels == 2)
assert(opened.total_frames > 0)
assert(opened.duration > 220 and opened.duration < 230)

assert(math.abs(audio.set_volume(25) - 0.25) < 0.001)
assert(math.abs(audio.poll().volume - 0.25) < 0.001)
audio.set_volume(100)

assert(audio.play())
local produced = audio.pump(opened.sample_rate / 10)
assert(produced.consumed_frames > 0)
assert(produced.position > 0.09 and produced.position < 0.12)

local analysis = audio.analysis()
assert(analysis.sample_rate == opened.sample_rate)
assert(analysis.channels == opened.channels)
assert(analysis.frame_count > 0)
assert(#analysis.pcm_s16le > 0)
assert(analysis.peak > 0)
assert(analysis.rms > 0)

audio.pause()
local paused = audio.poll()
audio.pump(opened.sample_rate / 10)
local still_paused = audio.poll()
assert(still_paused.consumed_frames == paused.consumed_frames)
assert(still_paused.position == paused.position)

assert(audio.play())
local resumed = audio.pump(opened.sample_rate / 10)
assert(resumed.consumed_frames > still_paused.consumed_frames)

assert(audio.seek(90.0))
local sought = audio.poll()
assert(math.abs(sought.position - 90.0) < 0.02)
audio.pump(opened.sample_rate / 10)
assert(audio.poll().position > 90.09)

assert(audio.seek(opened.duration - 0.01))
audio.play()
local ended = audio.pump(opened.sample_rate)
assert(ended.ended == true)
assert(ended.playing == false)

audio.close()

local invalid = audio.open(
    "/tmp/tangara-no-such-audio-file.flac"
)
assert(not invalid.ok)
assert(type(invalid.error) == "string")
audio.close()

print(string.format(
    "Real FLAC decoder passed: bytes=%d rate=%d channels=%d " ..
        "duration=%.3f peak=%.4f rms=%.4f",
    size,
    opened.sample_rate,
    opened.channels,
    opened.duration,
    analysis.peak,
    analysis.rms
))
os.exit(0)
