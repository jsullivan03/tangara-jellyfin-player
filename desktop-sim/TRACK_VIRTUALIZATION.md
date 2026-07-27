# Local Library Tracks virtualization

This stage virtualizes only the top-level Local Library **Tracks** screen.

The logical track collection remains in Lua, but LVGL owns a fixed pool of at most seven reusable track rows. The pool is rebound as focus moves through the logical collection.

Unchanged screens:

- Artists
- Artist detail
- Albums
- Album detail
- Playlists
- Favorites

Behavior retained:

- Sort is one upward movement above the first track.
- Sorting preserves the selected track ID.
- Returning from a child screen restores the selected track.
- Track activation uses the logical item currently bound to the focused row.
- Artwork and marquee widgets are reused rather than recreated per track.

Measurement:

```bash
./desktop-sim/run_local_library_virtualized.sh
```

Results are written to:

```text
build/local-library-virtualized.csv
```

The committed eager-row baseline remains in:

```text
build/local-library-baseline.csv
```

## Sort reset behavior

Applying a changed sort resets the virtual Tracks window to logical index 1. The Sort row remains focused, and the first downward input selects the first item in the new sorted order. This matches the eager-row screen and prevents an old selected ID from anchoring the row pool near the middle or end of a newly sorted list.
