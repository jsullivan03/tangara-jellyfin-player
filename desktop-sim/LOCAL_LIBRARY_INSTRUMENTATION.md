# Local Library Measurement Instrumentation

This desktop-only instrumentation measures the current Local Library implementation before list virtualization.

It does not alter Tangara firmware behavior or Local Library rendering.

## Metrics

Each benchmark process records:

- Track count
- Screen construction and initial-layout time
- Active LVGL objects before and after opening Tracks
- Active LVGL timer count
- Lua memory before data creation and after screen creation
- Process resident memory before and after screen creation
- Maximum resident memory

The active-object count recursively walks the currently loaded native-style simulator screen. Timer count walks LVGL's global timer list. Lua memory comes from the active Lua state.

Desktop process memory is not an ESP32 heap measurement. The object count, timer count, and growth trends are intended to identify architectural scaling problems before hardware profiling.

## Run

```bash
./desktop-sim/run_local_library_baseline.sh
```

The default output is:

```text
build/local-library-baseline.csv
```

The benchmark uses separate simulator processes for 118, 500, 1,000, and 5,000 tracks so retained status timers and process peak-memory values from one case do not contaminate another case.

## Expected interpretation

The current implementation creates one permanent row and its child objects for every track. The baseline should therefore show approximately linear growth in object count and Lua memory as the number of tracks increases.

After virtualization, this same benchmark should show nearly constant LVGL object count and UI memory regardless of library size.
