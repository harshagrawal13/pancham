-- Pancham schema (single-machine, no Supabase Auth).
-- Data is scoped by a plain-text `username` column set per browser.
-- RLS is disabled — the publishable key in the browser has full access.
-- Only safe to expose to a trusted network (e.g. localhost).

create table folders (
  id uuid default gen_random_uuid() primary key,
  name text not null,
  parent_id uuid references folders(id) on delete cascade,
  username text not null,
  created_at timestamptz default now()
);

create table notations (
  id uuid default gen_random_uuid() primary key,
  name text not null,
  folder_id uuid references folders(id) on delete set null,
  username text not null,
  content jsonb not null default '{}',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index folders_username_idx on folders(username);
create index notations_username_idx on notations(username);
