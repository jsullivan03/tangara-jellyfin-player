# Tangara Jellyfin Player — Shareable Desktop Simulator

This is a development snapshot of the Tangara Jellyfin Player desktop simulator. It is intentionally shareable before the player is feature-complete so another Tangara owner can build, run, and evaluate the current Local/Sync UI and help with development.

## Current product model

- **Playback is Local-only.** Tracks play from files already downloaded to the simulated Tangara library.
- **Sync is acquisition/download.** Sync is not HTTP music streaming.
- A compatible Tangara companion/backend is required for live Jellyfin catalog and download features.
- The simulator is useful for UI/navigation development, but it is not proof of physical Tangara timing, memory, audio, power, or wheel behavior.

## Arch Linux prerequisites

Install the desktop build dependencies:

```bash
sudo pacman -S --needed base-devel git cmake pkgconf sdl2 lua53
```

The package includes the Tangara Lua/LVGL binding source. The authoritative snapshot does not contain `lib/lvgl`, while its `desktop-sim/lv_conf.h` explicitly targets LVGL 9.1.0. The build helper therefore fetches the exact LVGL v9.1.0 release commit (`e1c0b21b2723d391b885de4b2ee5cc997eccca91`) only when `lib/lvgl` is absent. It never replaces an existing LVGL tree. No ESP-IDF setup is needed just to build the desktop simulator.

## Build

From the package/repository root:

```bash
./desktop-sim/build-jellyfin-sim.sh
```

Equivalent manual commands:

```bash
cmake -S desktop-sim -B desktop-sim/build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build desktop-sim/build --parallel
```

## Configure

Copy the sanitized example:

```bash
cp desktop-sim/tangara-sim.env.example desktop-sim/tangara-sim.env
```

Edit these values:

```bash
TANGARA_SIM_SERVER_URL=http://localhost:8788
TANGARA_SIM_DEVICE_ID=tangara-sim-001
TANGARA_SIM_AUDIO_MODE=audible
```

`TANGARA_SIM_SERVER_URL` is the companion URL reachable from the simulator. `TANGARA_SIM_DEVICE_ID` should be unique for the simulated device. `TANGARA_SIM_AUDIO_MODE` can be changed if audible simulator playback is not desired.

You can also provide the same values directly in the environment instead of using the local config file.

## Run

```bash
./desktop-sim/run-jellyfin-sim.sh
```

The launcher reads `desktop-sim/tangara-sim.env` by default. A different config file can be selected with `TANGARA_SIM_CONFIG=/path/to/file`.

## Run automated regressions

The normal suite does not run optional live-companion tests. It auto-detects Arch's `lua5.3` / `luac5.3` binaries from the `lua53` package, so no manual interpreter override is normally needed:

```bash
./tools/run-tangara-regressions.sh --all
```

Focused suites are also available:

```bash
./tools/run-tangara-regressions.sh --identity
./tools/run-tangara-regressions.sh --download
./tools/run-tangara-regressions.sh --navigation
./tools/run-tangara-regressions.sh --rendering
./tools/run-tangara-regressions.sh --playback
```

## Known limitations

This is a share candidate, not a finished Tangara replacement firmware. In particular:

- The current album detail layout is still temporary; the planned UI is an iPod-inspired split view with tracks on the left and artwork/title/artist on the right.
- Navigation and selection motion are being rebuilt incrementally. Broad transition polish is not complete.
- Sync currently covers only part of the larger planned Jellyfin synchronization model.
- Storage, Settings/time, themes, lyrics, visualizer, OTA, broader offline reconciliation, and several queue/action controls remain incomplete or future work.
- Simulator behavior still needs real-device validation for heap/PSRAM pressure, SD latency, audio underruns, Wi-Fi/audio coexistence, physical wheel timing, sleep/lock behavior, font storage, artwork decode memory, and battery impact.
- Live Sync/download behavior depends on the companion implementation and the device ID linked there.
- The share package contains no user credentials, tokens, private IPs, or personal server configuration. Keep recipient-specific configuration in the ignored `desktop-sim/tangara-sim.env` file.

## Useful current behavior to preserve while contributing

- canonical artist/album/track identity;
- FIFO download ordering and durable download state;
- incomplete Local albums remain one grey, noninteractive placeholder until complete;
- `View in Local` appears only after authoritative completion;
- Sync virtual lists use a fixed row pool and must not reveal black/recycled gaps;
- album-row long-hold remains available, including queued/downloading Sync albums where ordinary click may be disabled;
- fresh album entry focuses Play;
- routine background catalog/artwork/bootstrap work must not keep the top-left activity indicator animated.

Please keep changes narrow, add regression coverage for changed behavior, and do not replace the current tree from historical patches.
