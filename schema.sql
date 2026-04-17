create table folders (
  id uuid default gen_random_uuid() primary key,
  name text not null,
  parent_id uuid references folders(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade not null,
  created_at timestamptz default now()
);

create table notations (
  id uuid default gen_random_uuid() primary key,
  name text not null,
  folder_id uuid references folders(id) on delete set null,
  user_id uuid references auth.users(id) on delete cascade not null,
  content jsonb not null default '{}',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table folders enable row level security;
alter table notations enable row level security;

create policy "Users manage own folders" on folders
  for all using (auth.uid() = user_id);

create policy "Users manage own notations" on notations
  for all using (auth.uid() = user_id);
