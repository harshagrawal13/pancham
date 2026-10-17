-- migrate:up
-- Pancham's database on kamaji. PostgREST serves the api schema as pancham_anon at
-- pancham-api.harsh-agrawal.com; kamaji-server's add-app creates the database and both roles
-- before this runs, so this file only builds what is inside.
--
-- What it keeps:
--   documents   one row per notation, forever. Never updated except head_rev, never deleted.
--   revisions   one row per saved version of a notation, forever. APPEND-ONLY: pancham_anon has
--               no update or delete on it, and a trigger refuses both from anyone. A rename,
--               a move, a delete and a restore are each a new revision too, so every document's
--               whole history, including what was removed, is here.
--
-- Two kinds of notation, told apart by `scope`, which is fixed when the notation is made:
--   private    seen and changed by its owner only
--   global     seen by everyone signed in, made and changed by admins only (the shared library)

create schema private;
create schema api;
comment on schema api is 'Served by PostgREST as pancham_anon at pancham-api.harsh-agrawal.com, behind Cloudflare Access.';

-- ---------------------------------------------------------------------------
-- Who is asking
-- ---------------------------------------------------------------------------
-- server/server.py signs a short-lived JWT at sign-in, with the secret PostgREST also holds.
-- PostgREST has verified it by the time these read it:
--   no JWT          -> nobody: sees nothing, writes nothing
--   {sub, email}    -> signed in: their own private notations and every global one
--   {admin: true}   -> may also make and change global notations
create function private.claims() returns jsonb
    language sql stable
    as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function private.sub() returns uuid
    language sql stable
    as $$ select nullif(private.claims()->>'sub', '')::uuid $$;
create function private.is_admin() returns boolean
    language sql stable
    as $$ select private.claims()->'admin' = 'true'::jsonb $$;

-- May the caller write to this notation (add a revision)?
create function private.can_write(p_scope text, p_owner uuid) returns boolean
    language sql stable
    as $$ select private.sub() is not null
               and ((p_scope = 'private' and p_owner = private.sub())
                 or (p_scope = 'global' and private.is_admin())) $$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.documents (
  id          uuid primary key,           -- made by the app, so a retried create is harmless
  scope       text not null check (scope in ('private', 'global')),
  owner       uuid not null,              -- who made it; for a global notation, the admin
  forked_from uuid references public.documents (id),   -- "Add to my library" copies a global notation
  head_rev    int not null default 0 check (head_rev >= 0),   -- its newest revision
  created_at  timestamptz not null default clock_timestamp()
);
create index documents_owner on public.documents (owner) where scope = 'private';

create table public.revisions (
  seq        bigserial primary key,       -- strictly increasing in commit order: the sync cursor
  doc_id     uuid not null references public.documents (id),
  rev        int not null check (rev > 0),
  author     uuid not null,
  name       text not null check (length(name) between 1 and 200),
  folder     text not null default '' check (length(folder) <= 200),   -- '' is the library's top level
  content    jsonb not null check (jsonb_typeof(content) = 'object' and octet_length(content::text) < 8000000),
  deleted    boolean not null default false,   -- a delete is a revision, so it can be undone
  note       text check (length(note) <= 200),  -- 'restored from revision 4', 'imported', ...
  device     text check (length(device) <= 100),
  created_at timestamptz not null default clock_timestamp(),   -- the moment of the save (after the lock below), so it sorts like seq
  unique (doc_id, rev)
);
create index revisions_by_doc on public.revisions (doc_id, rev desc);

-- History is never rewritten. These stop even a superuser's careless UPDATE or DELETE;
-- changing them means dropping the trigger on purpose.
create function private.refuse_rewrite() returns trigger
    language plpgsql
    as $$ begin raise exception '% on % is not allowed: Pancham keeps every revision', tg_op, tg_table_name; end $$;
create trigger revisions_append_only before update or delete on public.revisions
    for each row execute function private.refuse_rewrite();
create trigger revisions_no_truncate before truncate on public.revisions
    for each statement execute function private.refuse_rewrite();
create trigger documents_no_delete before delete on public.documents
    for each row execute function private.refuse_rewrite();
create trigger documents_no_truncate before truncate on public.documents
    for each statement execute function private.refuse_rewrite();

create function private.documents_head_only() returns trigger
    language plpgsql
    as $$
begin
  if (new.id, new.scope, new.owner, new.forked_from, new.created_at)
       is distinct from (old.id, old.scope, old.owner, old.forked_from, old.created_at)
     or new.head_rev < old.head_rev then
    raise exception 'documents: only head_rev may change, and only upward';
  end if;
  return new;
end $$;
create trigger documents_head_only before update on public.documents
    for each row execute function private.documents_head_only();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.documents enable row level security;
alter table public.revisions enable row level security;

create policy read_documents on public.documents for select to pancham_anon
  using (private.sub() is not null and (scope = 'global' or owner = private.sub()));
create policy add_documents on public.documents for insert to pancham_anon
  with check (owner = private.sub() and private.can_write(scope, owner));
create policy bump_documents on public.documents for update to pancham_anon
  using (private.can_write(scope, owner)) with check (private.can_write(scope, owner));

-- A revision is visible when its document is (the policy above applies inside this subquery),
-- and may be added by whoever may write to the document, as themselves.
create policy read_revisions on public.revisions for select to pancham_anon
  using (exists (select 1 from public.documents d where d.id = doc_id));
