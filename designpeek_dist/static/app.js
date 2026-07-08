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
  filter: { status: 'all', app: null },
  selected: new Set(),
  batchMode: false,
  importTargetPid: null,
  stats: null,
  currentTab: 'screenshots',
  projects: [],
  currentProject: null,
  projectFilter: 'all',
  modalSelected: new Set(),
  lightboxIndex: -1,
  lightboxItems: [],
  searchQuery: '',
  searchResults: null,
  manageMode: false,
};

// ── Init ─────────────────────────────────────────────────

async function init() {
  await Promise.all([loadStats(), loadScreenshots(), loadProjects()]);
  renderAppFilters();
  setupTabs();
  setupProjectFilters();
  checkAndroidStatus();

  // Restore last tab from sessionStorage
  const lastTab = sessionStorage.getItem('dp_tab');
  if (lastTab) switchTab(lastTab);
}

function setupProjectFilters() {
  document.querySelectorAll('#projectStatusFilters .filter-item').forEach(item => {
    item.addEventListener('click', () => {
      state.projectFilter = item.dataset.filter;
      document.querySelectorAll('#projectStatusFilters .filter-item').forEach(el =>
        el.classList.toggle('active', el.dataset.filter === state.projectFilter));
      state.currentProject = null;
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
  document.getElementById('countInbox').textContent = state.stats.inbox_count || 0;
  document.getElementById('countAll').textContent =
    (state.stats.inbox_count || 0) + (state.stats.organized_count || 0);
  // Show/hide inbox filter
  document.getElementById('filterInbox').style.display =
    (state.stats.inbox_count || 0) > 0 ? '' : 'none';
}

async function loadScreenshots() {
  const res = await fetch('/api/screenshots?limit=500');
  state.screenshots = await res.json();
  updateFavoritesCount();
  if (state.currentTab === 'screenshots') renderGrid();
}

async function loadProjects() {
  const res = await fetch('/api/projects');
  state.projects = await res.json();
  updateProjectCounts();
  renderProjectNav();
}

function updateProjectCounts() {
  const all = state.projects.length;
  const analyzed = state.projects.filter(p => p.analysis).length;
  document.getElementById('countAllProjects').textContent = all;
  document.getElementById('countPending').textContent = all - analyzed;
  document.getElementById('countAnalyzedProjects').textContent = analyzed;
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
  state.batchMode = false;
  state.manageMode = false;

  document.querySelectorAll('#projectStatusFilters .filter-item').forEach(el => el.classList.remove('active'));
  renderProjectNav();

  // Show project detail in main
  document.getElementById('viewScreenshots').classList.remove('active');
  document.getElementById('viewProject').classList.add('active');
  document.getElementById('projectViewTitle').textContent = proj.name;
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
      state.filter.app = state.filter.app === item.dataset.app ? null : item.dataset.app;
      state.filter.status = 'all';
      state.tagFilter = null;
      highlightFilters();
      renderGrid();
    });
    item.addEventListener('dragover', (e) => { e.preventDefault(); item.classList.add('drop-target'); });
    item.addEventListener('dragleave', () => { item.classList.remove('drop-target'); });
    item.addEventListener('drop', (e) => {
      e.preventDefault();
      item.classList.remove('drop-target');
      const sid = e.dataTransfer.getData('text/plain');
      if (sid) quickClassify(sid, item.dataset.app);
    });
  });
}

document.querySelectorAll('#statusFilters .filter-item').forEach(item => {
  item.addEventListener('click', () => {
    state.filter.status = item.dataset.status;
    state.filter.app = null;

    highlightFilters();
    renderGrid();
  });
});

