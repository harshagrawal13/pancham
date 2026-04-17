const SWARA_MAP = {
  S: { base: 'सा', letter: 'S' },
  R: { base: 'रे', letter: 'R' },
  G: { base: 'ग',  letter: 'G' },
  M: { base: 'म',  letter: 'M' },
  P: { base: 'प',  letter: 'P' },
  D: { base: 'ध',  letter: 'D' },
  N: { base: 'नि', letter: 'N' },
};

const TAALS = {
  teentaal: {
    matras: 16,
    markers: ['X','','','','2','','','','0','','','','3','','',''],
  },
  teentaal_khali: {
    matras: 16,
    markers: ['0','','','','3','','','','X','','','','2','','',''],
  },
};

const state = {
  title: '',
  raga: '',
  taal: 'teentaal',
  laya: '',
  bpm: '',
  notes: '',
  sections: [],
};

// ── MULTI-FILE & AUTO-SAVE STATE ────────────────────────
let isDirty = false;
let isSaving = false;
let autoSaveTimer = null;
let titleRenameTimer = null;

function newLine(type = 'notation') {
  return { type, cells: Array(16).fill('') };
}

function newSection(name = 'स्थायी') {
  return { name, lines: [newLine('notation')] };
}

function migrateLine(line) {
  if (Array.isArray(line)) return { type: 'notation', cells: line };
  return line;
}

// ── PARSING ─────────────────────────────────────────────

function parseCell(text) {
  if (!text) return [];
  const tokens = text.trim().split(/\s+/);
  const result = [];
  tokens.forEach(tok => {
    parseToken(tok).forEach(s => result.push(s));
  });
  return result;
}

function parseToken(tok) {
  const results = [];
  let i = 0;
  while (i < tok.length) {
    const ch = tok[i];
    if (ch === '-' || ch === 's') {
      results.push({ sustain: true });
      i++; continue;
    }
    let octave = 0;
    if (ch === '.') { octave = -1; i++; if (i >= tok.length) break; }
    else if (ch === '^') { octave = 1; i++; if (i >= tok.length) break; }
    const nc = tok[i];
    const upper = nc.toUpperCase();
    if (!SWARA_MAP[upper]) { i++; continue; }
    const komal = (nc !== nc.toUpperCase()) && 'RGDN'.includes(upper);
    let tivra = false;
    if (upper === 'M' && tok[i+1] === "'") { tivra = true; i++; }
    results.push({ base: upper, komal, tivra, octave });
    i++;
  }
  return results;
}

// ── RENDERING ───────────────────────────────────────────

function renderSwara(sw) {
  if (sw.sustain) return '<span class="swara sustain">ऽ</span>';
  const cls = ['swara'];
  if (sw.komal) cls.push('komal');
  if (sw.tivra) cls.push('tivra');
  if (sw.octave === -1) cls.push('mandra');
  if (sw.octave === 1) cls.push('taar');
  return `<span class="${cls.join(' ')}">${SWARA_MAP[sw.base].base}</span>`;
}

function renderCell(text) {
  const swaras = parseCell(text);
  if (!swaras.length) return '';
  const count = swaras.length;
  let sizeClass = '';
  if (count === 2) sizeClass = 'multi-2';
  else if (count === 3) sizeClass = 'multi-3';
  else if (count >= 4) sizeClass = 'multi-4';
  const inner = swaras.map(renderSwara).join('');
  return sizeClass ? `<span class="swara-group ${sizeClass}">${inner}</span>` : inner;
}

function render() {
  const sectionsEl = document.getElementById('sections');
  sectionsEl.innerHTML = '';
  state.sections.forEach((sec, si) => {
    const secEl = document.createElement('section');
    secEl.className = 'section';
    secEl.innerHTML = `
      <div class="section-header">
        <input type="text" value="${sec.name}" data-si="${si}" class="section-name" placeholder="Section">
        <button class="remove-section no-print" data-si="${si}">Remove section</button>
      </div>
    `;
    secEl.appendChild(renderSection(si, sec));
    sectionsEl.appendChild(secEl);
  });
  bindEvents();
}

