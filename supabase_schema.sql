-- UTCCNJ app schema. This file is a running log of migrations -- run the
-- next new "Migration N" block in the Supabase SQL Editor as it's added
-- (Project -> SQL Editor -> New query -> paste -> Run). Each block is safe
-- to re-run by itself, but re-running the whole file from scratch only
-- works before Migration 3 (later blocks assume earlier ones already ran).

create extension if not exists pgcrypto;

-- ── Tables ──────────────────────────────────────────────────────────

create table if not exists users (
  id uuid primary key default gen_random_uuid(),
  identifier text unique not null,        -- phone number or email, whatever they log in with
  display_name text not null,
  role text not null default 'general' check (role in ('teacher', 'parent', 'general')),
  created_at timestamptz not null default now()
);

create table if not exists announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  date_label text not null,               -- free-form display date, e.g. "July 14 - July 18"
  created_at timestamptz not null default now()
);

create table if not exists homework_posts (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references users(id),
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create table if not exists homework_responses (
  id uuid primary key default gen_random_uuid(),
  homework_post_id uuid not null references homework_posts(id),
  parent_id uuid not null references users(id),
  kid_name text not null,
  response_text text not null,
  created_at timestamptz not null default now()
);

-- ── Row Level Security ──────────────────────────────────────────────
-- App connects with the public "anon" key only. Content (announcements,
-- events, users) is managed by you directly in the Supabase Table Editor,
-- which uses privileged access and bypasses RLS entirely. So the anon key
-- only ever needs: read access to content, and insert-only access to the
-- two homework tables (no update/delete from the app at all).

alter table users enable row level security;
alter table announcements enable row level security;
alter table events enable row level security;
alter table homework_posts enable row level security;
alter table homework_responses enable row level security;

-- No policies granted directly on `users` for anon -- login goes through
-- the login_lookup() function below instead, so the full roster (names,
-- phone numbers/emails) is never readable via the API.

create policy "anyone can read announcements" on announcements
  for select using (true);

create policy "anyone can read events" on events
  for select using (true);

create policy "anyone can read homework posts" on homework_posts
  for select using (true);

create policy "teachers/parents can post homework" on homework_posts
  for insert with check (true);

create policy "anyone can read homework responses" on homework_responses
  for select using (true);

create policy "parents can respond to homework" on homework_responses
  for insert with check (true);

-- ── Login (no password, just phone/email lookup) ────────────────────
-- SECURITY DEFINER lets this function read the users table even though
-- anon has no direct select policy on it -- it only ever returns the one
-- matching row's id/name/role, never the whole table.

create or replace function login_lookup(p_identifier text)
returns table (id uuid, display_name text, role text)
language sql
security definer
set search_path = public
as $$
  select id, display_name, role
  from users
  where identifier = p_identifier;
$$;

grant execute on function login_lookup(text) to anon, authenticated;

-- ── Seed data (optional -- delete this block if you'd rather add your
--    own roster/content by hand in the Table Editor) ─────────────────

insert into users (identifier, display_name, role) values
  ('teacher@example.com', 'Sample Teacher', 'teacher'),
  ('parent@example.com', 'Sample Parent', 'parent'),
  ('member@example.com', 'Sample Member', 'general')
on conflict (identifier) do nothing;

insert into announcements (title, body)
select * from (values
  ('Sunday Service Time', 'Sunday service starts at 3:30 PM this week. Doors open at 9:30 AM for fellowship and coffee beforehand.'),
  ('Potluck Lunch', 'Join us for a potluck lunch right after service — bring a dish to share! Tables will be set up in the fellowship hall.')
) as seed(title, body)
where not exists (select 1 from announcements);

insert into events (title, body, date_label)
select * from (values
  ('Vacation Bible School', 'Daily from 9 AM to 12 PM. Open to kids ages 5-12. Snacks and crafts provided. Sign up at the welcome desk or call the church office.', 'July 14 - July 18'),
  ('Men''s Breakfast', 'Monthly men''s breakfast in the fellowship hall. This month''s topic: serving the community. All men welcome, no RSVP needed.', 'July 12, 8:00 AM')
) as seed(title, body, date_label)
where not exists (select 1 from events);


-- ════════════════════════════════════════════════════════════════════
-- Migration 2: classes + kids, homework scoped to a class
-- Run this block in the SQL Editor after the schema above is already applied.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

create table if not exists classes (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  age_range text not null,
  teacher_id uuid references users(id),
  created_at timestamptz not null default now()
);

create table if not exists kids (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  class_id uuid not null references classes(id),
  parent_id uuid not null references users(id),
  created_at timestamptz not null default now()
);

alter table classes enable row level security;
alter table kids enable row level security;

drop policy if exists "anyone can read classes" on classes;
create policy "anyone can read classes" on classes
  for select using (true);

-- No select policy on `kids` for anon -- children's names are only ever
-- readable through the two functions below, each scoped to one parent or
-- one class, never the whole roster at once.

-- ── Scope homework to a class ────────────────────────────────────────
-- Development testing left some rows with no class assigned; clear those
-- out (this only ever matches rows created before this migration, so it's
-- a no-op on every future run).

alter table homework_posts add column if not exists class_id uuid references classes(id);
alter table homework_responses add column if not exists kid_id uuid references kids(id);

delete from homework_responses where homework_post_id in (select id from homework_posts where class_id is null);
delete from homework_posts where class_id is null;
alter table homework_posts alter column class_id set not null;

delete from homework_responses where kid_id is null;
alter table homework_responses alter column kid_id set not null;
alter table homework_responses drop column if exists kid_name;

-- ── Lookup functions (avoid exposing the full kids roster) ───────────

create or replace function get_kids_for_parent(p_parent_id uuid)
returns table (id uuid, name text, class_id uuid, class_name text)
language sql
security definer
set search_path = public
as $$
  select k.id, k.name, k.class_id, c.name as class_name
  from kids k
  join classes c on c.id = k.class_id
  where k.parent_id = p_parent_id;
$$;

grant execute on function get_kids_for_parent(uuid) to anon, authenticated;

create or replace function get_class_roster(p_class_id uuid)
returns table (id uuid, name text)
language sql
security definer
set search_path = public
as $$
  select id, name from kids where class_id = p_class_id;
$$;

grant execute on function get_class_roster(uuid) to anon, authenticated;

-- ── Real teachers + classes (replaces the placeholder teacher account) ──

delete from users where identifier = 'teacher@example.com';

insert into users (identifier, display_name, role)
select * from (values
  ('rebekkah.maggam', 'Rebekkah Maggam', 'teacher'),
  ('grace.chintapalli', 'Grace Chintapalli', 'teacher'),
  ('sharada.nanneti', 'Sharada Nanneti', 'teacher'),
  ('sridhar.nerudumilli', 'Sridhar Nerudumilli', 'teacher')
) as seed(identifier, display_name, role)
on conflict (identifier) do nothing;

insert into classes (name, age_range, teacher_id)
select v.name, v.age_range, u.id
from (values
  ('Shining Stars', '3-6', 'rebekkah.maggam'),
  ('Little Stars', '6-9', 'grace.chintapalli'),
  ('Fishermen Group 1', '9-12', 'sharada.nanneti'),
  ('Fishermen Group 2', '12-15', 'sridhar.nerudumilli')
) as v(name, age_range, teacher_identifier)
join users u on u.identifier = v.teacher_identifier
on conflict (name) do nothing;


-- ════════════════════════════════════════════════════════════════════
-- Migration 3: split login identifier into real phone/email columns
-- `identifier` was one column doing double duty as login credential and
-- contact info. Splitting it lets a person log in with either one while
-- we keep both on file for actually contacting them later.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table users add column if not exists phone text;
alter table users add column if not exists email text;

-- Carry over the two working sample accounts; the 4 teacher placeholders
-- are intentionally left blank until real phone/email are provided.
update users set email = identifier where identifier = 'parent@example.com' and email is null;
update users set email = identifier where identifier = 'member@example.com' and email is null;

create unique index if not exists users_phone_key on users (phone) where phone is not null;
create unique index if not exists users_email_key on users (email) where email is not null;

alter table users drop column if exists identifier;

alter table users drop constraint if exists users_has_contact_info;
alter table users add constraint users_has_contact_info check (phone is not null or email is not null);

-- login_lookup keeps the same name/signature (still takes one string) so
-- main.py doesn't need any changes -- it now just checks both columns.
create or replace function login_lookup(p_identifier text)
returns table (id uuid, display_name text, role text)
language sql
security definer
set search_path = public
as $$
  select id, display_name, role
  from users
  where phone = p_identifier or email = p_identifier;
$$;

grant execute on function login_lookup(text) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 4: WhatsApp number as its own contact field
-- Not used for login -- just contact info, kept separate since someone's
-- WhatsApp number doesn't have to match their regular phone number.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table users add column if not exists whatsapp text;

create unique index if not exists users_whatsapp_key on users (whatsapp) where whatsapp is not null;


-- ════════════════════════════════════════════════════════════════════
-- Migration 5: real teacher contact info
-- Fills in the 4 teachers with their actual phone/WhatsApp/email. Written
-- as INSERTs (not UPDATEs) since users/classes were cleared manually
-- after a constraint violation, so there were no placeholder rows left to
-- match against. Also recreates the classes (which reference these
-- teachers) and the two sample parent/general accounts used for testing.
-- Also makes email login case-insensitive, since "Rebekah.alvin@gmail.com"
-- and "rebekah.alvin@gmail.com" should be treated as the same login.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

insert into users (display_name, role, phone, whatsapp, email)
select * from (values
  ('Rebekkah Maggam', 'teacher', '412-620-8980', '412-620-8980', lower('Rebekah.alvin@gmail.com')),
  ('Grace Chintapalli', 'teacher', '732-397-7073', '732-397-7073', lower('gracekalapala999@gmail.com')),
  ('Sharada Nanneti', 'teacher', '732-4293375', '732-4293375', lower('sharada.nanneti@gmail.com')),
  ('Sridhar Nerudumilli', 'teacher', '732-742-1160', '91 80-74171024', lower('snered@gmail.com'))
) as seed(display_name, role, phone, whatsapp, email)
where not exists (
  select 1 from users u where u.email = seed.email or u.phone = seed.phone
);

-- Sample parent/general test accounts, also wiped -- recreated so
-- parent/general login keeps working for testing.
insert into users (display_name, role, email)
select * from (values
  ('Sample Parent', 'parent', 'parent@example.com'),
  ('Sample Member', 'general', 'member@example.com')
) as seed(display_name, role, email)
where not exists (select 1 from users u where u.email = seed.email);

insert into classes (name, age_range, teacher_id)
select v.name, v.age_range, u.id
from (values
  ('Shining Stars', '3-6', lower('Rebekah.alvin@gmail.com')),
  ('Little Stars', '6-9', lower('gracekalapala999@gmail.com')),
  ('Fishermen Group 1', '9-12', lower('sharada.nanneti@gmail.com')),
  ('Fishermen Group 2', '12-15', lower('snered@gmail.com'))
) as v(name, age_range, teacher_email)
join users u on u.email = v.teacher_email
on conflict (name) do nothing;

create or replace function login_lookup(p_identifier text)
returns table (id uuid, display_name text, role text)
language sql
security definer
set search_path = public
as $$
  select id, display_name, role
  from users
  where phone = p_identifier or lower(email) = lower(p_identifier);
$$;

grant execute on function login_lookup(text) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 6: members table, imported from UTCCNJ_Members.xlsx
-- One row per family member (not per login account -- unlike `users`,
-- this is the full church roster including kids, spouses, etc., sourced
-- from the "Birthdays" sheet of the spreadsheet the office maintains).
-- `family_code` groups members of the same household together (e.g.
-- everyone with family_code 'Maggam01' is one family). `birth_month_day`
-- is MM/DD text, not a date -- the source sheet has no birth year.
-- RLS is on with no policies granted to anon, same as `users`/`kids`:
-- this is PII (names, phone numbers) not meant to be readable by the
-- app's anon key. Nothing in main.py reads this table yet.
-- Safe to re-run except the INSERT block, which is not idempotent (no
-- natural unique key across rows to conflict on) -- only run the INSERT
-- once.
-- ════════════════════════════════════════════════════════════════════

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  first_name text not null,
  middle_name text,
  last_name text,
  phone_number text,
  family_code text not null,
  birth_month_day text,
  gender text check (gender in ('Male', 'Female')),
  status_in_family text,
  active boolean not null default true,
  email text,
  whatsapp_id text,
  created_at timestamptz not null default now()
);

