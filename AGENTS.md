# Working on Vidlib

Vidlib is a native, local macOS media catalog. Preserve a small, straightforward interface; iterate on existing controls rather than introducing a design system or web wrapper.

## Non-negotiable data behavior

- Source video/audio files and their folders are read-only. Never move, rename, copy, delete, rewrite metadata, or create sidecars beside them. “Add” and “drop into collection” mean catalog references/membership only.
- Store user edits (titles, descriptions, tags, collection membership, LUT assignment, audio gain) in the local catalog. Imported LUT definitions are copied into app-owned support storage.
- Keep catalog data separate from evictable cache data. Cache clearing must not remove catalog data or imported LUTs.
- Preserve backward compatibility. New fields must decode older catalogs; use optional fields or explicit decoding defaults. Test migration and preserve existing IDs. Version-two migration makes a consistent SQLite backup before upgrades are saved.
- Never use the user's real catalog for automated tests. Use a temporary database and generated media. Do not commit footage, recordings, LUTs, databases, secrets, app bundles, screenshots of personal libraries, or caches.

## Architecture

- Swift package executable; SwiftUI UI, AppKit `AVPlayerView`, AVFoundation playback/metadata, Core Image LUT processing, SQLite snapshot persistence.
- `Models.swift`: Codable catalog types and app-owned paths. The internal `Clip` type represents both video and audio for compatibility.
- `LibraryModel.swift`: main-actor state and catalog actions. Save once per batch operation.
- `ClipSelection.swift`: deterministic selection semantics and catalog-ID drag payload. IDs, never source file URLs, are dragged.
- `LibraryView.swift` / `ManagementViews.swift`: plain SwiftUI UI. Collection drop targets live outside `List`; the list previously swallowed row-level drops. `CollectionDropTarget.swift` owns a native AppKit drag destination with full-row hit testing and a drag-over highlight. Keep drag-source creation free of observable state mutations. Transport catalog IDs as a custom data representation, with a validated native string fallback.
- `MediaServices.swift`: background recursive discovery, bounded thumbnail work, shared audio-analysis jobs, disk-cache eviction, and player-item setup.
- `AudioServices.swift`: bounded-memory waveform/peak analysis and nondestructive audio gain through a processing tap. Preserve floating-point samples above unity. Do not use `AVPlayer.volume` for boost.
- `CatalogStore.swift`: app-owned SQLite catalog and legacy backup. SQLite currently stores a single atomic JSON snapshot; do not imply relational indexing exists.

## Performance and refresh

- NAS access must not block the main actor. Avoid synchronous media I/O in SwiftUI view bodies.
- Use lazy grids, cached thumbnails, bounded requests, and streaming audio analysis. Do not load full recordings into memory. Coalesce repeated waveform requests.
- Refresh is manual and recursive over saved roots. New camera-import subfolders must be discovered without adding them separately. Do not introduce recurring timers or automatic startup scans without an explicit product requirement.
- Refresh discovers additions; it does not delete offline entries, relink moved files, or refresh existing metadata. Keep these limits clear.
- Native player geometry must obey the proposed width/height rather than AVPlayerView's intrinsic size. Keep portrait thumbnails centered independently of the duration badge.
- Avoid SwiftUI `VideoPlayer`: it crashed in superclass metadata initialization on the development OS/toolchain. Use the AppKit wrapper.

## Build and verification

Developed with Xcode 27.1 / Swift 6.4 on Apple silicon; package minimum runtime is macOS 14.

```sh
zsh scripts/test.sh
zsh scripts/build-app.sh
open build/Vidlib.app
```

The audio-mix integration test needs access to macOS media services; a restricted terminal sandbox can cause `AVAssetReader.startReading()` to fail even when the same test passes in a normal terminal. Report that distinction instead of changing gain semantics to satisfy the sandbox.

Run meaningful tests for changed behavior: backward decoding, source preservation, recursive refresh/deduplication, search, batch selection/edits, drag serialization/membership, waveform samples, and gain output. Tests generate their own fixtures.

Use a separate app bundle identifier and `VIDLIB_DATA_DIR` / `VIDLIB_CACHE_DIR` when smoke-testing with a synthetic catalog. The window must clearly say “Test Catalog.” Keep the user's normal app/catalog available, and reopen it after replacing the main executable. Never overwrite a running app executable.

Before pushing, review the staged file list and diff for private media paths or generated data. Keep README behavior and limitations consistent with the implementation. Do not invent license terms or promise codec/HDR/color accuracy that has not been validated.