function renderSection(si, sec) {
  const taal = TAALS[state.taal];
  const tableWrap = document.createElement('div');
  tableWrap.className = 'section-table';

  const markers = `<div class="taal-markers">${taal.markers.map(m =>
    `<div class="taal-cell">${m}</div>`).join('')}</div>`;
  const nums = `<div class="matra-row">${Array.from({length: taal.matras}, (_, i) =>
    `<div class="matra-cell">${i+1}</div>`).join('')}</div>`;

  let rows = '';
  sec.lines.forEach((line, li) => {
    const lineObj = migrateLine(line);
    sec.lines[li] = lineObj;
    const isLyric = lineObj.type === 'lyric';
    const rowClass = isLyric ? 'notation-row lyric-row' : 'notation-row';

    const cells = lineObj.cells.map((cell, ci) => {
      if (isLyric) {
        return `<div class="notation-cell lyric-cell">
          <input type="text" data-si="${si}" data-li="${li}" data-ci="${ci}" data-type="lyric" value="${escapeAttr(cell)}" placeholder="">
        </div>`;
      }
      const hasContent = cell.trim().length > 0;
      const inputStyle = hasContent ? ' style="display:none"' : '';
      const previewStyle = hasContent ? ' style="display:flex"' : '';
      return `<div class="notation-cell">
        <input type="text" data-si="${si}" data-li="${li}" data-ci="${ci}" data-type="notation" value="${escapeAttr(cell)}" placeholder=""${inputStyle}>
        <div class="preview" data-preview="${si}-${li}-${ci}"${previewStyle}>${renderCell(cell)}</div>
      </div>`;
    }).join('');

    const removeBtn = `<button class="remove-line-btn no-print" data-si="${si}" data-li="${li}" title="Remove row">\u00D7</button>`;
    rows += `<div class="${rowClass}" data-si="${si}" data-li="${li}">${cells}${removeBtn}</div>`;
  });

  const addBtn = `<div class="add-row-wrap no-print">
    <button class="add-row-btn" data-si="${si}">+</button>
    <div class="add-row-menu" data-si="${si}">
      <button class="add-row-option" data-si="${si}" data-type="notation">Notation</button>
      <button class="add-row-option" data-si="${si}" data-type="lyric">Lyric</button>
    </div>
  </div>`;

  tableWrap.innerHTML = markers + nums + rows + addBtn;
  return tableWrap;
}

function escapeAttr(s) { return String(s).replace(/"/g,'&quot;'); }

// ── EVENT BINDING ───────────────────────────────────────

function bindEvents() {
  document.querySelectorAll('.notation-cell input[data-type="notation"]').forEach(inp => {
    const prev = inp.parentElement.querySelector('.preview');
    inp.addEventListener('input', e => {
      const { si, li, ci } = e.target.dataset;
      state.sections[si].lines[li].cells[ci] = e.target.value;
      if (prev) prev.innerHTML = renderCell(e.target.value);
      save();
    });
    inp.addEventListener('keydown', handleCellKey);
    inp.addEventListener('blur', () => {
      const { si, li, ci } = inp.dataset;
      commitCell(inp, si, li, ci);
    });
    if (prev) {
      prev.addEventListener('click', () => {
        prev.style.display = 'none';
        inp.style.display = '';
        inp.focus();
      });
    }
  });

  document.querySelectorAll('.notation-cell input[data-type="lyric"]').forEach(inp => {
    inp.addEventListener('input', e => {
      const { si, li, ci } = e.target.dataset;
      state.sections[si].lines[li].cells[ci] = e.target.value;
      save();
    });
    inp.addEventListener('keydown', e => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const { si, li, ci } = e.target.dataset;
        const nextCi = +ci + 1;
        if (nextCi < 16) focusCell(si, li, nextCi);
      }
    });
  });

  document.querySelectorAll('.section-name').forEach(el => {
    el.addEventListener('input', e => {
      state.sections[e.target.dataset.si].name = e.target.value;
      save();
    });
  });

  document.querySelectorAll('.remove-section').forEach(el => {
    el.addEventListener('click', e => {
      state.sections.splice(+e.target.dataset.si, 1);
      if (!state.sections.length) state.sections.push(newSection());
      save(); render();
    });
  });

  document.querySelectorAll('.remove-line-btn').forEach(el => {
    el.addEventListener('click', e => {
      e.stopPropagation();
      const { si, li } = e.target.dataset;
      state.sections[si].lines.splice(+li, 1);
      if (!state.sections[si].lines.length) state.sections[si].lines.push(newLine('notation'));
      save(); render();
    });
  });

  document.querySelectorAll('.add-row-btn').forEach(btn => {
    btn.addEventListener('click', e => {
      e.stopPropagation();
      btn.nextElementSibling.classList.toggle('visible');
    });
  });

  document.querySelectorAll('.add-row-option').forEach(opt => {
    opt.addEventListener('click', e => {
      e.stopPropagation();
      const si = +e.target.dataset.si;
      const type = e.target.dataset.type;
      state.sections[si].lines.push(newLine(type));
      save(); render();
    });
  });

  document.addEventListener('click', () => {
    document.querySelectorAll('.add-row-menu.visible').forEach(m => m.classList.remove('visible'));
  });
}