alter table members enable row level security;

insert into members
  (first_name, middle_name, last_name, phone_number, family_code, birth_month_day, gender, status_in_family, active, email, whatsapp_id)
values
  ('Josh', null, 'Neredumalli', null, 'Neredumalli01', '01/01', 'Male', 'Son', true, null, null),
  ('Sujatha', null, 'Jilla', '7325758089', 'Jilla01', '01/02', 'Female', 'Mother', false, null, null),
  ('Josephine', null, 'Sarella', '7324296463', 'Sarella01', '01/05', 'Female', 'Daughter', true, null, null),
  ('Jemima', null, 'Sarella', '9083927647', 'Sarella01', '01/05', 'Female', 'Daughter', true, null, null),
  ('Rajinikanth', null, 'Penumala', '7326620677', 'Penumala01', '01/09', 'Male', 'Father', true, null, null),
  ('Neil', 'Theodore', 'Moluguri', '7324259816', 'Moluguri01', '01/16', 'Male', 'Son', true, null, null),
  ('Sandeep', 'Joseph', 'Sokkula', '2017361821', 'Sokkula01', '01/16', 'Male', 'Husband', true, null, null),
  ('Suneeth', null, 'Penumula', '7322094541', 'Penumula01', '01/19', 'Male', 'Son', true, null, null),
  ('Sushanth', null, 'Penumula', null, 'Penumula01', '01/26', 'Male', 'Son', true, null, null),
  ('Sathvik', null, 'Penumala', null, 'Penumala01', '02/06', 'Male', 'Son', true, null, null),
  ('Joanna', null, 'Inumula', null, 'Inumula01', '02/09', 'Female', 'Daughter', true, null, null),
  ('Nalinikanth', null, 'Penumala', '7323711450', 'Penumala01', '02/16', 'Male', 'Father', true, null, null),
  ('Mylah', null, 'Jilla', null, 'Jilla01', '02/17', 'Female', 'Daughter', false, null, null),
  ('Timothy', null, 'Kalapala', '9085295807', 'Kalapala01', '02/20', 'Male', 'Son', false, null, null),
  ('Joshua', null, 'Sarella', '9082215016', 'Sarella01', '02/22', 'Male', 'Father', true, null, null),
  ('Jonathan', 'Israel', 'Polimary', null, 'Polimary01', '03/05', 'Male', 'Son', true, null, null),
  ('Adelina', null, 'Maggam', null, 'Maggam01', '03/07', 'Female', 'Daughter', true, null, null),
  ('Jyostna', null, 'Kalapala', '9084768866', 'Kalapala01', '03/17', 'Female', 'Mother', false, null, null),
  ('Aiyana', null, 'Chintapalli', null, 'Chintapalli01', '03/22', 'Female', 'Daughter', true, null, null),
  ('Ryan', null, 'Moluguri', null, 'Moluguri01', '03/23', 'Male', 'Son', true, null, null),
  ('Aaron', null, 'Moluguri', null, 'Moluguri01', '03/23', 'Male', 'Son', true, null, null),
  ('Rajakumari', null, 'Moluguri', '5513584386', 'Moluguri01', '03/23', 'Female', 'Mother', true, null, null),
  ('Ritvik', null, 'Sundaram', null, 'Sundaram01', '03/27', 'Male', 'Son', true, null, null),
  ('Alvin', null, 'Maggam', '4128011841', 'Maggam01', '03/31', 'Male', 'Father', true, null, null),
  ('Pramod', null, 'Palaparti', '7323971253', 'Palaparti01', '04/05', 'Male', 'Father', true, null, null),
  ('Vini', null, 'Manchala', '2256639567', 'Manchala01', '04/10', 'Female', 'Wife', true, null, null),
  ('Alan', null, 'Maggam', null, 'Maggam01', '04/10', 'Male', 'Son', true, null, null),
  ('Niveditha', null, 'Penumala', '7326620956', 'Penumala01', '04/12', 'Female', 'Mother', true, null, null),
  ('Abilash', null, 'Jilla', null, 'Jilla01', '04/15', 'Male', 'Son', false, null, null),
  ('Manisha', null, 'Iruvanti', '6173202118', 'Iruvanti01', '04/17', 'Female', 'Wife', true, null, null),
  ('Gopinath', null, 'Potharlanka', null, 'Potharlanka01', '04/28', 'Male', 'Father', true, null, null),
  ('Noel', null, 'Kusuma', '8482443828', 'Kusuma01', '05/01', 'Male', 'Son', true, null, null),
  ('Sridevi', null, 'Kusuma', '7328416516', 'Kusuma01', '05/07', 'Female', 'Mother', true, null, null),
  ('Vijay', null, 'Talari', '7329866757', 'Talari01', '05/13', 'Male', 'Father', true, null, null),
  ('Ethan', null, 'Roy', null, 'Roy01', '05/14', 'Male', 'Son', true, null, null),
  ('Sudha Kiran', null, 'Gatala', '7733832987', 'Gatala01', '05/18', 'Male', 'Father', true, null, null),
  ('Niva', null, 'Sundaram', null, 'Sundaram01', '05/20', 'Male', 'Daughter', true, null, null),
  ('Grace', null, 'Inumula', '8482568651', 'Inumula01', '05/23', 'Female', 'Daughter', true, null, null),
  ('Dinesh', null, 'Bellary', '5512259771', 'Bellary01', '05/24', 'Male', 'Father', true, null, null),
  ('Jay', 'Viraaj', 'Divya', null, 'Divya01', '05/24', 'Male', 'Son', true, null, null),
  ('Venkat', null, 'Punati', '3157968787', 'Punati01', '05/27', 'Male', 'Father', true, null, null),
  ('Aparna', null, 'Inumula', '7327701572', 'Inumula01', '05/31', 'Female', 'Mother', true, null, null),
  ('Vasudha', null, 'Sundaram', null, 'Sundaram01', '06/02', 'Female', 'Mother', true, null, null),
  ('Ariya', null, 'Jilla', null, 'Jilla01', '06/03', 'Female', 'Daughter', false, null, null),
  ('Dheeraj', null, 'Bellary', '8483364247', 'Bellary01', '06/05', 'Male', 'Son', true, null, null),
  ('Veronica', null, 'Neredumalli', '2038077738', 'Neredumalli01', '06/05', 'Female', 'Mother', true, null, null),
  ('Rachel', null, 'Sarella', '7187554875', 'Sarella01', '06/06', 'Female', 'Mother', true, null, null),
  ('Jamie', null, 'Manchala', '2253626507', 'Manchala01', '06/07', 'Male', 'Husband', true, null, null),
  ('Deepa', null, 'Nutulapati', '5512323368', 'Nutulapati01', '06/08', 'Female', 'Mother', true, null, null),
  ('Paul', null, 'Kalapala', '2017362998', 'Kalapala01', '06/09', 'Male', 'Father', false, null, null),
  ('Prashanth', null, 'Sundaram', null, 'Sundaram01', '06/11', 'Male', 'Father', true, null, null),
  ('David', null, 'Parisapogu', '7328329994', 'Parisapogu01', '06/14', 'Male', 'Father', true, null, null),
  ('Prathyusha (Preeti)', null, 'Israel', '2034143305', 'Israel01', '06/16', 'Female', 'Mother', true, null, null),
  ('Nita', null, 'Villuri', '7325002768', 'Villuri01', '06/17', 'Female', 'Mother', false, null, null),
  ('Avinash', null, 'Gottiparthi', '8134059965', 'Gottiparthi01', '06/18', 'Male', 'Husband', true, null, null),
  ('Mrudhu Bhashini', null, 'Palaparti', '7327319759', 'Palaparti01', '06/19', 'Female', 'Mother', true, null, null),
  ('Manasa', null, 'Penumala', '7326460366', 'Penumala01', '06/20', 'Female', 'Mother', true, null, null),
  ('Emily', null, 'Neredumalli', null, 'Neredumalli01', '06/25', 'Female', 'Daughter', true, null, null),
  ('Sreshta', null, 'Nutulapati', '3477141329', 'Nutulapati01', '06/26', 'Female', 'Daughter', true, null, null),
  ('Madhuri', null, 'Joseph', '7327816711', 'Joseph01', '06/26', 'Female', 'Mother', true, null, null),
  ('Evelyn', null, 'Talari', '7329867967', 'Talari01', '06/28', 'Female', 'Mother', true, null, null),
  ('Sharmili', null, 'Penumula', null, 'Penumula01', '06/29', 'Female', 'Daughter', true, null, null),
  ('Ruth', null, 'Villuri', null, 'Villuri01', '07/02', 'Female', 'Daughter', false, null, null),
  ('Sridhar', null, 'Nerudumalli', '7327421160', 'Nerudumalli01', '07/04', 'Male', 'Father', true, null, null),
  ('Joseph', null, 'Villuri', null, 'Villuri01', '07/06', 'Male', 'Son', false, null, null),
  ('Daniel', null, 'Kusuma', '8482443827', 'Kusuma01', '07/12', 'Male', 'Son', true, null, null),
  ('Kishore', null, 'Inumula', '6789109877', 'Inumula01', '07/16', 'Male', 'Father', true, null, null),
  ('Nishith', 'Abhay', 'Palaparti', null, 'Palaparti01', '07/20', 'Male', 'Son', true, null, null),
  ('Naveen', 'kumar', null, null, '01', '07/23', 'Male', 'Son', false, null, null),
  ('Ravi', 'Kumar', 'Moluguri', '7329107870', 'Moluguri01', '07/27', 'Male', 'Father', true, null, null),
  ('Jessica', 'Roy', 'Madda', null, 'Madda01', '07/28', 'Female', 'Daughter', true, null, null),
  ('Emmanuel', null, 'Inumula', null, 'Inumula01', '07/28', 'Male', 'Son', true, null, null),
  ('Vinod', 'Roy', 'Madda', '8183225789', 'Madda01', '08/06', 'Male', 'Father', true, null, null),
  ('Vihaan', 'Isaac', 'Joseph', null, 'Joseph01', '08/08', 'Male', 'Son', true, null, null),
  ('Sunitha', 'Dinesh', 'Bellary', '5512259791', 'Bellary01', '08/11', 'Female', 'Mother', true, null, null),
  ('Suresh', null, 'Jilla', null, 'Jilla01', '08/13', 'Male', 'Son', true, null, null),
  ('Ratna Kumar', null, 'Nutulapati', '3467049534', 'Nutulapati01', '08/14', 'Male', 'Father', true, null, null),
  ('Serena', null, 'Maggam', null, 'Maggam01', '08/19', 'Female', 'Daughter', true, null, null),
  ('Preethika', null, 'Jogu', '7323970030', 'Jogu01', '08/19', 'Female', 'Mother', true, null, null),
  ('Riya', null, 'Jeedi', null, 'Jeedi01', '08/24', 'Female', 'Daughter', true, null, null),
  ('Kiran', null, 'Chintapalli', '9046350273', 'Chintapalli01', '08/28', 'Male', 'Father', true, null, null),
  ('Anvesh', null, 'Jogu', '7036180717', 'Jogu01', '08/28', 'Male', 'Father', true, null, null),
  ('Sharada', null, 'Nanneti', '7324293375', 'Nanneti01', '08/30', 'Female', 'Mother', true, null, null),
  ('James', null, 'Parisapogu', '7327428565', 'Parisapogu01', '09/01', 'Male', 'Father', true, null, null),
  ('Jaden', null, 'Inumula', null, 'Inumula01', '09/02', 'Male', 'Son', true, null, null),
  ('Sasha', null, 'Iruvanti', null, 'Iruvanti01', '09/02', 'Female', 'Daughter', true, null, null),
  ('Mavis', null, 'Pattabhi', '9083803075', 'Pattabhi01', '09/05', 'Female', 'Mother', true, null, null),
  ('Darin', null, 'Talari', '7323104746', 'Talari01', '09/06', 'Male', 'Son', true, null, null),
  ('Samson', null, 'Jeedi', '6099066960', 'Jeedi01', '09/07', 'Male', 'Father', true, null, null),
  ('Joanne', null, 'Kalapala', null, 'Kalapala01', '09/09', 'Female', 'Daughter', false, null, null),
  ('Akash', null, 'Jilla', null, 'Jilla01', '09/10', 'Male', 'Son', false, null, null),
  ('Grace', null, 'Chintapalli', null, 'Chintapalli01', '09/11', 'Female', 'Mother', true, null, null),
  ('Cyrus', null, 'Jogu', null, 'Jogu01', '09/12', 'Male', 'Son', true, null, null),
  ('Cyril', null, 'Jogu', null, 'Jogu01', '09/12', 'Male', 'Son', true, null, null),
  ('Sunny', null, 'Israel', '2013033250', 'Israel01', '09/12', 'Male', 'Father', true, null, null),
  ('Sujay', null, null, null, '01', '09/17', 'Male', 'Son', true, null, null),
  ('Tanmayee', null, 'Joseph', null, 'Joseph01', '09/21', 'Female', 'Daughter', true, null, null),
  ('Nathan', null, 'Jeedi', null, 'Jeedi01', '09/22', 'Male', 'Son', true, null, null),
  ('Amaira', 'Judith', 'Chintapalli', null, 'Chintapalli01', '09/23', 'Female', 'Daughter', true, null, null),
  ('Mahith', 'Tanay', 'Palaparti', '7324444634', 'Palaparti01', '10/03', 'Male', 'Son', true, null, null),
  ('Pranita', null, 'Sokkula', '8482703545', 'Sokkula01', '10/03', 'Female', 'Wife', true, null, null),
  ('Johnson', null, 'Joseph', '7329865201', 'Joseph01', '10/05', 'Male', 'Father', true, null, null),
  ('Vincent', null, 'Villuri', null, 'Villuri01', '10/08', 'Male', 'Son', false, null, null),
  ('Kavya', null, 'Jeedi', '6099062357', 'Jeedi01', '10/09', 'Female', 'Mother', true, null, null),
  ('Bobby', null, 'Nanneti', '7324293447', 'Nanneti01', '10/17', 'Male', 'Father', true, null, null),
  ('Rebekah', null, 'Maggam', '4126208980', 'Maggam01', '10/20', 'Female', 'Mother', true, null, null),
  ('Neelima', null, 'kumar', null, 'kumar01', '10/22', 'Female', 'Mother', true, null, null),
  ('Jagdeesh', null, 'kumar', null, 'kumar01', '10/22', 'Male', 'Father', false, null, null),
  ('Abigail', 'Cheryl (Goldie)', 'Jogu', null, 'Jogu01', '10/25', 'Female', 'Daughter', true, null, null),
  ('Sandeep', null, 'Iruvanti', '6177948891', 'Iruvanti01', '10/25', 'Male', 'Father', true, null, null),
  ('Tanmai', null, 'Talari', '9084768037', 'Talari01', '10/27', 'Female', 'Daughter', true, null, null),
  ('Phoebe', null, 'Nanneti', '7323181769', 'Nanneti01', '10/27', 'Female', 'Daughter', true, null, null),
  ('Jasmine', null, 'Sarella', '9083315015', 'Sarella01', '10/28', 'Female', 'Daughter', true, null, null),
  ('Olivia', null, 'Israel', null, 'Israel01', '10/29', 'Female', 'Daughter', true, null, null),
  ('Vishal', null, 'Roy', null, 'Roy01', '10/30', 'Male', 'Son', true, null, null),
  ('Ramaprasad', null, 'Kusuma', '2017801746', 'Kusuma01', '11/03', 'Male', 'Father', true, null, null),
  ('Adarsh', null, 'Gatala', null, 'Gatala01', '11/07', 'Male', 'Son', true, null, null),
  ('Divya', null, 'Divya', null, 'Divya01', '11/07', 'Female', 'Mother', true, null, null),
  ('Lyra', null, 'Naveen', null, 'Naveen01', '11/08', 'Female', 'Daughter', true, null, null),
  ('Chirish Tej', null, 'Kundeti', null, 'Kundeti01', '11/21', 'Male', 'Son', false, null, null),
  ('Pranati', null, 'Burani', null, 'Burani01', '11/21', 'Female', 'Daughter', true, null, null),
  ('Arjaalu', null, 'Gopinath', '7329104417', 'Gopinath01', '11/28', 'Female', 'Mother', true, null, null),
  ('Abhinav', null, 'Gatala', null, 'Gatala01', '11/29', 'Male', 'Son', true, null, null),
  ('Mounica', null, 'Chettu', null, 'Chettu01', '12/08', 'Female', 'Wife', true, null, null),
  ('Vara', null, 'Parisapogu', null, 'Parisapogu01', '12/12', 'Female', 'Mother', true, null, null),
  ('Roopa', 'Devi', 'Gathala', '7328584545', 'Gathala01', '12/18', 'Female', 'Mother', true, null, null),
  ('Joel', null, 'Nanneti', null, 'Nanneti01', '12/22', 'Male', 'Son', true, null, null),
  ('Prameela', null, 'Roy', '8187449593', 'Roy01', '12/29', 'Female', 'Mother', true, null, null),
  ('Nikhil', null, 'Chepuri', '6097272739', 'Chepuri01', '12/31', 'Male', 'Husband', true, null, null);


