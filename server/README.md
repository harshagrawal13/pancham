# Pancham's backend

Pancham keeps every notation on kamaji, in Postgres, and caches a copy on each Mac. People sign in
with an email and a one-time code. There are two kinds of notation:

- **private**: seen and changed by its owner only;
- **global**: made and changed by admins only, read by everyone signed in (the shared library).

Every save is a revision and nothing is ever deleted, so each notation has its whole history, deleted
ones included.

```
Pancham.app ──(auth)──────► pancham.harsh-agrawal.com      server/server.py   :8005  sign-in, JWTs
     │  local cache                                              │ sqlite (codes, sessions: disposable)
     │  ~/Library/Application Support/Pancham/accounts/<id>/     │
     └──(documents)─► pancham-api.harsh-agrawal.com  PostgREST   :3004  ──► Postgres "pancham"
                      (Cloudflare Access in front of both; the app sends the service token)
```

## The database (`db/migrations/`)

`documents` (one row per notation) and `revisions` (one row per saved version) are the only tables.
`revisions` is **append-only**: the API role has no update or delete on it and a trigger refuses both
from anyone, so history can't be rewritten. Row level security reads who is asking from the JWT
(`sub` = the account, `admin` = may manage global notations), so each account sees its own private
notations plus every global one.

The API (`api` schema, served by PostgREST):

| | |
|---|---|
| `GET /docs?seq=gt.<cursor>&order=seq.asc&limit=50` | the sync feed: newest revision of each changed notation, content included |
| `GET /docs?deleted=eq.true&scope=eq.private&select=...` | your deleted notations (they can come back) |
| `GET /revisions?doc_id=eq.<id>&select=rev,...&order=rev.desc` | a notation's history |
| `GET /revisions?doc_id=eq.<id>&rev=eq.<n>&select=content` | one old version |
| `POST /rpc/save_revision` | the one way to create or change a notation: optimistic (`p_base` = the revision you started from; 409 on a conflict), idempotent (saving what is already there changes nothing) |

A rename, a move, a delete and a restore are each a revision too. An "undo" is a new revision with the
old content, never an edit of history.

## Sign-in (`server.py`, `auth.py`)

`POST /auth/v1/otp {email}` emails a six-digit code (good for 30 minutes and used once; up to five can be
live at once, so a stranger asking for codes can't cancel the one you just got; ten wrong tries in 15
minutes lock that address for the rest of the window); `POST /auth/v1/verify {email, token}` returns an access token (an HS256 JWT PostgREST
checks itself, one hour) and a refresh token (the session, 90 days from last use);
`/auth/v1/token?grant_type=refresh_token` and `/auth/v1/logout` do the obvious. An account's id is a
UUIDv5 of its email, so notations belong to an address and survive losing the session file.

Who may sign in is a list, not a table, and **an empty list lets nobody in**. It is in `server/.env` on
kamaji (gitignored; see `.env.example`).

## Running a copy on this Mac

```
brew install postgresql@18 postgrest dbmate
python3 server/dev_stack.py --admin you@example.com --allow friend@example.com
```

prints the URLs and runs a throwaway Postgres + PostgREST + sign-in server until you close it (nothing
is emailed: the code is written to a file it names). To point a build of the app at it without touching
your real data:

```
open Pancham.app --env PANCHAM_AUTH_URL=http://127.0.0.1:P --env PANCHAM_REST_URL=http://127.0.0.1:Q \
                 --env PANCHAM_DATA_DIR=/tmp/pancham-dev
```

## Tests

```
python3 -I -m unittest discover -s server/tests          # sign-in, and the database through PostgREST
xcodebuild test -project Pancham.xcodeproj -scheme Pancham -destination 'platform=macOS' -only-testing:PanchamTests
```

The Swift tests start `dev_stack.py` per test and drive the app's real sync code against it: push, pull,
conflicts, rename/move, delete/undelete, restore, global vs private, offline, revoked sessions. Both
skip when the Homebrew tools are missing.

## Putting it on kamaji

kamaji is production only; follow kamaji-server's [Add an app](https://github.com/harshagrawal13/kamaji-server/blob/main/docs/runbook.md#add-an-app).
The pieces are ready in `server/kamaji/` (once they are in kamaji-server, which then owns them, delete that folder here so two copies can't drift):

1. **Cloudflare dashboard** (one-time): an Access application `pancham` for `pancham.harsh-agrawal.com`
   and `pancham-api.harsh-agrawal.com`, with a Service Auth policy for a new service token
   `pancham-app`. Copy the application's AUD tag and the token's id and secret.
2. **kamaji-server**: add `server/kamaji/apps.toml.snippet` (with the AUD) to `apps.toml` and
   `server/kamaji/com.harsh.pancham.plist` to `launchagents/`; `bin/kamaji render`; commit, push.
3. **kamaji**: the Pancham checkout must be clean (`git status`), then `bin/kamaji add-app pancham --yes`.
4. **`server/.env` on kamaji** (0600): `PANCHAM_ADMIN_EMAILS=you@example.com`, and an email provider:
   `PANCHAM_SMTP_*` (e.g. Gmail with an app password) or `RESEND_API_KEY`, plus `PANCHAM_AUTH_EMAIL_FROM`
   (see `.env.example`). Until a sender domain is verified with Resend, only the
   Resend account's owner gets mail; anyone else gets a code from `python3 server/auth_cli.py code <email>`.
5. `bin/kamaji deploy pancham --yes`, then `bin/kamaji check`.
6. **Build the app** with the token in `Config/Local.xcconfig` (see `Config/Pancham.xcconfig`).

7. **Put your existing notations in the cloud, once:**
   `python3 server/import_notations.py ~/Documents/Pancham --email you@example.com`. It signs in like the app
   (type the emailed code), adds each notation as a private one, and skips any already there.

Adding a person later is one more address in `PANCHAM_AUTH_EMAILS` and a restart of `com.harsh.pancham`.