function handleCellKey(e) {
  if (e.key === 'Tab') return;
  if (e.key === 'Enter') {
    e.preventDefault();
    const { si, li, ci } = e.target.dataset;
    commitCell(e.target, si, li, ci);
    const nextCi = +ci + 1;
    if (nextCi < 16) focusCell(si, li, nextCi);
  }
}

function commitCell(input, si, li, ci) {
  if (!input.value.trim()) return;
  const prev = input.parentElement.querySelector('.preview');
  if (prev) {
    prev.innerHTML = renderCell(input.value);
    prev.style.display = 'flex';
  }
  input.style.display = 'none';
}

function focusCell(si, li, ci) {
  const el = document.querySelector(`input[data-si="${si}"][data-li="${li}"][data-ci="${ci}"]`);
  if (el) el.focus();
}

// ── SAVE / LOAD ─────────────────────────────────────────

function save() {
  const meta = {
    title: document.getElementById('title').value,
    raga: document.getElementById('raga').value,
    laya: document.getElementById('laya').value,
    bpm: document.getElementById('bpm').value,
    taal: document.getElementById('taal').value,
    notes: document.getElementById('notes').value,
  };
  Object.assign(state, meta);
  updateEmptyClasses();

  // Save to localStorage (keyed by file ID if we have one)
  const key = currentFileId ? `sargam_${currentFileId}` : 'sargam';
  localStorage.setItem(key, JSON.stringify(state));
  isDirty = true;
}

function updateEmptyClasses() {
  const laya = document.getElementById('laya').value.trim();
  const bpm = document.getElementById('bpm').value.trim();
  const notes = document.getElementById('notes').value.trim();
  document.querySelector('.meta-laya').classList.toggle('empty', !laya);
  document.querySelector('.meta-bpm').classList.toggle('empty', !bpm);
  document.querySelector('.notes-section').classList.toggle('empty', !notes);
}

function loadStateToDOM() {
  state.sections.forEach(sec => {
    sec.lines = sec.lines.map(migrateLine);
  });
  if (!state.sections.length) state.sections = [newSection('स्थायी'), newSection('अंतरा')];
  document.getElementById('title').value = state.title || '';
  document.getElementById('raga').value = state.raga || '';
  document.getElementById('laya').value = state.laya || '';
  document.getElementById('bpm').value = state.bpm || '';
  document.getElementById('taal').value = state.taal || 'teentaal';
  document.getElementById('notes').value = state.notes || '';
  updateEmptyClasses();
}

function clearEditor() {
  state.title = '';
  state.raga = '';
  state.taal = 'teentaal';
  state.laya = '';
  state.bpm = '';
  state.notes = '';
  state.sections = [newSection('स्थायी'), newSection('अंतरा')];
  loadStateToDOM();
  render();
}

// ── DRIVE FILE OPERATIONS ───────────────────────────────

async function openFile(fileId, fileName) {
  // Flush current dirty state
  if (isDirty && currentFileId) {
    await saveToDrive();
  }

  showSyncStatus('Loading...');

  try {
    const content = await driveGetFileContent(fileId);

    // Reset state
    Object.keys(state).forEach(k => delete state[k]);
    Object.assign(state, { title: '', raga: '', taal: 'teentaal', laya: '', bpm: '', notes: '', sections: [] });
    Object.assign(state, content);

    currentFileId = fileId;
    currentFileName = fileName;
    isDirty = false;

    // Cache in localStorage
    localStorage.setItem(`sargam_${fileId}`, JSON.stringify(state));
    localStorage.setItem('sargam_current_file', fileId);

    loadStateToDOM();
    render();
    renderTree();
    showSyncStatus('');
  } catch (err) {
    console.error('Failed to open file:', err);
    showSyncStatus('Load failed', true);
  }
}

