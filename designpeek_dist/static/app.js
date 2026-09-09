// DesignPeek — 前端交互

const APP_ICONS = {
  '微信': '💬', 'WeChat': '💬',
  '抖音': '🎵', 'TikTok': '🎵',
  '小红书': '📕', 'RED': '📕',
  '微博': '📢', 'Weibo': '📢',
  '支付宝': '💙', 'Alipay': '💙',
  '淘宝': '🛒', 'Taobao': '🛒',
  '京东': '🐶', 'JD': '🐶',
  '美团': '🛵', 'Meituan': '🛵',
  '饿了么': '🍔', 'Eleme': '🍔',
  '拼多多': '📦', 'Pinduoduo': '📦',
  '快手': '📹', 'Kuaishou': '📹',
  'B站': '📺', '哔哩哔哩': '📺', 'Bilibili': '📺',
  '知乎': '🧠', 'Zhihu': '🧠',
  '芒果TV': '🥭', 'MangoTV': '🥭',
  '百度': '🔍', 'Baidu': '🔍',
  '网易云音乐': '🎧', 'NetEase': '🎧',
  'QQ音乐': '🎼', 'QQ': '💬',
  '高德地图': '🗺', 'Amap': '🗺',
  '滴滴': '🚗', 'Didi': '🚗',
  '携程旅行': '🐬', '携程': '🐬', 'Ctrip': '🐬',
  '大众点评': '⭐', 'Dianping': '⭐',
  '闲鱼': '🐟', 'Xianyu': '🐟',
  '得物': '👟', 'Dewu': '👟',
  'SHEIN': '👗',
  'Temu': '📦',
  'Instagram': '📷', 'IG': '📷',
  'YouTube': '▶️',
  'Spotify': '🎵',
  'Netflix': '🎬',
  '快捷指令': '⚙️', 'Shortcuts': '⚙️',
};

// Real app icons from Google Play (auto-generated)
const APP_ICON_IMG = {
  '微信': '/static/icons/com.tencent.mm.png',
  '抖音': '/static/icons/com.ss.android.ugc.aweme.png',
  '小红书': '/static/icons/com.xingin.xhs.png',
  '微博': '/static/icons/com.sina.weibo.png',
  '淘宝': '/static/icons/com.taobao.taobao.png',
  '京东': '/static/icons/com.jingdong.app.mall.png',
  '美团': '/static/icons/com.sankuai.meituan.png',
  '支付宝': '/static/icons/com.eg.android.AlipayGphone.png',
  '快手': '/static/icons/com.kuaishou.png',
  'B站': '/static/icons/tv.danmaku.bili.png',
  '哔哩哔哩': '/static/icons/tv.danmaku.bili.png',
  '拼多多': '/static/icons/com.xunmeng.pinduoduo.png',
  '钉钉': '/static/icons/com.alibaba.android.rimet.png',
  '网易云音乐': '/static/icons/com.netease.cloudmusic.png',
  '闲鱼': '/static/icons/com.taobao.idlefish.png',
  '芒果TV': '/static/icons/com.hunantv.imgo.activity.png',
  '携程旅行': '/static/icons/com.ctrip.android.viewhome.png',
  '大众点评': '/static/icons/com.dianping.v1.png',
};

function appIcon(name) {
  if (!name) return '';
  // Real icon first
  let imgPath = APP_ICON_IMG[name];
  if (!imgPath) {
    const lower = name.toLowerCase();
    for (const [key, val] of Object.entries(APP_ICON_IMG)) {
      if (key.toLowerCase() === lower) { imgPath = val; break; }
    }
  }
  if (imgPath) return `<img class="app-icon-img" src="${imgPath}" alt="${escapeHtml(name)}">`;
  // Emoji fallback
  const icon = APP_ICONS[name];
  if (icon) return `<span class="app-icon">${icon}</span>`;
  const lower = name.toLowerCase();
  for (const [key, val] of Object.entries(APP_ICONS)) {
    if (key.toLowerCase() === lower) return `<span class="app-icon">${val}</span>`;
  }
  return '';
}

let state = {
  screenshots: [],
  filter: { status: 'inbox', app: null },
  selected: new Set(),
  batchMode: false,
  importTargetPid: null,
  stats: null,
  currentTab: 'screenshots',
  projects: [],
  conversations: [],
  currentConversation: null,
  folders: [],
  currentFolderId: null,
  folderPickerId: null,
  appFiltersExpanded: false,
  currentProject: null,
  projectFilter: 'all',
  collapsedAnalysisFolders: new Set(),
  modalSelected: new Set(),
  lightboxIndex: -1,
  lightboxItems: [],
  lightboxZoom: 1,
  lightboxFitScale: 1,
  lightboxPan: { x: 0, y: 0 },
  lightboxRotation: 0,
  lightboxDrag: null,
  lightboxDetailsOpen: false,
  searchQuery: '',
  searchResults: null,
  searchIndexing: false,
  searchProgress: null,
  manageMode: false,
  screenshotSignature: '',
  autoRefreshTimer: null,
  lasso: null,
  suppressNextCardClick: false,
  editingAnalysisBrief: false,
  analysisPollTimer: null,
  aiSettings: null,
  draftDimensions: [],
  draftScreenshotOrder: [],
  sequenceDragIndex: null,
};

// ── Init ─────────────────────────────────────────────────

async function init() {
  await Promise.all([loadStats(), loadScreenshots(), loadProjects(), loadConversations(), loadFolders()]);
  state.screenshotSignature = buildScreenshotSignature(state.screenshots);
  renderAppFilters();
  renderFolderFilters();
  setupTabs();
  setupProjectFilters();
  setupLassoSelection();
  setupLightboxInteractions();
  checkAndroidStatus();
  startRealtimeRefresh();

  // Restore last tab from sessionStorage
  const requestedConversation = new URLSearchParams(location.search).get('conversation');
  const lastTab = sessionStorage.getItem('dp_tab');
  if (requestedConversation && state.conversations.some(item => item.id === requestedConversation)) {
    switchTab('projects');
    selectConversation(requestedConversation);
  } else if (lastTab) switchTab(lastTab);
}

function setupProjectFilters() {
  document.querySelectorAll('#projectStatusFilters .filter-item').forEach(item => {
    item.addEventListener('click', () => {
      state.projectFilter = item.dataset.filter;
      document.querySelectorAll('#projectStatusFilters .filter-item').forEach(el =>
        el.classList.toggle('active', el.dataset.filter === state.projectFilter));
      state.currentProject = null;
      state.currentConversation = null;
      renderProjectNav();
      renderProjectList();
    });
  });
}

// ── Tabs ─────────────────────────────────────────────────

function setupTabs() {
  document.querySelectorAll('.tab-nav-item').forEach(item => {
    item.addEventListener('click', () => switchTab(item.dataset.tab));
  });
}

function switchTab(tab) {
  state.currentTab = tab;
  state.currentProject = null;
  state.currentConversation = null;
  sessionStorage.setItem('dp_tab', tab);
  state.batchMode = false;
  state.selected.clear();
  document.getElementById('batchBar').style.display = 'none';
  document.getElementById('btnBatch').textContent = '批量管理';

  // Tab buttons
  document.querySelectorAll('.tab-nav-item').forEach(el =>
    el.classList.toggle('active', el.dataset.tab === tab));

  // Sidebar content
  document.getElementById('tabSidebarScreenshots').classList.toggle('active', tab === 'screenshots');
  document.getElementById('tabSidebarProjects').classList.toggle('active', tab === 'projects');

  // Main views
  document.getElementById('viewScreenshots').classList.toggle('active', tab === 'screenshots');
  document.getElementById('viewProject').classList.toggle('active', tab === 'projects');

  // Upload button only on screenshots tab
  document.getElementById('sidebarUploadArea').style.display = tab === 'screenshots' ? '' : 'none';

  if (tab === 'screenshots') {
    renderGrid();
  } else {
    backToProjectList();
  }
}

// ── Data Loading ─────────────────────────────────────────

async function loadStats() {
  const res = await fetch('/api/stats');
  state.stats = await res.json();
  applyStatsToSidebar();
}

function applyStatsToSidebar() {
  if (!state.stats) return;
  document.getElementById('countInbox').textContent = state.stats.inbox_count || 0;
}

async function loadScreenshots() {
  const res = await fetch('/api/screenshots?limit=500');
  state.screenshots = await res.json();
  state.screenshotSignature = buildScreenshotSignature(state.screenshots);
  updateFavoritesCount();
  if (state.currentTab === 'screenshots') renderGrid();
}

async function loadProjects() {
  const res = await fetch('/api/projects');
  state.projects = await res.json();
  updateProjectCounts();
  renderProjectNav();
}

async function loadConversations() {
  const res = await fetch('/api/conversations');
  state.conversations = await res.json();
  updateProjectCounts();
  renderProjectNav();
}

async function loadFolders() {
  const res = await fetch('/api/folders');
  state.folders = await res.json();
  renderFolderFilters();
}

function buildScreenshotSignature(items) {
  return items.map(s => [
    s.id,
    s.path,
    s.mtime,
    s.status,
    s.app || '',
    s.page_type || '',
    s.analysis?.favorite ? 'fav' : '',
    s.analysis?.note || '',
  ].join(':')).join('|');
}

function isInteractionBusy() {
  const modalIds = [
    'lightbox',
    'createProjectModal',
    'addScreenshotsModal',
    'importProjectModal',
    'folderPickerModal',
    'phoneGuideModal',
    'pathEditorModal',
  ];
  return state.batchMode || modalIds.some(id => {
    const el = document.getElementById(id);
    return el && el.style.display === 'flex';
  });
}

function startRealtimeRefresh() {
  if (state.autoRefreshTimer) clearInterval(state.autoRefreshTimer);
  state.autoRefreshTimer = setInterval(autoRefreshScreenshots, 2500);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) autoRefreshScreenshots();
  });
}

async function autoRefreshScreenshots() {
  if (document.hidden || isInteractionBusy()) return;
  try {
    const [statsRes, screenshotsRes, foldersRes] = await Promise.all([
      fetch('/api/stats'),
      fetch('/api/screenshots?limit=500'),
      fetch('/api/folders'),
    ]);
    const [stats, screenshots, folders] = await Promise.all([
      statsRes.json(),
      screenshotsRes.json(),
      foldersRes.json(),
    ]);
    const nextSignature = buildScreenshotSignature(screenshots);
    if (nextSignature === state.screenshotSignature) return;

    const previousIds = new Set(state.screenshots.map(s => s.id));
    const newCount = screenshots.filter(s => !previousIds.has(s.id)).length;

    state.stats = stats;
    state.screenshots = screenshots;
    state.folders = folders;
    state.screenshotSignature = nextSignature;
    applyStatsToSidebar();
    updateFavoritesCount();
    renderAppFilters();
    renderFolderFilters();

    if (state.currentTab === 'screenshots') {
      renderGrid();
      if (newCount > 0) showToast(`已同步 ${newCount} 张新截图`);
    } else if (state.currentTab === 'projects' && !state.currentProject && !state.currentConversation) {
      renderProjectList();
    }
  } catch (err) {
    // Keep polling quiet; the next successful tick will catch up.
  }
}

function updateProjectCounts() {
  const unclassified = state.conversations.filter(item => !item.project_id).length;
  document.getElementById('countAllProjects').textContent = unclassified;
}

// ── Sidebar: Project Nav ─────────────────────────────────

function renderProjectNav() {
  const el = document.getElementById('projectNavList');
  if (!state.projects.length) {
    el.innerHTML = '<div class="nav-empty">暂无项目</div>';
    return;
  }
  el.innerHTML = state.projects.map(p => {
    const count = Object.keys(p.screenshots || {}).length;
    const date = new Date(p.created_at).toLocaleDateString('zh-CN');
    return `
    <div class="nav-item nav-item-proj ${state.currentProject && state.currentProject.id === p.id ? 'active' : ''}"
         onclick="selectProject('${p.id}')">
      <div class="project-card-name">${escapeHtml(p.name)}</div>
      <div class="project-card-meta">${count} 张截图 · ${date} 创建</div>
    </div>
  `}).join('');
}

function selectProject(pid) {
  const proj = state.projects.find(p => p.id === pid);
  if (!proj) return;
  state.currentProject = proj;
  state.currentConversation = null;
  state.batchMode = false;
  state.manageMode = false;
  state.editingAnalysisBrief = false;

  document.querySelectorAll('#projectStatusFilters .filter-item').forEach(el => el.classList.remove('active'));
  renderProjectNav();

  // Show project detail in main
  document.getElementById('viewScreenshots').classList.remove('active');
  document.getElementById('viewProject').classList.add('active');
  document.getElementById('projectViewTitle').textContent = proj.name;
  ['btnShareConversation', 'btnRenameConversation', 'btnDeleteConversation'].forEach(id => document.getElementById(id).style.display = 'none');
  renderProjectDetail();
}

// ── Sidebar: Screenshot Filters ──────────────────────────

function renderAppFilters() {
  const el = document.getElementById('appFilters');
  const apps = getSortedApps();
  el.innerHTML = apps.map(a => {
    const total = Object.values(state.stats.apps[a] || {}).reduce((s, c) => s + c, 0);
    return `<div class="filter-item" data-app="${a}"><span>${appIcon(a)}${a}</span><span class="count">${total}</span></div>`;
  }).join('');

  el.querySelectorAll('.filter-item').forEach(item => {
    item.addEventListener('click', () => {
      const isClearing = state.filter.app === item.dataset.app;
      state.filter.app = isClearing ? null : item.dataset.app;
      state.filter.status = isClearing ? 'inbox' : 'all';
      state.currentFolderId = null;
      state.tagFilter = null;
      highlightFilters();
      renderGrid();
    });
  });
}

function toggleAppFilters() {
  state.appFiltersExpanded = !state.appFiltersExpanded;
  const list = document.getElementById('appFilters');
  const toggle = document.getElementById('appFiltersToggle');
  list.hidden = !state.appFiltersExpanded;
  toggle.setAttribute('aria-expanded', String(state.appFiltersExpanded));
  toggle.classList.toggle('expanded', state.appFiltersExpanded);
}

function getFolder(fid) {
  return state.folders.find(f => f.id === fid);
}

function renderFolderFilters() {
  const el = document.getElementById('folderFilters');
  if (!el) return;

  if (!state.folders.length) {
    el.innerHTML = '<div class="nav-empty">暂无文件夹</div>';
    return;
  }

  el.innerHTML = state.folders.map(f => {
    const count = (f.screenshots || []).length;
    return `<div class="filter-item folder-filter ${state.currentFolderId === f.id ? 'active' : ''}"
      data-folder-id="${f.id}" title="右键可重命名或删除">
      <span>📁 ${escapeHtml(f.name)}</span><span class="count">${count}</span>
    </div>`;
  }).join('');

  el.querySelectorAll('.folder-filter').forEach(item => {
    const fid = item.dataset.folderId;
    item.addEventListener('click', () => {
      const isClearing = state.currentFolderId === fid;
      state.currentFolderId = isClearing ? null : fid;
      state.filter.status = isClearing ? 'inbox' : 'all';
      state.filter.app = null;
      highlightFilters();
      renderGrid();
    });
    item.addEventListener('contextmenu', (e) => showFolderContextMenu(e, fid));
    item.addEventListener('dragover', (e) => {
      e.preventDefault();
      item.classList.add('drop-target');
    });
    item.addEventListener('dragleave', () => item.classList.remove('drop-target'));
    item.addEventListener('drop', async (e) => {
      e.preventDefault();
      item.classList.remove('drop-target');
      const ids = getDraggedScreenshotIds(e);
      if (ids.length) await addScreenshotsToFolder(fid, ids);
    });
  });
}

async function createFolder() {
  const name = prompt('新建素材文件夹名称');
  if (!name || !name.trim()) return;

  const res = await fetch('/api/folders', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: name.trim() }),
  });
  const data = await res.json();
  if (!data.ok) {
    showToast('创建失败: ' + (data.error || '未知错误'));
    return;
  }
  await loadFolders();
  state.currentFolderId = data.folder.id;
  if (state.batchMode && state.selected.size) {
    await addScreenshotsToFolder(data.folder.id, [...state.selected]);
  }
  highlightFilters();
  renderGrid();
  showToast('素材文件夹已创建');
}

async function renameFolder(fid) {
  const folder = getFolder(fid);
  if (!folder) return;
  const name = prompt('重命名素材文件夹', folder.name);
  if (!name || !name.trim() || name.trim() === folder.name) return;

  const res = await fetch(`/api/folders/${fid}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: name.trim() }),
  });
  const data = await res.json();
  if (!data.ok) {
    showToast('重命名失败: ' + (data.error || '未知错误'));
    return;
  }
  await Promise.all([loadFolders(), loadScreenshots(), loadStats()]);
  highlightFilters();
  renderGrid();
  showToast('素材文件夹已重命名');
}

async function deleteFolder(fid) {
  const folder = getFolder(fid);
  if (!folder) return;
  if (!confirm(`确定删除「${folder.name}」素材文件夹？\n其中的截图会移回“新添加截图”，图片不会被删除。`)) return;

  const res = await fetch(`/api/folders/${fid}`, { method: 'DELETE' });
  const data = await res.json();
  if (!data.ok) {
    showToast('删除失败: ' + (data.error || '未知错误'));
    return;
  }
  if (state.currentFolderId === fid) state.currentFolderId = null;
  state.filter.status = 'inbox';
  await Promise.all([loadFolders(), loadScreenshots(), loadStats()]);
  highlightFilters();
  renderGrid();
  showToast('素材文件夹已删除，截图已移回新添加截图');
}

async function addScreenshotsToFolder(fid, ids) {
  const uniqueIds = [...new Set(ids)].filter(Boolean);
  if (!uniqueIds.length) return;

  const res = await fetch(`/api/folders/${fid}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ add_screenshots: uniqueIds }),
  });
  const data = await res.json();
  if (!data.ok) {
    showToast('移入文件夹失败: ' + (data.error || '未知错误'));
    return;
  }
  await Promise.all([loadFolders(), loadScreenshots(), loadStats()]);
  renderFolderFilters();
  renderAppFilters();
  renderGrid();
  showToast(`已加入素材文件夹 ${uniqueIds.length} 张`);
}

function showFolderPicker() {
  if (!state.selected.size) return;
  state.folderPickerId = null;
  const el = document.getElementById('folderPickerList');
  if (!state.folders.length) {
    el.innerHTML = '<div class="nav-empty">暂无素材文件夹，请先在左侧点击 + 新建</div>';
  } else {
    el.innerHTML = state.folders.map(folder => `
      <div class="nav-item" data-folder-id="${folder.id}" onclick="selectFolderPicker('${folder.id}', this)">
        <span class="nav-label">📁 ${escapeHtml(folder.name)}</span>
        <span class="count">${(folder.screenshots || []).length}</span>
      </div>
    `).join('');
  }
  document.getElementById('btnFolderPickerConfirm').disabled = true;
  document.getElementById('folderPickerModal').style.display = 'flex';
}

function selectFolderPicker(fid, el) {
  state.folderPickerId = fid;
  document.querySelectorAll('#folderPickerList .nav-item').forEach(item => item.classList.remove('active'));
  el.classList.add('active');
  document.getElementById('btnFolderPickerConfirm').disabled = false;
}

function hideFolderPicker() {
  document.getElementById('folderPickerModal').style.display = 'none';
  state.folderPickerId = null;
}

