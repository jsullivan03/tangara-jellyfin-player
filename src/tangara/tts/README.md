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

Text-to-speech can be enabled under the Display settings on Tangara, by
enabling the _"Spoken Interface"_ setting. Please note that this will not be
a user-visible change unless TTS phrases are loaded onto the SD card under
`/.tangara-tts/`.

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
card as `/.tangara-tts/1e3e816187453bf8.wav`, it would be played back when the
settings icon is highlighted.

## Finding the KOMIHASH of UI strings

If you connect to your Tangara via the serial console, the `provider` module
logs a `WARN`ing each time it cannot find a TTS sample. You can enable these
log messages on the console by using the command `loglevel warn`, and then
manipulating the click wheel to move through the UI to discover other missing
TTS samples.