-- ════════════════════════════════════════════════════════════════════
-- Migration 7: log in against members.phone_number instead of users
-- Login no longer uses the `users` table at all -- a person types their
-- phone number, it's matched against members.phone_number, and
-- role_in_church comes back with it (not yet used to gate features --
-- just captured/displayed for now). No phone number entered = guest
-- access, no lookup performed. An entered phone number that doesn't
-- match any member is still rejected with an error (not silently
-- treated as guest).
-- Safe to re-run.
--
-- NOTE: classes.teacher_id, homework_posts.teacher_id, kids.parent_id,
-- and homework_responses.parent_id are still foreign keys into `users`,
-- not `members`. Now that login identity comes from `members`, those
-- FK'd features (posting homework, the parent kid-picker) will need
-- their own migration before they work again -- out of scope for this
-- change per the "we'll get to that part later" plan.
-- ════════════════════════════════════════════════════════════════════

alter table members add column if not exists role_in_church text;

create or replace function member_login_lookup(p_phone_number text)
returns table (id uuid, first_name text, role_in_church text)
language sql
security definer
set search_path = public
as $$
  select id, first_name, role_in_church
  from members
  where phone_number = regexp_replace(p_phone_number, '\D', '', 'g');
$$;

grant execute on function member_login_lookup(text) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 8: repoint teacher_id/parent_id at members, drop users
-- dependency entirely. `users` is being retired -- this moves
-- classes.teacher_id, kids.parent_id, homework_posts.teacher_id, and
-- homework_responses.parent_id to reference members(id) instead, and
-- remaps the 4 real rows currently pointing at the old users.id values
-- (kids and homework_responses have 0 rows today, so there's nothing to
-- remap there -- just the FK target changes).
--
-- The 4 teacher remaps below are matched by phone number against the
-- known values from Migration 5, except Grace Chintapalli, who has no
-- phone_number on file in members -- matched by name instead (the only
-- Grace Chintapalli row). Verify these 4 updates against your own data
-- before running if anything's changed since this was written.
--
-- Also drops login_lookup(), which is dead code now that main.py logs
-- in against members -- it queries `users` directly, so it has to go
-- before `users` can be dropped.
--
-- NOT safe to re-run: the teacher_id/homework_posts.teacher_id UPDATEs
-- below match against the *old* users.id values, which only exist
-- before this migration runs once. Run once, verify, then drop `users`.
-- ════════════════════════════════════════════════════════════════════