async function confirmFolderPicker() {
  if (!state.folderPickerId || !state.selected.size) return;
  const fid = state.folderPickerId;
  hideFolderPicker();
  await addScreenshotsToFolder(fid, [...state.selected]);
}

document.querySelectorAll('#statusFilters .filter-item').forEach(item => {
  item.addEventListener('click', () => {
    state.filter.status = item.dataset.status;
    state.filter.app = null;
    state.currentFolderId = null;

    highlightFilters();
    renderGrid();
  });
});

function highlightFilters() {
  document.querySelectorAll('#statusFilters .filter-item').forEach(el =>
    el.classList.toggle('active', !state.currentFolderId && !state.filter.app && el.dataset.status === state.filter.status));
  document.querySelectorAll('#appFilters .filter-item').forEach(el =>
    el.classList.toggle('active', !state.currentFolderId && el.dataset.app === state.filter.app));
  document.querySelectorAll('#folderFilters .folder-filter').forEach(el =>
    el.classList.toggle('active', el.dataset.folderId === state.currentFolderId));

  const parts = [];
  const folder = state.currentFolderId ? getFolder(state.currentFolderId) : null;
  if (folder) parts.push(folder.name);
  else if (state.filter.app) parts.push(state.filter.app);

  if (!folder && state.filter.status !== 'all') {
    const labels = { inbox: '新添加截图', organized: '已整理', favorites: '已收藏' };
    parts.push(labels[state.filter.status] || '');
  }
  document.getElementById('viewTitle').textContent = parts.length ? parts.join(' · ') : '截图';
}

// ── Date grouping ────────────────────────────────────────

function groupLabel(ts) {
  const d = new Date(ts * 1000);
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const diffDays = Math.floor((today - new Date(d.getFullYear(), d.getMonth(), d.getDate())) / 86400000);
  if (diffDays === 0) return { key: 'day_0', label: '今天' };
  if (diffDays === 1) return { key: 'day_1', label: '昨天' };
  if (diffDays === 2) return { key: 'day_2', label: '前天' };
  const m = d.getMonth() + 1;
  const y = d.getFullYear();
  const label = y === now.getFullYear() ? `${m}月` : `${y}年${m}月`;
  return { key: `month_${y}-${m}`, label };
}

// ── Render Grid ──────────────────────────────────────────

function renderGrid() {
  const content = document.getElementById('content');
  let items = state.screenshots;

  // Search is global and takes priority over sidebar filters.
  if (state.searchResults !== null) {
    const resultSet = new Set(state.searchResults);
    items = items.filter(s => resultSet.has(s.id));
  } else {
    if (state.filter.status === 'inbox') items = items.filter(s => s.status === 'inbox');
    else if (state.filter.status === 'organized') items = items.filter(s => s.status === 'organized');
    else if (state.filter.status === 'favorites') items = items.filter(s => s.analysis?.favorite);
    if (state.filter.app) items = items.filter(s => s.app === state.filter.app);
    if (state.currentFolderId) {
      const folder = getFolder(state.currentFolderId);
      const ids = new Set(folder?.screenshots || []);
      items = items.filter(s => ids.has(s.id));
    }
  }

  if (!items.length) {
    if (state.searchQuery) {
      const progress = state.searchProgress;
      const message = state.searchIndexing
        ? `正在识别图片文字${progress ? ` ${progress.processed}/${progress.total}` : ''}，结果会自动出现`
        : `未找到包含「${escapeHtml(state.searchQuery)}」的截图`;
      content.innerHTML = `<div class="search-no-results"><div class="icon">🔍</div><p>${message}</p><p style="font-size:12px;color:var(--text-muted);">可搜索图片文字、素材文件夹、来源 App、备注或文件名</p></div>`;
    } else {
      content.innerHTML = `<div class="empty"><div class="empty-icon">📱</div><p>没有匹配的截图</p></div>`;
    }
    return;
  }

  // Group by day (recent 3) then month
  const groups = {};
  items.forEach(s => {
    const gl = groupLabel(s.mtime || 0);
    if (!groups[gl.key]) groups[gl.key] = { key: gl.key, label: gl.label, items: [] };
    groups[gl.key].items.push(s);
  });

  // Sort groups: day groups first (reverse), then month groups (reverse)
  const sortedGroups = Object.values(groups).sort((a, b) => {
    const ta = a.items[0].mtime || 0;
    const tb = b.items[0].mtime || 0;
    return tb - ta;
  });

  let html = '';
  let isFirst = true;
  sortedGroups.forEach(g => {
    const monthClick = state.batchMode ? `onclick="batchSelectMonth('${g.key}')"` : '';
    html += `<div class="month-header" data-month="${g.key}" ${monthClick} style="${state.batchMode ? 'cursor:pointer;user-select:none;' : ''}"><span class="month-check" style="${state.batchMode ? '' : 'display:none;'}"></span>${g.label}</div>`;
    html += `<div class="grid">` +
      (isFirst && shouldShowDragGuide() ? renderDragGuideCard() : '') +
      g.items.map(s => {
        const isSelected = state.selected.has(s.id);
        const isInbox = s.status === 'inbox';
        const canDrag = !state.batchMode || isSelected;
        return `
          <div class="card ${isSelected ? 'selected' : ''} ${state.batchMode ? 'selectable' : ''}"
               data-id="${s.id}" data-month="${g.key}"
               draggable="${canDrag ? 'true' : 'false'}"
               ondragstart="${canDrag ? `dragStart(event, this.dataset.id)` : ''}"
               oncontextmenu="showScreenshotContextMenu(event, this.dataset.id)"
               onclick="${state.batchMode ? `toggleCard('${s.id}', event)` : `openLightbox('${s.id}')`}">
            <div class="check">✓</div>
            ${s.analysis?.note ? '<div class="note-dot"></div>' : ''}
            <img class="thumb" src="/screenshots/${s.path}" loading="lazy" alt="" draggable="false">
            <div class="meta">
              ${s.app ? `<div class="app-tag">${appIcon(s.app)}${s.app}</div>` : '<div class="app-tag" style="color:var(--text-muted)">未归类</div>'}
              ${s.page_type && s.page_type !== '其他' ? `<div class="type-tag">${s.page_type}</div>` : ''}
              ${s.analysis && s.analysis.page_type && s.analysis.page_type !== '其他' && s.analysis.page_type !== s.page_type ? `<div class="type-tag">${escapeHtml(s.analysis.page_type)}</div>` : ''}
            </div>
          </div>`;
      }).join('') + '</div>';
    isFirst = false;
  });

  content.innerHTML = html;
}

// ── Drag Guide Card ─────────────────────────────────────

function shouldShowDragGuide() {
  if (state.batchMode) return false;
  if (state.searchResults !== null) return false;
  if (state.filter.status !== 'inbox') return false;
  try {
    return !localStorage.getItem('dp_drag_guide_dismissed');
  } catch (e) { return true; }
}

function renderDragGuideCard() {
  return `<div class="drag-guide-card">
    <div class="drag-guide-icon">👆</div>
    <div class="drag-guide-text">拖拽截图到左侧<br>素材文件夹即可归档</div>
    <button class="btn btn-secondary btn-sm" onclick="dismissDragGuide()">知道了</button>
  </div>`;
}

function dismissDragGuide() {
  try { localStorage.setItem('dp_drag_guide_dismissed', '1'); } catch (e) {}
  const card = document.querySelector('.drag-guide-card');
  if (card) card.remove();
}

// ── Drag & Drop Classify ────────────────────────────────

function dragStart(event, id) {
  const ids = state.selected.has(id) ? [...state.selected] : [id];
  event.dataTransfer.setData('text/plain', id);
  event.dataTransfer.setData('application/json', JSON.stringify({ screenshotIds: ids }));
  event.dataTransfer.effectAllowed = 'move';
  const card = event.target.closest('.card');
  if (card) card.classList.add('dragging');
  const thumb = card?.querySelector('.thumb');
  if (thumb) {
    const ghost = thumb.cloneNode(true);
    ghost.style.width = '100px';
    ghost.style.position = 'absolute';
    ghost.style.top = '-9999px';
    document.body.appendChild(ghost);
    event.dataTransfer.setDragImage(ghost, 50, 68);
    setTimeout(() => ghost.remove(), 0);
  }
}

function getDraggedScreenshotIds(event) {
  try {
    const payload = event.dataTransfer.getData('application/json');
    if (payload) {
      const parsed = JSON.parse(payload);
      if (Array.isArray(parsed.screenshotIds)) return parsed.screenshotIds;
    }
  } catch (err) {}
  const sid = event.dataTransfer.getData('text/plain');
  return sid ? [sid] : [];
}

document.addEventListener('dragend', (e) => {
  document.querySelectorAll('.card.dragging').forEach(c => c.classList.remove('dragging'));
});

function getSsMap() {
  const m = {};
  state.screenshots.forEach(s => { m[s.id] = s; });
  return m;
}

function getSortedApps() {
  const apps = state.stats?.apps || {};
  const pinned = ['京东'];
  // Find most recent mtime per app
  const latest = {};
  state.screenshots.forEach(s => {
    if (s.app && !latest[s.app]) latest[s.app] = s.mtime || 0;
    if (s.app && s.mtime > latest[s.app]) latest[s.app] = s.mtime;
  });
  Object.keys(apps).forEach(a => { if (!(a in latest)) latest[a] = 0; });
  const sorted = Object.entries(latest)
    .sort((a, b) => b[1] - a[1])
    .map(e => e[0]);
  // Pinned apps first, then rest
  const top = pinned.filter(a => sorted.includes(a));
  const rest = sorted.filter(a => !pinned.includes(a));
  return [...top, ...rest];
}

// ── Batch Mode ───────────────────────────────────────────

function toggleBatchMode() {
  state.batchMode = !state.batchMode;
  state.selected.clear();
  document.getElementById('batchBar').style.display = state.batchMode ? 'flex' : 'none';
  document.getElementById('btnBatch').textContent = state.batchMode ? '取消' : '批量管理';
  document.getElementById('selectedCount').textContent = '0';
  if (state.batchMode) renderBatchProjectBtns();
  renderGrid();
}

function renderBatchProjectBtns() {
  const el = document.getElementById('batchProjectBtns');
  if (!el) return;
  el.innerHTML = '<button class="btn btn-primary btn-sm" onclick="startConversationFromSelection()">开始分析</button>';
}

