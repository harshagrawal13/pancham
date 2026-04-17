/*
 * Supabase data layer for Pancham.
 *
 * This is a single-machine multi-user app: rows are scoped by a plain-text
 * `username` column (no password, no Supabase Auth). The username is chosen
 * on first load and cached in localStorage. All queries filter by it.
 *
 * Schema: see schema.sql.
 */

// ── CONFIG ──────────────────────────────────────────────
// Values are injected by config.js (generated from .env by build-config.sh).
const SUPABASE_URL = window.PANCHAM_CONFIG?.SUPABASE_URL;
const SUPABASE_ANON_KEY = window.PANCHAM_CONFIG?.SUPABASE_ANON_KEY;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  throw new Error('Missing Supabase config. Run ./build-config.sh to generate config.js from .env.');
}

// Local reference to the created Supabase client. Named `sb` (not `supabase`)
// because the CDN UMD bundle already defines a global `supabase` at parse time,
// and a `let supabase` here throws SyntaxError: "already been declared".
let sb = null;
let currentUsername = null;

// ── INIT ────────────────────────────────────────────────

function initSupabase() {
  sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}

function setUsername(name) {
  currentUsername = name;
  localStorage.setItem('pancham_username', name);
}

function loadUsername() {
  currentUsername = localStorage.getItem('pancham_username') || null;
  return currentUsername;
}

function clearUsername() {
  currentUsername = null;
  localStorage.removeItem('pancham_username');
}

// ── FOLDERS + NOTATIONS CRUD ────────────────────────────

async function dbListItems(parentId) {
  const foldersQuery = sb
    .from('folders')
    .select('id, name, created_at')
    .eq('username', currentUsername)
    .order('name');

  if (parentId) {
    foldersQuery.eq('parent_id', parentId);
  } else {
    foldersQuery.is('parent_id', null);
  }

  const notationsQuery = sb
    .from('notations')
    .select('id, name, updated_at')
    .eq('username', currentUsername)
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
  const { data, error } = await sb
    .from('folders')
    .insert({
      name,
      parent_id: parentId || null,
      username: currentUsername,
    })
    .select()
    .single();
  if (error) throw error;
  return { id: data.id, name: data.name, mimeType: 'folder' };
}

async function dbCreateNotation(name, folderId, content) {
  const { data, error } = await sb
    .from('notations')
    .insert({
      name,
      folder_id: folderId || null,
      username: currentUsername,
      content,
    })
    .select()
    .single();
  if (error) throw error;
  return { id: data.id, name: data.name, mimeType: 'notation' };
}

async function dbUpdateNotation(id, content) {
  const { error } = await sb
    .from('notations')
    .update({ content, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) throw error;
}

async function dbRenameNotation(id, newName) {
  const { error } = await sb
    .from('notations')
    .update({ name: newName })
    .eq('id', id);
  if (error) throw error;
}

async function dbRenameFolder(id, newName) {
  const { error } = await sb
    .from('folders')
    .update({ name: newName })
    .eq('id', id);
  if (error) throw error;
}

async function dbDeleteNotation(id) {
  const { error } = await sb
    .from('notations')
    .delete()
    .eq('id', id);
  if (error) throw error;
}

async function dbDeleteFolder(id) {
  const { error } = await sb
    .from('folders')
    .delete()
    .eq('id', id);
  if (error) throw error;
}

async function dbGetNotationContent(id) {
  const { data, error } = await sb
    .from('notations')
    .select('content')
    .eq('id', id)
    .single();
  if (error) throw error;
  return data.content;
}

// Aliases used elsewhere (legacy names from the old Google Drive backend).
const driveListFiles = dbListItems;
const driveCreateFolder = dbCreateFolder;
const driveCreateFile = (name, parentId, content) => dbCreateNotation(name, parentId, content);
const driveUpdateFile = (fileId, content) => dbUpdateNotation(fileId, content);
const driveDeleteFile = (fileId) => dbDeleteNotation(fileId);
const driveGetFileContent = dbGetNotationContent;

async function driveRenameFile(fileId, newName) {
  const cleanName = newName.replace(/\.sargam\.json$/i, '');
  try {
    await dbRenameNotation(fileId, cleanName);
  } catch {
    await dbRenameFolder(fileId, cleanName);
  }
}