alter table classes drop constraint if exists classes_teacher_id_fkey;
alter table kids drop constraint if exists kids_parent_id_fkey;
alter table homework_posts drop constraint if exists homework_posts_teacher_id_fkey;
alter table homework_responses drop constraint if exists homework_responses_parent_id_fkey;

-- Remap homework_posts.teacher_id -- all 3 existing rows were posted by
-- Sharada Nanneti (old users.id b7bdd590-7695-4010-a36b-d491418c6b1b,
-- the same value currently on classes.teacher_id for Fishermen Group 1).
update homework_posts
set teacher_id = (select id from members where phone_number = '7324293375')
where teacher_id = 'b7bdd590-7695-4010-a36b-d491418c6b1b';

update classes set teacher_id = (select id from members where phone_number = '4126208980')
  where name = 'Shining Stars';
update classes set teacher_id = (select id from members where first_name = 'Grace' and last_name = 'Chintapalli')
  where name = 'Little Stars';
update classes set teacher_id = (select id from members where phone_number = '7324293375')
  where name = 'Fishermen Group 1';
update classes set teacher_id = (select id from members where phone_number = '7327421160')
  where name = 'Fishermen Group 2';

alter table classes add constraint classes_teacher_id_fkey
  foreign key (teacher_id) references members(id);