async function _doImportToProject(pid) {
  const items = [...state.selected].map(id => ({ id, module: '' }));
  const res = await fetch(`/api/projects/${pid}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ add_screenshots: items }),
  });
  const data = await res.json();
  if (!data.ok) {
    showToast('加入分析项目失败: ' + (data.error || '未知错误'));
    return false;
  }
  state.selected.clear();
  document.getElementById('selectedCount').textContent = '0';
  await loadProjects();
  renderProjectNav();
  renderBatchProjectBtns();
  renderGrid();
  return true;
}

async function batchImportToProject(pid) {
  if (!state.selected.size) return;
  const count = state.selected.size;
  if (await _doImportToProject(pid)) {
    showToast(`已加入分析项目 ${count} 张`);
  }
}

function toggleCard(id, event) {
  event.stopPropagation();
  if (state.suppressNextCardClick) {
    state.suppressNextCardClick = false;
    return;
  }
  if (state.selected.has(id)) state.selected.delete(id);
  else state.selected.add(id);
  document.getElementById('selectedCount').textContent = state.selected.size;
  const card = document.querySelector(`.card[data-id="${id}"]`);
  if (card) {
    const selected = state.selected.has(id);
    card.classList.toggle('selected', selected);
    if (state.batchMode) card.draggable = selected;
  }
  updateMonthChecks();
}

function setupLassoSelection() {
  const content = document.getElementById('content');
  if (!content) return;

  content.addEventListener('mousedown', (e) => {
    if (!state.batchMode || e.button !== 0) return;
    if (e.target.closest('button, input, textarea, select, a')) return;
    if (e.target.closest('.card.selected')) return;
    e.preventDefault();

    const box = document.createElement('div');
    box.className = 'lasso-box';
    document.body.appendChild(box);
    state.lasso = {
      startX: e.clientX,
      startY: e.clientY,
      box,
      moved: false,
    };
  });

  document.addEventListener('mousemove', (e) => {
    if (!state.lasso) return;
    const lasso = state.lasso;
    const left = Math.min(lasso.startX, e.clientX);
    const top = Math.min(lasso.startY, e.clientY);
    const width = Math.abs(e.clientX - lasso.startX);
    const height = Math.abs(e.clientY - lasso.startY);

    if (width < 4 && height < 4) return;
    lasso.moved = true;
    lasso.box.style.left = `${left}px`;
    lasso.box.style.top = `${top}px`;
    lasso.box.style.width = `${width}px`;
    lasso.box.style.height = `${height}px`;

    const selectionRect = { left, top, right: left + width, bottom: top + height };
    state.selected.clear();
    document.querySelectorAll('#content .card.selectable').forEach(card => {
      const rect = card.getBoundingClientRect();
      const intersects = !(rect.right < selectionRect.left ||
        rect.left > selectionRect.right ||
        rect.bottom < selectionRect.top ||
        rect.top > selectionRect.bottom);
      card.classList.toggle('selected', intersects);
      card.draggable = intersects;
      if (intersects) state.selected.add(card.dataset.id);
    });
    document.getElementById('selectedCount').textContent = state.selected.size;
    updateMonthChecks();
  });

  document.addEventListener('mouseup', () => {
    if (!state.lasso) return;
    const moved = state.lasso.moved;
    state.lasso.box.remove();
    state.lasso = null;
    if (moved) state.suppressNextCardClick = true;
  });
}

function updateMonthChecks() {
  document.querySelectorAll('.month-check').forEach(check => {
    const monthKey = check.closest('.month-header').dataset.month;
    if (!monthKey) return;
    const cards = document.querySelectorAll(`.card[data-month="${monthKey}"]`);
    const allSelected = cards.length > 0 && [...cards].every(c => state.selected.has(c.dataset.id));
    check.classList.toggle('checked', allSelected);
  });
}

function batchSelectAll() {
  const cards = document.querySelectorAll('#content .card.selectable');
  const allIds = [...cards].map(c => c.dataset.id);
  const allSelected = allIds.every(id => state.selected.has(id));
  if (allSelected) {
    allIds.forEach(id => state.selected.delete(id));
    cards.forEach(c => { c.classList.remove('selected'); c.draggable = false; });
  } else {
    allIds.forEach(id => { state.selected.add(id); });
    cards.forEach(c => { c.classList.add('selected'); c.draggable = true; });
  }
  document.getElementById('selectedCount').textContent = state.selected.size;
  updateMonthChecks();
}

function batchSelectMonth(monthKey) {
  const cards = document.querySelectorAll(`.card.selectable[data-month="${monthKey}"]`);
  const monthIds = [...cards].map(c => c.dataset.id);
  const allSelected = monthIds.every(id => state.selected.has(id));
  if (allSelected) {
    monthIds.forEach(id => state.selected.delete(id));
    cards.forEach(c => { c.classList.remove('selected'); c.draggable = false; });
  } else {
    monthIds.forEach(id => state.selected.add(id));
    cards.forEach(c => { c.classList.add('selected'); c.draggable = true; });
  }
  document.getElementById('selectedCount').textContent = state.selected.size;
  updateMonthChecks();
}

// ── Batch: Delete ────────────────────────────────────────

async function batchDelete() {
  if (!state.selected.size) return;
  if (!confirm(`确定删除 ${state.selected.size} 张截图？此操作不可撤销。`)) return;
  const res = await fetch('/api/delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids: [...state.selected] }),
  });
  const data = await res.json();
  if (data.ok) {
    showToast(`已删除 ${data.deleted.length} 张`);
    state.selected.clear();
    document.getElementById('selectedCount').textContent = '0';
    await Promise.all([loadStats(), loadScreenshots(), loadProjects()]);
    renderAppFilters();
    renderGrid();
  }
}

// ── Context Menu: Delete Screenshot ─────────────────────

function hideScreenshotContextMenu() {
  document.querySelectorAll('.screenshot-context-menu').forEach(el => el.remove());
}

function showScreenshotContextMenu(event, id) {
  event.preventDefault();
  event.stopPropagation();

  if (state.batchMode && !state.selected.has(id)) {
    state.selected.clear();
    state.selected.add(id);
    document.querySelectorAll('#content .card.selectable').forEach(card => {
      const selected = card.dataset.id === id;
      card.classList.toggle('selected', selected);
      card.draggable = selected;
    });
    document.getElementById('selectedCount').textContent = '1';
    updateMonthChecks();
  }

  const ids = state.batchMode && state.selected.has(id) ? [...state.selected] : [id];
  const isMultiple = ids.length > 1;

  hideScreenshotContextMenu();

  const menu = document.createElement('div');
  menu.className = 'screenshot-context-menu';
  menu.innerHTML = `
    ${isMultiple ? '' : `<button class="context-menu-item" data-action="copy">
      <span>复制图片</span>
    </button>`}
    <button class="context-menu-item" data-action="reveal">
      <span>打开本地图片文件夹</span>
    </button>
    <button class="context-menu-item danger" data-action="delete">
      <span>${isMultiple ? `删除 ${ids.length} 张截图` : '删除截图'}</span>
    </button>
  `;
  const copyButton = menu.querySelector('[data-action="copy"]');
  if (copyButton) copyButton.addEventListener('click', () => copyScreenshot(id));
  menu.querySelector('[data-action="reveal"]').addEventListener('click', () => openScreenshotFolders(ids));
  menu.querySelector('[data-action="delete"]').addEventListener('click', () => deleteScreenshotsFromMenu(ids));
  document.body.appendChild(menu);

  const rect = menu.getBoundingClientRect();
  const left = Math.min(event.clientX, window.innerWidth - rect.width - 8);
  const top = Math.min(event.clientY, window.innerHeight - rect.height - 8);
  menu.style.left = `${Math.max(8, left)}px`;
  menu.style.top = `${Math.max(8, top)}px`;
}

async function openScreenshotFolders(ids) {
  hideScreenshotContextMenu();
  const res = await fetch('/api/reveal', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids }),
  });
  const data = await res.json();
  if (data.ok) showToast(data.opened > 1 ? `已打开 ${data.opened} 个本地文件夹` : '已在访达中打开');
  else showToast('打开失败: ' + (data.error || '未知错误'));
}

async function deleteScreenshotsFromMenu(ids) {
  hideScreenshotContextMenu();
  const count = ids.length;
  if (!confirm(count > 1 ? `确定删除这 ${count} 张截图？此操作不可撤销。` : '确定删除这张截图？此操作不可撤销。')) return;

  const res = await fetch('/api/delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids }),
  });
  const data = await res.json();
  if (!data.ok) {
    showToast('删除失败: ' + (data.error || '未知错误'));
    return;
  }

  ids.forEach(sid => state.selected.delete(sid));
  document.getElementById('selectedCount').textContent = state.selected.size;
  await Promise.all([loadStats(), loadScreenshots(), loadProjects(), loadFolders()]);
  renderAppFilters();
  renderGrid();
  showToast(`已删除 ${data.deleted.length} 张截图`);
}

function showFolderContextMenu(event, fid) {
  event.preventDefault();
  event.stopPropagation();
  hideScreenshotContextMenu();

  const menu = document.createElement('div');
  menu.className = 'screenshot-context-menu';
  menu.innerHTML = `
    <button class="context-menu-item" data-action="rename">
      <span>重命名文件夹</span>
    </button>
    <button class="context-menu-item danger" data-action="delete">
      <span>删除文件夹</span>
    </button>
  `;
  menu.querySelector('[data-action="rename"]').addEventListener('click', () => {
    hideScreenshotContextMenu();
    renameFolder(fid);
  });
  menu.querySelector('[data-action="delete"]').addEventListener('click', () => {
    hideScreenshotContextMenu();
    deleteFolder(fid);
  });
  document.body.appendChild(menu);

  const rect = menu.getBoundingClientRect();
  const left = Math.min(event.clientX, window.innerWidth - rect.width - 8);
  const top = Math.min(event.clientY, window.innerHeight - rect.height - 8);
  menu.style.left = `${Math.max(8, left)}px`;
  menu.style.top = `${Math.max(8, top)}px`;
}

async function copyScreenshot(id) {
  hideScreenshotContextMenu();
  const item = state.screenshots.find(s => s.id === id);
  if (!item) return;
  const url = `${location.origin}/screenshots/${item.path}`;

  try {
    const res = await fetch(url);
    const blob = await res.blob();
    if (navigator.clipboard && window.ClipboardItem) {
      await navigator.clipboard.write([new ClipboardItem({ [blob.type || 'image/png']: blob })]);
      showToast('图片已复制');
      return;
    }
  } catch (err) {}

  try {
    await navigator.clipboard.writeText(url);
    showToast('已复制图片地址');
  } catch (err) {
    showToast('复制失败，请在大图中手动复制');
  }
}

async function deleteSingleScreenshot(id) {
  hideScreenshotContextMenu();
  if (!confirm('确定删除这张截图？此操作不可撤销。')) return;

  const res = await fetch('/api/delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids: [id] }),
  });
  const data = await res.json();
  if (!data.ok) {
    showToast('删除失败: ' + (data.error || '未知错误'));
    return;
  }

  state.selected.delete(id);
  await Promise.all([loadStats(), loadScreenshots(), loadProjects()]);
  renderAppFilters();
  if (state.currentProject) {
    state.currentProject = state.projects.find(p => p.id === state.currentProject.id) || null;
    if (state.currentProject) renderProjectDetail();
    else renderProjectList();
  } else {
    renderGrid();
  }
  showToast('已删除截图');
}

document.addEventListener('click', hideScreenshotContextMenu);
document.addEventListener('scroll', hideScreenshotContextMenu, true);

// ── Batch: Import to Project ─────────────────────────────

function batchImportProject() {
  if (!state.selected.size) return;
  state.importTargetPid = null;
  renderImportProjectList();
  document.getElementById('btnImportConfirm').disabled = true;
  document.getElementById('importProjectModal').style.display = 'flex';
}

function renderImportProjectList() {
  const el = document.getElementById('importProjectList');
  if (!state.projects.length) {
    el.innerHTML = '<div class="nav-empty">暂无分析项目，可点击下方新建</div>';
  } else {
    el.innerHTML = state.projects.map(p => `
      <div class="nav-item ${state.importTargetPid === p.id ? 'active' : ''}" onclick="selectImportTarget('${p.id}', this)">
        <span class="nav-label">${escapeHtml(p.name)}</span>
        <span class="count">${Object.keys(p.screenshots || {}).length}</span>
      </div>
    `).join('');
  }
}

async function createProjectFromImport() {
  const name = prompt('新建分析项目名称');
  if (!name || !name.trim()) return;

  const res = await fetch('/api/projects', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: name.trim(), description: '' }),
  });
  const data = await res.json();
  if (!data.ok) {
    showToast('创建分析项目失败: ' + (data.error || '未知错误'));
    return;
  }

  await loadProjects();
  state.importTargetPid = data.project.id;
  renderImportProjectList();
  document.getElementById('btnImportConfirm').disabled = false;
  showToast('分析项目已创建');
}

function selectImportTarget(pid, el) {
  state.importTargetPid = pid;
  document.querySelectorAll('#importProjectList .nav-item').forEach(e => e.classList.remove('active'));
  el.classList.add('active');
  document.getElementById('btnImportConfirm').disabled = false;
}

function hideImportProject() {
  document.getElementById('importProjectModal').style.display = 'none';
  state.importTargetPid = null;
}

async function confirmImportProject() {
  if (!state.importTargetPid || !state.selected.size) return;
  const count = state.selected.size;
  const targetPid = state.importTargetPid;
  hideImportProject();
  if (await _doImportToProject(targetPid)) {
    showToast(`已加入分析项目 ${count} 张`);
    state.currentTab = 'projects';
    sessionStorage.setItem('dp_tab', 'projects');
    document.querySelectorAll('.tab-nav-item').forEach(el => el.classList.toggle('active', el.dataset.tab === 'projects'));
    document.getElementById('tabSidebarScreenshots').classList.remove('active');
    document.getElementById('tabSidebarProjects').classList.add('active');
    document.getElementById('viewScreenshots').classList.remove('active');
    document.getElementById('viewProject').classList.add('active');
    document.getElementById('sidebarUploadArea').style.display = 'none';
    selectProject(targetPid);
  }
}

// ═══════════════════════════════════════════════════════════
// ── Project Detail ────────────────────────────────────────
// ═══════════════════════════════════════════════════════════

function backToProjectList() {
  state.currentProject = null;
  state.projectFilter = 'all';
  document.querySelectorAll('#projectStatusFilters .filter-item').forEach(el =>
    el.classList.toggle('active', el.dataset.filter === 'all'));
  renderProjectNav();
  renderProjectList();
}

function renderProjectList() {
  const el = document.getElementById('projectContent');
  const today = new Date();
  const todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime() / 1000;

  // Find today's screenshots not yet in any project
  const projectIds = new Set();
  state.projects.forEach(p => { Object.keys(p.screenshots || {}).forEach(id => projectIds.add(id)); });
  const todayUnassigned = state.screenshots.filter(s =>
    (s.mtime || 0) >= todayStart && !projectIds.has(s.id)
  );

  const ssMap = getSsMap();

  let quickHtml = '';
  if (todayUnassigned.length > 0) {
    const thumbs = todayUnassigned.slice(0, 12).map(s =>
      `<img class="quick-thumb" src="/screenshots/${s.path}" loading="lazy">`
    ).join('');
    quickHtml = `<div class="quick-project-card quick-cta" onclick="quickCreateProjectFromToday(${todayUnassigned.length})">
      <div class="quick-header">
        <div class="quick-project-icon">📱</div>
        <div class="quick-project-info">
          <div class="quick-project-title">今天导入了 <strong>${todayUnassigned.length}</strong> 张新截图</div>
          <div class="quick-project-hint">点击基于这些截图创建分析项目</div>
        </div>
        <button class="btn btn-primary btn-sm" style="flex-shrink:0;">创建分析项目</button>
      </div>
      <div class="quick-thumbs">${thumbs}</div>
    </div>`;
  }

  let visibleProjects = state.projects;
  if (state.projectFilter === 'pending') visibleProjects = state.projects.filter(p => !p.analysis);
  else if (state.projectFilter === 'analyzed') visibleProjects = state.projects.filter(p => p.analysis);

  let listHtml = '';
  if (state.projects.length) {
    listHtml = visibleProjects.map(p => {
      const ids = Object.keys(p.screenshots || {});
      const iconHtml = `<div class="quick-project-icon">📂</div>`;
      const bottomThumbs = ids.slice(0, 8).map(sid => {
        const ss = ssMap[sid];
        return ss ? `<img class="quick-thumb" src="/screenshots/${ss.path}" loading="lazy">` : '';
      }).join('');
      return `<div class="quick-project-card" onclick="selectProject('${p.id}')">
        <div class="quick-header">
          ${iconHtml}
          <div class="quick-project-info">
            <div class="quick-project-title">${escapeHtml(p.name)}${p.analysis ? ' <span class="proj-badge-analyzed">已分析</span>' : ''}</div>
            <div class="quick-project-hint">${ids.length} 张截图 · ${new Date(p.created_at).toLocaleDateString('zh-CN')} 创建</div>
          </div>
          <div class="quick-project-arrow">→</div>
        </div>
        ${bottomThumbs ? `<div class="quick-thumbs">${bottomThumbs}</div>` : ''}
      </div>`;
    }).join('');
  }

  const gridHtml = listHtml ? `<div style="margin-top:4px;">${listHtml}</div>` : '';
  el.innerHTML = quickHtml + gridHtml;

  document.getElementById('projectToolbar').style.display = 'none';
}

async function quickCreateProjectFromToday(count) {
  const today = new Date();
  const todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime() / 1000;
  const dateStr = `${today.getMonth() + 1}月${today.getDate()}日`;

  // Create project
  const res = await fetch('/api/projects', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: `${dateStr}截图分析`, description: `${dateStr}导入的 ${count} 张截图` }),
  });
  const data = await res.json();
  if (!data.ok) { showToast('创建失败'); return; }

  // Add today's screenshots not in any project
  const projectIds = new Set();
  state.projects.forEach(p => { Object.keys(p.screenshots || {}).forEach(id => projectIds.add(id)); });
  const ids = state.screenshots
    .filter(s => (s.mtime || 0) >= todayStart && !projectIds.has(s.id))
    .map(s => ({ id: s.id, module: '' }));

  if (ids.length) {
    await fetch(`/api/projects/${data.project.id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ add_screenshots: ids }),
    });
  }

  await loadProjects();
  selectProject(data.project.id);
  showToast(`已创建项目并导入 ${ids.length} 张截图`);
}

// ── Comparison Board ─────────────────────────────────────

function renderComparisonBoard(proj) {
  const tags = proj.analysis?.screenshot_tags;
  if (!tags || !Object.keys(tags).length) return '';

  const ssMap = getSsMap();
  const projScreenshots = proj.screenshots || {};

  // Map filename → sid
  const filenameToSid = {};
  for (const sid of Object.keys(projScreenshots)) {
    const ss = ssMap[sid];
    if (ss) {
      const fn = sid + (ss.path ? ss.path.slice(ss.path.lastIndexOf('.')) : '.png');
      filenameToSid[fn] = sid;
    }
  }

  // Group screenshots by touchpoint and app
  // groups[touchpoint][app] = [sid, ...]
  const touchpointApps = {};
  const appCounts = {};
  for (const [filename, touchpoint] of Object.entries(tags)) {
    const sid = filenameToSid[filename] || filename.replace(/\.\w+$/, '');
    const ss = ssMap[sid];
    if (!ss) continue;
    const app = ss.app || '未归类';
    if (!touchpointApps[touchpoint]) touchpointApps[touchpoint] = {};
    if (!touchpointApps[touchpoint][app]) touchpointApps[touchpoint][app] = [];
    touchpointApps[touchpoint][app].push({ sid, ss });
    appCounts[app] = (appCounts[app] || 0) + 1;
  }

  // Sort touchpoints by total screenshots desc
  const touchpoints = Object.keys(touchpointApps).sort((a, b) => {
    const totalA = Object.values(touchpointApps[a]).reduce((s, arr) => s + arr.length, 0);
    const totalB = Object.values(touchpointApps[b]).reduce((s, arr) => s + arr.length, 0);
    return totalB - totalA;
  });

  // Collect all apps and sort by count desc
  const pinned = ['京东'];
  const appNames = Object.keys(appCounts).sort((a, b) => appCounts[b] - appCounts[a]);
  const apps = [...pinned.filter(a => appNames.includes(a)), ...appNames.filter(a => !pinned.includes(a))];

  // Build grid: first column touchpoint name, then one column per app
  const gridCols = `120px repeat(${apps.length}, auto)`;
  const totalCols = apps.length + 1;

  // Header row
  let html = `<div class="cmp-table" style="grid-template-columns:${gridCols};">`;
  html += `<div class="cmp-hd-corner">模块</div>`;
  apps.forEach(app => {
    html += `<div class="cmp-hd-app">${appIcon(app)}${escapeHtml(app)}</div>`;
  });

  // Touchpoint rows
  const touchpointAnalysis = proj.analysis?.touchpoint_analysis || [];
  const tpAnalysisMap = {};
  touchpointAnalysis.forEach(t => {
    tpAnalysisMap[t.touchpoint] = t;
  });

  touchpoints.forEach(tp => {
    html += `<div class="cmp-row-tp" onclick="toggleTpAnalysis(this, '${escapeHtml(tp).replace(/'/g, "\\'")}')"><span class="cmp-row-arrow">▶</span>${escapeHtml(tp)}</div>`;
    apps.forEach(app => {
      const items = touchpointApps[tp]?.[app] || [];
      if (items.length) {
        html += `<div class="cmp-cell">`;
        items.forEach(item => {
          const thumb = `/screenshots/${item.ss.path}`;
          html += `<img class="cmp-thumb" src="${thumb}" loading="lazy"
            onclick="event.stopPropagation(); openLightbox('${item.sid}')" title="${escapeHtml(app)}">`;
        });
        html += `</div>`;
      } else {
        html += `<div class="cmp-cell"><span class="cmp-empty">—</span></div>`;
      }
    });

    // Analysis row (collapsed by default)
    const analysis = tpAnalysisMap[tp];
    if (analysis) {
      html += `<div class="cmp-analysis-row" data-tp="${escapeHtml(tp)}" style="grid-column:1/-1;">
        <strong>对比分析：</strong>${renderText(analysis.comparison || '')}
        ${(analysis.highlights || []).length ? '<div style="margin-top:4px;"><strong>亮点：</strong>' + analysis.highlights.map(h => renderText(h)).join('；') + '</div>' : ''}
        ${analysis.best_practice ? '<div style="margin-top:2px;"><strong>最佳实践：</strong>' + renderText(analysis.best_practice) + '</div>' : ''}
      </div>`;
    }
  });

  html += `</div>`; // close cmp-table

  return `<div class="cmp-board" id="cmpBoard">
    <div class="cmp-header" onclick="toggleComparisonBoard()">
      <span class="cmp-title">📊 对比看板</span>
      <span class="cmp-toggle">收起</span>
    </div>
    <div class="cmp-body">${html}</div>
  </div>`;
}

function toggleComparisonBoard() {
  const body = document.querySelector('.cmp-board .cmp-body');
  const toggle = document.querySelector('.cmp-board .cmp-toggle');
  if (!body) return;
  const hidden = body.style.display === 'none';
  body.style.display = hidden ? '' : 'none';
  toggle.textContent = hidden ? '收起' : '展开';
}

function toggleTpAnalysis(el, tp) {
  const arrow = el.querySelector('.cmp-row-arrow');
  arrow.classList.toggle('open');
  const row = document.querySelector(`.cmp-analysis-row[data-tp="${CSS.escape(tp)}"]`);
  if (row) row.classList.toggle('open');
}

function renderProjectDetail() {
  const proj = state.currentProject;
  if (!proj) return;
  const el = document.getElementById('projectContent');
  const ids = Object.keys(proj.screenshots || {});
  const ssHtml = renderProjectScreenshotGrid(proj, true);

  document.getElementById('projectToolbar').style.display = '';
  document.getElementById('btnAnalyzeProject').disabled = ids.length === 0;
  const isNewAnalysis = !!proj.analysis?.comparison_board;
  const legacyBoard = proj.analysis && !isNewAnalysis ? renderComparisonBoard(proj) : '';
  const hasResult = !!proj.analysis;
  const status = proj.analysis_status || { state: 'draft' };

  if (state.manageMode) {
    el.innerHTML = `
      ${proj.description ? `<div class="project-desc">${escapeHtml(proj.description)}</div>` : ''}
      <div class="section-title" style="margin-top:8px;">管理项目截图 (${ids.length})</div>
      ${ssHtml}
    `;
  } else if (status.state === 'queued' || status.state === 'analyzing') {
    el.innerHTML = renderAnalysisProgress(proj);
    startAnalysisPolling(proj.id);
  } else if (state.editingAnalysisBrief || !hasResult && status.state !== 'dimensions_ready') {
    el.innerHTML = renderAnalysisPreparation(proj, ssHtml);
  } else if (status.state === 'dimensions_ready') {
    state.draftDimensions = JSON.parse(JSON.stringify(proj.analysis_brief?.framework?.dimensions || []));
    state.draftScreenshotOrder = [...(proj.analysis_brief?.screenshot_order || Object.keys(proj.screenshots || {}))];
    el.innerHTML = renderDimensionConfirmation(proj);
  } else if (isNewAnalysis) {
    el.innerHTML = renderEvidenceAnalysis(proj);
  } else {
    el.innerHTML = `
      ${proj.description ? `<div class="project-desc">${escapeHtml(proj.description)}</div>` : ''}
      ${legacyBoard}
      ${renderProjectAnalysis(proj.analysis, !!legacyBoard)}
    `;
  }

  document.getElementById('btnManageScreenshots').style.display = ids.length ? '' : 'none';
  document.getElementById('btnManageScreenshots').textContent = state.manageMode ? '← 返回看板' : '管理截图';
  document.getElementById('btnAddScreenshots').style.display = state.manageMode || !hasResult ? '' : 'none';
  document.getElementById('btnAnalyzeProject').style.display = state.manageMode ? 'none' : '';
  document.getElementById('btnAnalyzeProject').textContent = hasResult ? '重新分析' : '准备分析';
  document.getElementById('btnDeleteProject').style.display = state.manageMode ? 'none' : '';
}

function renderProjectScreenshotGrid(proj, removable = false, compact = false) {
  const ids = Object.keys(proj.screenshots || {});
  if (!ids.length) return '<div class="empty-state-inline">还没有添加截图，点击上方「+ 添加截图」</div>';
  const ssMap = getSsMap();
  return `<div class="project-screenshot-grid ${compact ? 'compact' : ''}">` + ids.map(sid => {
    const ss = ssMap[sid];
    const appName = ss?.app || '未归类';
    return `<div class="project-ss-item" onclick="openProjectLightbox('${sid}')">
      ${ss ? `<img src="/screenshots/${ss.path}" loading="lazy" alt="${escapeHtml(appName)}">` : '<div class="no-thumb">?</div>'}
      <div class="project-ss-meta"><span class="project-ss-app">${appIcon(appName)}${escapeHtml(appName)}</span></div>
      ${removable ? `<button class="btn-remove-ss" onclick="event.stopPropagation();removeScreenshotFromProject('${sid}')" title="移除">✕</button>` : ''}
    </div>`;
  }).join('') + '</div>';
}

function renderAnalysisPreparation(proj, ssHtml) {
  const brief = proj.analysis_brief || {};
  const statusError = proj.analysis_status?.state === 'failed' ? proj.analysis_status.error : '';
  return `<div class="analysis-workbench">
    <section class="analysis-brief-panel" id="analysisBriefPanel">
      <div class="workbench-step"><span>1</span><div><strong>定义分析问题</strong><p>问题越具体，对比结果越可用。</p></div></div>
      <label for="analysisQuestion">想从这些截图中了解什么 <em>必填</em></label>
      <textarea id="analysisQuestion" rows="3" placeholder="例如：各 App 如何在商品详情页突出优惠并引导下单？">${escapeHtml(brief.question || '')}</textarea>
      <div class="question-presets">
        <button onclick="useQuestionPreset('对比各 App 在这个模块中的信息层级和操作引导')">模块对比</button>
        <button onclick="useQuestionPreset('对比各 App 整个页面的视觉风格、布局和品牌表达')">视觉风格</button>
        <button onclick="useQuestionPreset('对比各 App 完成目标任务的步骤、入口、反馈和可能阻力')">操作动线</button>
      </div>
      <label for="analysisContext">使用场景 <span>选填</span></label>
      <input id="analysisContext" type="text" value="${escapeHtml(brief.context || '')}" placeholder="例如：用于新版商详页改版讨论">
      ${statusError ? `<div class="analysis-inline-error">${escapeHtml(statusError)}</div>` : ''}
      <div class="brief-actions"><span>${Object.keys(proj.screenshots || {}).length} 张截图将作为分析证据</span><button class="btn btn-primary" onclick="generateAnalysisDimensions()">生成分析维度</button></div>
    </section>
    <section class="project-evidence-section"><div class="workbench-section-head"><strong>项目截图</strong><span>点击查看原图</span></div>${ssHtml}</section>
  </div>`;
}

