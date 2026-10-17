# UTCCNJ Mobile App

A church app for UTCCNJ, built with [Flet](https://flet.dev) (Python that compiles
to Android/iOS/web/desktop via Flutter) and [Supabase](https://supabase.com)
(hosted Postgres) as the backend.

## Architecture

- `main.py` is the whole app — single-file Flet app, route-based navigation
  (`page.views` stack), no separate backend server code. All data access goes
  straight from `main.py` to Supabase via `supabase-py`.
- **Login has no password.** A person types their phone number or email; it's
  looked up against the `users` table via the `login_lookup()` Postgres
  function (case-insensitive on email). Role comes back with it and gates
  which screens/buttons show.
- Right now we test via `flet run --ios` / `flet run -w`, which runs `main.py`
  as a dev server that a phone (via the **Flet** app from the App Store) or
  browser connects to over the LAN. **This is temporary.** The long-term plan
  is `flet build apk` / `flet build ipa` to produce standalone compiled apps
  for the App Store / Play Store — at that point the compiled app talks
  directly to Supabase (anon key + Row Level Security), no server needed at
  all. iOS builds require a Mac/Xcode or a CI runner with one; Android builds
  fine from Windows.

## Environment

- Python venv is `venv/` — **not** `.venv/` (that's an empty stray folder from
  early setup, never deleted, ignore it). Always invoke
  `venv/Scripts/python.exe` or `venv/Scripts/flet.exe` directly.
- Credentials live in `.env` (gitignored): `SUPABASE_URL`, `SUPABASE_ANON_KEY`.
  Loaded via `python-dotenv` at the top of `main.py`.
- No git repo initialized in this folder yet.

## Database (Supabase)

`supabase_schema.sql` is a **running log of migrations** — each "Migration N"
block is meant to be pasted into the Supabase SQL Editor and run once, in
order. It is not a single idempotent script you re-run wholesale (see the
header comment in the file for exactly where that stops being true). When
adding new schema changes, append a new numbered migration block rather than
editing old ones, unless a prior migration never actually applied (e.g. it
targeted rows that had already been deleted) — check with the user first.

Tables:
- **`users`** — `phone`, `email`, `whatsapp` (all nullable, unique when
  present, at least one of phone/email required), `display_name`, `role`
  (`teacher` | `parent` | `general`).
- **`classes`** — 4 Sunday school classes, each with one `teacher_id` (FK to
  `users`): Shining Stars (3-6, Rebekkah Maggam), Little Stars (6-9, Grace
  Chintapalli), Fishermen Group 1 (9-12, Sharada Nanneti), Fishermen Group 2
  (12-15, Sridhar Nerudumilli).
- **`kids`** — child records (`name`, `class_id`, `parent_id`). **Table
  exists but is not yet seeded** — waiting on the student list from the user.
  A parent can have multiple kids, same or different classes.
- **`announcements`**, **`events`** — general content, visible to everyone.
  Managed by the user directly in Supabase's Table Editor (not through the
  app), matching their preference to administer content from a browser
  rather than build an in-app admin UI.
- **`homework_posts`** — teacher-authored, scoped to `class_id` (looked up
  automatically from the logged-in teacher via `classes.teacher_id` — a
  teacher never picks their class, the app already knows it).
- **`homework_responses`** — parent-authored, references `kid_id`. **Not
  fully wired in `main.py` yet** — the UI still needs a kid-picker for
  parents, blocked on the `kids` table being populated.

RLS is on for every table. The anon key can only ever: read announcements/
events/homework, and insert (never update/delete) homework posts/responses.
The full `users` and `kids` tables are deliberately **not** directly
selectable via anon — login and kid lookups go through `SECURITY DEFINER`
functions (`login_lookup`, `get_kids_for_parent`, `get_class_roster`) that
return only the matching row(s), not the whole table. This was a deliberate
choice since the compiled app will eventually embed the anon key client-side,
which anyone can extract from the binary.

## Known gotchas (learned the hard way this session)

- **`page.push_route(route)` is a no-op if `route` equals Flet's internally
  tracked last-seen route** (`Page.before_event` in the flet package cancels
  the event). This bit us on login: pushing `"/"` after a successful login
  did nothing because the route had never actually changed away from `"/"`
  (the login screen is just a *view* shown while unauthenticated, not a real
  route change). Fix used throughout `main.py`: call `route_change(page.route)`
  directly instead of `push_route` whenever you need to force a rebuild
  without an actual route change (see `logout_click` and the login `submit`
  handler).
- Flet's Flutter-web/canvas rendering has no real DOM elements for most
  widgets — browser automation tools can't click buttons by selector or
  CSS. A hidden `<input>` overlay does exist for text fields (so typing can
  be tested), but buttons cannot be reliably driven this way. Verify button
  flows via real device/browser interaction, or by testing the underlying
  Supabase calls directly in a throwaway script.
- When launching `flet run --ios` or `-w` from a script/background process
  on Windows, set `PYTHONUNBUFFERED=1` and `PYTHONIOENCODING=utf-8` —
  otherwise output buffers and the ASCII-art QR code crashes on Windows'
  default cp1252 console encoding.
- Windows Firewall needs an inbound rule for whatever port `flet run` binds
  to before another device on the LAN can reach it; adding firewall rules
  needs admin rights.
- `flet run --ios`/`-w` picks a port and keeps re-using it across restarts as
  long as no other process is bound to it — kill stray `python.exe` /
  `flet.exe` processes from previous test runs before relaunching, or you'll
  hit "address already in use" errors.

## Pending / next steps

- User will provide the actual student list (names + which class) to seed
  the `kids` table.
- Once seeded, wire the parent-side homework response flow in `main.py`: a
  kid-picker (via `get_kids_for_parent` RPC) instead of the current
  unfinished free-text approach.
- Quiz feature planned for later — same shape as homework (a post + one
  response per user), so it should reuse the same pattern once homework is
  fully working.
- Eventually: `flet build apk`/`ipa` for real App Store / Play Store
  submission (Apple Developer $99/yr, Google Play $25 one-time).
