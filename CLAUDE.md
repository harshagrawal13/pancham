# CLAUDE.md

Notes for Claude Code working in this repo.

## What this is

Pancham is a native macOS SwiftUI app for writing Hindustani classical notations in the Bhatkhande system. Each notation is a `.pancham` file (JSON under the hood). macOS 15 Sequoia minimum.

## Build

```
xcodegen generate
xcodebuild -project Pancham.xcodeproj -scheme Pancham -destination 'platform=macOS' build
```

`xcodegen` is required to regenerate the project from `project.yml`. Install it with `brew install xcodegen`. `Pancham.xcodeproj` is checked in, so a fresh clone can be opened in Xcode without running xcodegen first.

## Architecture

Single target `Pancham`, built from source under `Pancham/`:

- `App/PanchamApp.swift` — `@main`, `DocumentGroup<PanchamDocument>`. Menu customization via `.commands { }`.
- `Document/`
  - `PanchamDocument.swift` — `FileDocument` conforming to `.panchamNotation` UTType. Wraps a `Composition`.
  - `Composition.swift` — `Composition`, `CompositionSection`, `Line`, `LineType`. All `Codable`. `CompositionSection` is named to avoid collision with `SwiftUI.Section`. `Line.init(from:)` accepts both the `{ type, cells }` shape and the legacy bare-array shape from old web-app exports (see `migrateLine` in the pre-refactor `app.js`).
  - `Taal.swift` — `TaalID` enum with `matras`, `markers`, `vibhags`, `vibhagEndIndices`.
- `DSL/SwaraParser.swift` — direct port of the `parseToken` / `parseCell` functions from the old `app.js`. Returns `[SwaraToken]`.
- `Views/` — one file per visual concept. Hierarchy is `EditorView` → (toolbar) + page: `MetaHeaderView`, `SectionView` (× N) containing `NotationGridView` with `CellView` cells that delegate rendering to `SwaraView` / `RenderedCell` in render mode.
- `Theme/Theme.swift` — colour and font tokens mapped 1:1 from the old Hindustan Editorial CSS. `Color(hex:)` helper, `paperBackground()` view modifier for the cream + double-rule page treatment.
- `Resources/Fonts/` — four variable-font TTFs (Noto Serif Devanagari, EB Garamond upright + italic, IBM Plex Sans). Registered via `ATSApplicationFontsPath=Fonts` in `Info.plist`, referenced in `Theme.Fonts.*` by family name.

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