function renderDimensionConfirmation(proj) {
  const brief = proj.analysis_brief || {};
  const framework = brief.framework || {};
  const dimensions = state.draftDimensions;
  return `<div class="analysis-workbench">
    <section class="dimension-panel">
      <div class="workbench-step"><span>2</span><div><strong>确认分析维度</strong><p>可编辑、删除或新增，确认后才会正式读取截图。</p></div></div>
      <div class="brief-summary"><span>研究问题</span><strong>${escapeHtml(brief.question || '')}</strong></div>
      <div class="method-line"><span>分析类型：${escapeHtml(framework.analysis_type || '综合分析')}</span>${(framework.methods || []).map(m => `<b>${escapeHtml(m)}</b>`).join('')}</div>
      <div class="dimension-list" id="dimensionList">${dimensions.map((d, i) => renderDimensionRow(d, i)).join('')}</div>
      <button class="btn btn-secondary btn-sm" onclick="addAnalysisDimension()">+ 新增维度</button>
      ${renderScreenshotOrderEditor(proj)}
      ${framework.limitations ? `<p class="method-limit"><strong>分析边界：</strong>${escapeHtml(framework.limitations)}</p>` : ''}
      <div class="dimension-actions"><button class="btn btn-secondary" onclick="editAnalysisQuestion()">返回修改问题</button><button class="btn btn-primary" onclick="analyzeProject()">确认维度并开始分析</button></div>
    </section>
  </div>`;
}

function renderScreenshotOrderEditor(proj) {
  const ssMap = getSsMap();
  const items = renderScreenshotOrderItems(ssMap);
  return `<div class="sequence-editor"><div class="sequence-heading"><strong>确认截图顺序</strong><span>拖动调整；动线分析会按此顺序识别步骤</span></div><div class="sequence-list" id="sequenceList">${items}</div></div>`;
}

function renderScreenshotOrderItems(ssMap = getSsMap()) {
  return state.draftScreenshotOrder.map((sid, index) => {
    const ss = ssMap[sid];
    if (!ss) return '';
    const app = ss.app || '未归类';
    return `<div class="sequence-item" draggable="true" ondragstart="startSequenceDrag(event, ${index})" ondragover="event.preventDefault()" ondrop="dropSequenceItem(event, ${index})" ondragend="endSequenceDrag()"><span class="sequence-index">${index + 1}</span><img src="/screenshots/${ss.path}" alt=""><div><strong>${appIcon(app)}${escapeHtml(app)}</strong><small>第 ${index + 1} 步证据</small></div><div class="sequence-actions"><button onclick="event.stopPropagation();moveAnalysisScreenshot(${index}, -1)" ${index === 0 ? 'disabled' : ''} title="上移">↑</button><button onclick="event.stopPropagation();moveAnalysisScreenshot(${index}, 1)" ${index === state.draftScreenshotOrder.length - 1 ? 'disabled' : ''} title="下移">↓</button></div></div>`;
  }).join('');
}

function startSequenceDrag(event, index) {
  state.sequenceDragIndex = index;
  event.dataTransfer.effectAllowed = 'move';
  event.currentTarget.classList.add('dragging');
}

function dropSequenceItem(event, targetIndex) {
  event.preventDefault();
  const sourceIndex = state.sequenceDragIndex;
  if (sourceIndex === null || sourceIndex === targetIndex) return;
  const [sid] = state.draftScreenshotOrder.splice(sourceIndex, 1);
  state.draftScreenshotOrder.splice(targetIndex, 0, sid);
  state.sequenceDragIndex = null;
  document.getElementById('sequenceList').innerHTML = renderScreenshotOrderItems();
}

function endSequenceDrag() {
  state.sequenceDragIndex = null;
  document.querySelectorAll('.sequence-item.dragging').forEach(item => item.classList.remove('dragging'));
}

function moveAnalysisScreenshot(index, offset) {
  const target = index + offset;
  if (target < 0 || target >= state.draftScreenshotOrder.length) return;
  [state.draftScreenshotOrder[index], state.draftScreenshotOrder[target]] = [state.draftScreenshotOrder[target], state.draftScreenshotOrder[index]];
  document.getElementById('sequenceList').innerHTML = renderScreenshotOrderItems();
}

function renderDimensionRow(d, index) {
  return `<div class="dimension-row" data-index="${index}"><span class="dimension-number">${index + 1}</span><div><input class="dimension-name" value="${escapeHtml(d.name || '')}" aria-label="维度名称"><input class="dimension-focus" value="${escapeHtml(d.focus || '')}" aria-label="观察重点"></div><button class="dimension-delete" onclick="removeAnalysisDimension(${index})" title="删除维度">✕</button></div>`;
}

function renderAnalysisProgress(proj) {
  const status = proj.analysis_status || {};
  const total = status.total || Object.keys(proj.screenshots || {}).length;
  const processed = status.processed || 0;
  const percent = total ? Math.round(processed / total * 100) : 0;
  const phaseText = status.phase === 'synthesis' ? '正在汇总对比结论' : '正在逐张提取图片证据';
  return `<div class="analysis-progress-panel"><div class="analysis-progress-mark"></div><h2>${phaseText}</h2><p>${status.phase === 'synthesis' ? '图片证据已整理完成，正在按确认的维度生成看板。' : `已处理 ${processed} / ${total} 张，可以留在此页查看进度。`}</p><div class="analysis-progress-track"><span style="width:${status.phase === 'synthesis' ? 100 : percent}%"></span></div>${status.failed ? `<small>${status.failed} 张暂未成功，其余截图会继续分析</small>` : ''}</div>`;
}

function renderEvidenceThumbs(ids) {
  const ssMap = getSsMap();
  return (ids || []).map(id => {
    const ss = ssMap[id];
    return ss ? `<button class="evidence-thumb" onclick="openProjectLightbox('${id}')" title="查看证据"><img src="/screenshots/${ss.path}" alt=""><span>${escapeHtml(ss.app || '未归类')}</span></button>` : '';
  }).join('');
}

function confidenceLabel(value) {
  return { high: '高置信', medium: '中置信', low: '低置信' }[value] || '未标注';
}

function renderEvidenceAnalysis(proj) {
  const analysis = proj.analysis || {};
  const brief = proj.analysis_brief || {};
  const framework = brief.framework || {};
  const board = analysis.comparison_board || [];
  const meta = analysis.meta || {};
  const appNames = [...new Set(board.flatMap(row => (row.apps || []).map(item => item.app)))];
  const boardRows = board.map(row => {
    const appMap = Object.fromEntries((row.apps || []).map(item => [item.app, item]));
    return `<div class="evidence-board-row">
      <div class="evidence-dimension"><strong>${escapeHtml(row.dimension_name || '')}</strong><p>${escapeHtml(row.comparison || '')}</p>${row.opportunity ? `<div class="dimension-opportunity"><span>机会点</span>${escapeHtml(row.opportunity)}</div>` : ''}</div>
      <div class="evidence-app-grid" style="--app-columns:${Math.max(appNames.length, 1)}">${appNames.map(app => {
        const item = appMap[app];
        if (!item) return `<div class="evidence-app-cell empty-cell"><strong>${appIcon(app)}${escapeHtml(app)}</strong><span>暂无证据</span></div>`;
        return `<div class="evidence-app-cell"><div class="evidence-cell-head"><strong>${appIcon(app)}${escapeHtml(app)}</strong><span class="confidence ${escapeHtml(item.confidence || '')}">${confidenceLabel(item.confidence)}</span></div><p>${escapeHtml(item.finding || '')}</p>${(item.strengths || []).map(v => `<div class="evidence-point positive">${escapeHtml(v)}</div>`).join('')}${(item.risks || []).map(v => `<div class="evidence-point risk">${escapeHtml(v)}</div>`).join('')}<div class="evidence-thumbs">${renderEvidenceThumbs(item.evidence_ids)}</div></div>`;
      }).join('')}</div>
    </div>`;
  }).join('');

  const findings = (analysis.key_findings || []).map((item, index) => `<article class="finding-item"><span class="finding-index">${String(index + 1).padStart(2, '0')}</span><div class="finding-body"><div class="finding-title-line"><h3>${escapeHtml(item.title || '')}</h3><span class="confidence ${escapeHtml(item.confidence || '')}">${confidenceLabel(item.confidence)}</span></div><p><strong>观察</strong>${escapeHtml(item.observation || '')}</p><p><strong>意义</strong>${escapeHtml(item.implication || '')}</p><div class="finding-recommendation"><strong>建议</strong>${escapeHtml(item.recommendation || '')}</div><div class="evidence-thumbs">${renderEvidenceThumbs(item.evidence_ids)}</div></div></article>`).join('');
  const report = analysis.report || {};
  const recommendations = (report.recommendations || []).map(item => `<div class="report-action"><span class="priority ${escapeHtml(item.priority || '')}">${item.priority === 'high' ? '高' : item.priority === 'medium' ? '中' : '低'}</span><div><strong>${escapeHtml(item.action || '')}</strong><p>${escapeHtml(item.reason || '')}</p><div class="evidence-thumbs">${renderEvidenceThumbs(item.evidence_ids)}</div></div></div>`).join('');
  const measurements = (report.measurement_hypotheses || []).map(item => `<tr><td>${escapeHtml(item.goal || '')}</td><td>${escapeHtml(item.signal || '')}</td><td>${escapeHtml(item.metric || '')}</td></tr>`).join('');

  return `<div class="analysis-results">
    ${proj.analysis_status?.state === 'stale' ? '<div class="stale-analysis-notice">项目截图已变更，当前结果仍为上一版。点击右上角「重新分析」更新。</div>' : ''}
    <header class="analysis-result-header"><div><span class="result-kicker">研究问题</span><h2>${escapeHtml(brief.question || '')}</h2><p>${escapeHtml(analysis.answer || '')}</p></div><div class="result-meta"><span>${meta.analyzed_count || Object.keys(proj.screenshots || {}).length} 张证据</span><span>${escapeHtml(meta.provider || '')} / ${escapeHtml(meta.model || '')}</span></div></header>
    <div class="method-line result-methods"><span>${escapeHtml(framework.analysis_type || '综合分析')}</span>${(framework.methods || []).map(m => `<b>${escapeHtml(m)}</b>`).join('')}</div>
    <section class="evidence-board"><div class="workbench-section-head"><strong>图片证据对比看板</strong><span>点击小图查看原始证据</span></div>${boardRows || '<div class="empty-state-inline">暂无可展示的对比维度</div>'}</section>
    ${findings ? `<section class="findings-section"><div class="workbench-section-head"><strong>核心发现</strong><span>观察、意义和建议分开呈现</span></div>${findings}</section>` : ''}
    <section class="supporting-report"><div class="workbench-section-head"><strong>辅助文字报告</strong></div><p class="report-summary">${escapeHtml(report.summary || '')}</p>${recommendations ? `<div class="report-actions">${recommendations}</div>` : ''}${measurements ? `<div class="measurement-wrap"><h3>待验证指标</h3><table><thead><tr><th>目标</th><th>信号</th><th>指标</th></tr></thead><tbody>${measurements}</tbody></table></div>` : ''}${report.limitations ? `<div class="report-limit"><strong>分析边界</strong>${escapeHtml(report.limitations)}</div>` : ''}</section>
  </div>`;
}

function focusAnalysisBrief() {
  state.editingAnalysisBrief = true;
  renderProjectDetail();
  requestAnimationFrame(() => document.getElementById('analysisQuestion')?.focus());
}

function useQuestionPreset(text) {
  const input = document.getElementById('analysisQuestion');
  if (input) { input.value = text; input.focus(); }
}

async function generateAnalysisDimensions() {
  if (!state.currentProject) return;
  const question = document.getElementById('analysisQuestion')?.value.trim() || '';
  const context = document.getElementById('analysisContext')?.value.trim() || '';
  if (question.length < 4) { showToast('请先写下一个具体的分析问题'); return; }
  const button = document.querySelector('.brief-actions .btn-primary');
  if (button) { button.disabled = true; button.textContent = '正在生成...'; }
  try {
    const res = await fetch(`/api/projects/${state.currentProject.id}/dimensions`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ question, context }) });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || '生成失败');
    await refreshCurrentProject();
    state.editingAnalysisBrief = false;
    renderProjectDetail();
  } catch (error) {
    showToast(error.message);
    if (error.message.includes('API Key')) showAISettings();
  } finally {
    if (button) { button.disabled = false; button.textContent = '生成分析维度'; }
  }
}

function collectDraftDimensions() {
  return [...document.querySelectorAll('.dimension-row')].map((row, index) => ({ id: `dimension_${index + 1}`, name: row.querySelector('.dimension-name').value.trim(), focus: row.querySelector('.dimension-focus').value.trim() })).filter(d => d.name && d.focus);
}

function addAnalysisDimension() {
  state.draftDimensions = collectDraftDimensions();
  if (state.draftDimensions.length >= 8) { showToast('最多保留 8 个分析维度'); return; }
  state.draftDimensions.push({ id: `dimension_${state.draftDimensions.length + 1}`, name: '新分析维度', focus: '填写需要观察的具体内容' });
  document.getElementById('dimensionList').innerHTML = state.draftDimensions.map((d, i) => renderDimensionRow(d, i)).join('');
}

function removeAnalysisDimension(index) {
  state.draftDimensions = collectDraftDimensions();
  if (state.draftDimensions.length <= 1) { showToast('至少保留 1 个分析维度'); return; }
  state.draftDimensions.splice(index, 1);
  document.getElementById('dimensionList').innerHTML = state.draftDimensions.map((d, i) => renderDimensionRow(d, i)).join('');
}

function editAnalysisQuestion() {
  state.editingAnalysisBrief = true;
  renderProjectDetail();
}

async function refreshCurrentProject() {
  const pid = state.currentProject?.id;
  await loadProjects();
  state.currentProject = state.projects.find(p => p.id === pid) || null;
}

function startAnalysisPolling(pid) {
  clearInterval(state.analysisPollTimer);
  state.analysisPollTimer = setInterval(async () => {
    if (state.currentProject?.id !== pid) { clearInterval(state.analysisPollTimer); return; }
    const res = await fetch(`/api/projects/${pid}/analysis-status`);
    const data = await res.json();
    if (!data.ok) return;
    if (['complete', 'failed'].includes(data.status.state)) {
      clearInterval(state.analysisPollTimer);
      await refreshCurrentProject();
      if (data.status.state === 'failed') state.editingAnalysisBrief = true;
      renderProjectDetail();
      showToast(data.status.state === 'complete' ? '分析完成' : `分析失败：${data.status.error || '未知错误'}`);
    } else {
      state.currentProject.analysis_status = data.status;
      document.getElementById('projectContent').innerHTML = renderAnalysisProgress(state.currentProject);
    }
  }, 1500);
}

function openProjectLightbox(id) {
  const ids = new Set(Object.keys(state.currentProject?.screenshots || {}));
  const items = state.screenshots.filter(s => ids.has(s.id));
  const index = items.findIndex(s => s.id === id);
  if (index < 0) return;
  state.lightboxItems = items;
  state.lightboxIndex = index;
  showLightboxImage();
  document.getElementById('lightbox').style.display = 'flex';
  document.body.style.overflow = 'hidden';
}

function toggleManageScreenshots() {
  state.manageMode = !state.manageMode;
  renderProjectDetail();
}

// ── Touchpoint Confirmation ─────────────────────────────

function renderTouchpointConfirm() {
  const proj = state.currentProject;
  if (!proj || !proj.analysis || !proj.analysis.screenshot_tags) return;

  const el = document.getElementById('projectContent');
  document.getElementById('projectToolbar').style.display = '';
  document.getElementById('btnAnalyzeProject').style.display = 'none';
  document.getElementById('btnAddScreenshots').style.display = 'none';
  document.getElementById('btnDeleteProject').style.display = 'none';

  const tags = proj.analysis.screenshot_tags;
  const ssMap = getSsMap();

  // Map filename → sid
  const filenameToSid = {};
  for (const sid of Object.keys(proj.screenshots || {})) {
    const ss = ssMap[sid];
    if (ss) {
      const fn = sid + (ss.path ? ss.path.slice(ss.path.lastIndexOf('.')) : '.png');
      filenameToSid[fn] = sid;
    }
  }

  // Group screenshots by touchpoint
  const groups = {};
  const assigned = new Set();
  for (const [filename, touchpoint] of Object.entries(tags)) {
    const sid = filenameToSid[filename] || filename.replace(/\.\w+$/, '');
    if (!groups[touchpoint]) groups[touchpoint] = [];
    const ss = ssMap[sid];
    groups[touchpoint].push({ sid, ss });
    assigned.add(sid);
  }

  // Find unassigned
  const unassigned = [];
  for (const sid of Object.keys(proj.screenshots || {})) {
    if (!assigned.has(sid)) {
      unassigned.push({ sid, ss: ssMap[sid] });
    }
  }
  if (unassigned.length) groups['未分类'] = unassigned;

  // Store for drag operations
  state._confirmGroups = groups;

  let groupsHtml = '';
  for (const [tp, items] of Object.entries(groups)) {
    const isUnclassified = tp === '未分类';
    const thumbs = items.map(item => {
      const thumb = item.ss ? `/screenshots/${item.ss.path}` : '';
      return thumb ? `<img class="cf-ss-thumb" src="${thumb}" loading="lazy" draggable="true"
        data-sid="${item.sid}" data-from="${escapeHtml(tp)}"
        ondragstart="cfDragStart(event)" ondragend="cfDragEnd(event)">` : '';
    }).join('');

    groupsHtml += `<div class="cf-group" data-tp="${escapeHtml(tp)}"
      ondragover="cfDragOver(event)" ondragleave="cfDragLeave(event)" ondrop="cfDrop(event)">
      <div class="cf-group-header">
        <span class="cf-group-name" ${isUnclassified ? '' : `contenteditable="true"`}
          onblur="cfRenameGroup(this, '${escapeHtml(tp)}')">${escapeHtml(tp)}</span>
        <span class="cf-group-count">${items.length} 张</span>
      </div>
      <div class="cf-group-thumbs">${thumbs || `<span class="cf-drop-hint">拖入截图</span>`}</div>
    </div>`;
  }

  el.innerHTML = `
    <div class="cf-panel">
      <div class="cf-panel-header">
        <div>
          <h3 style="font-size:16px;font-weight:600;margin:0;">模块分类确认</h3>
          <p style="font-size:12px;color:var(--text-muted);margin:4px 0 0;">AI 已自动分类，可拖拽截图调整模块，确认后生成对比矩阵</p>
        </div>
      </div>
      <div class="cf-groups">${groupsHtml}</div>
      <div class="cf-panel-footer">
        <button class="btn btn-secondary btn-sm" onclick="cfAddGroup()">+ 新增模块</button>
        <div style="flex:1;"></div>
        <button class="btn btn-secondary btn-sm" onclick="renderProjectDetail()">跳过</button>
        <button class="btn btn-primary btn-sm" onclick="cfConfirm()">确认并生成报告</button>
      </div>
    </div>`;
}

