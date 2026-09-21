(() => {
  'use strict';

  const DEFAULT_CANVAS_ID = 'canvas_default';
  const SAVE_DELAY = 600;
  const MATERIAL_REFRESH_INTERVAL = 3500;
  const MIN_SCALE = 0.08;
  const MAX_SCALE = 5;
  const HUABAN_URL = 'https://huaban.com/';
  const SOURCE_STORAGE_KEY = 'dp_canvas_active_source';
  const LEFT_PANEL_STORAGE_KEY = 'dp_canvas_left_panel_width';
  const LEFT_PANEL_MIN = 240;
  const LEFT_PANEL_MAX = 960;
  const LEFT_PANEL_GAP = 24;      // 拖到最宽时，与右侧分析面板之间保留的间距
  const LEFT_PANEL_STEP = 16;     // 键盘方向键每次调整的宽度
  const PANEL_STORAGE_KEYS = {
    material: 'dp_canvas_material_collapsed',
    huaban: 'dp_canvas_huaban_collapsed',
    fonts: 'dp_canvas_fonts_collapsed',
    analysis: 'dp_canvas_analysis_collapsed',
  };

  const FONT_DRAG_TYPE = 'application/x-designpeek-font';
  const FONT_ACCEPTED_EXTENSIONS = ['.ttf', '.otf', '.woff', '.woff2'];

  // 三个内置“艺术字”示意图。面板预览和画布节点共用同一套参数，
  // 面板侧转成 CSS，画布侧转成 Konva 配置，改一处两边同步。
  // 只用了实测确认存在的字体，华文艺术字系列在近几代 macOS 上已改为按需下载。
  const FONT_STYLES = {
    song: {
      key: 'song',
      label: '宋韵',
      sample: '山茶',
      family: 'STSong, Songti SC, serif',
      fontSize: 56,
      fontStyle: 'normal',
      letterSpacing: 8,
      gradient: ['#c8a15a', '#8a6a2f'],
      stroke: null,
      strokeWidth: 0,
      shadow: null,
    },
    hei: {
      key: 'hei',
      label: '黑潮',
      sample: '浪潮',
      family: 'Heiti SC, PingFang SC, sans-serif',
      fontSize: 58,
      fontStyle: 'bold',
      letterSpacing: 2,
      fill: '#252623',
      shadow: { color: '#d9603c', blur: 0, offsetX: 6, offsetY: 6, opacity: 0.9 },
    },
    neon: {
      key: 'neon',
      label: '霓虹',
      sample: '回声',
      family: 'PingFang SC, sans-serif',
      fontSize: 58,
      fontStyle: 'bold',
      letterSpacing: 4,
      outlineOnly: true,
      stroke: '#b7f24a',
      strokeWidth: 2,
      shadow: { color: '#b7f24a', blur: 16, offsetX: 0, offsetY: 0, opacity: 0.75 },
    },
  };
  const FONT_STYLE_ORDER = ['song', 'hei', 'neon'];
  // 用户上传的字体用这个中性样式，字体本身才是主角。
  const UPLOADED_FONT_STYLE = {
    key: 'uploaded',
    label: '自定义',
    sample: '永念',
    fontSize: 56,
    fontStyle: 'normal',
    letterSpacing: 4,
    fill: '#252623',
  };

  const workspaceState = {
    screenshots: [],
    screenshotMap: new Map(),
    folders: [],
    filter: { type: 'inbox', id: null, label: '新添加截图' },
    searchIds: null,
    searchTimer: null,
    stage: null,
    layer: null,
    transformer: null,
    selectedNode: null,
    canvas: null,
    // 服务端已有多画布数据结构；界面尚未提供切换器时也不能误写默认画布。
    canvasId: DEFAULT_CANVAS_ID,
    // 暂时无法加载源素材的元素不渲染，但下一次保存时必须原样保留。
    unresolvedCanvasElements: [],
    saveTimer: null,
    saveInFlight: false,
    pendingSave: false,
    panning: false,
    panOrigin: null,
    materialSignature: '',
    source: 'screenshots',
    huabanFrame: null,
    pasting: false,
    leftPanelWidth: null,
    fonts: [],
    fontMap: new Map(),
    loadedFonts: new Set(),
  };

  const dom = {};

  document.addEventListener('DOMContentLoaded', initCanvasWorkspace);

  async function initCanvasWorkspace() {
    if (!window.Konva) {
      setSaveState('error', '画布组件加载失败');
      return;
    }
    cacheDom();
    bindWorkspaceEvents();
    initStage();
    // 字体要先注册完再渲染画布，否则文字节点会按兜底字体量错尺寸。
    await Promise.all([loadMaterials(), loadCanvas(), loadFonts()]);
    renderCanvasElements();
    window.setInterval(refreshMaterialsQuietly, MATERIAL_REFRESH_INTERVAL);
  }

  function cacheDom() {
    const ids = [
      'canvasMaterialCount', 'canvasRefreshMaterials', 'canvasMaterialSearch',
      'canvasClearSearch', 'canvasInboxCount', 'canvasFavoriteCount',
      'canvasFolderList', 'canvasMaterialTitle', 'canvasVisibleCount',
      'canvasMaterialGrid', 'canvasMaterialEmpty', 'canvasStageShell',
      'canvasStage', 'canvasEmptyState', 'canvasDropIndicator',
      'canvasSaveState', 'canvasZoomValue', 'canvasResetView',
      'canvasPhoneUpload', 'canvasLocalUpload', 'canvasUploadInput',
      'canvasMaterialToggle', 'canvasAnalysisPanel', 'canvasAnalysisCount',
      'canvasAnalysisSettings', 'canvasAnalysisToggle', 'canvasAnalysisHome',
      'canvasAnalyzeSelection', 'canvasAnalysisNavHost', 'canvasAnalysisDetail',
      'canvasAnalysisBack', 'canvasAnalysisToolbarHost', 'canvasAnalysisContentHost',
      'canvasHuabanPanel', 'canvasHuabanStatus', 'canvasHuabanReload',
      'canvasHuabanOpen', 'canvasHuabanToggle', 'canvasHuabanLoading',
      'canvasHuabanFrameWrap', 'canvasMaterialResize', 'canvasHuabanResize',
      'canvasFontPanel', 'canvasFontStatus', 'canvasFontUpload', 'canvasFontToggle',
      'canvasFontScroll', 'canvasFontBuiltinList', 'canvasFontUploadedList',
      'canvasFontUploadedCount', 'canvasFontEmpty', 'canvasFontDropzone',
      'canvasFontInput', 'canvasFontResize',
    ];
    ids.forEach(id => { dom[id] = document.getElementById(id); });
  }

  function bindWorkspaceEvents() {
    document.querySelectorAll('.source-item').forEach(button => {
      button.addEventListener('click', () => selectWorkspaceSource(button.dataset.source));
    });

    document.querySelectorAll('.material-filter').forEach(button => {
      button.addEventListener('click', () => {
        selectMaterialFilter(button.dataset.filter, null, button.textContent.trim().replace(/\d+$/, '').trim());
      });
    });

    dom.canvasRefreshMaterials.addEventListener('click', () => loadMaterials(true));
    dom.canvasMaterialSearch.addEventListener('input', onMaterialSearch);
    dom.canvasClearSearch.addEventListener('click', clearMaterialSearch);
    dom.canvasResetView.addEventListener('click', fitCanvasContent);
    dom.canvasPhoneUpload.addEventListener('click', () => {
      if (typeof window.showPhoneGuide === 'function') window.showPhoneGuide();
    });
    dom.canvasLocalUpload.addEventListener('click', () => dom.canvasUploadInput.click());
    dom.canvasUploadInput.addEventListener('change', uploadLocalMaterials);
    dom.canvasMaterialToggle.addEventListener('click', () => toggleFloatingPanel('material'));
    dom.canvasAnalysisToggle.addEventListener('click', () => toggleFloatingPanel('analysis'));
    dom.canvasAnalysisSettings.addEventListener('click', () => {
      if (typeof showAISettings === 'function') showAISettings();
    });
    dom.canvasAnalysisBack.addEventListener('click', showAnalysisHome);
    dom.canvasAnalyzeSelection.addEventListener('click', createAnalysisFromCanvasSelection);
    dom.canvasHuabanReload.addEventListener('click', () => loadHuabanFrame(true));
    dom.canvasHuabanOpen.addEventListener('click', () => window.open(HUABAN_URL, '_blank', 'noopener'));
    dom.canvasHuabanToggle.addEventListener('click', () => toggleFloatingPanel('huaban'));
    dom.canvasFontToggle.addEventListener('click', () => toggleFloatingPanel('fonts'));
    dom.canvasFontUpload.addEventListener('click', () => dom.canvasFontInput.click());
    dom.canvasFontInput.addEventListener('change', handleFontUpload);
    bindFontDropzone();
    document.addEventListener('paste', handleWorkspacePaste);
    bindPanelResize(dom.canvasMaterialResize);
    bindPanelResize(dom.canvasHuabanResize);
    bindPanelResize(dom.canvasFontResize);
    // 用 ResizeObserver 而不是 window.resize：前者在布局完成后再回调，
    // 拿到的面板位置才是新断点下的值。
    const widthObserver = new ResizeObserver(renderLeftPanelWidth);
    widthObserver.observe(document.querySelector('.canvas-workspace'));
    widthObserver.observe(dom.canvasAnalysisPanel);

    restoreFloatingPanels();
    restoreWorkspaceSource();
    restoreLeftPanelWidth();
    setupAnalysisBridge();

    dom.canvasStageShell.addEventListener('dragover', event => {
      if (!hasCanvasDrag(event)) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = 'copy';
      dom.canvasStageShell.classList.add('drag-over');
    });
    dom.canvasStageShell.addEventListener('dragleave', event => {
      if (!dom.canvasStageShell.contains(event.relatedTarget)) {
        dom.canvasStageShell.classList.remove('drag-over');
      }
    });
    dom.canvasStageShell.addEventListener('drop', dropOnCanvas);

    window.addEventListener('keydown', event => {
      const target = event.target;
      if (target && ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)) return;
      if ((event.key === 'Delete' || event.key === 'Backspace') && workspaceState.selectedNode) {
        event.preventDefault();
        event.stopImmediatePropagation();
        removeSelectedCanvasImage();
      }
      if (event.key === 'Escape') clearCanvasSelection();
    }, true);

    window.addEventListener('beforeunload', flushCanvasSave);
  }

  function selectWorkspaceSource(source) {
    if (!['screenshots', 'huaban', 'fonts'].includes(source)) return;
    workspaceState.source = source;
    document.querySelectorAll('.source-item').forEach(button => {
      const active = button.dataset.source === source;
      button.classList.toggle('active', active);
      button.setAttribute('aria-pressed', String(active));
    });
    const materialPanel = document.querySelector('.material-panel');
    if (materialPanel) materialPanel.hidden = source !== 'screenshots';
    dom.canvasHuabanPanel.hidden = source !== 'huaban';
    dom.canvasFontPanel.hidden = source !== 'fonts';
    try { localStorage.setItem(SOURCE_STORAGE_KEY, source); } catch (_) {}
    if (source === 'huaban') ensureHuabanFrame();
    if (source === 'fonts') renderFonts();
    renderLeftPanelWidth();
  }

  function restoreWorkspaceSource() {
    let stored = null;
    try { stored = localStorage.getItem(SOURCE_STORAGE_KEY); } catch (_) {}
    selectWorkspaceSource(['huaban', 'fonts'].includes(stored) ? stored : 'screenshots');
  }

  // 花瓣只在用户第一次点开时才加载，避免每次打开 Pin 都请求外部站点。
  function ensureHuabanFrame() {
    if (!workspaceState.huabanFrame) {
      const frame = document.createElement('iframe');
      frame.className = 'huaban-frame';
      frame.title = '花瓣';
      // 只放开写入权限：花瓣页面要能响应「复制图片」，但不该读取用户剪贴板。
      frame.setAttribute('allow', 'clipboard-write; fullscreen');
      frame.addEventListener('load', () => { dom.canvasHuabanLoading.hidden = true; });
      workspaceState.huabanFrame = frame;
      loadHuabanFrame();
      dom.canvasHuabanFrameWrap.append(frame);
    }
  }

  function loadHuabanFrame(isReload = false) {
    const frame = workspaceState.huabanFrame;
    if (!frame) return;
    dom.canvasHuabanLoading.hidden = false;
    frame.src = HUABAN_URL;
    if (isReload) workspaceToast('已重新加载花瓣');
  }

  function activeLeftPanel() {
    if (workspaceState.source === 'huaban') return dom.canvasHuabanPanel;
    if (workspaceState.source === 'fonts') return dom.canvasFontPanel;
    return document.querySelector('.material-panel');
  }

  // 最宽不能压到右侧分析面板，留出 LEFT_PANEL_GAP 的间距。
  function maxLeftPanelWidth() {
    const panel = activeLeftPanel();
    if (!panel || !dom.canvasAnalysisPanel) return LEFT_PANEL_MAX;
    const available = dom.canvasAnalysisPanel.getBoundingClientRect().left
      - panel.getBoundingClientRect().left - LEFT_PANEL_GAP;
    if (!Number.isFinite(available)) return LEFT_PANEL_MAX;
    return clamp(available, LEFT_PANEL_MIN, LEFT_PANEL_MAX);
  }

  function setLeftPanelWidth(width, persist = false) {
    workspaceState.leftPanelWidth = clamp(width, LEFT_PANEL_MIN, maxLeftPanelWidth());
    renderLeftPanelWidth();
    if (!persist) return;
    try {
      localStorage.setItem(LEFT_PANEL_STORAGE_KEY, String(Math.round(workspaceState.leftPanelWidth)));
    } catch (_) {}
  }

  // 窗口变窄时只收窄渲染宽度，用户原本设定的宽度留着，窗口恢复后还会回来。
  function renderLeftPanelWidth() {
    const workspace = document.querySelector('.canvas-workspace');
    if (!workspace || workspaceState.leftPanelWidth === null) return;
    const width = Math.min(workspaceState.leftPanelWidth, maxLeftPanelWidth());
    workspace.style.setProperty('--left-panel-width', `${Math.round(width)}px`);
  }

  function resetLeftPanelWidth() {
    workspaceState.leftPanelWidth = null;
    const workspace = document.querySelector('.canvas-workspace');
    if (workspace) workspace.style.removeProperty('--left-panel-width');
    try { localStorage.removeItem(LEFT_PANEL_STORAGE_KEY); } catch (_) {}
  }

  function restoreLeftPanelWidth() {
    let stored = NaN;
    try { stored = Number(localStorage.getItem(LEFT_PANEL_STORAGE_KEY)); } catch (_) {}
    if (!Number.isFinite(stored) || stored <= 0) return;
    workspaceState.leftPanelWidth = clamp(stored, LEFT_PANEL_MIN, LEFT_PANEL_MAX);
    renderLeftPanelWidth();
  }

  function bindPanelResize(handle) {
    if (!handle) return;
    const panel = handle.closest('.material-panel, .huaban-panel, .font-panel');
    if (!panel) return;

    handle.addEventListener('pointerdown', event => {
      if (event.button !== 0 || panel.classList.contains('collapsed')) return;
      event.preventDefault();
      const startX = event.clientX;
      const startWidth = panel.getBoundingClientRect().width;
      let dragged = false;
      handle.setPointerCapture(event.pointerId);
      document.body.classList.add('resizing-left-panel');

      const onMove = moveEvent => {
        dragged = true;
        setLeftPanelWidth(startWidth + moveEvent.clientX - startX);
      };
      const onEnd = endEvent => {
        handle.removeEventListener('pointermove', onMove);
        handle.removeEventListener('pointerup', onEnd);
        handle.removeEventListener('pointercancel', onEnd);
        document.body.classList.remove('resizing-left-panel');
        if (handle.hasPointerCapture(endEvent.pointerId)) handle.releasePointerCapture(endEvent.pointerId);
        if (dragged) setLeftPanelWidth(workspaceState.leftPanelWidth, true);
      };
      handle.addEventListener('pointermove', onMove);
      handle.addEventListener('pointerup', onEnd);
      handle.addEventListener('pointercancel', onEnd);
    });

    handle.addEventListener('dblclick', resetLeftPanelWidth);

    handle.addEventListener('keydown', event => {
      const current = workspaceState.leftPanelWidth ?? panel.getBoundingClientRect().width;
      const step = event.shiftKey ? LEFT_PANEL_STEP * 3 : LEFT_PANEL_STEP;
      if (event.key === 'ArrowLeft') setLeftPanelWidth(current - step, true);
      else if (event.key === 'ArrowRight') setLeftPanelWidth(current + step, true);
      else if (event.key === 'Enter' || event.key === 'Home') resetLeftPanelWidth();
      else return;
      event.preventDefault();
    });
  }

  async function loadMaterials(showFeedback = false) {
    dom.canvasRefreshMaterials.classList.add('loading');
    try {
      const [screenshotsResponse, foldersResponse] = await Promise.all([
        fetch('/api/screenshots?limit=1000'),
        fetch('/api/folders'),
      ]);
      if (!screenshotsResponse.ok || !foldersResponse.ok) throw new Error('素材读取失败');
      const [screenshots, folders] = await Promise.all([
        screenshotsResponse.json(), foldersResponse.json(),
      ]);
      workspaceState.screenshots = screenshots;
      workspaceState.screenshotMap = new Map(screenshots.map(item => [item.id, item]));
      workspaceState.folders = folders;
      workspaceState.materialSignature = materialSignature(screenshots, folders);
      renderMaterialFilters();
      renderMaterials();
      if (showFeedback) workspaceToast('素材已刷新');
    } catch (error) {
      workspaceToast('暂时无法读取素材，请稍后重试');
    } finally {
      dom.canvasRefreshMaterials.classList.remove('loading');
    }
  }

  async function refreshMaterialsQuietly() {
    if (document.hidden) return;
    try {
      const [screenshotsResponse, foldersResponse] = await Promise.all([
        fetch('/api/screenshots?limit=1000'),
        fetch('/api/folders'),
      ]);
      const [screenshots, folders] = await Promise.all([
        screenshotsResponse.json(), foldersResponse.json(),
      ]);
      const signature = materialSignature(screenshots, folders);
      if (signature === workspaceState.materialSignature) return;
      workspaceState.screenshots = screenshots;
      workspaceState.screenshotMap = new Map(screenshots.map(item => [item.id, item]));
      workspaceState.folders = folders;
      workspaceState.materialSignature = signature;
      renderMaterialFilters();
      renderMaterials();
    } catch (_) {
      // A later poll will restore the material list.
    }
  }

  function materialSignature(screenshots, folders) {
    return `${screenshots.map(item => `${item.id}:${item.path}:${item.mtime}:${item.analysis?.favorite ? 1 : 0}`).join('|')}::${folders.map(folder => `${folder.id}:${folder.name}:${folder.screenshots?.length || 0}`).join('|')}`;
  }

  function renderMaterialFilters() {
    const inboxCount = workspaceState.screenshots.filter(item => item.status === 'inbox').length;
    const favoriteCount = workspaceState.screenshots.filter(item => item.analysis?.favorite).length;
    dom.canvasInboxCount.textContent = inboxCount;
    dom.canvasFavoriteCount.textContent = favoriteCount;
    dom.canvasMaterialCount.textContent = `${workspaceState.screenshots.length} 张本地素材`;

    dom.canvasFolderList.replaceChildren();
    if (!workspaceState.folders.length) {
      const empty = document.createElement('div');
      empty.className = 'material-folder-empty';
      empty.textContent = '暂无素材文件夹';
      dom.canvasFolderList.append(empty);
      return;
    }
    workspaceState.folders.forEach(folder => {
      const button = document.createElement('button');
      button.className = 'material-folder-item';
      button.dataset.folderId = folder.id;
      if (workspaceState.filter.type === 'folder' && workspaceState.filter.id === folder.id) {
        button.classList.add('active');
      }
      const label = document.createElement('span');
      const icon = document.createElement('i');
      icon.className = 'ri-folder-3-line';
      const name = document.createElement('span');
      name.textContent = folder.name;
      label.append(icon, name);
      const count = document.createElement('b');
      count.textContent = folder.screenshots?.length || 0;
      button.append(label, count);
      button.addEventListener('click', () => selectMaterialFilter('folder', folder.id, folder.name));
      dom.canvasFolderList.append(button);
    });
  }

  function selectMaterialFilter(type, id, label) {
    workspaceState.filter = { type, id, label };
    clearMaterialSearch(false);
    document.querySelectorAll('.material-filter').forEach(button => {
      button.classList.toggle('active', button.dataset.filter === type);
    });
    document.querySelectorAll('.material-folder-item').forEach(button => {
      button.classList.toggle('active', type === 'folder' && button.dataset.folderId === id);
    });
    renderMaterials();
  }

  function getVisibleMaterials() {
    if (workspaceState.searchIds) {
      return workspaceState.screenshots.filter(item => workspaceState.searchIds.has(item.id));
    }
    if (workspaceState.filter.type === 'favorites') {
      return workspaceState.screenshots.filter(item => item.analysis?.favorite);
    }
    if (workspaceState.filter.type === 'folder') {
      return workspaceState.screenshots.filter(item => item.folder_id === workspaceState.filter.id);
    }
    return workspaceState.screenshots.filter(item => item.status === 'inbox');
  }

  function renderMaterials() {
    const visible = getVisibleMaterials();
    const searching = workspaceState.searchIds !== null;
    dom.canvasMaterialTitle.textContent = searching ? '搜索结果' : workspaceState.filter.label;
    dom.canvasVisibleCount.textContent = `${visible.length} 张`;
    dom.canvasMaterialGrid.replaceChildren();
    dom.canvasMaterialEmpty.hidden = visible.length > 0;

    visible.forEach(item => {
      const card = document.createElement('button');
      card.className = 'material-thumb';
      card.draggable = true;
      card.type = 'button';
      card.title = '拖入右侧画布';
      card.setAttribute('aria-label', `拖动素材 ${item.app || item.id} 到画布`);

      const imageWrap = document.createElement('span');
      imageWrap.className = 'material-thumb-image';
      const image = document.createElement('img');
      image.src = screenshotUrl(item.path);
      image.alt = '';
      image.loading = 'lazy';
      image.draggable = false;
      const dragMark = document.createElement('span');
      dragMark.className = 'material-thumb-drag';
      dragMark.innerHTML = '<i class="ri-drag-move-2-line"></i>';
      imageWrap.append(image, dragMark);

      const meta = document.createElement('span');
      meta.className = 'material-thumb-meta';
      const metaIcon = document.createElement('i');
      metaIcon.className = item.analysis?.favorite ? 'ri-heart-3-fill' : 'ri-image-line';
      const metaText = document.createElement('span');
      metaText.textContent = item.app || materialFolderName(item) || '未标记来源';
      meta.append(metaIcon, metaText);
      card.append(imageWrap, meta);
      card.addEventListener('dragstart', event => {
        event.dataTransfer.effectAllowed = 'copy';
        event.dataTransfer.setData('application/x-designpeek-screenshot', item.id);
        event.dataTransfer.setData('text/plain', item.id);
      });
      dom.canvasMaterialGrid.append(card);
    });
  }

  function materialFolderName(item) {
    return workspaceState.folders.find(folder => folder.id === item.folder_id)?.name || '';
  }

  function onMaterialSearch() {
    const query = dom.canvasMaterialSearch.value.trim();
    dom.canvasClearSearch.hidden = !query;
    window.clearTimeout(workspaceState.searchTimer);
    if (!query) {
      workspaceState.searchIds = null;
      renderMaterials();
      return;
    }
    workspaceState.searchTimer = window.setTimeout(() => searchMaterials(query), 220);
  }

  async function searchMaterials(query) {
    try {
      const response = await fetch(`/api/search?q=${encodeURIComponent(query)}`);
      const result = await response.json();
      if (dom.canvasMaterialSearch.value.trim() !== query) return;
      workspaceState.searchIds = new Set(result.ids || []);
      renderMaterials();
    } catch (_) {
      workspaceToast('搜索暂时不可用');
    }
  }

  function clearMaterialSearch(focus = true) {
    dom.canvasMaterialSearch.value = '';
    dom.canvasClearSearch.hidden = true;
    workspaceState.searchIds = null;
    window.clearTimeout(workspaceState.searchTimer);
    if (focus) dom.canvasMaterialSearch.focus();
    renderMaterials();
  }

  async function uploadLocalMaterials(event) {
    const files = Array.from(event.target.files || []);
    if (!files.length) return;
    dom.canvasLocalUpload.disabled = true;
    let uploaded = 0;
    for (const file of files) {
      const form = new FormData();
      form.append('file', file);
      try {
        const response = await fetch('/api/upload', { method: 'POST', body: form });
        const result = await response.json();
        if (result.ok) uploaded += 1;
      } catch (_) {
        // Continue with the remaining files and report the total below.
      }
    }
    event.target.value = '';
    dom.canvasLocalUpload.disabled = false;
    await loadMaterials();
    workspaceToast(uploaded === files.length ? `已上传 ${uploaded} 张素材` : `已上传 ${uploaded}/${files.length} 张素材`);
  }

  const PASTED_EXTENSIONS = {
    'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif',
    'image/webp': 'webp', 'image/bmp': 'bmp', 'image/tiff': 'tiff',
  };

  async function handleWorkspacePaste(event) {
    const target = event.target;
    if (target && (target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName))) return;
    const item = Array.from(event.clipboardData?.items || [])
      .find(entry => entry.kind === 'file' && entry.type.startsWith('image/'));
    if (!item) {
      workspaceToast('剪贴板里没有图片，请先复制一张图片');
      return;
    }
    const blob = item.getAsFile();
    if (!blob) {
      workspaceToast('读不到剪贴板里的图片，请重新复制一次');
      return;
    }
    event.preventDefault();
    await pasteImageToCanvas(blob);
  }

  async function pasteImageToCanvas(blob) {
    if (workspaceState.pasting) return;
    workspaceState.pasting = true;
    try {
      const form = new FormData();
      form.append('file', new File([blob], pastedFileName(blob), { type: blob.type || 'image/png' }));
      const response = await fetch('/api/upload', { method: 'POST', body: form });
      const result = await response.json();
      if (!response.ok || !result.ok) throw new Error(result.error || '图片保存失败');
      await loadMaterials();
      const screenshot = findUploadedScreenshot(result.filename);
      if (!screenshot) throw new Error('图片已保存，但暂时读不到这张素材');
      await addCanvasImage(screenshot, canvasViewportCenter());
      workspaceToast('已粘贴到画布，并放进「新添加截图」');
    } catch (error) {
      workspaceToast(error.message || '粘贴失败，请重试');
    } finally {
      workspaceState.pasting = false;
    }
  }

  function pastedFileName(blob) {
    const extension = PASTED_EXTENSIONS[blob.type] || 'png';
    const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    return `huaban_${stamp}_${Math.random().toString(16).slice(2, 8)}.${extension}`;
  }

  function findUploadedScreenshot(filename) {
    if (!filename) return null;
    const stem = String(filename).replace(/\.[^.]+$/, '');
    return workspaceState.screenshots.find(item => item.id === stem)
      || workspaceState.screenshots.find(item => String(item.path).endsWith(`/${filename}`))
      || null;
  }

  // ── 字体素材 ───────────────────────────────────────────────────────

  async function loadFonts() {
    try {
      const response = await fetch('/api/fonts');
      if (!response.ok) throw new Error('字体读取失败');
      const result = await response.json();
      workspaceState.fonts = Array.isArray(result.fonts) ? result.fonts : [];
    } catch (_) {
      workspaceState.fonts = [];
    }
    workspaceState.fontMap = new Map(workspaceState.fonts.map(item => [item.id, item]));
    // 浏览器不跨刷新保留 FontFace，每次进页面都要按索引重新注册一遍。
    await Promise.all(workspaceState.fonts.map(font => ensureFontFace(font)));
    renderFonts();
  }

  async function ensureFontFace(font) {
    if (!font || !font.family || !font.url) return false;
    if (workspaceState.loadedFonts.has(font.family)) return true;
    if (typeof FontFace !== 'function') return false;
    try {
      const face = new FontFace(font.family, `url("${font.url}")`);
      await face.load();
      document.fonts.add(face);
      workspaceState.loadedFonts.add(font.family);
      return true;
    } catch (_) {
      workspaceToast(`字体「${font.family}」加载失败，画布上会显示为默认字体`);
      return false;
    }
  }

  // 元素只记 style_key，样式参数始终从预设取，避免旧数据里存着过时的颜色。
  function fontStyleOf(element) {
    if (element.font_id || element.style_key === UPLOADED_FONT_STYLE.key) return UPLOADED_FONT_STYLE;
    return FONT_STYLES[element.style_key] || FONT_STYLES.song;
  }

  // 面板预览用 CSS 还原预设，和画布侧的 Konva 配置出自同一份参数。
  function fontPreviewStyle(style, family) {
    const css = {
      fontFamily: family || style.family,
      fontSize: `${Math.round(style.fontSize * 0.6)}px`,
      letterSpacing: `${Math.round((style.letterSpacing || 0) * 0.6)}px`,
    };
    if (style.fontStyle === 'bold') css.fontWeight = '700';
    if (style.shadow) {
      const { offsetX = 0, offsetY = 0, blur = 0, color } = style.shadow;
      css.textShadow = `${offsetX}px ${offsetY}px ${blur}px ${color}`;
    }
    if (style.outlineOnly) {
      css.color = 'transparent';
      css.webkitTextStroke = `${style.strokeWidth || 1}px ${style.stroke}`;
    } else if (style.gradient) {
      css.backgroundImage = `linear-gradient(135deg, ${style.gradient[0]}, ${style.gradient[1]})`;
      css.webkitBackgroundClip = 'text';
      css.backgroundClip = 'text';
      css.color = 'transparent';
    } else {
      css.color = style.fill || '#252623';
    }
    return css;
  }

  function renderFonts() {
    if (!dom.canvasFontBuiltinList) return;

    dom.canvasFontBuiltinList.replaceChildren();
    FONT_STYLE_ORDER.forEach(key => {
      const style = FONT_STYLES[key];
      dom.canvasFontBuiltinList.append(buildFontCard({
        dragKey: `builtin:${key}`,
        label: style.label,
        hint: '内置示意',
        sample: style.sample,
        style,
        family: style.family,
      }));
    });

    dom.canvasFontUploadedList.replaceChildren();
    workspaceState.fonts.forEach(font => {
      dom.canvasFontUploadedList.append(buildFontCard({
        dragKey: `font:${font.id}`,
        label: font.family,
        hint: formatFontSize(font.size),
        sample: UPLOADED_FONT_STYLE.sample,
        style: UPLOADED_FONT_STYLE,
        family: `"${font.family}"`,
        font,
      }));
    });

    dom.canvasFontUploadedCount.textContent = `${workspaceState.fonts.length} 个`;
    dom.canvasFontEmpty.hidden = workspaceState.fonts.length > 0;
  }

  function buildFontCard({ dragKey, label, hint, sample, style, family, font = null }) {
    const card = document.createElement('div');
    card.className = 'font-card';
    card.draggable = true;
    card.tabIndex = 0;
    card.setAttribute('role', 'button');
    card.title = `拖动「${label}」到画布`;
    card.setAttribute('aria-label', `拖动字体 ${label} 到画布`);

    const sampleEl = document.createElement('span');
    sampleEl.className = 'font-card-sample';
    sampleEl.textContent = sample;
    Object.assign(sampleEl.style, fontPreviewStyle(style, family));

    const meta = document.createElement('span');
    meta.className = 'font-card-meta';
    const name = document.createElement('b');
    name.textContent = label;
    const tail = document.createElement('span');
    tail.textContent = hint;
    meta.append(name, tail);

    card.append(sampleEl, meta);

    if (font) {
      const remove = document.createElement('button');
      remove.className = 'font-card-delete';
      remove.type = 'button';
      remove.title = `删除字体 ${label}`;
      remove.setAttribute('aria-label', `删除字体 ${label}`);
      remove.innerHTML = '<i class="ri-delete-bin-line"></i>';
      remove.addEventListener('click', event => {
        event.stopPropagation();
        deleteFont(font);
      });
      card.append(remove);
    }

    card.addEventListener('dragstart', event => {
      event.dataTransfer.effectAllowed = 'copy';
      event.dataTransfer.setData(FONT_DRAG_TYPE, dragKey);
      event.dataTransfer.setData('text/plain', label);
      card.classList.add('dragging');
    });
    card.addEventListener('dragend', () => card.classList.remove('dragging'));
    // 双击直接落到视口中央，省一次拖拽
    card.addEventListener('dblclick', () => addCanvasFont(dragKey, canvasViewportCenter()));

    return card;
  }

  function formatFontSize(bytes) {
    const size = Number(bytes) || 0;
    if (size <= 0) return '字体文件';
    return size >= 1024 * 1024
      ? `${(size / 1024 / 1024).toFixed(1)} MB`
      : `${Math.max(1, Math.round(size / 1024))} KB`;
  }

  function isFontFile(file) {
    const name = String(file?.name || '').toLowerCase();
    return FONT_ACCEPTED_EXTENSIONS.some(ext => name.endsWith(ext));
  }

  function fontFilesFrom(event) {
    const items = Array.from(event.dataTransfer?.items || []);
    const files = items.length
      ? items.filter(item => item.kind === 'file').map(item => item.getAsFile())
      : Array.from(event.dataTransfer?.files || []);
    return files.filter(file => file && isFontFile(file));
  }

  function bindFontDropzone() {
    const zone = dom.canvasFontDropzone;
    if (!zone) return;
    ['dragenter', 'dragover'].forEach(type => {
      zone.addEventListener(type, event => {
        if (!fontFilesFrom(event).length) return;
        event.preventDefault();
        event.stopPropagation();
        zone.classList.add('drag-over');
      });
    });
    zone.addEventListener('dragleave', () => zone.classList.remove('drag-over'));
    zone.addEventListener('drop', async event => {
      const files = fontFilesFrom(event);
      if (!files.length) return;
      event.preventDefault();
      event.stopPropagation();
      zone.classList.remove('drag-over');
      await uploadFontFiles(files);
    });
    zone.addEventListener('click', () => dom.canvasFontInput.click());
  }

  async function handleFontUpload(event) {
    const files = Array.from(event.target.files || []);
    event.target.value = '';
    await uploadFontFiles(files);
  }

  async function uploadFontFiles(files) {
    const accepted = files.filter(isFontFile);
    if (!accepted.length) {
      workspaceToast(`请选择 ${FONT_ACCEPTED_EXTENSIONS.join(' / ')} 格式的字体文件`);
      return;
    }
    let uploaded = 0;
    for (const file of accepted) {
      const form = new FormData();
      form.append('file', file, file.name);
      try {
        const response = await fetch('/api/fonts/upload', { method: 'POST', body: form });
        const result = await response.json().catch(() => ({}));
        if (!response.ok || !result.ok) throw new Error(result.error || '上传失败');
        uploaded += 1;
      } catch (error) {
        workspaceToast(`${file.name}：${error.message || '上传失败'}`);
      }
    }
    if (!uploaded) return;
    await loadFonts();
    selectWorkspaceSource('fonts');
    workspaceToast(uploaded === 1 ? '字体已上传，拖到画布就能用' : `已上传 ${uploaded} 个字体`);
  }

  async function deleteFont(font) {
    if (!confirm(`确定删除字体「${font.family}」？\n画布上用到它的文字会退回默认字体。`)) return;
    try {
      const response = await fetch(`/api/fonts/${encodeURIComponent(font.id)}`, { method: 'DELETE' });
      if (!response.ok) throw new Error('删除失败');
    } catch (error) {
      workspaceToast(error.message || '删除失败');
      return;
    }
    workspaceState.loadedFonts.delete(font.family);
    await loadFonts();
    workspaceToast('字体已删除');
  }

  async function addCanvasFont(dragKey, point) {
    const isBuiltin = dragKey.startsWith('builtin:');
    const styleKey = isBuiltin ? dragKey.slice('builtin:'.length) : UPLOADED_FONT_STYLE.key;
    const font = isBuiltin ? null : workspaceState.fontMap.get(dragKey.slice('font:'.length));
    const style = isBuiltin ? FONT_STYLES[styleKey] : UPLOADED_FONT_STYLE;
    if (!style) return;
    if (!isBuiltin && !font) {
      workspaceToast('这个字体已经不在了，请重新上传');
      await loadFonts();
      return;
    }
    if (font) await ensureFontFace(font);

    const element = {
      id: createElementId(),
      type: 'text',
      text: style.sample,
      font_family: font ? `"${font.family}"` : style.family,
      style_key: styleKey,
      font_id: font ? font.id : '',
      x: 0,
      y: 0,
      width: 0,
      height: 0,
      rotation: 0,
      z_index: nextCanvasZIndex(),
    };
    const node = createCanvasTextNode(element);
    element.width = node.width();
    element.height = node.height();
    node.position({ x: point.x - element.width / 2, y: point.y - element.height / 2 });
    workspaceState.layer.add(node);
    workspaceState.transformer.moveToTop();
    selectCanvasNode(node);
    workspaceState.layer.batchDraw();
    updateCanvasEmptyState();
    scheduleCanvasSave();
  }

  // 把样式预设翻译成 Konva 配置；渐变依赖节点尺寸，所以要等 Konva 量完文字再设。
  function createCanvasTextNode(element) {
    const style = fontStyleOf(element);
    const family = element.font_family || style.family;
    const config = {
      id: element.id,
      name: 'canvas-text',
      x: element.x || 0,
      y: element.y || 0,
      text: element.text,
      fontFamily: family,
      fontSize: style.fontSize,
      fontStyle: style.fontStyle === 'bold' ? 'bold' : 'normal',
      letterSpacing: style.letterSpacing || 0,
      rotation: element.rotation || 0,
      draggable: true,
      // 自定义属性统一加 dp 前缀，避开 Konva 自己的 fontFamily / text 等字段
      dpText: element.text,
      dpFamily: family,
      dpStyleKey: style.key,
      dpFontId: element.font_id || '',
      dpPersistedZIndex: Number(element.z_index) || 0,
    };

    if (style.outlineOnly) {
      config.fillEnabled = false;
      config.stroke = style.stroke;
      config.strokeWidth = style.strokeWidth || 1;
    } else {
      config.fill = style.fill || '#252623';
    }
    if (style.shadow) {
      config.shadowColor = style.shadow.color;
      config.shadowBlur = style.shadow.blur || 0;
      config.shadowOffsetX = style.shadow.offsetX || 0;
      config.shadowOffsetY = style.shadow.offsetY || 0;
      config.shadowOpacity = style.shadow.opacity ?? 1;
      config.shadowForStrokeEnabled = true;
    }

    const node = new Konva.Text(config);
    applyTextGradient(node);
    bindCanvasNodeEvents(node);
    return node;
  }

  // 尺寸变了要重算渐变端点，否则渐变会停在创建时的长度上。
  function applyTextGradient(node) {
    const style = fontStyleOf({ style_key: node.getAttr('dpStyleKey'), font_id: node.getAttr('dpFontId') });
    if (!style.gradient || style.outlineOnly) return;
    node.fillPriority('linear-gradient');
    node.fillLinearGradientStartPoint({ x: 0, y: 0 });
    node.fillLinearGradientEndPoint({ x: node.width(), y: node.height() });
    node.fillLinearGradientColorStops([0, style.gradient[0], 1, style.gradient[1]]);
  }

  function canvasViewportCenter() {
    const stage = workspaceState.stage;
    return {
      x: (stage.width() / 2 - stage.x()) / stage.scaleX(),
      y: (stage.height() / 2 - stage.y()) / stage.scaleY(),
    };
  }

  function initStage() {
    const width = dom.canvasStageShell.clientWidth;
    const height = dom.canvasStageShell.clientHeight;
    workspaceState.stage = new Konva.Stage({ container: dom.canvasStage, width, height });
    workspaceState.layer = new Konva.Layer({ imageSmoothingEnabled: true });
    workspaceState.transformer = new Konva.Transformer({
      rotateEnabled: false,
      keepRatio: true,
      flipEnabled: false,
      borderStroke: '#202124',
      borderStrokeWidth: 1,
      anchorStroke: '#202124',
      anchorFill: '#ffffff',
      anchorSize: 8,
      anchorCornerRadius: 2,
      enabledAnchors: ['top-left', 'top-right', 'bottom-left', 'bottom-right'],
      boundBoxFunc: (oldBox, newBox) => {
        if (Math.abs(newBox.width) < 40 || Math.abs(newBox.height) < 40) return oldBox;
        return newBox;
      },
    });
    workspaceState.layer.add(workspaceState.transformer);
    workspaceState.stage.add(workspaceState.layer);

    workspaceState.stage.on('mousedown touchstart', event => {
      if (event.target !== workspaceState.stage) return;
      clearCanvasSelection();
      const pointer = workspaceState.stage.getPointerPosition();
      if (!pointer) return;
      workspaceState.panning = true;
      workspaceState.panOrigin = {
        pointer,
        stage: { x: workspaceState.stage.x(), y: workspaceState.stage.y() },
      };
      dom.canvasStageShell.classList.add('panning');
    });
    workspaceState.stage.on('mousemove touchmove', () => {
      if (!workspaceState.panning || !workspaceState.panOrigin) return;
      const pointer = workspaceState.stage.getPointerPosition();
      if (!pointer) return;
      workspaceState.stage.position({
        x: workspaceState.panOrigin.stage.x + pointer.x - workspaceState.panOrigin.pointer.x,
        y: workspaceState.panOrigin.stage.y + pointer.y - workspaceState.panOrigin.pointer.y,
      });
      updateCanvasGrid();
      workspaceState.stage.batchDraw();
      scheduleCanvasSave();
    });
    workspaceState.stage.on('mouseup touchend mouseleave', stopCanvasPan);
    workspaceState.stage.on('wheel', zoomCanvasAtPointer);

    new ResizeObserver(() => resizeStage()).observe(dom.canvasStageShell);
    updateCanvasGrid();
  }

  function resizeStage() {
    if (!workspaceState.stage) return;
    workspaceState.stage.size({
      width: dom.canvasStageShell.clientWidth,
      height: dom.canvasStageShell.clientHeight,
    });
    workspaceState.stage.batchDraw();
  }

  function stopCanvasPan() {
    if (!workspaceState.panning) return;
    workspaceState.panning = false;
    workspaceState.panOrigin = null;
    dom.canvasStageShell.classList.remove('panning');
    scheduleCanvasSave();
  }

  function zoomCanvasAtPointer(event) {
    event.evt.preventDefault();
    const stage = workspaceState.stage;
    const oldScale = stage.scaleX();
    const pointer = stage.getPointerPosition();
    if (!pointer) return;
    const worldPoint = {
      x: (pointer.x - stage.x()) / oldScale,
      y: (pointer.y - stage.y()) / oldScale,
    };
    const direction = event.evt.deltaY > 0 ? -1 : 1;
    const factor = event.evt.ctrlKey ? 1.035 : 1.08;
    const nextScale = clamp(direction > 0 ? oldScale * factor : oldScale / factor, MIN_SCALE, MAX_SCALE);
    stage.scale({ x: nextScale, y: nextScale });
    stage.position({
      x: pointer.x - worldPoint.x * nextScale,
      y: pointer.y - worldPoint.y * nextScale,
    });
    updateCanvasGrid();
    updateZoomLabel();
    stage.batchDraw();
    scheduleCanvasSave();
  }

  function updateCanvasGrid() {
    if (!workspaceState.stage) return;
    const scale = workspaceState.stage.scaleX();
    const size = Math.max(8, 20 * scale);
    const x = modulo(workspaceState.stage.x(), size);
    const y = modulo(workspaceState.stage.y(), size);
    dom.canvasStageShell.style.setProperty('--canvas-grid-size', `${size}px`);
    dom.canvasStageShell.style.setProperty('--canvas-grid-x', `${x}px`);
    dom.canvasStageShell.style.setProperty('--canvas-grid-y', `${y}px`);
  }

  function updateZoomLabel() {
    dom.canvasZoomValue.textContent = `${Math.round(workspaceState.stage.scaleX() * 100)}%`;
  }

  function hasCanvasDrag(event) {
    const types = Array.from(event.dataTransfer?.types || []);
    return types.includes('application/x-designpeek-screenshot') || types.includes(FONT_DRAG_TYPE);
  }

  async function dropOnCanvas(event) {
    dom.canvasStageShell.classList.remove('drag-over');
    const types = Array.from(event.dataTransfer?.types || []);
    const isScreenshot = types.includes('application/x-designpeek-screenshot');
    const isFont = types.includes(FONT_DRAG_TYPE);
    if (!isScreenshot && !isFont) return;
    event.preventDefault();

    const rect = dom.canvasStageShell.getBoundingClientRect();
    const worldPoint = screenToWorld({ x: event.clientX - rect.left, y: event.clientY - rect.top });

    if (isFont) {
      const key = event.dataTransfer.getData(FONT_DRAG_TYPE);
      if (key) await addCanvasFont(key, worldPoint);
      return;
    }

    const screenshot = workspaceState.screenshotMap.get(event.dataTransfer.getData('application/x-designpeek-screenshot'));
    if (!screenshot) {
      workspaceToast('这张素材暂时无法读取');
      return;
    }
    await addCanvasImage(screenshot, worldPoint);
  }

  function screenToWorld(point) {
    const stage = workspaceState.stage;
    return {
      x: (point.x - stage.x()) / stage.scaleX(),
      y: (point.y - stage.y()) / stage.scaleY(),
    };
  }

  async function addCanvasImage(screenshot, point) {
    try {
      const image = await loadImage(screenshotUrl(screenshot.path));
      const size = initialImageSize(image.naturalWidth, image.naturalHeight);
      const element = {
        id: createElementId(),
        type: 'image',
        screenshot_id: screenshot.id,
        x: point.x - size.width / 2,
        y: point.y - size.height / 2,
        width: size.width,
        height: size.height,
        rotation: 0,
        z_index: nextCanvasZIndex(),
      };
      const node = createCanvasImageNode(image, element);
      workspaceState.layer.add(node);
      workspaceState.transformer.moveToTop();
      selectCanvasNode(node);
      workspaceState.layer.batchDraw();
      updateCanvasEmptyState();
      scheduleCanvasSave();
    } catch (_) {
      workspaceToast('图片载入失败，请刷新素材后重试');
    }
  }

  function createCanvasImageNode(image, element) {
    const node = new Konva.Image({
      id: element.id,
      name: 'canvas-image',
      image,
      x: element.x,
      y: element.y,
      width: element.width,
      height: element.height,
      rotation: element.rotation || 0,
      draggable: true,
      cornerRadius: 4,
      shadowColor: '#252623',
      shadowBlur: 9,
      shadowOpacity: 0.12,
      shadowOffsetY: 2,
      screenshotId: element.screenshot_id,
      dpPersistedZIndex: Number(element.z_index) || 0,
    });
    bindCanvasNodeEvents(node);
    return node;
  }

  function bindCanvasNodeEvents(node) {
    node.on('mousedown touchstart', event => {
      event.cancelBubble = true;
      selectCanvasNode(node);
    });
    node.on('dragstart', () => {
      selectCanvasNode(node);
      dom.canvasStageShell.classList.add('has-selection');
    });
    node.on('dragend', () => {
      dom.canvasStageShell.classList.remove('has-selection');
      scheduleCanvasSave();
    });
    node.on('transformend', () => {
      const scaleX = Math.abs(node.scaleX());
      const scaleY = Math.abs(node.scaleY());
      node.scale({ x: 1, y: 1 });
      if (node.name() === 'canvas-text') {
        // 文字按字号缩放；直接改 width/height 会触发换行，字形就变了
        node.fontSize(Math.max(10, Math.round(node.fontSize() * Math.max(scaleX, scaleY))));
        applyTextGradient(node);
      } else {
        node.width(Math.max(40, node.width() * scaleX));
        node.height(Math.max(40, node.height() * scaleY));
      }
      workspaceState.transformer.forceUpdate();
      workspaceState.layer.batchDraw();
      scheduleCanvasSave();
    });
  }

  function selectCanvasNode(node) {
    workspaceState.selectedNode = node;
    workspaceState.transformer.nodes([node]);
    workspaceState.transformer.moveToTop();
    workspaceState.layer.batchDraw();
    updateAnalyzeSelectionButton();
  }

  function clearCanvasSelection() {
    if (!workspaceState.transformer) return;
    workspaceState.selectedNode = null;
    workspaceState.transformer.nodes([]);
    workspaceState.layer.batchDraw();
    updateAnalyzeSelectionButton();
  }

  const PANEL_CONFIG = {
    material: { label: '截图素材', onLeft: true, panel: () => document.querySelector('.material-panel'), button: () => dom.canvasMaterialToggle },
    huaban: { label: '花瓣', onLeft: true, panel: () => dom.canvasHuabanPanel, button: () => dom.canvasHuabanToggle },
    fonts: { label: '字体', onLeft: true, panel: () => dom.canvasFontPanel, button: () => dom.canvasFontToggle },
    analysis: { label: '分析', onLeft: false, panel: () => dom.canvasAnalysisPanel, button: () => dom.canvasAnalysisToggle },
  };

  function toggleFloatingPanel(panelName, forceCollapsed = null) {
    const config = PANEL_CONFIG[panelName];
    if (!config) return;
    const panel = config.panel();
    const button = config.button();
    if (!panel || !button) return;
    const collapsed = forceCollapsed === null ? !panel.classList.contains('collapsed') : forceCollapsed;
    panel.classList.toggle('collapsed', collapsed);
    button.setAttribute('aria-expanded', String(!collapsed));
    const actionLabel = `${collapsed ? '展开' : '收起'}${config.label}`;
    button.title = actionLabel;
    button.setAttribute('aria-label', actionLabel);
    const icon = button.querySelector('i');
    if (icon) {
      const pointsRight = config.onLeft ? collapsed : !collapsed;
      icon.className = pointsRight ? 'ri-arrow-right-s-line' : 'ri-arrow-left-s-line';
    }
    try { localStorage.setItem(PANEL_STORAGE_KEYS[panelName], collapsed ? '1' : '0'); } catch (_) {}
    // 分析面板宽度变了，左侧面板的可拖范围也跟着变。
    if (panelName === 'analysis') renderLeftPanelWidth();
  }

  function restoreFloatingPanels() {
    const stored = name => {
      try { return localStorage.getItem(PANEL_STORAGE_KEYS[name]) === '1'; } catch (_) { return false; }
    };
    toggleFloatingPanel('material', stored('material'));
    toggleFloatingPanel('huaban', stored('huaban'));
    toggleFloatingPanel('fonts', stored('fonts'));
    toggleFloatingPanel('analysis', stored('analysis'));
  }

  function setupAnalysisBridge() {
    const nav = document.getElementById('tabSidebarProjects');
    const toolbar = document.getElementById('projectToolbar');
    const content = document.getElementById('projectContent');
    if (!nav || !toolbar || !content) return;

    nav.classList.add('active');
    dom.canvasAnalysisNavHost.append(nav);
    dom.canvasAnalysisToolbarHost.append(toolbar);
    dom.canvasAnalysisContentHost.append(content);
    dom.canvasAnalysisNavHost.addEventListener('click', event => {
      if (event.target.closest('.analysis-folder-toggle, .project-nav-actions')) return;
      if (event.target.closest('.analysis-nav-item, .analysis-folder-row, .analysis-section-heading')) {
        window.setTimeout(showAnalysisDetail, 0);
      }
    });
    dom.canvasAnalysisContentHost.addEventListener('click', event => {
      if (event.target.closest('.conversation-list-card')) window.setTimeout(showAnalysisDetail, 0);
    });

    updateAnalysisCount();
    window.setTimeout(() => {
      if (typeof renderProjectNav === 'function') renderProjectNav();
      updateAnalysisCount();
      if (typeof state !== 'undefined' && (state.currentConversation || state.currentProject)) showAnalysisDetail();
    }, 500);
    window.setInterval(updateAnalysisCount, 3000);
  }

  function showAnalysisHome() {
    dom.canvasAnalysisHome.hidden = false;
    dom.canvasAnalysisDetail.hidden = true;
    if (typeof backToProjectList === 'function') backToProjectList();
    history.replaceState(null, '', '/');
    updateAnalysisCount();
  }

  function showAnalysisDetail() {
    dom.canvasAnalysisHome.hidden = true;
    dom.canvasAnalysisDetail.hidden = false;
    updateAnalysisCount();
  }

  function updateAnalysisCount() {
    if (!dom.canvasAnalysisCount) return;
    const count = typeof state !== 'undefined' && Array.isArray(state.conversations)
      ? state.conversations.length
      : 0;
    dom.canvasAnalysisCount.textContent = `${count} 个分析`;
  }

  function updateAnalyzeSelectionButton() {
    if (!dom.canvasAnalyzeSelection) return;
    const node = workspaceState.selectedNode;
    // 分析只吃截图素材，字体元素没有对应的截图可引用，直接置灰。
    const screenshotId = node && node.name() !== 'canvas-text' ? node.getAttr('screenshotId') : null;
    const label = dom.canvasAnalyzeSelection.querySelector('small');
    dom.canvasAnalyzeSelection.disabled = !screenshotId;
    if (!label) return;
    if (!node) {
      label.textContent = '请先在画布中选择一张图片';
      return;
    }
    if (!screenshotId) {
      label.textContent = '字体元素不支持分析';
      return;
    }
    const screenshot = workspaceState.screenshotMap.get(screenshotId);
    label.textContent = screenshot?.app || materialFolderName(screenshot || {}) || '已选择 1 张素材';
  }

  async function createAnalysisFromCanvasSelection() {
    const node = workspaceState.selectedNode;
    if (!node) return;
    const screenshotId = node.name() !== 'canvas-text' ? node.getAttr('screenshotId') : null;
    if (!screenshotId) {
      workspaceToast('字体元素不支持分析，请选择截图素材');
      return;
    }
    dom.canvasAnalyzeSelection.disabled = true;
    try {
      const response = await fetch('/api/conversations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ screenshot_ids: [screenshotId] }),
      });
      const result = await response.json();
      if (!response.ok || !result.ok) throw new Error(result.error || '无法创建分析');
      if (typeof loadConversations === 'function') await loadConversations();
      if (typeof selectConversation === 'function') selectConversation(result.conversation.id);
      toggleFloatingPanel('analysis', false);
      showAnalysisDetail();
      workspaceToast('已创建分析，请填写你想研究的问题');
    } catch (error) {
      workspaceToast(error.message || '无法创建分析');
    } finally {
      updateAnalyzeSelectionButton();
      updateAnalysisCount();
    }
  }

  function removeSelectedCanvasImage() {
    const node = workspaceState.selectedNode;
    if (!node) return;
    const isText = node.name() === 'canvas-text';
    clearCanvasSelection();
    node.destroy();
    workspaceState.layer.batchDraw();
    updateCanvasEmptyState();
    scheduleCanvasSave();
    workspaceToast(isText ? '已从画布移除' : '已从画布移除，原素材仍然保留');
  }

  async function loadCanvas() {
    setSaveState('saving', '正在载入');
    try {
      const response = await fetch('/api/canvases');
      if (!response.ok) throw new Error('画布读取失败');
      const documentData = await response.json();
      const canvasId = documentData.active_canvas_id || DEFAULT_CANVAS_ID;
      workspaceState.canvasId = canvasId;
      workspaceState.canvas = documentData.canvases?.[canvasId] || emptyCanvas(canvasId);
      const viewport = workspaceState.canvas.viewport || {};
      workspaceState.stage.position({ x: Number(viewport.x) || 0, y: Number(viewport.y) || 0 });
      const scale = clamp(Number(viewport.scale) || 1, MIN_SCALE, MAX_SCALE);
      workspaceState.stage.scale({ x: scale, y: scale });
      updateCanvasGrid();
      updateZoomLabel();
      setSaveState('saved', '已保存');
    } catch (_) {
      workspaceState.canvasId = DEFAULT_CANVAS_ID;
      workspaceState.canvas = emptyCanvas();
      setSaveState('error', '使用空白画布');
    }
  }

  async function renderCanvasElements() {
    const elements = [...(workspaceState.canvas?.elements || [])].sort((a, b) => a.z_index - b.z_index);
    workspaceState.unresolvedCanvasElements = [];
    const loaded = await Promise.all(elements.map(async element => {
      if (element.type === 'text') return createCanvasTextNode(element);
      const screenshot = workspaceState.screenshotMap.get(element.screenshot_id);
      if (!screenshot) {
        workspaceState.unresolvedCanvasElements.push(element);
        return null;
      }
      try {
        const image = await loadImage(screenshotUrl(screenshot.path));
        return createCanvasImageNode(image, element);
      } catch (_) {
        workspaceState.unresolvedCanvasElements.push(element);
        return null;
      }
    }));
    loaded.filter(Boolean).forEach(node => workspaceState.layer.add(node));
    workspaceState.transformer.moveToTop();
    workspaceState.layer.batchDraw();
    updateCanvasEmptyState();
  }

  function updateCanvasEmptyState() {
    dom.canvasEmptyState.hidden = getCanvasNodes().length > 0;
  }

  function fitCanvasContent() {
    const nodes = getCanvasNodes();
    if (!nodes.length) {
      workspaceState.stage.position({ x: 0, y: 0 });
      workspaceState.stage.scale({ x: 1, y: 1 });
    } else {
      clearCanvasSelection();
      const bounds = nodes.reduce((result, node) => unionRects(result, node.getClientRect({ relativeTo: workspaceState.stage })), null);
      const padding = 84;
      const availableWidth = Math.max(100, workspaceState.stage.width() - padding * 2);
      const availableHeight = Math.max(100, workspaceState.stage.height() - padding * 2);
      const scale = clamp(Math.min(availableWidth / bounds.width, availableHeight / bounds.height, 1), MIN_SCALE, MAX_SCALE);
      workspaceState.stage.scale({ x: scale, y: scale });
      workspaceState.stage.position({
        x: (workspaceState.stage.width() - bounds.width * scale) / 2 - bounds.x * scale,
        y: (workspaceState.stage.height() - bounds.height * scale) / 2 - bounds.y * scale,
      });
    }
    updateCanvasGrid();
    updateZoomLabel();
    workspaceState.stage.batchDraw();
    scheduleCanvasSave();
  }

  function scheduleCanvasSave() {
    window.clearTimeout(workspaceState.saveTimer);
    setSaveState('saving', '正在保存');
    workspaceState.saveTimer = window.setTimeout(saveCanvas, SAVE_DELAY);
  }

  async function saveCanvas() {
    if (workspaceState.saveInFlight) {
      workspaceState.pendingSave = true;
      return;
    }
    workspaceState.saveInFlight = true;
    const payload = serializeCanvas();
    try {
      const response = await fetch(`/api/canvases/${encodeURIComponent(workspaceState.canvasId)}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      if (!response.ok) throw new Error('保存失败');
      const result = await response.json();
      workspaceState.canvas = result.canvas;
      setSaveState('saved', '已保存');
    } catch (_) {
      setSaveState('error', '保存失败');
    } finally {
      workspaceState.saveInFlight = false;
      if (workspaceState.pendingSave) {
        workspaceState.pendingSave = false;
        saveCanvas();
      }
    }
  }

  function flushCanvasSave() {
    if (!workspaceState.stage || !workspaceState.canvas) return;
    window.clearTimeout(workspaceState.saveTimer);
    fetch(`/api/canvases/${encodeURIComponent(workspaceState.canvasId)}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(serializeCanvas()),
      keepalive: true,
    }).catch(() => {});
  }

  function serializeCanvas() {
    return {
      id: workspaceState.canvasId,
      name: workspaceState.canvas?.name || '默认画布',
      viewport: {
        x: workspaceState.stage.x(),
        y: workspaceState.stage.y(),
        scale: workspaceState.stage.scaleX(),
      },
      elements: serializedCanvasElements(),
    };
  }

  function serializedCanvasElements() {
    const rendered = getCanvasNodes().map((node, index) => {
        const persistedZIndex = Number(node.getAttr('dpPersistedZIndex'));
        const geometry = {
          id: node.id(),
          x: node.x(),
          y: node.y(),
          width: node.width(),
          height: node.height(),
          rotation: node.rotation(),
          z_index: Number.isFinite(persistedZIndex) ? persistedZIndex : index,
        };
        if (node.name() === 'canvas-text') {
          return {
            ...geometry,
            type: 'text',
            text: node.getAttr('dpText'),
            font_family: node.getAttr('dpFamily'),
            style_key: node.getAttr('dpStyleKey'),
            font_id: node.getAttr('dpFontId') || '',
          };
        }
        return { ...geometry, type: 'image', screenshot_id: node.getAttr('screenshotId') };
      });
    return [...workspaceState.unresolvedCanvasElements, ...rendered]
      .sort((left, right) => (left.z_index || 0) - (right.z_index || 0))
      .map((element, index) => ({ ...element, z_index: index }));
  }

  function nextCanvasZIndex() {
    const unresolved = workspaceState.unresolvedCanvasElements.map(element => Number(element.z_index) || 0);
    const rendered = getCanvasNodes().map(node => Number(node.getAttr('dpPersistedZIndex')) || 0);
    return Math.max(-1, ...unresolved, ...rendered) + 1;
  }

  function setSaveState(type, text) {
    if (!dom.canvasSaveState) return;
    dom.canvasSaveState.className = `canvas-save-state ${type === 'saved' ? '' : type}`.trim();
    const icon = dom.canvasSaveState.querySelector('i');
    const label = dom.canvasSaveState.querySelector('span');
    if (icon) icon.className = type === 'saving' ? 'ri-loader-4-line' : type === 'error' ? 'ri-error-warning-line' : 'ri-checkbox-circle-line';
    if (label) label.textContent = text;
  }

  function getCanvasNodes() {
    return workspaceState.layer ? workspaceState.layer.find('.canvas-image, .canvas-text') : [];
  }

  function screenshotUrl(path) {
    return `/screenshots/${String(path).split('/').map(encodeURIComponent).join('/')}`;
  }

  function loadImage(url) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = reject;
      image.src = url;
    });
  }

  function initialImageSize(width, height) {
    const safeWidth = Math.max(1, width || 1);
    const safeHeight = Math.max(1, height || 1);
    const scale = Math.min(240 / safeWidth, 520 / safeHeight, 1);
    return { width: Math.round(safeWidth * scale), height: Math.round(safeHeight * scale) };
  }

  function createElementId() {
    if (window.crypto?.randomUUID) return `canvas_img_${window.crypto.randomUUID()}`;
    return `canvas_img_${Date.now()}_${Math.random().toString(16).slice(2)}`;
  }

  function emptyCanvas(canvasId = DEFAULT_CANVAS_ID) {
    return { id: canvasId, name: '默认画布', viewport: { x: 0, y: 0, scale: 1 }, elements: [] };
  }

  function unionRects(a, b) {
    if (!a) return { x: b.x, y: b.y, width: b.width, height: b.height };
    const x = Math.min(a.x, b.x);
    const y = Math.min(a.y, b.y);
    const right = Math.max(a.x + a.width, b.x + b.width);
    const bottom = Math.max(a.y + a.height, b.y + b.height);
    return { x, y, width: right - x, height: bottom - y };
  }

  function modulo(value, divisor) {
    return ((value % divisor) + divisor) % divisor;
  }

  function clamp(value, minimum, maximum) {
    return Math.min(maximum, Math.max(minimum, value));
  }

  function workspaceToast(message) {
    if (typeof window.showToast === 'function') {
      window.showToast(message);
      return;
    }
    const toast = document.createElement('div');
    toast.className = 'toast';
    toast.textContent = message;
    document.body.append(toast);
    window.setTimeout(() => toast.remove(), 2200);
  }
})();