async function createNewFile(parentFolderId) {
  // Flush current
  if (isDirty && currentFileId) {
    await saveToDrive();
  }

  // Reset to blank
  Object.keys(state).forEach(k => delete state[k]);
  Object.assign(state, {
    title: 'Untitled',
    raga: '',
    taal: 'teentaal',
    laya: '',
    bpm: '',
    notes: '',
    sections: [newSection('स्थायी'), newSection('अंतरा')],
  });

  showSyncStatus('Creating...');
  try {
    const file = await driveCreateFile('Untitled', parentFolderId, state);
    currentFileId = file.id;
    currentFileName = file.name;
    isDirty = false;

    localStorage.setItem(`sargam_${file.id}`, JSON.stringify(state));
    localStorage.setItem('sargam_current_file', file.id);

    loadStateToDOM();
    render();
    showSyncStatus('Created');
    setTimeout(() => showSyncStatus(''), 1500);
  } catch (err) {
    console.error('Failed to create file:', err);
    showSyncStatus('Create failed', true);
  }
}

async function saveToDrive() {
  if (!currentFileId || !isSignedIn() || isSaving) return;
  isSaving = true;
  isDirty = false;

  try {
    await driveUpdateFile(currentFileId, state);
    showSyncStatus('Saved');
    setTimeout(() => {
      const el = document.getElementById('sync-status');
      if (el.textContent === 'Saved') showSyncStatus('');
    }, 2000);
  } catch (err) {
    isDirty = true;
    showSyncStatus('Save failed', true);
    console.error('Auto-save error:', err);
  } finally {
    isSaving = false;
  }
}

function showSyncStatus(text, isError) {
  const el = document.getElementById('sync-status');
  el.textContent = text;
  el.className = 'sync-status' + (isError ? ' error' : '');
}

function startAutoSave() {
  if (autoSaveTimer) clearInterval(autoSaveTimer);
  autoSaveTimer = setInterval(() => {
    if (isDirty && currentFileId && isSignedIn() && !isSaving) {
      saveToDrive();
    }
  }, 5000);
}

// ── TITLE RENAME SYNC ───────────────────────────────────

function handleTitleChange() {
  save();
  clearTimeout(titleRenameTimer);
  titleRenameTimer = setTimeout(async () => {
    if (currentFileId && state.title && isSignedIn()) {
      try {
        await dbRenameNotation(currentFileId, state.title);
        currentFileName = state.title;
        // Refresh sidebar to reflect new name
        const treeKey = fileTree.selectedFolderId || 'root';
        if (fileTree.nodes.has(treeKey)) loadFolder(treeKey);
      } catch (err) {
        console.error('Rename failed:', err);
      }
    }
  }, 2000);
}