// ── Touchpoint confirm drag & drop ──────────────────────

let cfDragSid = null;
let cfDragFrom = null;

function cfDragStart(e) {
  cfDragSid = e.target.dataset.sid;
  cfDragFrom = e.target.dataset.from;
  e.target.classList.add('dragging');
  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/plain', cfDragSid);
}

function cfDragEnd(e) {
  e.target.classList.remove('dragging');
  document.querySelectorAll('.cf-group.drag-over').forEach(el => el.classList.remove('drag-over'));
}

function cfDragOver(e) {
  e.preventDefault();
  e.currentTarget.classList.add('drag-over');
}

function cfDragLeave(e) {
  e.currentTarget.classList.remove('drag-over');
}

function cfDrop(e) {
  e.preventDefault();
  e.currentTarget.classList.remove('drag-over');
  if (!cfDragSid) return;
  const toTp = e.currentTarget.dataset.tp;
  if (toTp === cfDragFrom) return;

  // Move in state._confirmGroups
  const groups = state._confirmGroups;
  if (!groups) return;

  // Find and remove from source
  let item = null;
  for (const [tp, items] of Object.entries(groups)) {
    const idx = items.findIndex(i => i.sid === cfDragSid);
    if (idx >= 0) {
      item = items.splice(idx, 1)[0];
      if (!items.length) delete groups[tp];
      break;
    }
  }
  // Add to target
  if (item) {
    if (!groups[toTp]) groups[toTp] = [];
    groups[toTp].push(item);
  }
  cfDragSid = null;
  cfDragFrom = null;
  cfRerenderGroups();
}

function cfRerenderGroups() {
  const container = document.querySelector('.cf-groups');
  if (!container) return;
  const groups = state._confirmGroups;
  if (!groups) return;

  let html = '';
  for (const [tp, items] of Object.entries(groups)) {
    const isUnclassified = tp === '未分类';
    const thumbs = items.map(item => {
      const thumb = item.ss ? `/screenshots/${item.ss.path}` : '';
      return thumb ? `<img class="cf-ss-thumb" src="${thumb}" loading="lazy" draggable="true"
        data-sid="${item.sid}" data-from="${escapeHtml(tp)}"
        ondragstart="cfDragStart(event)" ondragend="cfDragEnd(event)">` : '';
    }).join('');

    html += `<div class="cf-group" data-tp="${escapeHtml(tp)}"
      ondragover="cfDragOver(event)" ondragleave="cfDragLeave(event)" ondrop="cfDrop(event)">
      <div class="cf-group-header">
        <span class="cf-group-name" ${isUnclassified ? '' : `contenteditable="true"`}
          onblur="cfRenameGroup(this, '${escapeHtml(tp)}')">${escapeHtml(tp)}</span>
        <span class="cf-group-count">${items.length} 张</span>
      </div>
      <div class="cf-group-thumbs">${thumbs || `<span class="cf-drop-hint">拖入截图</span>`}</div>
    </div>`;
  }
  container.innerHTML = html;
}

function cfRenameGroup(el, oldName) {
  const newName = el.textContent.trim();
  if (!newName || newName === oldName) { el.textContent = oldName; return; }
  const groups = state._confirmGroups;
  if (!groups || !groups[oldName]) return;
  groups[newName] = groups[oldName];
  delete groups[oldName];
  el.closest('.cf-group').dataset.tp = newName;
  // Update draggable items' data-from
  el.closest('.cf-group').querySelectorAll('.cf-ss-thumb').forEach(img => {
    img.dataset.from = newName;
  });
  el.textContent = newName;
}

function cfAddGroup() {
  const groups = state._confirmGroups;
  if (!groups) return;
  let n = 1;
  while (groups[`新模块 ${n}`]) n++;
  groups[`新模块 ${n}`] = [];
  cfRerenderGroups();
  // Focus the new group name for editing
  setTimeout(() => {
    const el = document.querySelector('.cf-group:last-child .cf-group-name');
    if (el && el.contentEditable === 'true') {
      el.focus();
      document.execCommand('selectAll', false, null);
    }
  }, 100);
}

async function cfConfirm() {
  const proj = state.currentProject;
  if (!proj) return;
  const groups = state._confirmGroups;
  if (!groups) return;

  // Build update_modules payload
  const updateModules = [];
  for (const [tp, items] of Object.entries(groups)) {
    for (const item of items) {
      updateModules.push({ id: item.sid, module: tp === '未分类' ? '' : tp });
    }
  }

  // Save via API
  const res = await fetch(`/api/projects/${proj.id}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ update_modules: updateModules }),
  });
  const data = await res.json();
  if (data.ok) {
    await loadProjects();
    state.currentProject = state.projects.find(p => p.id === proj.id);
    // Restore toolbar buttons
    document.getElementById('btnAnalyzeProject').style.display = '';
    document.getElementById('btnAddScreenshots').style.display = '';
    document.getElementById('btnDeleteProject').style.display = '';
    renderProjectDetail();
    renderProjectNav();
    showToast('模块已确认，报告已生成');
  } else {
    showToast('保存失败: ' + (data.error || '未知错误'));
  }
}

function renderProjectAnalysis(a, skipTags = false) {
  if (a.raw) return `<div class="project-report"><pre style="white-space:pre-wrap;font-size:12px;">${escapeHtml(a.raw)}</pre></div>`;

  let html = '<div class="project-report">';

  // ── Strategy Summary (overview + recommendations merged) ──
  if (a.overview || a.recommendations) {
    html += `<div class="rp-section"><h3 class="rp-section-title">💡 设计策略总结</h3>`;
    if (a.overview) html += `<p class="rp-overview">${renderText(a.overview)}</p>`;
    if (a.recommendations) html += `<div class="rp-recommend">${renderText(a.recommendations)}</div>`;
    html += `</div>`;
  }

  // ── Screenshot tags (only when no comparison board) ──
  if (!skipTags && a.screenshot_tags && Object.keys(a.screenshot_tags).length) {
    html += `<div class="rp-section"><h3 class="rp-section-title">截图模块分类</h3>
      <div class="tag-list">${Object.entries(a.screenshot_tags).map(([fn, tag]) =>
        `<span class="tag">${escapeHtml(fn)} → ${escapeHtml(tag)}</span>`).join('')}</div></div>`;
  }

  // ── Platform Comparison ──
  if (a.platform_comparison && a.platform_comparison.length) {
    html += `<div class="rp-section"><h3 class="rp-section-title">📱 平台设计特点</h3>
      <div class="rp-platform-grid">`;
    a.platform_comparison.forEach(p => {
      html += `<div class="rp-platform-item">
        <div class="rp-platform-head">
          <span class="rp-platform-icon">${appIcon(p.platform)}</span>
          <span class="rp-platform-name">${escapeHtml(p.platform)}</span>
        </div>
        ${p.characteristics ? `<p class="rp-platform-desc">${renderText(p.characteristics)}</p>` : ''}
        <div class="rp-platform-tags">
          ${(p.strengths || []).map(s => `<span class="tag tag-good">✓ ${renderText(s)}</span>`).join('')}
          ${(p.weaknesses || []).map(w => `<span class="tag tag-bad">✗ ${renderText(w)}</span>`).join('')}
        </div>
      </div>`;
    });
    html += `</div></div>`;
  }

  // ── Design Highlights ──
  if (a.design_highlights && a.design_highlights.length) {
    html += `<div class="rp-section"><h3 class="rp-section-title">🔍 设计亮点</h3>
      <ul class="rp-highlights-list">`;
    a.design_highlights.forEach(d => {
      html += `<li>
        <span class="rp-hl-desc">${renderText(d.description)}</span>
        <span class="rp-hl-platform">${appIcon(d.platform)}${escapeHtml(d.platform || '')}</span>
        ${d.why_good ? `<span class="rp-hl-reason">${renderText(d.why_good)}</span>` : ''}
      </li>`;
    });
    html += `</ul></div>`;
  }

  html += '</div>';
  return html;
}

// ═══════════════════════════════════════════════════════════
// ── Project Actions ───────────────────────────────────────
// ═══════════════════════════════════════════════════════════

async function showAISettings() {
  const modal = document.getElementById('aiSettingsModal');
  const error = document.getElementById('aiSettingsError');
  error.style.display = 'none';
  modal.style.display = 'flex';
  try {
    const res = await fetch('/api/ai-settings');
    state.aiSettings = await res.json();
    const select = document.getElementById('aiProviderInput');
    select.innerHTML = state.aiSettings.providers.map(p => `<option value="${p.id}">${escapeHtml(p.label)}</option>`).join('');
    select.value = state.aiSettings.provider;
    document.getElementById('aiModelInput').value = state.aiSettings.model || '';
    document.getElementById('aiBaseUrlInput').value = state.aiSettings.base_url || '';
    document.getElementById('aiKeyInput').value = '';
    updateAIKeyStatus();
    onAIProviderChange(false);
  } catch (err) {
    error.textContent = err.message;
    error.style.display = '';
  }
}

function hideAISettings() {
  document.getElementById('aiSettingsModal').style.display = 'none';
}

function updateAIKeyStatus() {
  const settings = state.aiSettings || {};
  const el = document.getElementById('aiKeyStatus');
  el.textContent = settings.key_configured ? `已配置 ${settings.key_preview || 'API Key'}${settings.key_source === 'env' ? '（来自 .env）' : '（Mac 钥匙串）'}` : '尚未配置 API Key';
  el.classList.toggle('configured', !!settings.key_configured);
  const clearButton = document.getElementById('btnClearAIKey');
  clearButton.disabled = !settings.key_configured || settings.key_source === 'env';
  clearButton.title = settings.key_source === 'env' ? '该 Key 来自 .env，需在配置文件中删除' : '';
}

function onAIProviderChange(resetModel = true) {
  const provider = document.getElementById('aiProviderInput').value;
  const info = state.aiSettings?.providers?.find(p => p.id === provider);
  if (resetModel && info) {
    const returningToSaved = provider === state.aiSettings?.provider;
    document.getElementById('aiModelInput').value = returningToSaved ? state.aiSettings.model : info.default_model;
    document.getElementById('aiBaseUrlInput').value = returningToSaved ? state.aiSettings.base_url : (info.default_base_url || '');
  }
  document.getElementById('aiProviderHint').textContent = info?.hint || '';
  document.getElementById('aiBaseUrlInput').disabled = provider === 'gemini';
  if (state.aiSettings && provider !== state.aiSettings.provider) {
    const status = document.getElementById('aiKeyStatus');
    status.textContent = '切换服务商后，请填写对应的 API Key';
    status.classList.remove('configured');
    document.getElementById('btnClearAIKey').disabled = true;
  } else {
    updateAIKeyStatus();
  }
}

async function saveAISettings(keepOpen = false) {
  const error = document.getElementById('aiSettingsError');
  error.style.display = 'none';
  const payload = {
    provider: document.getElementById('aiProviderInput').value,
    model: document.getElementById('aiModelInput').value.trim(),
    base_url: document.getElementById('aiBaseUrlInput').value.trim(),
    api_key: document.getElementById('aiKeyInput').value.trim() || null,
  };
  if (!payload.model) { error.textContent = '请填写模型名称'; error.style.display = ''; return false; }
  const button = document.getElementById('btnSaveAI');
  button.disabled = true;
  try {
    const res = await fetch('/api/ai-settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || '保存失败');
    state.aiSettings = { ...state.aiSettings, ...data.settings };
    document.getElementById('aiKeyInput').value = '';
    updateAIKeyStatus();
    if (!keepOpen) { hideAISettings(); showToast('AI 设置已保存'); }
    return true;
  } catch (err) {
    error.textContent = err.message;
    error.style.display = '';
    return false;
  } finally {
    button.disabled = false;
  }
}

async function testAISettings() {
  const saved = await saveAISettings(true);
  if (!saved) return;
  const button = document.getElementById('btnTestAI');
  const error = document.getElementById('aiSettingsError');
  button.disabled = true; button.textContent = '测试中...';
  try {
    const res = await fetch('/api/ai-settings/test', { method: 'POST' });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || '连接失败');
    showToast('连接成功，可以开始分析');
  } catch (err) {
    error.textContent = `连接失败：${err.message}`;
    error.style.display = '';
  } finally {
    button.disabled = false; button.textContent = '测试连接';
  }
}

async function clearAIKey() {
  const provider = document.getElementById('aiProviderInput').value;
  if (!confirm('确定删除这个服务商保存的 API Key？')) return;
  const res = await fetch('/api/ai-settings', {
    method: 'PUT', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ provider, model: document.getElementById('aiModelInput').value.trim(), base_url: document.getElementById('aiBaseUrlInput').value.trim(), clear_key: true }),
  });
  const data = await res.json();
  if (!data.ok) { showToast(data.error || '删除失败'); return; }
  state.aiSettings = { ...state.aiSettings, ...data.settings };
  updateAIKeyStatus();
  showToast('API Key 已删除');
}

function showCreateProject() {
  document.getElementById('projectNameInput').value = '';
  document.getElementById('projectDescInput').value = '';
  document.getElementById('createProjectModal').style.display = 'flex';
  document.getElementById('projectNameInput').focus();
}

function hideCreateProject() {
  document.getElementById('createProjectModal').style.display = 'none';
}

async function createProject() {
  const name = document.getElementById('projectNameInput').value.trim();
  if (!name) { showToast('请输入文件夹名称'); return; }
  const res = await fetch('/api/projects', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, description: document.getElementById('projectDescInput').value.trim() }),
  });
  const data = await res.json();
  if (data.ok) {
    hideCreateProject();
    await loadProjects();
    if (state.batchMode) renderBatchProjectBtns();
    state.currentProject = null;
    renderProjectList();
    showToast('文件夹已创建，可将分析拖入归类');
  }
}

function showAddScreenshots() {
  if (!state.currentProject) return;
  state.modalSelected.clear();
  const existing = new Set(Object.keys(state.currentProject.screenshots || {}));
  const available = state.screenshots.filter(s => !existing.has(s.id));
  const el = document.getElementById('modalScreenshotList');

  if (!available.length) {
    el.innerHTML = '<p style="color:var(--text-muted);text-align:center;padding:24px;">所有截图都已加入项目</p>';
  } else {
    el.innerHTML = available.map(s => `
      <div class="modal-ss-item ${state.modalSelected.has(s.id) ? 'selected' : ''}"
           data-id="${s.id}" onclick="toggleModalSelect('${s.id}', this)">
        <img src="/screenshots/${s.path}" loading="lazy" alt="">
        <div class="modal-ss-info">
          <span class="modal-ss-app">${appIcon(s.app)}${escapeHtml(s.app || '未归类')}</span>
          <span class="modal-ss-type">${escapeHtml(s.page_type || '')}</span>
        </div>
        <div class="check">✓</div>
      </div>`).join('');
  }
  document.getElementById('addScreenshotsModal').style.display = 'flex';
}

function hideAddScreenshots() {
  document.getElementById('addScreenshotsModal').style.display = 'none';
  state.modalSelected.clear();
}

function toggleModalSelect(id, el) {
  if (state.modalSelected.has(id)) { state.modalSelected.delete(id); el.classList.remove('selected'); }
  else { state.modalSelected.add(id); el.classList.add('selected'); }
}

async function addScreenshotsToProject() {
  if (!state.currentProject || !state.modalSelected.size) return;
  const items = [...state.modalSelected].map(id => ({ id, module: '' }));
  const res = await fetch(`/api/projects/${state.currentProject.id}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ add_screenshots: items }),
  });
  const data = await res.json();
  if (data.ok) {
    hideAddScreenshots();
    await loadProjects();
    state.currentProject = state.projects.find(p => p.id === state.currentProject.id);
    renderProjectDetail();
    renderProjectNav();
    showToast(`已添加 ${state.modalSelected.size} 张截图`);
  } else showToast('添加失败: ' + (data.error || '未知错误'));
}

