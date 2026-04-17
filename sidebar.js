// ── DIALOG HELPERS (replaces native prompt/confirm/alert) ──

function showDialog({ title = '', message = '', initialValue = null, placeholder = '', okText = 'OK', cancelText = 'Cancel', danger = false }) {
  const wantsInput = initialValue !== null;
  return new Promise((resolve) => {
    const overlay = document.getElementById('dialog-overlay');
    const titleEl = document.getElementById('dialog-title');
    const msgEl = document.getElementById('dialog-message');
    const input = document.getElementById('dialog-input');
    const okBtn = document.getElementById('dialog-ok');
    const cancelBtn = document.getElementById('dialog-cancel');

    titleEl.textContent = title;
    msgEl.textContent = message;
    input.classList.toggle('hidden', !wantsInput);
    input.value = wantsInput ? initialValue : '';
    input.placeholder = placeholder;
    okBtn.textContent = okText;
    cancelBtn.textContent = cancelText;
    okBtn.classList.toggle('danger', danger);

    overlay.classList.remove('hidden');
    if (wantsInput) {
      setTimeout(() => { input.focus(); input.select(); }, 0);
    } else {
      setTimeout(() => okBtn.focus(), 0);
    }

    const cleanup = () => {
      overlay.classList.add('hidden');
      okBtn.removeEventListener('click', onOk);
      cancelBtn.removeEventListener('click', onCancel);
      document.removeEventListener('keydown', onKey);
      overlay.removeEventListener('mousedown', onOutside);
    };
    const onOk = () => {
      if (wantsInput) {
        const v = input.value.trim();
        if (!v) { input.focus(); return; }
        cleanup(); resolve(v);
      } else {
        cleanup(); resolve(true);
      }
    };
    const onCancel = () => { cleanup(); resolve(wantsInput ? null : false); };
    const onKey = (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); onOk(); }
      else if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
    };
    const onOutside = (e) => { if (e.target === overlay) onCancel(); };

    okBtn.addEventListener('click', onOk);
    cancelBtn.addEventListener('click', onCancel);
    document.addEventListener('keydown', onKey);
    overlay.addEventListener('mousedown', onOutside);
  });
}

function showPrompt(title, { initialValue = '', placeholder = '', okText = 'OK' } = {}) {
  return showDialog({ title, initialValue, placeholder, okText });
}

function showConfirm(title, { message = '', okText = 'OK', danger = false } = {}) {
  return showDialog({ title, message, okText, danger });
}

// ── SIDEBAR FILE TREE ───────────────────────────────────

const fileTree = {
  rootId: null, // null = root level (no parent_id)
  expanded: new Set(),
  nodes: new Map(), // folderId|'root' -> Array<{ id, name, mimeType }>
  selectedFolderId: null,
};

let currentFileId = null;
let currentFileName = null;

function initSidebar() {
  fileTree.expanded.add('root');
  document.getElementById('sidebar').classList.add('visible');
  return loadFolder('root');
}

async function loadFolder(folderId) {
  try {
    const parentId = folderId === 'root' ? null : folderId;
    const files = await driveListFiles(parentId);
    fileTree.nodes.set(folderId, files);
    renderTree();
  } catch (err) {
    console.error('Failed to load folder:', err);
  }
}

function renderTree() {
  const container = document.getElementById('file-tree');
  container.innerHTML = '';
  container.appendChild(buildTreeNode('root', 0));
}

function buildTreeNode(folderId, depth) {
  const fragment = document.createDocumentFragment();
  const items = fileTree.nodes.get(folderId) || [];

  items.forEach(item => {
    const isFolder = item.mimeType === 'folder';
    const el = document.createElement('div');
    el.className = 'tree-item' + (isFolder ? ' tree-folder' : ' tree-file');
    el.style.paddingLeft = (12 + depth * 16) + 'px';
    el.dataset.id = item.id;
    el.dataset.name = item.name;
    el.dataset.parentId = folderId;

    if (isFolder) {
      const expanded = fileTree.expanded.has(item.id);
      el.innerHTML = `<span class="tree-arrow">${expanded ? '\u25BE' : '\u25B8'}</span><span class="tree-name">${esc(item.name)}</span>`;
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        fileTree.selectedFolderId = item.id;
        toggleFolder(item.id);
      });
      el.addEventListener('contextmenu', (e) => showContextMenu(e, item, folderId, true));
      fragment.appendChild(el);
      if (expanded) {
        fragment.appendChild(buildTreeNode(item.id, depth + 1));
      }
    } else {
      el.innerHTML = `<span class="tree-icon">\u266A</span><span class="tree-name">${esc(item.name)}</span>`;
      if (currentFileId === item.id) el.classList.add('active');
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        fileTree.selectedFolderId = folderId === 'root' ? null : folderId;
        openFile(item.id, item.name);
      });
      el.addEventListener('contextmenu', (e) => showContextMenu(e, item, folderId, false));
      fragment.appendChild(el);
    }
  });

  return fragment;
}

