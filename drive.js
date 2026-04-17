/*
 * Supabase Backend for Sargam Notation Writer
 *
 * SETUP INSTRUCTIONS:
 * 1. Go to https://supabase.com and sign up (free)
 * 2. Create a new project (pick any region, set a database password)
 * 3. Wait for the project to finish provisioning (~2 minutes)
 * 4. Go to Project Settings > API
 *    - Copy "Project URL" and paste below as SUPABASE_URL
 *    - Copy "anon public" key and paste below as SUPABASE_ANON_KEY
 * 5. Go to SQL Editor, click "New query", paste this SQL, and click "Run":
 *
 *    -- Folders table
 *    create table folders (
 *      id uuid default gen_random_uuid() primary key,
 *      name text not null,
 *      parent_id uuid references folders(id) on delete cascade,
 *      user_id uuid references auth.users(id) on delete cascade not null,
 *      created_at timestamptz default now()
 *    );
 *
 *    -- Notations table
 *    create table notations (
 *      id uuid default gen_random_uuid() primary key,
 *      name text not null,
 *      folder_id uuid references folders(id) on delete set null,
 *      user_id uuid references auth.users(id) on delete cascade not null,
 *      content jsonb not null default '{}',
 *      created_at timestamptz default now(),
 *      updated_at timestamptz default now()
 *    );
 *
 *    -- Row Level Security
 *    alter table folders enable row level security;
 *    alter table notations enable row level security;
 *
 *    create policy "Users manage own folders" on folders
 *      for all using (auth.uid() = user_id);
 *
 *    create policy "Users manage own notations" on notations
 *      for all using (auth.uid() = user_id);
 *
 * 6. Go to Authentication > Settings, under "Email Auth":
 *    - Make sure "Enable Email Signup" is ON
 *    - (Optional) Turn OFF "Confirm email" for easier testing
 * 7. Serve the app: python3 -m http.server 8000
 * 8. Open http://localhost:8000
 */

// ── CONFIG ──────────────────────────────────────────────
// Values are injected by config.js (generated from .env by build-config.sh).
const SUPABASE_URL = window.PANCHAM_CONFIG?.SUPABASE_URL;
const SUPABASE_ANON_KEY = window.PANCHAM_CONFIG?.SUPABASE_ANON_KEY;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  throw new Error('Missing Supabase config. Run ./build-config.sh to generate config.js from .env.');
}

let supabase = null;
let currentUser = null;

// ── INIT ────────────────────────────────────────────────

function initSupabase() {
  supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}

async function checkSession() {
  const { data: { session } } = await supabase.auth.getSession();
  if (session) {
    currentUser = session.user;
    return true;
  }
  return false;
}

function onAuthStateChange(callback) {
  supabase.auth.onAuthStateChange((event, session) => {
    if (event === 'SIGNED_IN' && session) {
      currentUser = session.user;
      callback(true);
    } else if (event === 'SIGNED_OUT') {
      currentUser = null;
      callback(false);
    }
  });
}

async function signUpWithEmail(email, password) {
  const { data, error } = await supabase.auth.signUp({ email, password });
  if (error) throw error;
  return data;
}

async function signInWithEmail(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return data;
}

async function signOut() {
  await supabase.auth.signOut();
  currentUser = null;
}

function isSignedIn() {
  return !!currentUser;
}

// ── FOLDERS CRUD ────────────────────────────────────────

async function dbListItems(parentId) {
  // List folders and notations under a parent
  const foldersQuery = supabase
    .from('folders')
    .select('id, name, created_at')
    .eq('user_id', currentUser.id)
    .order('name');

  if (parentId) {
    foldersQuery.eq('parent_id', parentId);
  } else {
    foldersQuery.is('parent_id', null);
  }

  const notationsQuery = supabase
    .from('notations')
    .select('id, name, updated_at')
    .eq('user_id', currentUser.id)
    .order('name');

  if (parentId) {
    notationsQuery.eq('folder_id', parentId);
  } else {
    notationsQuery.is('folder_id', null);
  }

  const [foldersResult, notationsResult] = await Promise.all([foldersQuery, notationsQuery]);

  if (foldersResult.error) throw foldersResult.error;
  if (notationsResult.error) throw notationsResult.error;

  const folders = (foldersResult.data || []).map(f => ({
    id: f.id,
    name: f.name,
    mimeType: 'folder',
  }));

  const files = (notationsResult.data || []).map(n => ({
    id: n.id,
    name: n.name,
    mimeType: 'notation',
  }));

  return [...folders, ...files];
}

async function dbCreateFolder(name, parentId) {
  const { data, error } = await supabase
    .from('folders')
    .insert({
      name,
      parent_id: parentId || null,
      user_id: currentUser.id,
    })
    .select()
    .single();
  if (error) throw error;
  return { id: data.id, name: data.name, mimeType: 'folder' };
}

async function dbCreateNotation(name, folderId, content) {
  const { data, error } = await supabase
    .from('notations')
    .insert({
      name,
      folder_id: folderId || null,
      user_id: currentUser.id,
      content,
    })
    .select()
    .single();
  if (error) throw error;
  return { id: data.id, name: data.name, mimeType: 'notation' };
}

async function dbUpdateNotation(id, content) {
  const { error } = await supabase
    .from('notations')
    .update({ content, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) throw error;
}

async function dbRenameNotation(id, newName) {
  const { error } = await supabase
    .from('notations')
    .update({ name: newName })
    .eq('id', id);
  if (error) throw error;
}

async function dbRenameFolder(id, newName) {
  const { error } = await supabase
    .from('folders')
    .update({ name: newName })
    .eq('id', id);
  if (error) throw error;
}

async function dbDeleteNotation(id) {
  const { error } = await supabase
    .from('notations')
    .delete()
    .eq('id', id);
  if (error) throw error;
}

async function dbDeleteFolder(id) {
  const { error } = await supabase
    .from('folders')
    .delete()
    .eq('id', id);
  if (error) throw error;
}

async function dbGetNotationContent(id) {
  const { data, error } = await supabase
    .from('notations')
    .select('content')
    .eq('id', id)
    .single();
  if (error) throw error;
  return data.content;
}

// Aliases used by sidebar.js and app.js (matching the old drive.js interface)
const driveListFiles = dbListItems;
const driveCreateFolder = dbCreateFolder;
const driveCreateFile = (name, parentId, content) => dbCreateNotation(name, parentId, content);
const driveUpdateFile = (fileId, content) => dbUpdateNotation(fileId, content);
const driveDeleteFile = (fileId) => dbDeleteNotation(fileId);
const driveGetFileContent = dbGetNotationContent;

async function driveRenameFile(fileId, newName) {
  // Try notation first, then folder
  const cleanName = newName.replace(/\.sargam\.json$/i, '');
  try {
    await dbRenameNotation(fileId, cleanName);
  } catch {
    await dbRenameFolder(fileId, cleanName);
  }
}

// No-ops for compatibility
function startTokenRefresh() {}
function ensureToken() { return Promise.resolve(); }