async function removeScreenshotFromProject(sid) {
  if (!state.currentProject) return;
  if (!confirm('确定从项目中移除此截图？')) return;
  const res = await fetch(`/api/projects/${state.currentProject.id}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ remove_screenshots: [sid] }),
  });
  const data = await res.json();
  if (data.ok) {
    await loadProjects();
    state.currentProject = state.projects.find(p => p.id === state.currentProject.id);
    renderProjectDetail();
    renderProjectNav();
    showToast('已移除截图');
  }
}

async function analyzeProject() {
  if (!state.currentProject) return;
  const pid = state.currentProject.id;
  const dimensions = collectDraftDimensions();
  if (!dimensions.length) { showToast('请至少保留一个完整的分析维度'); return; }
  const brief = state.currentProject.analysis_brief || {};
  const button = document.querySelector('.dimension-actions .btn-primary');
  if (button) { button.disabled = true; button.textContent = '正在启动...'; }
  try {
    const res = await fetch(`/api/projects/${pid}/analyze`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ question: brief.question, context: brief.context, dimensions, screenshot_order: state.draftScreenshotOrder }),
    });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || '无法开始分析');
    await refreshCurrentProject();
    renderProjectDetail();
  } catch (error) {
    showToast(error.message);
    if (button) { button.disabled = false; button.textContent = '确认维度并开始分析'; }
  }
}

async function deleteProject() {
  if (!state.currentProject) return;
  if (!confirm('确定删除此项目？此操作不可撤销。')) return;
  const res = await fetch(`/api/projects/${state.currentProject.id}`, { method: 'DELETE' });
  if ((await res.json()).ok) {
    await loadProjects();
    switchTab('projects');
    showToast('项目已删除');
  }
}

// ── File Upload ──────────────────────────────────────────

async function handleFileUpload(event) {
  const files = event.target.files;
  if (!files.length) return;
  let uploaded = 0;
  for (const f of files) {
    const form = new FormData();
    form.append('file', f);
    const res = await fetch('/api/upload', { method: 'POST', body: form });
    if ((await res.json()).ok) uploaded++;
  }
  event.target.value = '';
  if (uploaded) {
    showToast(`已上传 ${uploaded} 张截图`);
    await Promise.all([loadStats(), loadScreenshots()]);
    renderAppFilters();
    renderGrid();
  }
}

// ── Utils ────────────────────────────────────────────────

function showToast(msg) {
  const existing = document.querySelector('.toast');
  if (existing) existing.remove();
  const t = document.createElement('div');
  t.className = 'toast'; t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 2300);
}

function escapeHtml(s) {
  if (!s) return '';
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

function renderText(s) {
  if (!s) return '';
  // Escape HTML, then convert **text** to highlighted spans
  const escaped = escapeHtml(s);
  return escaped.replace(/\*\*(.+?)\*\*/g, '<span class="hl">$1</span>');
}

// ── Phone Guide ────────────────────────────────────────────

function showPhoneGuide() {
  document.getElementById('phoneGuideModal').style.display = 'flex';
}

function hidePhoneGuide() {
  document.getElementById('phoneGuideModal').style.display = 'none';
}

// ── Keyboard ─────────────────────────────────────────────

document.addEventListener('keydown', (e) => {
  const lightboxOpen = document.getElementById('lightbox').style.display === 'flex';
  const editingText = ['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName);
  if (e.key === 'Escape') {
    if (lightboxOpen) closeLightbox();
    else if (document.getElementById('phoneGuideModal').style.display === 'flex') hidePhoneGuide();
    else if (document.getElementById('createProjectModal').style.display === 'flex') hideCreateProject();
    else if (document.getElementById('addScreenshotsModal').style.display === 'flex') hideAddScreenshots();
    else if (document.getElementById('folderPickerModal').style.display === 'flex') hideFolderPicker();
    else if (document.getElementById('importProjectModal').style.display === 'flex') hideImportProject();
    else if (state.batchMode) toggleBatchMode();
  }
  if (editingText || !lightboxOpen) return;
  if (e.key === 'ArrowLeft') {
    e.preventDefault();
    lightboxPrev();
  }
  if (e.key === 'ArrowRight') {
    e.preventDefault();
    lightboxNext();
  }
  if (e.key === '+' || e.key === '=') { e.preventDefault(); zoomLightboxStep(1); }
  if (e.key === '-') { e.preventDefault(); zoomLightboxStep(-1); }
  if (e.key === '0') { e.preventDefault(); resetLightboxView(); }
  if (e.key === '1') { e.preventDefault(); showLightboxActualSize(); }
  if (e.key === '[') { e.preventDefault(); rotateLightbox(-90); }
  if (e.key === ']') { e.preventDefault(); rotateLightbox(90); }
});

// ── Phone Capture ────────────────────────────────────────

let androidConnected = false;

async function checkAndroidStatus() {
  const res = await fetch('/api/capture/status');
  const data = await res.json();
  androidConnected = data.connected;
  updatePhoneBtn();
}

function updatePhoneBtn() {
  const btn = document.getElementById('btnPhoneCapture');
  if (androidConnected) {
    btn.textContent = '📸 安卓截图';
    btn.disabled = false;
    btn.style.opacity = '1';
  } else {
    btn.textContent = '📱 未连接';
    btn.disabled = true;
    btn.style.opacity = '0.5';
  }
}

async function handlePhoneCapture() {
  if (!androidConnected) return;
  const btn = document.getElementById('btnPhoneCapture');
  btn.disabled = true;
  btn.textContent = '截图中...';

  const res = await fetch('/api/capture/android', { method: 'POST' });
  const data = await res.json();

  if (data.ok) {
    showToast(`📱 已截图: ${data.app || '安卓截图'}`);
    await Promise.all([loadStats(), loadScreenshots()]);
    renderAppFilters();
    renderGrid();
  } else {
    showToast('截图失败: ' + (data.error || '未知错误'));
  }

  btn.disabled = false;
  updatePhoneBtn();
}

// ── Continuous Capture ───────────────────────────────────

let contCapturing = false;
let contStatusTimer = null;

async function toggleContCapture() {
  if (contCapturing) {
    await stopContCapture();
  } else {
    await startContCapture();
  }
}

async function startContCapture() {
  const res = await fetch('/api/capture/start', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: 'change' }),
  });
  const data = await res.json();
  if (!data.ok) { showToast(data.error); return; }

  contCapturing = true;
  const btn = document.getElementById('btnContCapture');
  btn.textContent = '⏹ 停止采集';
  btn.style.background = '#d94a4a';
  btn.style.animation = 'pulse 1.5s ease-in-out infinite';

  let lastCount = 0;

  contStatusTimer = setInterval(async () => {
    const r = await fetch('/api/capture/status');
    const d = await r.json();
    if (d.cont_captured !== lastCount) {
      lastCount = d.cont_captured;
      if (lastCount > 0) {
        await loadScreenshots();
        if (state.currentTab === 'screenshots') renderGrid();
      }
    }
  }, 1500);

  showToast('📱 边逛边截：浏览手机时自动截图');
}

async function stopContCapture() {
  const res = await fetch('/api/capture/stop', { method: 'POST' });
  const data = await res.json();

  contCapturing = false;
  clearInterval(contStatusTimer);

  const btn = document.getElementById('btnContCapture');
  btn.textContent = '📱 边逛边截';
  btn.style.background = '#1a1a1a';
  btn.style.animation = '';

  if (data.ok) {
    showToast(`✅ 已采集 ${data.captured} 张`);
    await Promise.all([loadStats(), loadScreenshots()]);
    renderAppFilters(); renderGrid();
  }
}

// ── Capture Paths ────────────────────────────────────────

let pathEditSteps = [];
let pathEditIndex = -1;
let coordPicked = null;

async function loadCapturePaths() {
  const res = await fetch('/api/capture/paths');
  const paths = await res.json();
  const el = document.getElementById('capturePathList');
  if (!paths.length) {
    el.innerHTML = '<div class="nav-empty">暂无采集路径</div>';
    return;
  }
  el.innerHTML = paths.map(p => `
    <div class="nav-item">
      <span class="nav-label">📋 ${escapeHtml(p.name)}</span>
      <button class="btn btn-sm" style="background:none;border:none;cursor:pointer;font-size:14px;padding:0 4px;" onclick="event.stopPropagation();runCapturePath('${p.id}')" title="执行">▶️</button>
      <button class="btn btn-sm" style="background:none;border:none;cursor:pointer;font-size:14px;padding:0 4px;" onclick="event.stopPropagation();editCapturePath('${p.id}')" title="编辑">✏️</button>
      <button class="btn btn-sm" style="background:none;border:none;cursor:pointer;font-size:14px;padding:0 4px;" onclick="event.stopPropagation();deleteCapturePath('${p.id}')" title="删除">🗑</button>
    </div>`).join('');
}

async function runCapturePath(pid) {
  const btn = event.target;
  btn.textContent = '⏳'; btn.disabled = true;
  showToast('正在执行采集路径...');
  const res = await fetch(`/api/capture/paths/${pid}/run`, { method: 'POST' });
  const data = await res.json();
  if (data.ok) {
    showToast(`采集完成！已截图 ${data.total} 张`);
    await Promise.all([loadStats(), loadScreenshots()]);
    renderAppFilters(); renderGrid();
  } else {
    showToast('采集失败: ' + (data.error || '未知错误'));
  }
  btn.textContent = '▶️'; btn.disabled = false;
}

function showCreatePath() {
  pathEditSteps = []; pathEditIndex = -1; coordPicked = null;
  document.getElementById('pathEditorTitle').textContent = '新建采集路径';
  document.getElementById('pathNameInput').value = '';
  document.getElementById('pathAppInput').value = '';
  document.getElementById('pathEditorModal').style.display = 'flex';
  document.getElementById('coordPicker').style.display = 'none';
  renderPathSteps();
}

function hidePathEditor() {
  document.getElementById('pathEditorModal').style.display = 'none';
  document.getElementById('coordPicker').style.display = 'none';
}

async function refreshCoordImage() {
  const res = await fetch('/api/capture/android', { method: 'POST' });
  const data = await res.json();
  if (data.ok) {
    document.getElementById('coordImage').src = '/screenshots/' + data.path + '?t=' + Date.now();
  }
  document.getElementById('coordMarker').style.display = 'none';
  document.getElementById('coordDisplay').textContent = '—';
  document.getElementById('btnConfirmCoord').disabled = true;
  coordPicked = null;
}

function addPathStep(action) {
  // Don't allow adding a new tap/swipe if there's an unconfirmed one
  if (action === 'tap' || action === 'swipe') {
    const last = pathEditSteps[pathEditSteps.length - 1];
    if (last && (last.action === 'tap' || last.action === 'swipe')) {
      const hasCoords = last.action === 'tap' ? (last.x && last.y) : (last.x1 && last.y1 && last.x2 && last.y2);
      if (!hasCoords) {
        showToast('请先在上方截图中点击选择坐标，确认后再添加新步骤');
        return;
      }
    }
  }

  const step = { action };
  if (action === 'tap') step.x = 0, step.y = 0;
  if (action === 'swipe') step.x1 = 0, step.y1 = 0, step.x2 = 0, step.y2 = 0, step.duration = 300;
  if (action === 'wait') step.sec = 2;
  pathEditSteps.push(step);
  pathEditIndex = pathEditSteps.length - 1;

  if (action === 'tap' || action === 'swipe') {
    coordPicked = null;
    document.getElementById('coordPicker').style.display = '';
    document.getElementById('coordHint').textContent = action === 'swipe' ? '👆 点击滑动起点（再点一次选终点）' : '👆 在下方截图上点击要操作的位置';
    refreshCoordImage();
  } else {
    document.getElementById('coordPicker').style.display = 'none';
  }
  renderPathSteps();
}

function pickCoord(e) {
  const img = e.target;
  const rect = img.getBoundingClientRect();
  const scaleX = 1080 / rect.width;
  const scaleY = 2400 / rect.height;
  const x = Math.round((e.clientX - rect.left) * scaleX);
  const y = Math.round((e.clientY - rect.top) * scaleY);
  coordPicked = { x, y };

  const marker = document.getElementById('coordMarker');
  marker.style.display = '';
  marker.style.left = ((e.clientX - rect.left) / rect.width * 100) + '%';
  marker.style.top = ((e.clientY - rect.top) / rect.height * 100) + '%';

  document.getElementById('coordDisplay').textContent = `(${x}, ${y})`;
  document.getElementById('btnConfirmCoord').disabled = false;
}

function confirmCoord() {
  if (!coordPicked) return;
  // Find the last unconfirmed tap or half-confirmed swipe
  let step = null;
  for (let i = pathEditSteps.length - 1; i >= 0; i--) {
    const s = pathEditSteps[i];
    if (s.action === 'tap' && !s.x && !s.y) { step = s; break; }
    if (s.action === 'swipe' && !s.x2 && !s.y2) { step = s; break; }
  }
  if (!step) return;

  if (step.action === 'tap') {
    step.x = coordPicked.x; step.y = coordPicked.y;
    document.getElementById('coordPicker').style.display = 'none';
  } else if (step.action === 'swipe') {
    if (!step.x1) {
      step.x1 = coordPicked.x; step.y1 = coordPicked.y;
      document.getElementById('coordHint').textContent = '👆 现在点击滑动终点';
      coordPicked = null;
      document.getElementById('coordMarker').style.display = 'none';
      document.getElementById('btnConfirmCoord').disabled = true;
      document.getElementById('coordDisplay').textContent = `起点: (${step.x1}, ${step.y1})`;
    } else {
      step.x2 = coordPicked.x; step.y2 = coordPicked.y;
      document.getElementById('coordPicker').style.display = 'none';
    }
  }
  renderPathSteps();
}

function renderPathSteps() {
  const el = document.getElementById('pathSteps');
  if (!pathEditSteps.length) {
    el.innerHTML = '<div style="color:var(--text-muted);font-size:12px;padding:12px;text-align:center;">添加步骤：📸截图 👆点击 👆滑动 ⏱等待 ⬅返回 🏠主页</div>';
    return;
  }
  const icons = { screenshot: '📸', tap: '👆', swipe: '👆', wait: '⏱', back: '⬅', home: '🏠' };
  el.innerHTML = pathEditSteps.map((s, i) => {
    let desc = icons[s.action] || s.action;
    let invalid = false;
    if (s.action === 'tap') {
      invalid = !s.x || !s.y;
      desc += invalid ? ' ⚠️ 未设置坐标' : ` 点击 (${s.x}, ${s.y})`;
    }
    if (s.action === 'swipe') {
      invalid = !s.x1 || !s.y1 || !s.x2 || !s.y2;
      desc += invalid ? ' ⚠️ 坐标未完整' : ` 滑动 (${s.x1},${s.y1}) → (${s.x2},${s.y2})`;
    }
    if (s.action === 'wait') desc += ` ${s.sec || 2}秒`;
    return `<div style="display:flex;align-items:center;gap:8px;padding:6px 8px;border-bottom:1px solid #f3f3f3;font-size:13px;${invalid ? 'background:#fff3f3;' : ''}">
      <span style="color:var(--text-muted);font-size:11px;min-width:18px;">${i + 1}.</span>
      <span style="flex:1;">${desc}</span>
      <button class="btn btn-sm" style="background:none;border:none;cursor:pointer;" onclick="removePathStep(${i})">✕</button>
    </div>`;
  }).join('');
}

function removePathStep(i) { pathEditSteps.splice(i, 1); renderPathSteps(); }

async function saveCapturePath() {
  const name = document.getElementById('pathNameInput').value.trim();
  if (!name) { showToast('请输入路径名称'); return; }
  if (!pathEditSteps.length) { showToast('请添加至少一个步骤'); return; }

  // Validate: no tap at (0,0) and no swipe with missing coords
  for (let i = 0; i < pathEditSteps.length; i++) {
    const s = pathEditSteps[i];
    if (s.action === 'tap' && (!s.x || !s.y)) {
      showToast(`第 ${i + 1} 步：点击坐标未设置，请在截图上点击选择位置`);
      return;
    }
    if (s.action === 'swipe' && (!s.x1 || !s.y1 || !s.x2 || !s.y2)) {
      showToast(`第 ${i + 1} 步：滑动坐标未设置完整，请点击起点和终点`);
      return;
    }
  }

  const app = document.getElementById('pathAppInput').value.trim();
  const res = await fetch('/api/capture/paths', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, app, steps: pathEditSteps }),
  });
  const data = await res.json();
  if (data.ok) {
    hidePathEditor();
    loadCapturePaths();
    showToast('路径已保存');
  } else {
    showToast('保存失败: ' + (data.error || ''));
  }
}

async function editCapturePath(pid) {
  const res = await fetch('/api/capture/paths');
  const paths = await res.json();
  const p = paths.find(x => x.id === pid);
  if (!p) return;
  pathEditSteps = JSON.parse(JSON.stringify(p.steps));
  pathEditIndex = -1;
  document.getElementById('pathEditorTitle').textContent = '编辑采集路径';
  document.getElementById('pathNameInput').value = p.name;
  document.getElementById('pathAppInput').value = p.app || '';
  document.getElementById('pathEditorModal').style.display = 'flex';
  renderPathSteps();
}

async function deleteCapturePath(pid) {
  if (!confirm('确定删除此采集路径？')) return;
  await fetch(`/api/capture/paths/${pid}`, { method: 'DELETE' });
  loadCapturePaths();
  showToast('已删除');
}

// ── Lightbox ─────────────────────────────────────────────

function getVisibleItems() {
  let items = state.screenshots;
  if (state.currentTab === 'projects' && state.currentProject) {
    const ssMap = getSsMap();
    const ids = Object.keys(state.currentProject.screenshots || {});
    return ids.map(id => ssMap[id]).filter(Boolean);
  }
  if (state.searchResults !== null) {
    const ids = new Set(state.searchResults);
    return items.filter(s => ids.has(s.id));
  }
  if (state.filter.status === 'inbox') items = items.filter(s => s.status === 'inbox');
  else if (state.filter.status === 'organized') items = items.filter(s => s.status === 'organized');
  else if (state.filter.status === 'favorites') items = items.filter(s => s.analysis?.favorite);
  if (state.filter.app) items = items.filter(s => s.app === state.filter.app);
  if (state.currentFolderId) {
    const folder = getFolder(state.currentFolderId);
    const ids = new Set(folder?.screenshots || []);
    items = items.filter(s => ids.has(s.id));
  }
  return items;
}

function openLightbox(id) {
  const items = getVisibleItems();
  const idx = items.findIndex(s => s.id === id);
  if (idx < 0) return;

  state.lightboxItems = items;
  state.lightboxIndex = idx;
  showLightboxImage();
  document.getElementById('lightbox').style.display = 'flex';
  document.body.style.overflow = 'hidden';
}

function closeLightbox() {
  document.getElementById('lightbox').style.display = 'none';
  document.body.style.overflow = '';
  state.lightboxItems = [];
  state.lightboxIndex = -1;
  state.lightboxDrag = null;
}

function setupLightboxInteractions() {
  const stage = document.getElementById('lightboxStage');
  if (!stage || stage.dataset.ready) return;
  stage.dataset.ready = 'true';
  stage.addEventListener('wheel', event => {
    event.preventDefault();
    const factor = Math.exp(-event.deltaY * 0.0016);
    zoomLightboxAt(state.lightboxZoom * factor, event.clientX, event.clientY);
  }, { passive: false });
  stage.addEventListener('dblclick', event => {
    event.preventDefault();
    const actualScale = state.lightboxFitScale * state.lightboxZoom;
    if (Math.abs(actualScale - 1) < 0.06) resetLightboxView();
    else showLightboxActualSize(event.clientX, event.clientY);
  });
  stage.addEventListener('pointerdown', event => {
    if (event.button !== 0 || state.lightboxZoom <= 1.01) return;
    state.lightboxDrag = { x: event.clientX, y: event.clientY,
                           panX: state.lightboxPan.x, panY: state.lightboxPan.y };
    stage.classList.add('dragging');
    stage.setPointerCapture(event.pointerId);
  });
  stage.addEventListener('pointermove', event => {
    if (!state.lightboxDrag) return;
    state.lightboxPan.x = state.lightboxDrag.panX + event.clientX - state.lightboxDrag.x;
    state.lightboxPan.y = state.lightboxDrag.panY + event.clientY - state.lightboxDrag.y;
    clampLightboxPan();
    applyLightboxTransform(false);
  });
  const endDrag = event => {
    if (!state.lightboxDrag) return;
    state.lightboxDrag = null;
    stage.classList.remove('dragging');
    if (stage.hasPointerCapture(event.pointerId)) stage.releasePointerCapture(event.pointerId);
  };
  stage.addEventListener('pointerup', endDrag);
  stage.addEventListener('pointercancel', endDrag);
  window.addEventListener('resize', () => {
    if (document.getElementById('lightbox').style.display === 'flex') fitLightboxImage();
  });
}

function fitLightboxImage() {
  const image = document.getElementById('lightboxImg');
  const stage = document.getElementById('lightboxStage');
  if (!image.naturalWidth || !stage.clientWidth || !stage.clientHeight) return;
  const turned = Math.abs(state.lightboxRotation % 180) === 90;
  const visualWidth = turned ? image.naturalHeight : image.naturalWidth;
  const visualHeight = turned ? image.naturalWidth : image.naturalHeight;
  state.lightboxFitScale = Math.min((stage.clientWidth - 24) / visualWidth,
                                    (stage.clientHeight - 24) / visualHeight, 1);
  image.style.width = `${image.naturalWidth * state.lightboxFitScale}px`;
  image.style.height = `${image.naturalHeight * state.lightboxFitScale}px`;
  state.lightboxZoom = 1;
  state.lightboxPan = { x: 0, y: 0 };
  applyLightboxTransform();
  populateLightboxDetails();
}

function resetLightboxView() {
  state.lightboxZoom = 1;
  state.lightboxPan = { x: 0, y: 0 };
  applyLightboxTransform();
}

function showLightboxActualSize(clientX, clientY) {
  const targetZoom = 1 / Math.max(state.lightboxFitScale, 0.01);
  if (clientX !== undefined) zoomLightboxAt(targetZoom, clientX, clientY);
  else {
    state.lightboxZoom = targetZoom;
    state.lightboxPan = { x: 0, y: 0 };
    applyLightboxTransform();
  }
}

function zoomLightboxStep(direction) {
  const stage = document.getElementById('lightboxStage');
  const factor = direction > 0 ? 1.25 : 0.8;
  const rect = stage.getBoundingClientRect();
  zoomLightboxAt(state.lightboxZoom * factor, rect.left + rect.width / 2, rect.top + rect.height / 2);
}

function zoomLightboxAt(nextZoom, clientX, clientY) {
  const stage = document.getElementById('lightboxStage');
  const rect = stage.getBoundingClientRect();
  const minZoom = Math.min(1, 0.08 / Math.max(state.lightboxFitScale, 0.01));
  const maxZoom = 8 / Math.max(state.lightboxFitScale, 0.01);
  nextZoom = Math.max(minZoom, Math.min(maxZoom, nextZoom));
  const ratio = nextZoom / state.lightboxZoom;
  const pointerX = clientX - (rect.left + rect.width / 2);
  const pointerY = clientY - (rect.top + rect.height / 2);
  state.lightboxPan.x = pointerX - (pointerX - state.lightboxPan.x) * ratio;
  state.lightboxPan.y = pointerY - (pointerY - state.lightboxPan.y) * ratio;
  state.lightboxZoom = nextZoom;
  clampLightboxPan();
  applyLightboxTransform();
}

function clampLightboxPan() {
  const image = document.getElementById('lightboxImg');
  const stage = document.getElementById('lightboxStage');
  const turned = Math.abs(state.lightboxRotation % 180) === 90;
  const width = (turned ? image.offsetHeight : image.offsetWidth) * state.lightboxZoom;
  const height = (turned ? image.offsetWidth : image.offsetHeight) * state.lightboxZoom;
  const maxX = width > stage.clientWidth ? (width - stage.clientWidth) / 2 + stage.clientWidth * 0.16 : 0;
  const maxY = height > stage.clientHeight ? (height - stage.clientHeight) / 2 + stage.clientHeight * 0.16 : 0;
  state.lightboxPan.x = Math.max(-maxX, Math.min(maxX, state.lightboxPan.x));
  state.lightboxPan.y = Math.max(-maxY, Math.min(maxY, state.lightboxPan.y));
}

function applyLightboxTransform(animate = true) {
  const transform = document.getElementById('lightboxImageTransform');
  const image = document.getElementById('lightboxImg');
  const stage = document.getElementById('lightboxStage');
  if (!transform || !image) return;
  transform.style.transition = animate ? '' : 'none';
  transform.style.transform = `translate3d(${state.lightboxPan.x}px, ${state.lightboxPan.y}px, 0) scale(${state.lightboxZoom})`;
  image.style.transform = `rotate(${state.lightboxRotation}deg)`;
  const actualPercent = Math.round(state.lightboxFitScale * state.lightboxZoom * 100);
  document.getElementById('lbZoomValue').textContent = `${actualPercent}%`;
  stage.classList.toggle('can-pan', state.lightboxZoom > 1.01);
}

function rotateLightbox(degrees) {
  state.lightboxRotation = (state.lightboxRotation + degrees + 360) % 360;
  fitLightboxImage();
}

function showLightboxImage() {
  const item = state.lightboxItems[state.lightboxIndex];
  if (!item) return;

  const image = document.getElementById('lightboxImg');
  state.lightboxRotation = 0;
  state.lightboxDetailsOpen = false;
  document.getElementById('lightboxDetails').hidden = true;
  document.getElementById('lbInfoBtn').classList.remove('active');
  document.getElementById('lbInfoBtn').setAttribute('aria-pressed', 'false');
  image.onload = () => requestAnimationFrame(fitLightboxImage);
  image.src = `/screenshots/${item.path}`;

  // Build info
  const date = new Date((item.mtime || 0) * 1000);
  const dateStr = `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()} ${String(date.getHours()).padStart(2,'0')}:${String(date.getMinutes()).padStart(2,'0')}`;

  const isFav = item.analysis?.favorite;
  let infoHtml = '';
  if (item.app) {
    infoHtml += `<span class="lb-app">${appIcon(item.app)}${escapeHtml(item.app)}</span>`;
  } else {
    infoHtml += `<span class="lb-app" style="opacity:0.5;">未归类</span>`;
  }
  if (item.page_type && item.page_type !== '其他') {
    infoHtml += `<span class="lb-meta">${escapeHtml(item.page_type)}</span>`;
  }
  infoHtml += `<span class="lb-meta">${dateStr}</span>`;
  document.getElementById('lightboxInfo').innerHTML = infoHtml;

  // Fav button
  const favBtn = document.getElementById('lbFavBtn');
  favBtn.innerHTML = `<i class="${isFav ? 'ri-heart-fill' : 'ri-heart-line'}"></i><span>${isFav ? '取消收藏' : '收藏'}</span>`;
  favBtn.setAttribute('aria-pressed', String(!!isFav));
  if (isFav) favBtn.classList.add('active');
  else favBtn.classList.remove('active');
  favBtn.dataset.sid = item.id;

  // Note
  document.getElementById('lightboxNoteInput').value = item.analysis?.note || '';
  document.getElementById('lightboxNoteInput').dataset.sid = item.id;

  // Counter
  document.getElementById('lightboxCounter').textContent =
    `${state.lightboxIndex + 1} / ${state.lightboxItems.length}`;

  // Update nav visibility
  document.querySelector('.lightbox-prev').style.display =
    state.lightboxIndex > 0 ? 'flex' : 'none';
  document.querySelector('.lightbox-next').style.display =
    state.lightboxIndex < state.lightboxItems.length - 1 ? 'flex' : 'none';
}

function getCurrentLightboxItem() {
  return state.lightboxItems[state.lightboxIndex] || null;
}

async function populateLightboxDetails() {
  const item = getCurrentLightboxItem();
  const image = document.getElementById('lightboxImg');
  if (!item || !image.naturalWidth) return;
  let bytes = 0;
  try {
    const response = await fetch(`/screenshots/${item.path}`, { method: 'HEAD' });
    bytes = Number(response.headers.get('content-length') || 0);
  } catch (error) {}
  if (getCurrentLightboxItem()?.id !== item.id) return;
  const folder = state.folders.find(entry => entry.id === item.folder_id);
  const extension = (item.path.split('.').pop() || '').toUpperCase();
  const date = new Date((item.mtime || 0) * 1000);
  document.getElementById('lightboxDetails').innerHTML = [
    ['尺寸', `${image.naturalWidth} × ${image.naturalHeight} px`],
    ['格式', extension || '未知'],
    ['文件大小', formatFileSize(bytes)],
    ['素材位置', folder?.name || '新添加截图'],
    ['添加时间', date.toLocaleString('zh-CN', { hour12: false })],
  ].map(([label, value]) => `<div class="lb-detail-item"><span>${label}</span><strong title="${escapeHtml(value)}">${escapeHtml(value)}</strong></div>`).join('');
}

function formatFileSize(bytes) {
  if (!bytes) return '未知';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function toggleLightboxDetails() {
  state.lightboxDetailsOpen = !state.lightboxDetailsOpen;
  const panel = document.getElementById('lightboxDetails');
  const button = document.getElementById('lbInfoBtn');
  panel.hidden = !state.lightboxDetailsOpen;
  button.classList.toggle('active', state.lightboxDetailsOpen);
  button.setAttribute('aria-pressed', String(state.lightboxDetailsOpen));
  if (state.lightboxDetailsOpen) populateLightboxDetails();
}

function copyCurrentLightboxImage() {
  const item = getCurrentLightboxItem();
  if (item) copyScreenshot(item.id);
}

function downloadCurrentLightboxImage() {
  const item = getCurrentLightboxItem();
  if (!item) return;
  const link = document.createElement('a');
  link.href = `/screenshots/${item.path}`;
  link.download = item.path.split('/').pop() || `${item.id}.png`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  showToast('正在下载原图');
}

function revealCurrentLightboxImage() {
  const item = getCurrentLightboxItem();
  if (item) openScreenshotFolders([item.id]);
}

let lightboxColorTimer = null;
async function pickLightboxColor() {
  if (!window.EyeDropper) {
    showToast('当前浏览器不支持取色器');
    return;
  }
  try {
    const result = await new EyeDropper().open();
    await navigator.clipboard.writeText(result.sRGBHex.toUpperCase());
    const panel = document.getElementById('lightboxColorResult');
    document.getElementById('lightboxColorSwatch').style.background = result.sRGBHex;
    document.getElementById('lightboxColorValue').textContent = result.sRGBHex.toUpperCase();
    panel.hidden = false;
    clearTimeout(lightboxColorTimer);
    lightboxColorTimer = setTimeout(() => { panel.hidden = true; }, 2600);
  } catch (error) {
    // Closing the system color picker is a normal cancellation.
  }
}

async function toggleFavoriteFromBtn() {
  const btn = document.getElementById('lbFavBtn');
  const id = btn.dataset.sid;
  if (!id) return;

  const res = await fetch('/api/favorite', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id }),
  });
  const data = await res.json();
  if (data.ok) {
    const isFav = data.favorite;
    btn.innerHTML = `<i class="${isFav ? 'ri-heart-fill' : 'ri-heart-line'}"></i><span>${isFav ? '取消收藏' : '收藏'}</span>`;
    btn.setAttribute('aria-pressed', String(isFav));
    if (isFav) {
      btn.classList.add('active');
    } else {
      btn.classList.remove('active');
    }

    const item = state.lightboxItems.find(s => s.id === id);
    if (item) {
      if (!item.analysis) item.analysis = {};
      item.analysis.favorite = isFav;
    }
    const ss = state.screenshots.find(s => s.id === id);
    if (ss) {
      if (!ss.analysis) ss.analysis = {};
      ss.analysis.favorite = isFav;
    }
    updateFavoritesCount();
    if (state.currentTab === 'screenshots' && state.filter.status === 'favorites') renderGrid();
  }
}

async function saveLightboxNote() {
  const input = document.getElementById('lightboxNoteInput');
  const sid = input.dataset.sid;
  const note = input.value.trim();
  if (!sid || note === (state.lightboxItems.find(s => s.id === sid)?.analysis?.note || '')) return;

  const res = await fetch('/api/note', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: sid, note }),
  });
  const data = await res.json();
  if (data.ok) {
    const item = state.lightboxItems.find(s => s.id === sid);
    if (item) {
      if (!item.analysis) item.analysis = {};
      item.analysis.note = note || undefined;
    }
    const ss = state.screenshots.find(s => s.id === sid);
    if (ss) {
      if (!ss.analysis) ss.analysis = {};
      ss.analysis.note = note || undefined;
    }
  }
}

function updateFavoritesCount() {
  const count = state.screenshots.filter(s => s.analysis?.favorite).length;
  const el = document.getElementById('countFavorites');
  if (el) el.textContent = count;
}

function lightboxPrev() {
  if (state.lightboxIndex > 0) {
    state.lightboxIndex--;
    showLightboxImage();
  }
}

function lightboxNext() {
  if (state.lightboxIndex < state.lightboxItems.length - 1) {
    state.lightboxIndex++;
    showLightboxImage();
  }
}

// ── Search ───────────────────────────────────────────────

let searchTimer = null;

async function onSearchInput() {
  clearTimeout(searchTimer);
  const q = document.getElementById('searchInput').value.trim();
  document.getElementById('searchClear').style.display = q ? '' : 'none';

  if (!q) {
    state.searchQuery = '';
    state.searchResults = null;
    state.searchIndexing = false;
    state.searchProgress = null;
    renderGrid();
    return;
  }

  state.searchQuery = q;
  searchTimer = setTimeout(() => runSearch(q), 250);
}

async function runSearch(q) {
  const res = await fetch(`/api/search?q=${encodeURIComponent(q)}`);
  const data = await res.json();
  if (document.getElementById('searchInput').value.trim() !== q) return;
  state.searchResults = Array.isArray(data) ? data : (data.ids || []);
  state.searchIndexing = Boolean(data.indexing);
  state.searchProgress = data.total ? { processed: data.processed || 0, total: data.total } : null;
  renderGrid();
  if (state.searchIndexing) {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => runSearch(q), 1200);
  }
}

function clearSearch() {
  document.getElementById('searchInput').value = '';
  document.getElementById('searchClear').style.display = 'none';
  state.searchQuery = '';
  state.searchResults = null;
  state.searchIndexing = false;
  state.searchProgress = null;
  renderGrid();
}

// ── Analysis conversations ──────────────────────────────

async function startConversationFromSelection() {
  if (!state.selected.size) { showToast('请先选择截图'); return; }
  const res = await fetch('/api/conversations', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ screenshot_ids: [...state.selected] }),
  });
  const data = await res.json();
  if (!data.ok) { showToast(data.error || '无法开始分析'); return; }
  state.selected.clear();
  await loadConversations();
  switchTab('projects');
  selectConversation(data.conversation.id);
}

function backToProjectList() {
  state.currentProject = null;
  state.currentConversation = null;
  renderProjectNav();
  renderProjectList();
}

function renderProjectNav() {
  const el = document.getElementById('projectNavList');
  const unclassifiedEl = document.getElementById('unclassifiedAnalysisList');
  if (!el || !unclassifiedEl) return;

  const unclassified = sortAnalysisNavItems(state.conversations.filter(item => !item.project_id));
  unclassifiedEl.innerHTML = unclassified.length
    ? unclassified.map(item => renderAnalysisNavItem(item, null)).join('')
    : '<div class="analysis-nav-empty">暂无待归类分析</div>';

  if (!state.projects.length) {
    el.innerHTML = '<div class="analysis-nav-empty folder-empty">还没有文件夹</div>';
    updateProjectCounts();
    return;
  }
  el.innerHTML = state.projects.map(folder => {
    const children = sortAnalysisNavItems(state.conversations.filter(item => item.project_id === folder.id));
    const collapsed = state.collapsedAnalysisFolders.has(folder.id);
    return `<div class="analysis-folder-group">
      <div class="analysis-folder-row project-drop-target ${state.currentProject?.id === folder.id ? 'active' : ''}"
           onclick="showProjectConversations('${folder.id}')"
           ondragover="handleAnalysisDragOver(event)" ondragleave="handleAnalysisDragLeave(event)"
           ondrop="dropConversationIntoGroup(event, '${folder.id}')">
        <button class="analysis-folder-toggle" onclick="event.stopPropagation();toggleAnalysisFolder('${folder.id}')" title="${collapsed ? '展开' : '收起'}">
          <i class="ri-arrow-right-s-line ${collapsed ? '' : 'expanded'}"></i>
        </button>
        <i class="${collapsed ? 'ri-folder-3-line' : 'ri-folder-open-line'} analysis-folder-icon"></i>
        <span class="analysis-folder-name" title="${escapeHtml(folder.name)}">${escapeHtml(folder.name)}</span>
        <span class="analysis-folder-count">${children.length}</span>
        <div class="project-nav-actions">
          <button onclick="event.stopPropagation();renameProjectContainer('${folder.id}')" title="重命名文件夹"><i class="ri-edit-line"></i></button>
          <button onclick="event.stopPropagation();deleteProjectContainer('${folder.id}')" title="删除文件夹"><i class="ri-delete-bin-line"></i></button>
        </div>
      </div>
      <div class="analysis-folder-children ${collapsed ? 'collapsed' : ''}">
        ${children.length ? children.map(item => renderAnalysisNavItem(item, folder.id)).join('') : '<div class="analysis-nav-empty">拖入分析进行归类</div>'}
      </div>
    </div>`;
  }).join('');
  updateProjectCounts();
}

function sortAnalysisNavItems(items) {
  return [...items].sort((a, b) => {
    const aOrder = Number.isFinite(a.sort_order) ? a.sort_order : null;
    const bOrder = Number.isFinite(b.sort_order) ? b.sort_order : null;
    if (aOrder !== null && bOrder !== null) return aOrder - bOrder;
    if (aOrder !== null) return 1;
    if (bOrder !== null) return -1;
    return String(b.updated_at || b.created_at || '').localeCompare(String(a.updated_at || a.created_at || ''));
  });
}

function renderAnalysisNavItem(item, folderId) {
  const statusClass = item.result ? 'complete' : ['queued', 'analyzing'].includes(item.status?.state) ? 'running' : 'draft';
  const active = state.currentConversation?.id === item.id ? 'active' : '';
  const targetFolder = folderId ? `'${folderId}'` : 'null';
  return `<div class="analysis-nav-item ${active}" draggable="${item.legacy ? 'false' : 'true'}"
      ondragstart="startConversationDrag(event, '${item.id}')" ondragend="endConversationDrag(event)"
      ondragover="handleAnalysisItemDragOver(event)" ondragleave="handleAnalysisDragLeave(event)"
      ondrop="dropConversationBefore(event, '${item.id}', ${targetFolder})" onclick="selectConversation('${item.id}')">
    <i class="ri-file-chart-line analysis-item-icon"></i>
    <span class="analysis-item-name" title="${escapeHtml(item.title || '新分析')}">${escapeHtml(item.title || '新分析')}</span>
    <span class="analysis-status-dot ${statusClass}" title="${item.result ? '已完成' : '待分析'}"></span>
  </div>`;
}

function renderProjectList(projectId = null) {
  const el = document.getElementById('projectContent');
  if (!el) return;
  hideLegacyToolbarButtons();
  document.getElementById('projectToolbar').style.display = 'none';
  let items = projectId
    ? state.conversations.filter(item => item.project_id === projectId)
    : state.conversations.filter(item => !item.project_id);
  items = sortAnalysisNavItems(items);
  const project = state.projects.find(item => item.id === projectId);
  const heading = project ? escapeHtml(project.name) : '待归类分析';
  const cards = items.map(renderConversationListCard).join('');
  el.innerHTML = `<div class="conversation-home"><div class="conversation-list-head"><div><span>分析对话</span><h1>${heading}</h1></div><small>${items.length} 个对话</small></div>${cards || '<div class="conversation-empty">从截图页批量选择图片，然后点击「开始分析」</div>'}</div>`;
}

function renderConversationListCard(item) {
  const ssMap = getSsMap();
  const thumbs = (item.screenshot_ids || []).slice(0, 4).map(id => {
    const ss = ssMap[id];
    return ss ? `<img src="/screenshots/${ss.path}" alt="">` : '';
  }).join('');
  const stateLabel = item.result ? '已完成' : item.status?.state === 'analyzing' ? '分析中' : '待提问';
  return `<article class="conversation-list-card" draggable="${item.legacy ? 'false' : 'true'}"
      ondragstart="startConversationDrag(event, '${item.id}')" onclick="selectConversation('${item.id}')">
    <div class="conversation-card-copy"><div class="conversation-card-title">${escapeHtml(item.title || '新分析')}</div><p>${escapeHtml(item.question || '还没有填写问题')}</p><div class="conversation-card-meta"><span>${(item.screenshot_ids || []).length} 张截图</span><span>${stateLabel}</span>${item.legacy ? '<span>旧版分析</span>' : ''}</div></div>
    <div class="conversation-card-thumbs">${thumbs}</div><span class="conversation-card-arrow">›</span>
  </article>`;
}

function showProjectConversations(pid) {
  state.currentProject = state.projects.find(item => item.id === pid) || null;
  state.currentConversation = null;
  renderProjectNav();
  renderProjectList(pid);
}

function showUnclassifiedConversations() {
  state.currentProject = null;
  state.currentConversation = null;
  renderProjectNav();
  renderProjectList();
}

function toggleAnalysisFolder(pid) {
  if (state.collapsedAnalysisFolders.has(pid)) state.collapsedAnalysisFolders.delete(pid);
  else state.collapsedAnalysisFolders.add(pid);
  renderProjectNav();
}

function selectConversation(cid) {
  const conversation = state.conversations.find(item => item.id === cid);
  if (!conversation) return;
  if (conversation.legacy) {
    const project = state.projects.find(item => `legacy_${item.id}` === cid);
    if (project) selectProject(project.id);
    return;
  }
  state.currentConversation = conversation;
  state.currentProject = null;
  state.draftScreenshotOrder = [...(conversation.screenshot_order?.length ? conversation.screenshot_order : conversation.screenshot_ids || [])];
  document.getElementById('projectToolbar').style.display = '';
  hideLegacyToolbarButtons();
  ['btnShareConversation', 'btnRenameConversation', 'btnDeleteConversation'].forEach(id => document.getElementById(id).style.display = '');
  document.getElementById('projectViewTitle').textContent = conversation.title || '新分析';
  renderProjectNav();
  renderConversationDetail();
  history.replaceState(null, '', `/?conversation=${encodeURIComponent(cid)}`);
}

function hideLegacyToolbarButtons() {
  ['btnAddScreenshots', 'btnManageScreenshots', 'btnAnalyzeProject', 'btnDeleteProject'].forEach(id => {
    const element = document.getElementById(id); if (element) element.style.display = 'none';
  });
  ['btnShareConversation', 'btnRenameConversation', 'btnDeleteConversation'].forEach(id => {
    const element = document.getElementById(id); if (element) element.style.display = state.currentConversation ? '' : 'none';
  });
}

function renderConversationDetail() {
  const conversation = state.currentConversation;
  if (!conversation) return;
  const el = document.getElementById('projectContent');
  const status = conversation.status || { state: 'draft' };
  if (['queued', 'analyzing'].includes(status.state)) {
    el.innerHTML = renderConversationProgress(conversation);
    startConversationPolling(conversation.id);
  } else if (conversation.result) {
    el.innerHTML = renderDecisionBrief(conversation);
  } else {
    el.innerHTML = renderConversationComposer(conversation);
  }
}

function conversationAttachmentGrid(conversation) {
  const ssMap = getSsMap();
  return `<div class="conversation-attachments">${(conversation.screenshot_ids || []).map(id => {
    const ss = ssMap[id];
    if (!ss) return '';
    return `<button onclick="openConversationLightbox('${id}')"><img src="/screenshots/${ss.path}" alt="${escapeHtml(ss.app || '')}"><span>${escapeHtml(ss.app || '未归类')}</span></button>`;
  }).join('')}</div>`;
}

const ANALYSIS_ANGLES = [
  ['找可借鉴的做法', '这些截图中有哪些值得借鉴的设计做法？'],
  ['找体验问题与风险', '这些截图中有哪些体验问题与设计风险？'],
  ['看信息层级与视觉表达', '这些页面如何组织信息层级与视觉表达，有哪些可借鉴或需规避之处？'],
  ['还原关键操作路径', '请还原这组截图中的关键操作路径，并指出连续性问题与优化机会。'],
  ['比较不同竞品的解法', '不同竞品分别如何解决同一个用户任务，各自的优劣与借鉴点是什么？'],
];

function renderConversationComposer(conversation) {
  const error = conversation.status?.state === 'failed' ? conversation.status.error : '';
  const angle = conversation.angle || '';
  return `<div class="conversation-workbench">
    <section class="conversation-compose"><div class="conversation-eyebrow">${(conversation.screenshot_ids || []).length} 张截图已附加</div>
      <h1>你想借鉴或验证什么？</h1>
      <textarea id="conversationQuestion" placeholder="你想借鉴或验证什么？&#10;例如：&#10;· 竞品如何让用户发现新品？&#10;· 商品卡如何突出新品、价格和促销？&#10;· 从首页到详情，信息怎样保持连续？&#10;· 哪些设计值得借鉴，哪些风险要避开？&#10;常用角度：入口与导航 · 信息层级与视觉表达 · 操作路径与反馈 · 决策与信任 · 跨场景一致性">${escapeHtml(conversation.question || '')}</textarea>
      <div class="analysis-angle-tags">${ANALYSIS_ANGLES.map(([name]) => `<button class="${angle === name ? 'active' : ''}" onclick="chooseAnalysisAngle('${name}')">${name}</button>`).join('')}</div>
      ${angle === '还原关键操作路径' ? renderConversationOrderEditor(conversation) : ''}
      ${error ? `<div class="analysis-inline-error">${escapeHtml(error)}</div>` : ''}
      <div class="conversation-submit"><span>AI 会自动选择最多 3 个最相关角度</span><button class="btn btn-primary" onclick="analyzeConversation()">开始分析</button></div>
    </section><section><div class="workbench-section-head"><strong>截图证据</strong><span>点击查看原图</span></div>${conversationAttachmentGrid(conversation)}</section>
  </div>`;
}

function chooseAnalysisAngle(name) {
  const question = document.getElementById('conversationQuestion')?.value || '';
  const conversation = state.currentConversation;
  if (!conversation) return;
  conversation.question = question.trim() || (ANALYSIS_ANGLES.find(item => item[0] === name)?.[1] || '');
  conversation.angle = conversation.angle === name ? '' : name;
  renderConversationDetail();
  requestAnimationFrame(() => document.getElementById('conversationQuestion')?.focus());
}

function renderConversationOrderEditor(conversation) {
  const ssMap = getSsMap();
  const items = state.draftScreenshotOrder.map((sid, index) => {
    const ss = ssMap[sid]; if (!ss) return '';
    return `<div class="sequence-item" draggable="true" ondragstart="startSequenceDrag(event, ${index})" ondragover="event.preventDefault()" ondrop="dropConversationSequence(event, ${index})" ondragend="endSequenceDrag()"><span class="sequence-index">${index + 1}</span><img src="/screenshots/${ss.path}" alt=""><div><strong>${escapeHtml(ss.app || '未归类')}</strong><small>第 ${index + 1} 步</small></div><div class="sequence-actions"><button onclick="event.stopPropagation();moveConversationScreenshot(${index},-1)" ${index === 0 ? 'disabled' : ''}>↑</button><button onclick="event.stopPropagation();moveConversationScreenshot(${index},1)" ${index === state.draftScreenshotOrder.length - 1 ? 'disabled' : ''}>↓</button></div></div>`;
  }).join('');
  return `<div class="sequence-editor"><div class="sequence-heading"><strong>确认关键路径顺序</strong><span>只有本次路径分析会使用此顺序</span></div><div class="sequence-list">${items}</div></div>`;
}

function dropConversationSequence(event, targetIndex) {
  event.preventDefault();
  const sourceIndex = state.sequenceDragIndex;
  if (sourceIndex === null || sourceIndex === targetIndex) return;
  const question = document.getElementById('conversationQuestion')?.value || '';
  const [id] = state.draftScreenshotOrder.splice(sourceIndex, 1);
  state.draftScreenshotOrder.splice(targetIndex, 0, id);
  state.currentConversation.question = question;
  renderConversationDetail();
}

function moveConversationScreenshot(index, offset) {
  const target = index + offset;
  if (target < 0 || target >= state.draftScreenshotOrder.length) return;
  const question = document.getElementById('conversationQuestion')?.value || '';
  [state.draftScreenshotOrder[index], state.draftScreenshotOrder[target]] = [state.draftScreenshotOrder[target], state.draftScreenshotOrder[index]];
  state.currentConversation.question = question;
  renderConversationDetail();
}

async function analyzeConversation() {
  const conversation = state.currentConversation;
  const question = document.getElementById('conversationQuestion')?.value.trim() || '';
  if (question.length < 4) { showToast('请先写下你想借鉴或验证的问题'); return; }
  const button = document.querySelector('.conversation-submit .btn-primary');
  if (button) { button.disabled = true; button.textContent = '正在启动...'; }
  const res = await fetch(`/api/conversations/${conversation.id}/analyze`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ question, angle: conversation.angle || '', screenshot_order: state.draftScreenshotOrder }),
  });
  const data = await res.json();
  if (!data.ok) {
    showToast(data.error || '无法开始分析');
    if ((data.error || '').includes('API Key')) showAISettings();
    if (button) { button.disabled = false; button.textContent = '开始分析'; }
    return;
  }
  conversation.question = question;
  conversation.status = { state: 'queued', processed: 0, total: conversation.screenshot_ids.length };
  renderConversationDetail();
}

function renderConversationProgress(conversation) {
  const status = conversation.status || {};
  const processed = status.processed || 0, total = status.total || conversation.screenshot_ids.length;
  const percent = total ? Math.round(processed / total * 100) : 0;
  const synthesis = status.phase === 'synthesis';
  return `<div class="analysis-progress-panel"><div class="analysis-progress-mark"></div><h2>${synthesis ? '正在形成决策速览' : '正在读取截图证据'}</h2><p>${synthesis ? '客观观察已整理完成，正在回答你的问题。' : `已处理 ${processed} / ${total} 张；已分析过的图片会直接复用观察。`}</p><div class="analysis-progress-track"><span style="width:${synthesis ? 100 : percent}%"></span></div>${status.failed ? `<small>${status.failed} 张暂未成功，其余截图会继续分析</small>` : ''}</div>`;
}

function startConversationPolling(cid) {
  clearInterval(state.analysisPollTimer);
  state.analysisPollTimer = setInterval(async () => {
    if (state.currentConversation?.id !== cid) { clearInterval(state.analysisPollTimer); return; }
    const res = await fetch(`/api/conversations/${cid}/analysis-status`);
    const data = await res.json(); if (!data.ok) return;
    if (['complete', 'failed'].includes(data.status.state)) {
      clearInterval(state.analysisPollTimer);
      await loadConversations();
      state.currentConversation = state.conversations.find(item => item.id === cid) || null;
      renderConversationDetail();
      renderProjectNav();
      showToast(data.status.state === 'complete' ? '决策速览已生成' : `分析失败：${data.status.error || '未知错误'}`);
    } else {
      state.currentConversation.status = data.status;
      document.getElementById('projectContent').innerHTML = renderConversationProgress(state.currentConversation);
    }
  }, 1200);
}

function renderDecisionBrief(conversation) {
  const result = conversation.result || {}, meta = result.meta || {}, details = result.details || {};
  const findings = (result.findings || []).map((item, index) => `<article class="decision-finding"><div class="decision-finding-index">0${index + 1}</div><div><div class="finding-title-line"><h3>${escapeHtml(item.title || '')}</h3><span class="confidence ${escapeHtml(item.confidence || '')}">${confidenceLabel(item.confidence)}</span></div><div class="decision-field"><b>竞品观察</b><p>${escapeHtml(item.observation || '')}</p></div><div class="decision-field insight"><b>对我的启示</b><p>${escapeHtml(item.implication || '')}</p></div><div class="decision-field action"><b>建议行动</b><p>${escapeHtml(item.action || '')}</p></div>${item.to_validate ? `<div class="decision-validation"><b>待验证</b>${escapeHtml(item.to_validate)}</div>` : ''}<div class="evidence-thumbs">${renderConversationEvidence(item.evidence || [])}</div></div></article>`).join('');
  const actions = (result.priority_actions || []).map(item => `<div class="priority-action"><span class="priority ${item.priority === 'high' ? 'high' : ''}">${item.priority === 'high' ? '高' : '中'}</span><div><strong>${escapeHtml(item.action || '')}</strong><p>${escapeHtml(item.reason || '')}</p></div></div>`).join('');
  const gaps = (result.evidence_gaps || []).map(item => `<div class="evidence-gap"><strong>${escapeHtml(item.gap || '')}</strong><span>建议补充：${escapeHtml(item.suggested_screenshot || '')}</span></div>`).join('');
  const perImage = (details.per_image || []).map(item => `<div class="detail-evidence-row"><strong>${escapeHtml(item.scene_label || '截图证据')}</strong><p>${escapeHtml(item.observation || '')}</p>${renderConversationEvidence([{ screenshot_id: item.screenshot_id, scene_label: item.scene_label }])}</div>`).join('');
  return `<div class="decision-brief"><header class="decision-header"><span>${escapeHtml(result.kind || '竞品诊断')} · 决策速览</span><h1>${escapeHtml(conversation.question || '')}</h1><p>${escapeHtml(result.conclusion || '')}</p><div class="decision-meta"><span>${meta.analyzed_count || conversation.screenshot_ids.length} 张证据</span>${(result.perspectives || []).map(item => `<b>${escapeHtml(item)}</b>`).join('')}</div></header><section class="decision-section"><div class="decision-section-head"><h2>核心发现</h2><span>观察、启示与行动分开呈现</span></div>${findings}</section><div class="decision-bottom-grid"><section><div class="decision-section-head"><h2>优先行动</h2></div>${actions || '<p class="empty-state-inline">暂无明确行动</p>'}</section><section><div class="decision-section-head"><h2>证据缺口</h2></div>${gaps || '<p class="empty-state-inline">当前证据足以形成初步判断</p>'}</section></div><details class="all-evidence"><summary>查看全部证据</summary><div class="all-evidence-content"><h3>逐图客观观察</h3>${perImage}<h3>方法与验证</h3><p>${escapeHtml(details.methodology || '基于静态截图的可见证据进行启发式归纳。')}</p>${(details.validation_metrics || []).map(item => `<p><strong>${escapeHtml(item.hypothesis || '')}</strong>：${escapeHtml(item.metric || '')}</p>`).join('')}</div></details><section class="follow-up-compose"><h2>继续追问这批截图</h2><textarea id="conversationQuestion" rows="2" placeholder="换一个问题，截图客观观察会直接复用"></textarea><div class="conversation-submit"><span>不会重新读取已有图片</span><button class="btn btn-primary" onclick="analyzeConversation()">继续分析</button></div></section></div>`;
}

function renderConversationEvidence(evidence) {
  const ssMap = getSsMap();
  return evidence.map(item => {
    const ss = ssMap[item.screenshot_id]; if (!ss) return '';
    return `<button class="evidence-thumb labeled" onclick="openConversationLightbox('${item.screenshot_id}')"><img src="/screenshots/${ss.path}" alt=""><span>${escapeHtml(item.scene_label || '截图证据')}</span></button>`;
  }).join('');
}

function openConversationLightbox(id) {
  const ids = new Set(state.currentConversation?.screenshot_ids || []);
  const items = state.screenshots.filter(item => ids.has(item.id));
  const index = items.findIndex(item => item.id === id); if (index < 0) return;
  state.lightboxItems = items; state.lightboxIndex = index; showLightboxImage();
  document.getElementById('lightbox').style.display = 'flex'; document.body.style.overflow = 'hidden';
}

async function shareConversation() {
  if (!state.currentConversation) return;
  const url = `${location.origin}/?conversation=${encodeURIComponent(state.currentConversation.id)}`;
  await navigator.clipboard.writeText(url); showToast('对话链接已复制');
}

async function renameConversation() {
  const conversation = state.currentConversation; if (!conversation) return;
  const title = prompt('分析对话名称', conversation.title || ''); if (!title?.trim()) return;
  const res = await fetch(`/api/conversations/${conversation.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title: title.trim() }) });
  const data = await res.json(); if (!data.ok) { showToast(data.error || '重命名失败'); return; }
  await loadConversations(); selectConversation(conversation.id); showToast('已重命名');
}

