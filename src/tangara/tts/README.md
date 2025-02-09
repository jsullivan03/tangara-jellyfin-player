# Text-to-speech on Tangara

The `tangara/tts/` module implements an audio accessibility layer for the
UI, providing the ability to play back text-to-speech recordings for each
UI element focused when using Tangara.

The code is structured in three pieces:

- `events.hpp`, providing the on-selection-changed and on-TTS-enabled events
  for the UI bindings.
- `player.cpp`, which supports TTS playback via low-memory audio decoders
  (currently, only WAV files), and
- `provider.cpp`, which is responsible for finding the TTS sample on the SD
  card for the focused UI element.

## End-user Configuration

Text-to-speech will automatically be enabled if you have loaded TTS phrases
onto the SD card, under `/.tangara-tts/`. These samples must be formatted
and named as per the instructions below.

To disable TTS, rename or delete the `/.tangara-tts/` directory on your SD
card.

## Supported Codecs

Currently, the TTS library only supports a WAV decoder. Natively, the player
expects 48 kHz audio, mono or stereo, and will (if required) resample the
audio to 48kHz for playback.

## Creating and enabling TTS Samples

TTS samples should be stored on your SD card, under `/.tangara-tts/`. The
`provider` expects that the TTS samples are stored in this directory as WAV
files, with a `.wav` extension, named as the hexadecimal version of the
[KOMIHASH](https://github.com/avaneev/komihash)ed TTS string.

For example, `Settings` hashes to `1e3e816187453bf8`. If you recorded a
short sample as a 48kHz (mono or stereo) WAV file, and stored it on the SD
card as `/.tangara-tts/1e3e816187453bf8.wav`, it would be played back when
the settings icon is highlighted.

## Finding the KOMIHASH of UI strings

If you connect to your Tangara via the serial console, the TTS provider
logs a `WARN`ing each time it cannot find a TTS sample. You can enable
these log messages on the console by using the command `loglevel warn`,
and then manipulating the click wheel to move through the UI to discover
other missing TTS samples.

## Tasks and Event Passing

### In the `ui` task

There are two main threads involved with running TTS - firstly, the `ui`
task, which is rooted in `ui::UiTask::Main()` (`src/tangara/ui/lvgl_task.hpp)`.
By way of the LVGL stack, eventually navigation in the UI results in sending
a `tts::SelectionChanged` message from `input::TextToSpeech::describe()`
(`src/tangara/input/feedback_tts.cpp`) to `tts::Provider::feed()`
(`src/tangara/tts/provider.cpp`), all in the UI task.

The `tts::Provider` is responsible for translating the UI string from a lump
of text to a TTS sample filename, which is then passed along to the player
in `tts::Player::playFile()` (`src/tangara/tts/player.cpp`), still on the UI
thread.

The UI task has a smaller stack than the `worker_X` tasks, and are not
appropriate to use for audio decoding work, both because they would block any
UI updates, and also have insufficient stack space for audio decode activity.

### Transitioning to the `WorkerPool` background threads

`playFile()` uses `tasks::WorkerPool::Dispatch()` to fire off a lambda in a
different task - one of the background `worker_X` tasks, owned by `WorkerPool`.
Control returns to the UI thread in under 2ms, so it remains pretty responsive
throughout this flow.

The background worker uses `tts::Player::openAndDecode` to do the bulk of the
decode/resample/playback work, and it is on this background task that the
majority of the work occurs. Note that there is nothing stopping the TTS worker
from consuming a number of worker tasks at once, but we rely on the interaction
of stream cancellation behaviour between the workers to ensure that previous
samples' playback is promptly terminated after a new sample is requested.