create policy add_revisions on public.revisions for insert to pancham_anon
  with check (author = private.sub()
              and exists (select 1 from public.documents d
                          where d.id = doc_id and private.can_write(d.scope, d.owner)));

-- ---------------------------------------------------------------------------
-- The API
-- ---------------------------------------------------------------------------
-- The newest revision of every notation the caller can see, content included. Who owns or wrote
-- a notation is deliberately NOT exposed: an account id is derived from an email, so it would let
-- anyone check a guessed address against it. The sync feed:
--   GET /docs?seq=gt.<cursor>&order=seq.asc&limit=50
-- and, without the content, the cheap listing:  GET /docs?select=id,scope,rev,name,folder,deleted
create view api.docs with (security_invoker = true) as
  select d.id, d.scope, d.forked_from, r.rev, r.seq, r.name, r.folder, r.deleted,
         r.created_at as updated_at, r.content
  from public.documents d
  join public.revisions r on r.doc_id = d.id and r.rev = d.head_rev;

-- Every revision of the notations the caller can see. A notation's history:
--   GET /revisions?doc_id=eq.<id>&select=rev,seq,name,folder,deleted,note,author,device,created_at&order=rev.desc
-- and one version's content:  GET /revisions?doc_id=eq.<id>&rev=eq.<n>
create view api.revisions with (security_invoker = true) as
  select seq, doc_id, rev, name, folder, deleted, note, device, created_at, content
  from public.revisions;

-- Save a notation: the one way to make or change one.
--   p_base  the revision this edit started from; 0 to create. If someone saved in between, 409
--           with the newer revision number in `details`, and nothing is written.
--   saving what the head already is changes nothing and returns the head, so a retry is harmless.
--   p_content left out keeps the head's content (a delete, a rename, a move send no content); it is
--   required to create.
--   p_scope applies only when creating; a notation never changes scope.
create function api.save_revision(
  p_doc uuid, p_base int, p_name text, p_folder text, p_content jsonb default null,
  p_deleted boolean default false, p_scope text default 'private',
  p_forked_from uuid default null, p_note text default null, p_device text default null
) returns json
    language plpgsql
    as $$
declare
  me   uuid := private.sub();
  d    public.documents;
  head public.revisions;
  eff  jsonb;
  new_rev int;
  new_seq bigint;
begin
  if me is null then
    raise sqlstate 'PT401' using message = 'sign in first';
  end if;
  if p_scope not in ('private', 'global') then
    raise sqlstate 'PT400' using message = 'scope must be private or global';
  end if;
  -- Revisions commit in the order their seq was handed out, so a client reading "seq > cursor"
  -- never skips one that commits late. Saves are rare; one at a time costs nothing.
  perform pg_advisory_xact_lock(hashtext('pancham.revisions'));

  select * into d from public.documents where id = p_doc;      -- row level security: mine, or global
  if not found then
    if p_base <> 0 then
      raise sqlstate 'PT404' using message = 'no such notation';
    end if;
    if p_scope = 'global' and not private.is_admin() then
      raise sqlstate 'PT403' using message = 'only admins make global notations';
    end if;
    if p_content is null then
      raise sqlstate 'PT400' using message = 'content is required to create a notation';
    end if;
    eff := p_content;
    -- a foreign key check ignores row level security, so only name sources the caller can see
    if p_forked_from is not null and not exists (select 1 from public.documents where id = p_forked_from) then
      raise sqlstate 'PT404' using message = 'no such notation to copy from';
    end if;
    insert into public.documents (id, scope, owner, forked_from) values (p_doc, p_scope, me, p_forked_from);
    new_rev := 1;
  else
    if not private.can_write(d.scope, d.owner) then
      raise sqlstate 'PT403' using message = case d.scope when 'global' then 'only admins change global notations' else 'not yours' end;
    end if;
    select * into head from public.revisions where doc_id = p_doc and rev = d.head_rev;
    if d.head_rev <> p_base then
      raise sqlstate 'PT409' using message = 'conflict', detail = d.head_rev::text;
    end if;
    eff := coalesce(p_content, head.content);
    if (head.name, head.folder, head.content, head.deleted) is not distinct from (p_name, coalesce(p_folder, ''), eff, p_deleted) then
      return json_build_object('rev', head.rev, 'seq', head.seq, 'changed', false);
    end if;
    new_rev := d.head_rev + 1;
  end if;

  insert into public.revisions (doc_id, rev, author, name, folder, content, deleted, note, device)
    values (p_doc, new_rev, me, p_name, coalesce(p_folder, ''), eff, p_deleted, p_note, p_device)
    returning seq into new_seq;
  update public.documents set head_rev = new_rev where id = p_doc;
  return json_build_object('rev', new_rev, 'seq', new_seq, 'changed', true);
end $$;

alter role pancham_anon set statement_timeout = '10s';
grant usage on schema api, private to pancham_anon;
grant execute on function private.claims(), private.sub(), private.is_admin(), private.can_write(text, uuid) to pancham_anon;
grant select, insert on public.documents, public.revisions to pancham_anon;
grant update (head_rev) on public.documents to pancham_anon;
grant usage on sequence public.revisions_seq_seq to pancham_anon;
grant select on api.docs, api.revisions to pancham_anon;
grant execute on function api.save_revision(uuid, int, text, text, jsonb, boolean, text, uuid, text, text) to pancham_anon;

notify pgrst, 'reload schema';

-- migrate:down
drop schema api cascade;
drop table public.revisions;
drop table public.documents;
drop schema private cascade;
alter role pancham_anon reset statement_timeout;