async function deleteConversation() {
  const conversation = state.currentConversation; if (!conversation || !confirm('删除这条分析对话？截图素材不会被删除。')) return;
  const res = await fetch(`/api/conversations/${conversation.id}`, { method: 'DELETE' });
  const data = await res.json(); if (!data.ok) { showToast(data.error || '删除失败'); return; }
  state.currentConversation = null; history.replaceState(null, '', '/'); await Promise.all([loadConversations(), loadProjects()]); backToProjectList(); showToast('对话已删除，截图仍保留');
}

function startConversationDrag(event, cid) {
  if (cid.startsWith('legacy_')) { event.preventDefault(); return; }
  event.dataTransfer.setData('text/designpeek-conversation', cid);
  event.dataTransfer.effectAllowed = 'move';
  requestAnimationFrame(() => event.currentTarget?.classList.add('dragging'));
}

function endConversationDrag(event) {
  event.currentTarget?.classList.remove('dragging');
  document.querySelectorAll('.drag-over, .drag-before').forEach(item => item.classList.remove('drag-over', 'drag-before'));
}

function handleAnalysisDragOver(event) {
  if (!Array.from(event.dataTransfer.types).includes('text/designpeek-conversation')) return;
  event.preventDefault();
  event.stopPropagation();
  event.currentTarget.classList.add('drag-over');
}