alter table kids add constraint kids_parent_id_fkey
  foreign key (parent_id) references members(id);
alter table homework_posts add constraint homework_posts_teacher_id_fkey
  foreign key (teacher_id) references members(id);
alter table homework_responses add constraint homework_responses_parent_id_fkey
  foreign key (parent_id) references members(id);

drop function if exists login_lookup(text);

-- After running and verifying (check classes/homework_posts below show
-- the right teacher on each row), users can be dropped:
--   drop table users;


-- ════════════════════════════════════════════════════════════════════
-- Migration 9: role_features crosswalk
-- Maps role_in_church values (e.g. "Pastor", "Sunday School Teacher")
-- to app feature keys (e.g. "edit_events", "edit_announcements",
-- "assign_homework"). Presence of a (role, feature) row means that role
-- has that feature -- there's no separate "denied" row, just absence.
-- Feature keys are plain app-defined strings, not a constrained lookup
-- table -- keep them consistent with whatever main.py checks against as
-- role-based gating gets built out later.
-- Not PII, so readable by anon (same as `classes`) -- the app will need
-- to read this client-side to decide what to show a given role. No
-- insert/update/delete from the app -- manage rows by hand in the Table
-- Editor, same as announcements/events.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

create table if not exists role_features (
  role text not null,
  feature text not null,
  primary key (role, feature)
);

alter table role_features enable row level security;

drop policy if exists "anyone can read role_features" on role_features;
create policy "anyone can read role_features" on role_features
  for select using (true);


-- ════════════════════════════════════════════════════════════════════
-- Migration 10: let the app insert/update/delete announcements
-- Announcements were previously admin-only via the Table Editor
-- (select-only for anon). main.py now shows insert/edit/delete UI to
-- members whose role has the edit_announcements feature in
-- role_features (Migration 9).
--
-- Same security tradeoff already accepted for homework_posts: RLS here
-- checks "true", not the caller's actual role -- the app's phone-number
-- login isn't a Supabase Auth session, so RLS has no way to verify who
-- is asking. main.py gates the UI, but anyone holding the anon key
-- (which ships inside the compiled app) could bypass that and write
-- directly via the API. Flagging it again since announcements are
-- public-facing, unlike homework which is class-scoped.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

drop policy if exists "app can insert announcements" on announcements;
create policy "app can insert announcements" on announcements
  for insert with check (true);

drop policy if exists "app can update announcements" on announcements;
create policy "app can update announcements" on announcements
  for update using (true) with check (true);

drop policy if exists "app can delete announcements" on announcements;
create policy "app can delete announcements" on announcements
  for delete using (true);


-- ════════════════════════════════════════════════════════════════════
-- Migration 11: let the app insert/update/delete events
-- Same shape as Migration 10, for events instead of announcements.
-- main.py shows insert/edit/delete UI to members whose role has the
-- edit_events feature in role_features (Migration 9). Same RLS caveat
-- as Migration 10 applies -- "true", not an actual per-caller check.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

drop policy if exists "app can insert events" on events;
create policy "app can insert events" on events
  for insert with check (true);

drop policy if exists "app can update events" on events;
create policy "app can update events" on events
  for update using (true) with check (true);

drop policy if exists "app can delete events" on events;
create policy "app can delete events" on events
  for delete using (true);


