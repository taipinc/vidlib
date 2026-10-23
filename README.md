# Vidlib

A native macOS catalog for video and audio, inspired by Lightroom's reference-in-place workflow. Browse media on local disks or a mounted NAS, organize it into collections, preview camera LUTs, and adjust audio playback gain without changing the originals.

Vidlib is an early personal application, built with SwiftUI, AppKit, AVFoundation, Core Image, MediaToolbox, and SQLite. It has no third-party package dependencies.

## Build and run

Developed and tested on Apple silicon with Xcode 27.1 / Swift 6.4. The package targets macOS 14 or later; older OS/toolchain combinations have not been validated.

```sh
git clone https://github.com/taipinc/vidlib.git
cd vidlib
zsh scripts/build-app.sh
open build/Vidlib.app
```

Open `Package.swift` in Xcode to work on the source. The build script creates a locally ad-hoc signed app. It is not notarized or packaged for public distribution.

```sh
zsh scripts/test.sh
```

Tests generate media in temporary directories and use isolated databases. The audio-mix integration test needs macOS media services; run the suite in a normal terminal if a restricted execution sandbox prevents AVAssetReader from starting.

## Catalog and organization

- **Add Folder** references files where they already live. Existing subfolders are included.
- **Refresh**, next to Add Folder (or Command-R), discovers newly added video/audio anywhere under the saved roots, including newly created camera-import folders. There are no folder watchers, background polling timers, or automatic startup scans.
- Refresh adds new files and avoids duplicates. It does not remove offline entries, detect file replacements, update existing metadata, or relink moved files.
- NAS folders must already be mounted in Finder. Local thumbnails remain browsable offline; playing an original requires access to it.
- The sidebar has separate Library, Collections, and Folders areas. Expand an individual folder to explore its subfolders.
- Shift-click selects a range in the current display order. Command-click toggles individual files; Command-Shift-click adds a range.
- Drag a selected thumbnail onto a collection to add the selected group. Drag an unselected thumbnail to add just that file. The collection highlights during a supported drag. Only catalog IDs are transferred; originals are not moved or copied.
- LUT assignment, tags, collection membership, and audio gain support batch selection. Mixed video/audio selections apply LUTs only to videos and gain only to audio. Batch tags add to existing tags.
- Give a file a **title** and **description** in the viewer and save its details. A nonempty title replaces its filename in the grid; the filename remains visible in File Details. Search includes titles, descriptions, filenames, tags, and folder paths.
- Recording dates use readable embedded metadata, falling back to an explicitly labeled filesystem creation date. Camera clocks and timezones may be inaccurate.

## Video and LUTs

Playback and seeking use macOS's media stack through native `AVPlayerView`. The viewer grows with available width and the clip's aspect ratio; settings scroll below it. Hover over player controls for fullscreen playback; Escape returns to the library. Narrow/portrait thumbnails are centered in their cells.

Import a 3D `.cube` LUT and assign it to a video or group of videos. **Manage LUTs** opens a dialog for renaming and importing LUTs. Renaming affects only the display name and preserves all assignments. Importing from this manager does not automatically assign the LUT to selected clips.

**LUT definitions are copied into Vidlib's support folder when imported.** The original `.cube` file can be moved afterward. Back up the catalog and its `LUTs` directory together. Clearing the thumbnail cache does not remove LUTs.

Use a LUT that matches the recording's gamma/gamut and intended SDR output. Camera-profile selection is manual. Supports 3D cubes sized 2–65 with a standard 0–1 input domain. Unsupported definitions fail explicitly. Bypass affects the focused preview; generated thumbnails retain the assigned LUT.

This is a LUT-preview workflow, not a validated grading pipeline. There is no automatic profile detection, exposure correction, full HDR workflow, or bundled Sony LUT. Actual camera output still needs comparison with a trusted color reference. H.264, HEVC, XF-AVC/MXF, and other formats depend on macOS codec support; there is no FFmpeg playback fallback or Canon RAW support.

## Audio

WAV/WAVE, AIFF/AIF/AIFC, CAF, M4A, MP3, AAC, FLAC, and ALAC extensions are discovered. Actual decoding depends on macOS support. Audio uses the same catalog, folders, collections, selection, tags, titles, descriptions, dates, and search as video.

