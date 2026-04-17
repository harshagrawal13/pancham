# Pancham

A static web app for writing Hindustani classical music notations in the Bhatkhande system. Type swaras with a simple keyboard DSL; they render as Devanagari with proper komal/tivra/mandra/taar markings.

## Features

- 16-cell matra grid with sections, notation lines, and lyric lines
- Title, raga, taal, laya, and BPM metadata
- File tree sidebar with folders, backed by Supabase
- Auto-save every 5s, with a localStorage cache for instant reloads
- Username-scoped storage — no real auth, just a name tied to your rows

## Running locally

```
cp .env.example .env    # fill in SUPABASE_URL + SUPABASE_ANON_KEY
./build-config.sh       # writes config.js from .env
python3 -m http.server 8000
```

Open `http://localhost:8000`. Re-run `build-config.sh` whenever `.env` changes.

Apply `schema.sql` in the Supabase SQL editor to create the `folders` and `notations` tables.

## Input DSL

Typed into each cell:

- `S R G M P D N` — shudh swaras
- `r g d n` — komal (lowercase)
- `M'` — tivra
- `.S` — mandra (lower octave)
- `^S` — taar (upper octave)
- `-` or `s` — sustain (ऽ)
- Space — multiple swaras in one matra
- Tab — next cell · Enter — commit and advance

## Architecture

Three plain scripts load into the same window and share globals:

- `drive.js` — Supabase client and data layer (`db*` / `drive*` functions)
- `sidebar.js` — file-tree UI, owns `currentFileId`
- `app.js` — editor core, owns the `state` object and rendering

No build step, no package manager, no tests. See `CLAUDE.md` for deeper notes.

## Auth

There is no Supabase Auth. On first load you type a username; it is stored in `localStorage` and appended to every query. RLS is disabled. Safe on localhost; **not** safe to expose publicly without adding a real auth layer.