async function toggleFolder(folderId) {
  if (fileTree.expanded.has(folderId)) {
    fileTree.expanded.delete(folderId);
  } else {
    fileTree.expanded.add(folderId);
    if (!fileTree.nodes.has(folderId)) {
      await loadFolder(folderId);
      return;
    }
  }
  renderTree();
}

function esc(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

// ── CONTEXT MENU ────────────────────────────────────────

let activeContextMenu = null;

function showContextMenu(e, item, parentFolderId, isFolder) {
  e.preventDefault();
  e.stopPropagation();
  closeContextMenu();

  const menu = document.createElement('div');
  menu.className = 'context-menu';
  menu.style.left = e.clientX + 'px';
  menu.style.top = e.clientY + 'px';

  const renameOpt = document.createElement('div');
  renameOpt.className = 'context-menu-item';
  renameOpt.textContent = 'Rename';
  renameOpt.addEventListener('click', () => {
    closeContextMenu();
    renameItem(item, isFolder, parentFolderId);
  });
  menu.appendChild(renameOpt);

  const deleteOpt = document.createElement('div');
  deleteOpt.className = 'context-menu-item danger';
  deleteOpt.textContent = 'Delete';
  deleteOpt.addEventListener('click', () => {
    closeContextMenu();
    deleteItem(item, isFolder, parentFolderId);
  });
  menu.appendChild(deleteOpt);

  document.body.appendChild(menu);
  activeContextMenu = menu;

  setTimeout(() => {
    document.addEventListener('click', closeContextMenu, { once: true });
  }, 0);
}

function closeContextMenu() {
  if (activeContextMenu) {
    activeContextMenu.remove();
    activeContextMenu = null;
  }
}

async function renameItem(item, isFolder, parentFolderId) {
  const newName = await showPrompt('Rename', { initialValue: item.name, okText: 'Rename' });
  if (!newName || newName === item.name) return;

  try {
    if (isFolder) {
      await dbRenameFolder(item.id, newName);
    } else {
      await dbRenameNotation(item.id, newName);
    }
    await loadFolder(parentFolderId);
  } catch (err) {
    console.error('Rename failed:', err);
  }
}

async function deleteItem(item, isFolder, parentFolderId) {
  const ok = await showConfirm(`Delete "${item.name}"?`, {
    message: isFolder ? 'The folder and everything inside it will be deleted.' : 'This notation will be permanently deleted.',
    okText: 'Delete',
    danger: true,
  });
  if (!ok) return;

  try {
    if (isFolder) {
      await dbDeleteFolder(item.id);
    } else {
      await dbDeleteNotation(item.id);
    }
    if (item.id === currentFileId) {
      currentFileId = null;
      currentFileName = null;
      localStorage.removeItem('sargam_current_file');
      clearEditor();
    }
    await loadFolder(parentFolderId);
  } catch (err) {
    console.error('Delete failed:', err);
  }
}

// ── CREATE NEW FILE / FOLDER ────────────────────────────

async function sidebarCreateFile() {
  const parentId = fileTree.selectedFolderId || null;
  await createNewFile(parentId);
  const treeKey = parentId || 'root';
  if (!fileTree.expanded.has(treeKey)) {
    fileTree.expanded.add(treeKey);
  }
  await loadFolder(treeKey);
}

async function sidebarCreateFolder() {
  const parentId = fileTree.selectedFolderId || null;
  const name = await showPrompt('New folder', { placeholder: 'Folder name', okText: 'Create' });
  if (!name) return;

  try {
    await dbCreateFolder(name, parentId);
    const treeKey = parentId || 'root';
    if (!fileTree.expanded.has(treeKey)) {
      fileTree.expanded.add(treeKey);
    }
    await loadFolder(treeKey);
  } catch (err) {
    console.error('Create folder failed:', err);
  }
}