function highlightFilters() {
  document.querySelectorAll('#statusFilters .filter-item').forEach(el =>
    el.classList.toggle('active', !state.filter.app && el.dataset.status === state.filter.status));
  document.querySelectorAll('#appFilters .filter-item').forEach(el =>
    el.classList.toggle('active', el.dataset.app === state.filter.app));

  const parts = [];
  if (state.filter.app) parts.push(state.filter.app);

  if (state.filter.status !== 'all') {
    const labels = { inbox: '待整理', organized: '已整理', favorites: '👍🏻 顶呱呱' };
    parts.push(labels[state.filter.status] || '');
  }
  document.getElementById('viewTitle').textContent = parts.length ? parts.join(' · ') : '全部截图';
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

  // Search filter (highest priority)
  if (state.searchResults !== null) {
    const resultSet = new Set(state.searchResults);
    items = items.filter(s => resultSet.has(s.id));
  }

  if (state.filter.status === 'inbox') items = items.filter(s => s.status === 'inbox');
  else if (state.filter.status === 'organized') items = items.filter(s => s.status === 'organized');
  else if (state.filter.status === 'favorites') items = items.filter(s => s.analysis?.favorite);
  if (state.filter.app) items = items.filter(s => s.app === state.filter.app);

  if (!items.length) {
    if (state.searchQuery) {
      content.innerHTML = `<div class="search-no-results"><div class="icon">🔍</div><p>未找到包含「${escapeHtml(state.searchQuery)}」的截图</p><p style="font-size:12px;color:var(--text-muted);">新截图上传后会自动识别文字，试试其他关键词</p></div>`;
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
        const canDrag = isInbox && !state.batchMode;
        return `
          <div class="card ${isSelected ? 'selected' : ''} ${state.batchMode ? 'selectable' : ''}"
               data-id="${s.id}" data-month="${g.key}"
               draggable="${canDrag ? 'true' : 'false'}"
               ondragstart="${canDrag ? `dragStart(event, '${s.id}')` : ''}"
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
  if (state.filter.status !== 'inbox') return false;
  try {
    return !localStorage.getItem('dp_drag_guide_dismissed');
  } catch (e) { return true; }
}

function renderDragGuideCard() {
  return `<div class="drag-guide-card">
    <div class="drag-guide-icon">👆</div>
    <div class="drag-guide-text">拖拽截图到左侧<br>App 名称即可归类</div>
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
  event.dataTransfer.setData('text/plain', id);
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

document.addEventListener('dragend', (e) => {
  document.querySelectorAll('.card.dragging').forEach(c => c.classList.remove('dragging'));
});

// ── Quick Classify ───────────────────────────────────────

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

async function quickClassify(id, app) {
  // Optimistic removal
  const card = document.querySelector(`.card[data-id="${id}"]`);
  if (card) card.style.display = 'none';

  const res = await fetch('/api/classify', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids: [id], app, page_type: '其他' }),
  });
  if ((await res.json()).ok) {
    dismissDragGuide();
    await Promise.all([loadStats(), loadScreenshots()]);
    renderAppFilters();
    renderGrid();
  } else {
    if (card) card.style.display = '';
    showToast('归类失败');
  }
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
  const projects = state.projects;
  if (!projects.length) {
    el.innerHTML = '<button class="btn btn-primary btn-sm" onclick="showCreateProject()">+ 创建新项目</button>';
    return;
  }
  const maxShow = 2;
  let html = '<button class="btn btn-primary btn-sm" onclick="showCreateProject()">+ 创建新项目</button>';
  projects.slice(0, maxShow).forEach(p => {
    html += `<button class="btn btn-primary btn-sm" onclick="batchImportToProject('${p.id}')">导入${escapeHtml(p.name)}</button>`;
  });
  if (projects.length > maxShow) {
    html += '<button class="btn btn-secondary btn-sm" onclick="batchImportProject()">导入其他项目</button>';
  }
  el.innerHTML = html;
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
    showToast('导入失败: ' + (data.error || '未知错误'));
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
    showToast(`已导入 ${count} 张`);
  }
}

