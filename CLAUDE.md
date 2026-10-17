# CLAUDE.md

Notes for Claude Code working in this repo.

## What this is

Pancham is a native macOS SwiftUI app for writing Hindustani classical notations in the Bhatkhande system. Each notation is a `.pancham` file (JSON under the hood). macOS 15 Sequoia minimum. Notations live on kamaji (Postgres, with full revision history) and are cached as files on each Mac; people sign in with an email and a one-time code. See `server/README.md`.

## Build

```
xcodegen generate
xcodebuild -project Pancham.xcodeproj -scheme Pancham -destination 'platform=macOS' build
```

`xcodegen` is required to regenerate the project from `project.yml`. Install it with `brew install xcodegen`. `Pancham.xcodeproj` is checked in, so a fresh clone can be opened in Xcode without running xcodegen first.

## Architecture

Single target `Pancham`, built from source under `Pancham/`:

- `App/PanchamApp.swift` — `@main`, one `WindowGroup` showing `RootView`. `App/Library.swift` scans a folder of `.pancham` files (and reports renames/deletes to sync); `App/Preferences.swift` holds the pending-open URL.
- `Document/`
  - `PanchamDocument.swift` — `FileDocument` conforming to `.panchamNotation` UTType. Wraps a `Composition`.
  - `Composition.swift` — `Composition`, `CompositionSection`, `Line`, `LineType`. All `Codable`. `CompositionSection` is named to avoid collision with `SwiftUI.Section`. `Line.init(from:)` accepts both the `{ type, cells }` shape and the legacy bare-array shape from old web-app exports (see `migrateLine` in the pre-refactor `app.js`).
  - `Taal.swift` — `TaalID` enum with `matras`, `markers`, `vibhags`, `vibhagEndIndices`.
- `Sync/` — Foundation-only, so it is compiled into both the app and `PanchamTests`. `AuthSession` (email-code sign-in, session in `session.json`), `PanchamAPI` (PostgREST calls), `SyncEngine` (push/pull between the local cache and the server), `SyncState` (`AccountStorage`: where the cache lives, and the manifest), `ServerConfig`.
- `DSL/SwaraParser.swift` — direct port of the `parseToken` / `parseCell` functions from the old `app.js`. Returns `[SwaraToken]`.
- `Views/` — one file per visual concept. Hierarchy is `EditorView` → (toolbar) + page: `MetaHeaderView`, `SectionView` (× N) containing `NotationGridView` with `CellView` cells that delegate rendering to `SwaraView` / `RenderedCell` in render mode.
- `Theme/Theme.swift` — colour and font tokens mapped 1:1 from the old Hindustan Editorial CSS. `Color(hex:)` helper, `paperBackground()` view modifier for the cream + double-rule page treatment.
- `Resources/Fonts/` — four variable-font TTFs (Noto Serif Devanagari, EB Garamond upright + italic, IBM Plex Sans). Registered via `ATSApplicationFontsPath=Fonts` in `Info.plist`, referenced in `Theme.Fonts.*` by family name.

## Accounts, sync and history

`RootView` shows `LoginView` until `AuthSession.account` is set (a stored session counts, offline too), then `LibraryEditor`. Each account has a cache folder, `~/Library/Application Support/Pancham/accounts/<id>/` (override the base with `PANCHAM_DATA_DIR`): `library/` (private notations as `folder/name.pancham`), `global/` (shared ones; read-only unless the account is an admin), `sync.json`. The editor only ever reads and writes those files, so it is as fast as before and works offline.

`SyncEngine` runs every 30 s and shortly after any save: it pushes files whose bytes/name/folder differ from what was last synced (each push is a new revision on the server) and pulls the server's change feed. A rename or delete must go through `Library` (it reports `LibraryEvent`s) so the notation keeps its identity and history; a file merely missing from the cache is fetched again, never treated as a delete. If both sides changed one notation, the local version is kept as a "(conflicted copy …)" notation. The server keeps every revision and never deletes: History and Recently deleted in the app read it back.

Point the app at a server with `PANCHAM_AUTH_URL` / `PANCHAM_REST_URL` (environment variables only; give a development run its own `PANCHAM_DATA_DIR` too); the Cloudflare Access service token comes from `Config/Local.xcconfig` (gitignored). `server/dev_stack.py` runs a throwaway backend for development. The server, the schema and the kamaji deployment are documented in `server/README.md`.

## Tests

```
python3 -I -m unittest discover -s server/tests
xcodebuild test -project Pancham.xcodeproj -scheme Pancham -destination 'platform=macOS' -only-testing:PanchamTests
```

The Swift tests drive `Sync/` against a real throwaway Postgres + PostgREST + sign-in server (`server/dev_stack.py`); they skip if `brew install postgresql@18 postgrest dbmate` hasn't been run. Never point tests at kamaji.

## State flow

There's no ObservableObject / Redux layer. The document is a value type; SwiftUI `@Binding` plumbing runs from `EditorView` → `SectionView` → `NotationGridView` → `CellView`. `PanchamDocument.composition.normalize()` runs on load to pad or truncate every line's `cells` array to the current taal's matra count; call it again if you ever change the taal programmatically mid-session.

## File format

Same JSON shape as the original web app's Export JSON output. The `.pancham` UTType conforms to `public.json` so macOS treats these as editable text files. Legacy web-app JSON (with the old `[string,…]` line shape) opens via the fallback path in `Line.init(from:)`.

## DSL

`S R G M P D N` shudh · lowercase `r g d n` komal · `M'` tivra · `.S` mandra · `^S` taar · `-`/`s` sustain (ऽ). Space inside one cell = multi-swara matra, sized down per the CSS `multi-2/3/4` scales (0.78 / 0.68 / 0.56).

## Gotchas

- `Section` is `SwiftUI.Section`. Our model type is **`CompositionSection`**. Don't rename it back.
- `DocumentGroup(newDocument:)` takes a `Document` value, not a closure.
- xcodegen, if given an `info:` block on a target, will stomp any custom `Info.plist`. The current `project.yml` omits `info:` and only sets `INFOPLIST_FILE` via target settings, so the checked-in `Pancham/Info.plist` is preserved.
- Hardened runtime is disabled in Debug (ad-hoc codesigning note during build). That's expected locally and doesn't affect release builds.