Waveform thumbnails summarize the whole recording and are scaled to that file's own peak, so quiet recordings remain visible. They do not indicate relative loudness across files or change with playback gain. The first waveform requires a streaming read of the recording; subsequent views use the disk cache. Memory use is bounded and concurrent requests share an analysis job.

**Audio Preview Gain** stores a per-file adjustment from −96 to +48 dB. It changes decoded samples during playback using an audio processing tap, including attenuation of 32-bit float recordings with samples above 0 dBFS. Source files are never rewritten. Player volume is a separate listening control.

**Peak Normalize to −1 dBFS** scans each selected audio file and stores an individual gain aimed at a sample peak of −1 dBFS. This is sample-peak normalization, not LUFS/loudness normalization, true-peak limiting, compression, or repair of audio clipped during recording. Silent files produce an explicit error without partial batch edits. Extremely large adjustments are constrained by the gain range. Positive gain can exceed full scale; normalization provides a practical starting point.

## Storage and safety

Vidlib never changes, moves, renames, deletes, writes metadata into, or creates sidecars beside source media. It creates no proxies or copied media library.

| Data | Default location | Disposable? |
| --- | --- | --- |
| Catalog | `~/Library/Application Support/Vidlib/catalog.sqlite` | No |
| Imported LUT definitions | `~/Library/Application Support/Vidlib/LUTs/` | No |
| Thumbnails and waveform analysis | `~/Library/Caches/Vidlib/Vidlib-Thumbnails/` | Yes |

Keep the catalog on a local disk. SQLite currently saves the catalog as one atomic JSON snapshot, suitable for a modest library; it does not yet use relational search indexes. The first load of an older catalog creates a consistent `catalog.before-v2.sqlite` backup before later saves add the new fields.

Cache settings control location and disk limit, show disk use, and clear generated thumbnails/waveform data. Oldest-used generated files are evicted at the limit. Changing location leaves the old cache in place; clear it first to reclaim that space. Visible images may remain in memory after clearing, and new requests may regenerate files. Cache and catalog locations must be separate from imported media roots.

Wi-Fi performance depends on network throughput, latency, bitrate, compression structure, and decoder support. Thumbnail generation is bounded; metadata scans run off the main actor; audio analysis streams rather than loading entire recordings. Playback does not yet suspend all indexing, and there are no measured latency guarantees.

## Development

See [AGENTS.md](AGENTS.md) for data-safety invariants, architecture, performance constraints, test guidance, and UI regression notes.

- `Sources/Vidlib/Models.swift`: catalog types and paths.
- `LibraryModel.swift`: observable state, import, search, batch actions, LUT management, details, gain.
- `ClipSelection.swift`: selection and drag payload semantics.
- `LibraryView.swift`, `ManagementViews.swift`: library, viewer, settings, LUT manager, and waveform UI.
- `CollectionDropTarget.swift`: native collection row drag destination and visual feedback.
- `MediaServices.swift`: discovery, cache, and playback setup.
- `AudioServices.swift`: waveform/peak analysis and playback gain.
- `CatalogStore.swift`: SQLite storage and migration backup.
- `CubeLUT.swift`: validated LUT loading and filtering.

For a synthetic UI catalog, use **a separate app bundle identifier** and set `VIDLIB_DATA_DIR` and `VIDLIB_CACHE_DIR` to temporary absolute paths. A custom data directory gives the window a “Test Catalog” title. Do not replace the user's active catalog for UI tests or overwrite a running executable.

`zsh scripts/build-app.sh --preview` builds `build/Vidlib Preview.app` with a separate bundle identifier for this purpose. Start its executable with those environment variables set; opening it without a data override uses the normal catalog location.

Tests cover source preservation, migration, title/description search, LUT renaming, mixed-media batch edits, recursive discovery/deduplication, float waveform analysis, actual audio-mix gain output, selection ranges, and native drag-payload transport. Generated fixtures include floating-point samples above unity.

Still to add: relinking, catalog removal, collection renaming/deletion, smart collections, manual date correction, optional proxies, scrub-preview strips, and broader camera/network/color validation.