function toggleCard(id, event) {
  event.stopPropagation();
  if (state.selected.has(id)) state.selected.delete(id);
  else state.selected.add(id);
  document.getElementById('selectedCount').textContent = state.selected.size;
  const card = document.querySelector(`.card[data-id="${id}"]`);
  if (card) card.classList.toggle('selected');
  updateMonthChecks();
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
    cards.forEach(c => c.classList.remove('selected'));
  } else {
    allIds.forEach(id => { state.selected.add(id); });
    cards.forEach(c => c.classList.add('selected'));
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
    cards.forEach(c => c.classList.remove('selected'));
  } else {
    monthIds.forEach(id => state.selected.add(id));
    cards.forEach(c => c.classList.add('selected'));
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

// ── Batch: Import to Project ─────────────────────────────

function batchImportProject() {
  if (!state.selected.size) return;
  state.importTargetPid = null;
  const el = document.getElementById('importProjectList');
  if (!state.projects.length) {
    el.innerHTML = '<div class="nav-empty">暂无项目，请先新建</div>';
  } else {
    el.innerHTML = state.projects.map(p => `
      <div class="nav-item" onclick="selectImportTarget('${p.id}', this)">
        <span class="nav-label">${escapeHtml(p.name)}</span>
        <span class="count">${Object.keys(p.screenshots || {}).length}</span>
      </div>
    `).join('');
  }
  document.getElementById('btnImportConfirm').disabled = true;
  document.getElementById('importProjectModal').style.display = 'flex';
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
  hideImportProject();
  if (await _doImportToProject(state.importTargetPid)) {
    showToast(`已导入 ${count} 张到项目`);
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
        <button class="btn btn-primary btn-sm" style="flex-shrink:0;">创建新项目</button>
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
  const screenshots = proj.screenshots || {};
  const ids = Object.keys(screenshots);
  const ssMap = getSsMap();

  let ssHtml = '';
  if (ids.length === 0) {
    ssHtml = `<div class="empty-state-inline">还没有添加截图，点击上方「+ 添加截图」按钮</div>`;
  } else {
    ssHtml = `<div class="project-screenshot-grid">` + ids.map(sid => {
      const ss = ssMap[sid];
      const thumb = ss ? `/screenshots/${ss.path}` : '';
      const appName = ss?.app || '未归类';
      const aiTag = (ss?.analysis && ss.analysis.page_type && ss.analysis.page_type !== '其他') ? ss.analysis.page_type : '';
      return `
      <div class="project-ss-item">
        ${thumb ? `<img src="${thumb}" loading="lazy" alt="">` : `<div class="no-thumb">?</div>`}
        <div class="project-ss-meta">
          <span class="project-ss-app">${appIcon(appName)}${escapeHtml(appName)}</span>
          ${aiTag ? `<span class="project-ss-module">${escapeHtml(aiTag)}</span>` : ''}
        </div>
        <button class="btn-remove-ss" onclick="event.stopPropagation(); removeScreenshotFromProject('${sid}')" title="移除">✕</button>
      </div>`;
    }).join('') + `</div>`;
  }

  document.getElementById('projectToolbar').style.display = '';
  document.getElementById('btnAnalyzeProject').disabled = ids.length === 0;

  const boardHtml = proj.analysis ? renderComparisonBoard(proj) : '';

  const analysisHtml = proj.analysis ? renderProjectAnalysis(proj.analysis, !!boardHtml) : '';

  if (state.manageMode && boardHtml) {
    // Manage mode: only show screenshot grid
    el.innerHTML = `
      ${proj.description ? `<div class="project-desc">${escapeHtml(proj.description)}</div>` : ''}
      <div class="section-title" style="margin-top:8px;">管理项目截图 (${ids.length})</div>
      ${ssHtml || '<div class="empty-state-inline">还没有添加截图，点击上方「+ 添加截图」按钮</div>'}
    `;
  } else {
    el.innerHTML = `
      ${proj.description ? `<div class="project-desc">${escapeHtml(proj.description)}</div>` : ''}
      ${boardHtml}
      ${analysisHtml}
    `;
  }

  document.getElementById('btnManageScreenshots').style.display = boardHtml ? '' : 'none';
  document.getElementById('btnManageScreenshots').textContent = state.manageMode ? '← 返回看板' : '管理截图';
  document.getElementById('btnAddScreenshots').style.display = state.manageMode ? '' : (boardHtml ? 'none' : '');
  document.getElementById('btnAnalyzeProject').style.display = state.manageMode ? 'none' : '';
  document.getElementById('btnDeleteProject').style.display = state.manageMode ? 'none' : '';
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
  if (!name) { showToast('请输入项目名称'); return; }
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
    selectProject(data.project.id);
    showToast('项目已创建');
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
  const btn = document.getElementById('btnAnalyzeProject');
  btn.disabled = true; btn.textContent = '分析中...';

  // Show loading placeholder
  const content = document.getElementById('projectContent');
  const prevHtml = content.innerHTML;
  content.innerHTML = '<div class="empty"><div class="empty-icon">🔍</div><p>正在分析截图，请稍候...</p></div>';

  const res = await fetch(`/api/projects/${pid}/analyze`, { method: 'POST' });
  const data = await res.json();
  if (data.ok) {
    await loadProjects();
    state.currentProject = state.projects.find(p => p.id === pid);
    renderProjectNav();
    renderTouchpointConfirm();
    showToast('分析完成，请确认模块分类');
  } else {
    btn.disabled = false; btn.textContent = '分析项目';
    content.innerHTML = prevHtml;
    showToast('分析失败: ' + (data.error || '未知错误'));
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
  if (e.key === 'Escape') {
    if (document.getElementById('lightbox').style.display === 'flex') closeLightbox();
    else if (state.batchMode) toggleBatchMode();
    else if (document.getElementById('phoneGuideModal').style.display === 'flex') hidePhoneGuide();
    else if (document.getElementById('createProjectModal').style.display === 'flex') hideCreateProject();
    else if (document.getElementById('addScreenshotsModal').style.display === 'flex') hideAddScreenshots();
    else if (document.getElementById('importProjectModal').style.display === 'flex') hideImportProject();
  }
  if (e.key === 'ArrowLeft' && document.getElementById('lightbox').style.display === 'flex') {
    e.preventDefault();
    lightboxPrev();
  }
  if (e.key === 'ArrowRight' && document.getElementById('lightbox').style.display === 'flex') {
    e.preventDefault();
    lightboxNext();
  }
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
  if (state.filter.status === 'inbox') items = items.filter(s => s.status === 'inbox');
  else if (state.filter.status === 'organized') items = items.filter(s => s.status === 'organized');
  else if (state.filter.status === 'favorites') items = items.filter(s => s.analysis?.favorite);
  if (state.filter.app) items = items.filter(s => s.app === state.filter.app);
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
}

function showLightboxImage() {
  const item = state.lightboxItems[state.lightboxIndex];
  if (!item) return;

  document.getElementById('lightboxImg').src = `/screenshots/${item.path}`;

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
  favBtn.textContent = isFav ? '👍🏻 已顶' : '👍🏻 顶呱呱';
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
    btn.textContent = isFav ? '👍🏻 已顶' : '👍🏻 顶呱呱';
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
  document.getElementById('countFavorites').textContent = count;
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
    renderGrid();
    return;
  }

  state.searchQuery = q;
  searchTimer = setTimeout(async () => {
    const res = await fetch(`/api/search?q=${encodeURIComponent(q)}`);
    state.searchResults = await res.json();
    renderGrid();
  }, 250);
}

function clearSearch() {
  document.getElementById('searchInput').value = '';
  document.getElementById('searchClear').style.display = 'none';
  state.searchQuery = '';
  state.searchResults = null;
  renderGrid();
}

// ── Start ────────────────────────────────────────────────

init();
