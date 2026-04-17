# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Pancham is a static web app for writing Hindustani classical music notations in the Bhatkhande system. No build step, no package manager — three plain `.js` files loaded by `index.html`, backed by Supabase for auth + storage.

## Running locally

```
cp .env.example .env    # then fill in SUPABASE_URL + SUPABASE_ANON_KEY
./build-config.sh       # writes config.js from .env
python3 -m http.server 8000
```

Then open `http://localhost:8000`. `build-config.sh` must be re-run whenever `.env` changes. The backend schema (tables `folders` and `notations`, RLS policies) is documented in the header comment of `drive.js` and must be applied manually in the Supabase SQL editor.

There are no tests, no linter, no build.

## Architecture

Three globals-based scripts share state by loading into the same window, in this order: `drive.js` → `sidebar.js` → `app.js`.

- **`app.js`** — editor core. Owns the single `state` object (title, raga, taal, laya, bpm, notes, sections[]). Each section has `lines[]`; each line has `type` (`notation` | `lyric`) and 16 `cells`. Parsing of the Bhatkhande input DSL happens in `parseToken`/`parseCell`; rendering to Devanagari swaras with komal/tivra/mandra/taar classes happens in `renderSwara`/`renderCell`. Auto-save runs on a 5s interval via `startAutoSave` when `isDirty && currentFileId`.
- **`drive.js`** — Supabase client + data layer. Despite the name (legacy from a Google Drive backend), this talks to Supabase Postgres. Exposes `db*` functions and `drive*` aliases kept for backward compat with `sidebar.js`/`app.js` call sites. Also owns `currentUsername` and the `setUsername`/`loadUsername`/`clearUsername` helpers — rows are scoped by a plain-text `username` column (no Supabase Auth).
- **`sidebar.js`** — file-tree UI. Owns `fileTree` (expanded set, cached nodes per folder, selected folder) plus the module-level `currentFileId`/`currentFileName` that `app.js` reads and mutates directly.

State flow: user edits DOM → `save()` serializes inputs into `state`, writes `localStorage.sargam_<fileId>`, sets `isDirty` → auto-save timer calls `saveToDrive()` → `dbUpdateNotation` writes to Supabase. On boot, the last-opened file is rendered from localStorage cache first, then refreshed from Supabase in the background.

## Auth model (there isn't one)

There is no Supabase Auth. On first load the user types a username into the overlay; it is stored in `localStorage.pancham_username` and appended to every insert / every query's `.eq('username', …)`. RLS is disabled on both tables. The "Switch user" button clears the cached username and reloads the overlay. This model trusts every client that can reach the publishable key — fine on localhost, **not** safe to expose publicly without adding a real auth layer back.

## Input DSL (for the notation cells)

Documented in the legend in `index.html`. Summary:
- `S R G M P D N` shudh · lowercase `r g d n` komal · `M'` tivra · `.S` mandra · `^S` taar
- `-` or `s` sustain (ऽ)
- Space inside one cell = multiple swaras in one matra (rendered with `multi-2/3/4` size classes)
- Tab moves to next cell; Enter commits and advances

## Things to watch for

- `.env` holds Supabase credentials (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_DB_PASSWORD`). It is gitignored. `build-config.sh` reads it and generates `config.js` (also gitignored), which `index.html` loads before `drive.js`. The anon/publishable key is safe to ship since RLS enforces per-user access; the DB password must never reach the browser, which is why we generate `config.js` rather than serving `.env` directly.
- Legacy localStorage key `sargam` (no fileId) is migrated into Supabase on first sign-in (`onSignedIn` in `app.js`) — preserve that migration path if you touch boot.
- `migrateLine()` upgrades the old line-is-an-array format to `{ type, cells }` — keep it whenever you touch persistence, old files in the wild still use the array shape.
- Scripts communicate through globals (`currentFileId`, `state`, `fileTree`); there is no module system. Adding `import`/`export` would require either bundling or switching the script tags to `type="module"`.
