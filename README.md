# Pancham · पंचम

A native macOS app for writing Hindustani classical music notations in the Bhatkhande system. Type swaras with a simple keyboard DSL; they render as Devanagari with proper komal/tivra/mandra/taar markings, on a cream editorial-manuscript page.

## Features

- Document-based (each notation is a `.pancham` file). File → New, Open, Save, Duplicate, Revert, Open Recent. macOS autosave + versioning come for free.
- 16-cell matra grid (or 14 for Deepchandi) with sections, notation lines, and lyric lines.
- Title, raga, taal, laya, and BPM metadata.
- Edit / Render toggle (⌘R). Render mode rewrites cells into typeset Devanagari with proper decorations, and is the view used for export.
- Hindustan Editorial visual design — cream paper, aubergine ink, EB Garamond + Noto Serif Devanagari + IBM Plex Sans (all bundled).

## Running it

Open `Pancham.xcodeproj` in Xcode 16+ on macOS 15 Sequoia, select the `Pancham` scheme, and hit Run. Or from the CLI:

```
xcodegen generate   # regenerate .xcodeproj from project.yml (only needed if you changed it)
xcodebuild -project Pancham.xcodeproj -scheme Pancham -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Pancham-*/Build/Products/Debug/Pancham.app
```

Requires Xcode 16+ and `brew install xcodegen` if you want to regenerate the project file from `project.yml`.

## Input DSL

Typed into each notation cell:

- `S R G M P D N` — shudh swaras
- `r g d n` — komal (lowercase, renders underlined)
- `M'` — tivra (vertical tick above)
- `.S` — mandra (dot below)
- `^S` — taar (dot above)
- `-` or `s` — sustain (ऽ)
- Space inside one cell — multiple swaras in the same matra (rendered smaller)
- Tab — next cell

## Project layout

```
Pancham.xcodeproj
Pancham/
  App/           @main, DocumentGroup, menu commands
  Document/      Composition / Section / Line / Taal — Codable state model
  DSL/           SwaraParser — ports parseToken/parseCell from the old web app
  Views/         EditorView, MetaHeaderView, SectionView, NotationGridView,
                 CellView, SwaraView, LegendView, NotesView
  Theme/         Theme.swift — colors, fonts, paperBackground modifier
  Resources/
    Fonts/       Bundled Noto Serif Devanagari, EB Garamond, IBM Plex Sans
  Assets.xcassets
  Info.plist     ATSApplicationFontsPath, UTExportedTypeDeclarations for .pancham
Examples/
  aaj-ibaadat.pancham, sakhi-ae-ri.pancham  (sample compositions)
project.yml      xcodegen spec
```

## File format

`.pancham` files are JSON. The schema matches the original web app's Export JSON output, so any JSON exported from the web version opens in the Mac app directly. See `Pancham/Document/Composition.swift` for the Codable types.

## License

The bundled fonts are redistributed under their original licenses (all OFL/SIL): Noto Serif Devanagari (Google), EB Garamond (Georg Mayr-Duffner), IBM Plex Sans (IBM). See each font's LICENSE on its upstream repository.