// ── BOOT ────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  const signInOverlay = document.getElementById('sign-in-overlay');
  const authForm = document.getElementById('auth-form');
  const authEmail = document.getElementById('auth-email');
  const authPassword = document.getElementById('auth-password');
  const authError = document.getElementById('auth-error');
  const authSignInBtn = document.getElementById('auth-signin-btn');
  const authSignUpBtn = document.getElementById('auth-signup-btn');

  initSupabase();

  async function onSignedIn() {
    signInOverlay.classList.add('hidden');
    authError.textContent = '';

    await initSidebar();

    // Migrate legacy localStorage data if exists
    const legacy = localStorage.getItem('sargam');
    if (legacy) {
      try {
        const legacyState = JSON.parse(legacy);
        if (legacyState.sections && legacyState.sections.length) {
          const title = legacyState.title || 'Migrated Notation';
          const file = await dbCreateNotation(title, null, legacyState);
          currentFileId = file.id;
          currentFileName = file.name;
          localStorage.setItem('sargam_current_file', file.id);
          Object.assign(state, legacyState);
          localStorage.removeItem('sargam');
        }
      } catch {}
    }

    // Open last file if we have one
    const lastFile = localStorage.getItem('sargam_current_file');
    if (lastFile && !currentFileId) {
      const cached = localStorage.getItem(`sargam_${lastFile}`);
      if (cached) {
        try {
          Object.assign(state, JSON.parse(cached));
          currentFileId = lastFile;
          loadStateToDOM();
          render();
          renderTree();
          // Refresh from DB in background
          dbGetNotationContent(lastFile).then(content => {
            Object.assign(state, content);
            localStorage.setItem(`sargam_${lastFile}`, JSON.stringify(state));
            loadStateToDOM();
            render();
          }).catch(() => {});
        } catch {}
      } else {
        try {
          await openFile(lastFile, '');
        } catch {
          clearEditor();
        }
      }
    } else if (currentFileId) {
      loadStateToDOM();
      render();
      renderTree();
    }

    startAutoSave();
  }

  async function boot() {
    const hasSession = await checkSession();
    if (hasSession) {
      await onSignedIn();
    }

    // Auth form: sign in
    authForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      authError.textContent = '';
      authSignInBtn.disabled = true;
      try {
        await signInWithEmail(authEmail.value, authPassword.value);
        await onSignedIn();
      } catch (err) {
        authError.textContent = err.message || 'Sign in failed';
      } finally {
        authSignInBtn.disabled = false;
      }
    });

    // Auth form: sign up
    authSignUpBtn.addEventListener('click', async () => {
      authError.textContent = '';
      if (!authEmail.value || !authPassword.value) {
        authError.textContent = 'Enter email and password';
        return;
      }
      if (authPassword.value.length < 6) {
        authError.textContent = 'Password must be at least 6 characters';
        return;
      }
      authSignUpBtn.disabled = true;
      try {
        await signUpWithEmail(authEmail.value, authPassword.value);
        // Some Supabase configs auto-sign-in after signup
        const hasSession = await checkSession();
        if (hasSession) {
          await onSignedIn();
        } else {
          authError.textContent = 'Check your email to confirm signup, then sign in.';
          authError.style.color = '#4a4';
        }
      } catch (err) {
        authError.textContent = err.message || 'Sign up failed';
      } finally {
        authSignUpBtn.disabled = false;
      }
    });
  }

  boot().catch(console.error);

  // ── TOOLBAR EVENTS ──────────────────────────────────

  ['raga','laya','bpm','taal','notes'].forEach(id => {
    document.getElementById(id).addEventListener('input', save);
  });

  document.getElementById('title').addEventListener('input', handleTitleChange);

  document.getElementById('add-section').addEventListener('click', () => {
    state.sections.push(newSection('संचारी'));
    save(); render();
  });

  document.getElementById('toggle-render').addEventListener('click', e => {
    const on = document.body.classList.toggle('render-mode');
    e.target.textContent = on ? 'Edit' : 'Render';
  });

  document.getElementById('export-pdf').addEventListener('click', () => window.print());

  // Export JSON (local backup)
  document.getElementById('export-json').addEventListener('click', () => {
    save();
    const json = JSON.stringify(state, null, 2);
    const blob = new Blob([json], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = (state.title || 'sargam') + '.json';
    a.click();
  });

  // Import JSON
  document.getElementById('import-json').addEventListener('change', e => {
    const f = e.target.files[0];
    if (!f) return;
    const r = new FileReader();
    r.onload = async () => {
      try {
        const imported = JSON.parse(r.result);
        Object.assign(state, imported);
        loadStateToDOM();
        render();
        save();
      } catch { alert('Invalid JSON'); }
    };
    r.readAsText(f);
    e.target.value = '';
  });

  document.getElementById('reset-file').addEventListener('click', () => {
    if (!confirm('Reset this file? All content will be cleared.')) return;
    state.title = '';
    state.raga = '';
    state.taal = 'teentaal';
    state.laya = '';
    state.bpm = '';
    state.notes = '';
    state.sections = [newSection('स्थायी'), newSection('अंतरा')];
    loadStateToDOM();
    render();
    save();
  });

  // Sidebar buttons
  document.getElementById('sidebar-new-file').addEventListener('click', sidebarCreateFile);
  document.getElementById('sidebar-new-folder').addEventListener('click', sidebarCreateFolder);
  document.getElementById('sign-out-btn').addEventListener('click', () => {
    signOut();
    currentFileId = null;
    currentFileName = null;
    clearEditor();
    document.getElementById('sidebar').classList.remove('visible');
    signInOverlay.classList.remove('hidden');
    if (autoSaveTimer) clearInterval(autoSaveTimer);
  });
});