function handleAnalysisItemDragOver(event) {
  if (!Array.from(event.dataTransfer.types).includes('text/designpeek-conversation')) return;
  event.preventDefault();
  event.stopPropagation();
  event.currentTarget.classList.add('drag-before');
}

function handleAnalysisDragLeave(event) {
  if (event.currentTarget.contains(event.relatedTarget)) return;
  event.currentTarget.classList.remove('drag-over', 'drag-before');
}

async function saveAnalysisGroupOrder(folderId, orderedIds) {
  const responses = await Promise.all(orderedIds.map((cid, index) => fetch(`/api/conversations/${cid}`, {
    method: 'PUT', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ project_id: folderId, sort_order: index }),
  })));
  const results = await Promise.all(responses.map(response => response.json()));
  const failure = results.find(result => !result.ok);
  if (failure) throw new Error(failure.error || '移动失败');
}

async function dropConversationIntoGroup(event, folderId) {
  event.preventDefault();
  event.stopPropagation();
  event.currentTarget.classList.remove('drag-over');
  const cid = event.dataTransfer.getData('text/designpeek-conversation');
  if (!cid || cid.startsWith('legacy_')) return;
  const current = sortAnalysisNavItems(state.conversations.filter(item => item.project_id === folderId && item.id !== cid));
  try {
    await saveAnalysisGroupOrder(folderId, [...current.map(item => item.id), cid]);
    await Promise.all([loadConversations(), loadProjects()]);
    renderProjectList(state.currentProject?.id || null);
    showToast(folderId ? '已移入文件夹' : '已移回待归类分析');
  } catch (error) {
    showToast(error.message || '移动失败');
  }
}

async function dropConversationBefore(event, targetId, folderId) {
  event.preventDefault();
  event.stopPropagation();
  event.currentTarget.classList.remove('drag-before');
  const cid = event.dataTransfer.getData('text/designpeek-conversation');
  if (!cid || cid === targetId || cid.startsWith('legacy_')) return;
  const group = sortAnalysisNavItems(state.conversations.filter(item => item.project_id === folderId && item.id !== cid));
  const targetIndex = group.findIndex(item => item.id === targetId);
  if (targetIndex < 0) return;
  group.splice(targetIndex, 0, state.conversations.find(item => item.id === cid));
  try {
    await saveAnalysisGroupOrder(folderId, group.filter(Boolean).map(item => item.id));
    await Promise.all([loadConversations(), loadProjects()]);
    renderProjectList(state.currentProject?.id || null);
  } catch (error) {
    showToast(error.message || '排序失败');
  }
}

async function renameProjectContainer(pid) {
  const project = state.projects.find(item => item.id === pid); if (!project) return;
  const name = prompt('文件夹名称', project.name); if (!name?.trim()) return;
  await fetch(`/api/projects/${pid}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: name.trim() }) });
  await loadProjects(); renderProjectList(state.currentProject?.id || null); showToast('文件夹已重命名');
}

async function deleteProjectContainer(pid) {
  if (!confirm('删除这个文件夹？其中的分析会回到“待归类分析”，截图不会删除。')) return;
  const res = await fetch(`/api/projects/${pid}`, { method: 'DELETE' }); const data = await res.json();
  if (!data.ok) { showToast(data.error || '删除失败'); return; }
  state.currentProject = null; await Promise.all([loadProjects(), loadConversations()]); renderProjectList(); showToast('文件夹已删除，分析与截图均已保留');
}

// ── Start ────────────────────────────────────────────────

init();