-- ════════════════════════════════════════════════════════════════════
-- Migration 12: uuid primary keys -> sequential integers
-- Every table's id column (and every FK pointing at one) moves from
-- `uuid default gen_random_uuid()` to `integer generated always as
-- identity` -- plain 1, 2, 3. Done as an in-place conversion (add new
-- integer columns, backfill from the old uuid values, then drop the old
-- ones) rather than dropping and recreating tables, because there's
-- live data in this database that only exists in Supabase, not in this
-- file (e.g. an announcement and 8 role_features rows added by hand
-- through the Table Editor since Migrations 9-11 were written) -- a
-- from-scratch rebuild would silently lose those.
--
-- One deliberate leftover: each referenced table (members, classes,
-- kids, homework_posts) gets a temporary UNIQUE constraint on its new
-- integer column so child tables can FK against it before it becomes
-- the primary key. That temp constraint is NOT dropped afterward --
-- Postgres ties each FK to the specific unique constraint it was
-- created against, so dropping it would either fail or take the FK
-- with it. It's left in place as a harmless redundant unique index
-- alongside the new primary key; totally fine at this table size.
--
-- Also note: `id` ends up as the last physical column in each table
-- (it's a rename of a newly-added column), not the first. Cosmetic
-- only -- main.py reads columns by name, never by position.
--
-- NOT safe to re-run -- it reads and clears out the old uuid columns
-- as it goes. Run once, verify (see the checks at the end), and only
-- then start relying on integer ids from the app.
-- ════════════════════════════════════════════════════════════════════

-- ── Step 1: new integer identity id column on every table, with a
--    temporary UNIQUE constraint on the 4 tables other tables FK to ──

alter table members add column if not exists id_int integer generated always as identity;
alter table members add constraint members_id_int_key unique (id_int);

alter table classes add column if not exists id_int integer generated always as identity;
alter table classes add constraint classes_id_int_key unique (id_int);

alter table kids add column if not exists id_int integer generated always as identity;
alter table kids add constraint kids_id_int_key unique (id_int);

alter table homework_posts add column if not exists id_int integer generated always as identity;
alter table homework_posts add constraint homework_posts_id_int_key unique (id_int);

alter table homework_responses add column if not exists id_int integer generated always as identity;
alter table announcements add column if not exists id_int integer generated always as identity;
alter table events add column if not exists id_int integer generated always as identity;

-- ── Step 2: new integer FK columns on child tables, backfilled by
--    joining the old uuid FK value to the parent's new id_int ──

alter table classes add column if not exists teacher_id_int integer references members(id_int);
update classes c set teacher_id_int = m.id_int from members m where c.teacher_id = m.id;

alter table kids add column if not exists class_id_int integer references classes(id_int);
update kids k set class_id_int = c.id_int from classes c where k.class_id = c.id;

alter table kids add column if not exists parent_id_int integer references members(id_int);
update kids k set parent_id_int = m.id_int from members m where k.parent_id = m.id;

alter table homework_posts add column if not exists teacher_id_int integer references members(id_int);
update homework_posts h set teacher_id_int = m.id_int from members m where h.teacher_id = m.id;

alter table homework_posts add column if not exists class_id_int integer references classes(id_int);
update homework_posts h set class_id_int = c.id_int from classes c where h.class_id = c.id;

alter table homework_responses add column if not exists homework_post_id_int integer references homework_posts(id_int);
update homework_responses r set homework_post_id_int = h.id_int from homework_posts h where r.homework_post_id = h.id;

alter table homework_responses add column if not exists parent_id_int integer references members(id_int);
update homework_responses r set parent_id_int = m.id_int from members m where r.parent_id = m.id;

alter table homework_responses add column if not exists kid_id_int integer references kids(id_int);
update homework_responses r set kid_id_int = k.id_int from kids k where r.kid_id = k.id;

-- ── Step 3: drop the old uuid FK constraints so the old uuid columns
--    underneath them can be dropped ──

alter table classes drop constraint if exists classes_teacher_id_fkey;
alter table kids drop constraint if exists kids_class_id_fkey;
alter table kids drop constraint if exists kids_parent_id_fkey;
alter table homework_posts drop constraint if exists homework_posts_teacher_id_fkey;
alter table homework_posts drop constraint if exists homework_posts_class_id_fkey;
alter table homework_responses drop constraint if exists homework_responses_homework_post_id_fkey;
alter table homework_responses drop constraint if exists homework_responses_parent_id_fkey;
alter table homework_responses drop constraint if exists homework_responses_kid_id_fkey;

-- ── Step 4: drop old uuid FK columns and rename the new integer ones
--    into place ──

alter table classes drop column if exists teacher_id;
alter table classes rename column teacher_id_int to teacher_id;

alter table kids drop column if exists class_id;
alter table kids rename column class_id_int to class_id;
alter table kids alter column class_id set not null;
alter table kids drop column if exists parent_id;
alter table kids rename column parent_id_int to parent_id;
alter table kids alter column parent_id set not null;

alter table homework_posts drop column if exists teacher_id;
alter table homework_posts rename column teacher_id_int to teacher_id;
alter table homework_posts alter column teacher_id set not null;
alter table homework_posts drop column if exists class_id;
alter table homework_posts rename column class_id_int to class_id;
alter table homework_posts alter column class_id set not null;

alter table homework_responses drop column if exists homework_post_id;
alter table homework_responses rename column homework_post_id_int to homework_post_id;
alter table homework_responses alter column homework_post_id set not null;
alter table homework_responses drop column if exists parent_id;
alter table homework_responses rename column parent_id_int to parent_id;
alter table homework_responses alter column parent_id set not null;
alter table homework_responses drop column if exists kid_id;
alter table homework_responses rename column kid_id_int to kid_id;
alter table homework_responses alter column kid_id set not null;

-- ── Step 5: drop old uuid id/PK columns and promote id_int to id ──

alter table homework_responses drop column if exists id;
alter table homework_responses rename column id_int to id;
alter table homework_responses add primary key (id);

alter table homework_posts drop column if exists id;
alter table homework_posts rename column id_int to id;
alter table homework_posts add primary key (id);

alter table kids drop column if exists id;
alter table kids rename column id_int to id;
alter table kids add primary key (id);

alter table classes drop column if exists id;
alter table classes rename column id_int to id;
alter table classes add primary key (id);

alter table members drop column if exists id;
alter table members rename column id_int to id;
alter table members add primary key (id);

alter table announcements drop column if exists id;
alter table announcements rename column id_int to id;
alter table announcements add primary key (id);

alter table events drop column if exists id;
alter table events rename column id_int to id;
alter table events add primary key (id);

-- ── Step 6: recreate the 3 functions with integer signatures. Return
--    type changes aren't allowed via create-or-replace, so drop first. ──

drop function if exists member_login_lookup(text);
create function member_login_lookup(p_phone_number text)
returns table (id integer, first_name text, role_in_church text)
language sql
security definer
set search_path = public
as $$
  select id, first_name, role_in_church
  from members
  where phone_number = regexp_replace(p_phone_number, '\D', '', 'g');
$$;

grant execute on function member_login_lookup(text) to anon, authenticated;

-- kids' actual name column is `student_name`, not `name` -- the table
-- was created by hand in the Table Editor before Migration 2's
-- `create table if not exists kids (...)` ran, so that statement
-- silently no-opped instead of creating the column names we expected.
-- Aliased back to `name` here so the RPC's external shape matches what
-- Migration 2's comments/main.py's future kid-picker expect.
drop function if exists get_kids_for_parent(uuid);
drop function if exists get_kids_for_parent(integer);
create function get_kids_for_parent(p_parent_id integer)
returns table (id integer, name text, class_id integer, class_name text)
language sql
security definer
set search_path = public
as $$
  select k.id, k.student_name as name, k.class_id, c.name as class_name
  from kids k
  join classes c on c.id = k.class_id
  where k.parent_id = p_parent_id;
$$;

grant execute on function get_kids_for_parent(integer) to anon, authenticated;

drop function if exists get_class_roster(uuid);
drop function if exists get_class_roster(integer);
create function get_class_roster(p_class_id integer)
returns table (id integer, name text)
language sql
security definer
set search_path = public
as $$
  select id, student_name as name from kids where class_id = p_class_id;
$$;

grant execute on function get_class_roster(integer) to anon, authenticated;

-- ── Verify after running (before trusting the app against this) ──
--   select id, name, teacher_id from classes;
--   select id, title, teacher_id, class_id from homework_posts;
-- id/teacher_id/class_id should all be small integers now, and every
-- row that had a teacher/class before should still have one.
--
-- If main.py or the Supabase dashboard's API explorer report a stale
-- schema (e.g. "column not found" right after running this), give
-- PostgREST's schema cache a few seconds to refresh, or reload it
-- manually from Database -> API in the Supabase dashboard.


-- ════════════════════════════════════════════════════════════════════
-- Migration 13: songs table (bilingual) + member language_preference
-- UTCCNJ is bilingual (English/Telugu) -- most members read both, but
-- not everyone reads Telugu, so song titles are split into
-- title_english (required) and title_telugu (optional, in case a song
-- hasn't been transliterated yet). main.py shows whichever matches the
-- logged-in member's language_preference, falling back to English for
-- guests or members with no preference set.
--
-- Read-only from the app, same treatment announcements/events
-- originally had: managed by hand in the Table Editor, no in-app
-- add/edit/delete for songs.
--
-- Feeds the "Share with choir" feature: a member checks off songs and
-- shares the list via a WhatsApp deep link. WhatsApp has no API for
-- posting straight into a group, so this pre-fills a message in the
-- member's own chat with themselves (via their phone number on file),
-- for them to forward into the choir group manually.
--
-- Also updates member_login_lookup (Migration 12) to return
-- language_preference -- has to be a fresh drop+create here since
-- Migration 12 already ran and altering an existing function's return
-- columns isn't allowed via create-or-replace.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table members add column if not exists language_preference text
  check (language_preference in ('english', 'telugu'));

create table if not exists songs (
  id integer generated always as identity primary key,
  title_english text not null,
  title_telugu text,
  created_at timestamptz not null default now()
);

alter table songs enable row level security;

drop policy if exists "anyone can read songs" on songs;
create policy "anyone can read songs" on songs
  for select using (true);

drop function if exists member_login_lookup(text);
create function member_login_lookup(p_phone_number text)
returns table (id integer, first_name text, role_in_church text, language_preference text)
language sql
security definer
set search_path = public
as $$
  select id, first_name, role_in_church, language_preference
  from members
  where phone_number = regexp_replace(p_phone_number, '\D', '', 'g');
$$;

grant execute on function member_login_lookup(text) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 14: rename songs -> songs_titles, add category
-- Renamed because a separate songs_lyrics table is planned later for
-- full lyrics -- keeping the two apart from the start avoids a second
-- rename once that lands. `alter table ... rename to` preserves the
-- rows already added through the Table Editor, and the existing RLS
-- policy stays attached to the table automatically through the rename
-- -- only its own name still says "songs", so that's renamed too for
-- clarity.
--
-- category is free text (Lent, Christmas, general worship, etc.) --
-- main.py builds its filter dropdown from whatever distinct values
-- exist, so new categories just need adding to the data, no code or
-- migration change.
--
-- NOT safe to re-run -- the rename fails on a second run since `songs`
-- won't exist anymore.
-- ════════════════════════════════════════════════════════════════════

alter table songs rename to songs_titles;
alter table songs_titles add column if not exists category text;

drop policy if exists "anyone can read songs" on songs_titles;
drop policy if exists "anyone can read songs_titles" on songs_titles;
create policy "anyone can read songs_titles" on songs_titles
  for select using (true);


-- ════════════════════════════════════════════════════════════════════
-- Migration 15: musical_key on songs_titles
-- Free text, not constrained to a fixed list -- keys can be sharps,
-- flats, majors, minors ("C#", "Cm", "Bb", etc). main.py displays it
-- at the end of each song's title, alongside the song's id shown as a
-- song number.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table songs_titles add column if not exists musical_key text;


-- ════════════════════════════════════════════════════════════════════
-- Migration 16: fix member_login_lookup after members.id -> member_id
-- members.id was renamed to member_id directly in Supabase (outside
-- this migration log, alongside the students table rework), which
-- broke login app-wide -- member_login_lookup still selected `id`,
-- a column that no longer exists. Re-pointed at member_id, still
-- returned as `id` so main.py (which reads result["id"]) needs no
-- changes.
--
-- Note for later: get_kids_for_parent and get_class_roster (Migration
-- 12/14) are ALSO stale -- they still query a `kids` table with a
-- single `parent_id`, but that table is now `students` with separate
-- mother_id/father_id and no parent_id at all. Not fixed here since
-- neither function is called by main.py yet (the parent kid-picker
-- still isn't built) -- worth a proper redesign against the real
-- students shape when that feature actually gets built, rather than
-- patching blind.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

drop function if exists member_login_lookup(text);
create function member_login_lookup(p_phone_number text)
returns table (id integer, first_name text, role_in_church text, language_preference text)
language sql
security definer
set search_path = public
as $$
  select member_id as id, first_name, role_in_church, language_preference
  from members
  where phone_number = regexp_replace(p_phone_number, '\D', '', 'g');
$$;

grant execute on function member_login_lookup(text) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 17: RLS for assignments (Sunday School Teacher feature)
-- assignments was created directly in Supabase (DDL supplied outside
-- this log) without RLS enabled -- turning it on here and applying the
-- same open-read / insert-only-with-app-side-gating pattern already
-- used for homework_posts/announcements/events. Gated in main.py by
-- the "assign_homework" role_features feature, which already exists
-- for the "Sunday School Teacher" role.
--
-- No FK constraints exist on class_id/teacher_id (none were in the
-- original DDL), so main.py resolves class names client-side instead
-- of relying on a PostgREST embed.
--
-- "Category" is quoted/capitalized in the original DDL -- kept exactly
-- as-is rather than renamed, to match the table as already created.
--
-- No update/delete policy yet -- closed/deleted are there for a future
-- step (closing an assignment, soft-delete), not wired up in the app
-- yet.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table assignments enable row level security;

drop policy if exists "anyone can read assignments" on assignments;
create policy "anyone can read assignments" on assignments
  for select using (true);

drop policy if exists "app can insert assignments" on assignments;
create policy "app can insert assignments" on assignments
  for insert with check (true);


-- ════════════════════════════════════════════════════════════════════
-- Migration 18: RLS for assignment_post_response
-- assignment_post_response was created directly in Supabase (DDL
-- supplied outside this log) without RLS enabled. Same open-read /
-- insert-only-with-app-side-gating pattern as assignments (Migration
-- 17). main.py fans out one row per student in the assigned class
-- right after an assignment is inserted -- see insert_assignment() /
-- create_assignment_responses() in main.py.
--
-- No FK constraints exist (none were in the original DDL) -- app-level
-- only, same tradeoff as assignments.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table assignment_post_response enable row level security;

drop policy if exists "anyone can read assignment_post_response" on assignment_post_response;
create policy "anyone can read assignment_post_response" on assignment_post_response
  for select using (true);

drop policy if exists "app can insert assignment_post_response" on assignment_post_response;
create policy "app can insert assignment_post_response" on assignment_post_response
  for insert with check (true);


-- ════════════════════════════════════════════════════════════════════
-- Migration 19: get_students_for_class() for the assignment fan-out
-- students (formerly kids) has RLS enabled with no SELECT policy for
-- anon -- deliberate, since it holds children's names and family
-- links. create_assignment_responses() in main.py was querying
-- students directly with the anon-key client and silently getting 0
-- rows back every time (no error -- RLS just filtered everything out),
-- so no assignment_post_response rows were ever created.
--
-- Fix follows the same pattern as member_login_lookup: a narrow
-- SECURITY DEFINER function that returns only the columns the fan-out
-- needs, scoped to one class, rather than opening a broad students
-- SELECT policy to anon.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

create or replace function get_students_for_class(p_class_id integer)
returns table (student_id integer, father_id integer, mother_id integer, family_code text)
language sql
security definer
set search_path = public
as $$
  select student_id, father_id, mother_id, family_code
  from students
  where class_id = p_class_id;
$$;

grant execute on function get_students_for_class(integer) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 20: parent-facing "Sunday School" tab
-- Any member who is a father_id or mother_id on an assignment_post_response
-- row should see a "Sunday School" tab listing those assignments --
-- irrespective of role_in_church (a parent might also be a Diaconnete,
-- a Clerk, etc; this isn't a role_features gate, it's driven by actual
-- data).
--
-- assignment_post_response links specific children to specific parents
-- -- that's more sensitive than a plain content list, so rather than
-- leaning on Migration 18's open "anyone can read" policy, this locks
-- that down and replaces it with a SECURITY DEFINER function scoped to
-- exactly one parent's own rows, same treatment as get_students_for_class
-- (Migration 19). student_id is intentionally NOT matched against
-- member_id here -- they're different tables' primary keys with no
-- guaranteed relationship, so comparing them directly would risk
-- showing a parent an unrelated child's assignment by pure id
-- coincidence.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

drop policy if exists "anyone can read assignment_post_response" on assignment_post_response;

create or replace function get_my_assignments(p_member_id integer)
returns table (
  assignment_id bigint,
  assignment_title character varying,
  assignment_description text,
  category text,
  class_name text,
  created_time timestamp without time zone,
  closed boolean,
  student_id integer
)
language sql
security definer
set search_path = public
as $$
  select
    a.assignment_id,
    a.assignment_title,
    a.assignment_description,
    a."Category" as category,
    c.name as class_name,
    a.created_time,
    a.closed,
    apr.student_id
  from assignment_post_response apr
  join assignments a on a.assignment_id = apr.assignment_id
  left join classes c on c.id = a.class_id
  where (apr.father_id = p_member_id or apr.mother_id = p_member_id)
    and coalesce(a.deleted, false) = false
  order by a.created_time desc;
$$;

grant execute on function get_my_assignments(integer) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 21: restore missing insert policy on assignment_post_response
-- The insert policy from Migration 18 is no longer present on the live
-- table (confirmed via direct test: assignments insert succeeds,
-- assignment_post_response insert fails with 42501 insufficient
-- privilege) -- likely lost along the way while the table was being
-- worked on directly in Supabase. Re-stating it here. Does not touch
-- the SELECT side -- that's intentionally gone since Migration 20,
-- replaced by the scoped get_my_assignments() function.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table assignment_post_response enable row level security;

drop policy if exists "app can insert assignment_post_response" on assignment_post_response;
create policy "app can insert assignment_post_response" on assignment_post_response
  for insert with check (true);


-- ════════════════════════════════════════════════════════════════════
-- Migration 22: add student_name to get_my_assignments
-- A parent can have two children in the same class, so the same
-- assignment can legitimately appear twice (once per child) in their
-- Sunday School Parent list -- student_name lets main.py show which
-- child each row is for. Joins students (SECURITY DEFINER bypasses its
-- RLS, same as the rest of this function already does for
-- assignment_post_response). concat_ws skips the child's last name
-- cleanly when it's null (e.g. the two roster entries with no last
-- name on file).
--
-- Return columns changed, so this needs drop+create rather than
-- create-or-replace.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

drop function if exists get_my_assignments(integer);
create function get_my_assignments(p_member_id integer)
returns table (
  assignment_id bigint,
  assignment_title character varying,
  assignment_description text,
  category text,
  class_name text,
  created_time timestamp without time zone,
  closed boolean,
  student_id integer,
  student_name text
)
language sql
security definer
set search_path = public
as $$
  select
    a.assignment_id,
    a.assignment_title,
    a.assignment_description,
    a."Category" as category,
    c.name as class_name,
    a.created_time,
    a.closed,
    apr.student_id,
    concat_ws(' ', s.student_firstname, s.student_lastname) as student_name
  from assignment_post_response apr
  join assignments a on a.assignment_id = apr.assignment_id
  left join classes c on c.id = a.class_id
  left join students s on s.student_id = apr.student_id
  where (apr.father_id = p_member_id or apr.mother_id = p_member_id)
    and coalesce(a.deleted, false) = false
  order by a.created_time desc;
$$;

grant execute on function get_my_assignments(integer) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 23: get_my_assignments -- first name only, no last name
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

drop function if exists get_my_assignments(integer);
create function get_my_assignments(p_member_id integer)
returns table (
  assignment_id bigint,
  assignment_title character varying,
  assignment_description text,
  category text,
  class_name text,
  created_time timestamp without time zone,
  closed boolean,
  student_id integer,
  student_name text
)
language sql
security definer
set search_path = public
as $$
  select
    a.assignment_id,
    a.assignment_title,
    a.assignment_description,
    a."Category" as category,
    c.name as class_name,
    a.created_time,
    a.closed,
    apr.student_id,
    s.student_firstname as student_name
  from assignment_post_response apr
  join assignments a on a.assignment_id = apr.assignment_id
  left join classes c on c.id = a.class_id
  left join students s on s.student_id = apr.student_id
  where (apr.father_id = p_member_id or apr.mother_id = p_member_id)
    and coalesce(a.deleted, false) = false
  order by a.created_time desc;
$$;

grant execute on function get_my_assignments(integer) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 24: mark-assignment-complete feature
-- - assignment_response_time: integer -> timestamp without time zone,
--   so it can actually hold now() (matches assignment_post_createdtime's
--   type). Safe -- this column has never been written to, still all
--   null on every row, so the type change has nothing real to convert.
-- - Adds an UPDATE policy on assignment_post_response (was insert-only
--   before now), same app-side-gated "true" pattern as the rest of the
--   app -- there's no real per-user DB session to check identity
--   against, so main.py is trusted to only let a parent mark their own
--   child's assignment complete.
-- - get_my_assignments now also returns assignment_post_response_id
--   (so main.py can target the exact row to update),
--   assignment_response_by, and assignment_response_time (so the
--   detail dialog can show whether it's already marked complete).
--   Return columns changed again, so drop+create.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table assignment_post_response
  alter column assignment_response_time type timestamp without time zone using null;

drop policy if exists "app can update assignment_post_response" on assignment_post_response;
create policy "app can update assignment_post_response" on assignment_post_response
  for update using (true) with check (true);

drop function if exists get_my_assignments(integer);
create function get_my_assignments(p_member_id integer)
returns table (
  assignment_post_response_id bigint,
  assignment_id bigint,
  assignment_title character varying,
  assignment_description text,
  category text,
  class_name text,
  created_time timestamp without time zone,
  closed boolean,
  student_id integer,
  student_name text,
  assignment_response_by integer,
  assignment_response_time timestamp without time zone
)
language sql
security definer
set search_path = public
as $$
  select
    apr.assignment_post_response_id,
    a.assignment_id,
    a.assignment_title,
    a.assignment_description,
    a."Category" as category,
    c.name as class_name,
    a.created_time,
    a.closed,
    apr.student_id,
    s.student_firstname as student_name,
    apr.assignment_response_by,
    apr.assignment_response_time
  from assignment_post_response apr
  join assignments a on a.assignment_id = apr.assignment_id
  left join classes c on c.id = a.class_id
  left join students s on s.student_id = apr.student_id
  where (apr.father_id = p_member_id or apr.mother_id = p_member_id)
    and coalesce(a.deleted, false) = false
  order by a.created_time desc;
$$;

grant execute on function get_my_assignments(integer) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 25: mark_assignment_response_complete() function
-- Migration 24's UPDATE policy (using true / with check true) doesn't
-- actually work: Postgres RLS requires a row to be visible under a
-- SELECT policy for UPDATE/DELETE to locate it via WHERE in the first
-- place, separate from the UPDATE policy's own USING clause. Migration
-- 20 deliberately removed the SELECT policy on assignment_post_response
-- (it links specific kids to specific parents), so the UPDATE policy
-- was silently matching zero rows -- confirmed empirically (update call
-- succeeds, 0 rows affected, no error).
--
-- Fix: a SECURITY DEFINER function instead of a table-level UPDATE
-- policy, same treatment as get_my_assignments/get_students_for_class.
-- Bonus: unlike the blanket "true" policy, this function actually
-- checks the caller-supplied member_id against father_id/mother_id
-- before updating -- real enforcement RLS alone couldn't give us here,
-- since there's no per-user DB session to check identity against.
--
-- Drops the non-functional UPDATE policy from Migration 24 since it's
-- dead weight -- all writes to this table now go through insert (app
-- can insert, Migration 21) or this function.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

drop policy if exists "app can update assignment_post_response" on assignment_post_response;

create or replace function mark_assignment_response_complete(p_response_id bigint, p_member_id integer)
returns void
language sql
security definer
set search_path = public
as $$
  update assignment_post_response
  set assignment_response_by = p_member_id,
      assignment_response_time = now()
  where assignment_post_response_id = p_response_id
    and (father_id = p_member_id or mother_id = p_member_id);
$$;

grant execute on function mark_assignment_response_complete(bigint, integer) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 26: rename id -> <table>_id on announcements, classes,
-- events, songs_titles
-- Plain column renames -- PRIMARY KEY constraints, identity sequences,
-- and any FK constraints in other tables that reference these columns
-- (e.g. students.class_id, assignments.class_id) all stay correctly
-- attached automatically, since Postgres tracks them by column, not
-- name. get_my_assignments is updated to match (classes.id ->
-- classes.class_id in its join).
--
-- get_kids_for_parent/get_class_roster also reference classes.id but
-- are already dead code (they query the old `kids` table, which no
-- longer exists) -- not touched here, consistent with earlier
-- migrations' decision to leave them for a proper rewrite once the
-- parent kid-picker feature is actually built, rather than patch dead
-- code blind.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table announcements rename column id to announcement_id;
alter table classes rename column id to class_id;
alter table events rename column id to event_id;
alter table songs_titles rename column id to song_title_id;

create or replace function get_my_assignments(p_member_id integer)
returns table (
  assignment_post_response_id bigint,
  assignment_id bigint,
  assignment_title character varying,
  assignment_description text,
  category text,
  class_name text,
  created_time timestamp without time zone,
  closed boolean,
  student_id integer,
  student_name text,
  assignment_response_by integer,
  assignment_response_time timestamp without time zone
)
language sql
security definer
set search_path = public
as $$
  select
    apr.assignment_post_response_id,
    a.assignment_id,
    a.assignment_title,
    a.assignment_description,
    a."Category" as category,
    c.name as class_name,
    a.created_time,
    a.closed,
    apr.student_id,
    s.student_firstname as student_name,
    apr.assignment_response_by,
    apr.assignment_response_time
  from assignment_post_response apr
  join assignments a on a.assignment_id = apr.assignment_id
  left join classes c on c.class_id = a.class_id
  left join students s on s.student_id = apr.student_id
  where (apr.father_id = p_member_id or apr.mother_id = p_member_id)
    and coalesce(a.deleted, false) = false
  order by a.created_time desc;
$$;

grant execute on function get_my_assignments(integer) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Migration 27: drop unused get_kids_for_parent / get_class_roster
-- Leftover from the old homework_responses "kid picker" flow, removed
-- along with homework_posts/homework_responses a while back. Never
-- called from main.py, and already broken (referenced the old `kids`
-- table/schema shape, which no longer exists). The assignments feature
-- that replaced homework doesn't need a kid-picker: it fans out to
-- every student in a class automatically on creation, and
-- get_my_assignments already looks a parent up directly by
-- father_id/mother_id without them picking a kid first.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

drop function if exists get_kids_for_parent(uuid);
drop function if exists get_kids_for_parent(integer);
drop function if exists get_class_roster(uuid);
drop function if exists get_class_roster(integer);


-- ════════════════════════════════════════════════════════════════════
-- Migration 28: RLS for songs_lyrics
-- Created directly in Supabase via the Table Editor, which enables RLS
-- by default with no policies -- anon was getting 0 rows back silently
-- (confirmed: service key sees 15 rows, anon key saw 0, no error).
-- Not sensitive data (song lyrics), so same "anyone can read" treatment
-- as songs_titles. Joined to songs_titles via song_id -> song_title_id.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

alter table songs_lyrics enable row level security;

drop policy if exists "anyone can read songs_lyrics" on songs_lyrics;
create policy "anyone can read songs_lyrics" on songs_lyrics
  for select using (true);
