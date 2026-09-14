(() => {
  'use strict';

  const DEFAULT_CANVAS_ID = 'canvas_default';
  const SAVE_DELAY = 600;
  const MATERIAL_REFRESH_INTERVAL = 3500;
  const MIN_SCALE = 0.08;
  const MAX_SCALE = 5;

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
    saveTimer: null,
    saveInFlight: false,
    pendingSave: false,
    panning: false,
    panOrigin: null,
    materialSignature: '',
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
    await Promise.all([loadMaterials(), loadCanvas()]);
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
    ];
    ids.forEach(id => { dom[id] = document.getElementById(id); });
  }

  function bindWorkspaceEvents() {
    document.querySelectorAll('.source-item').forEach(button => {
      button.addEventListener('click', () => {
        if (button.dataset.source === 'screenshots') return;
        workspaceToast(`${button.querySelector('span').textContent}素材源将在后续版本接入`);
      });
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

    dom.canvasStageShell.addEventListener('dragover', event => {
      if (!hasScreenshotDrag(event)) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = 'copy';
      dom.canvasStageShell.classList.add('drag-over');
    });
    dom.canvasStageShell.addEventListener('dragleave', event => {
      if (!dom.canvasStageShell.contains(event.relatedTarget)) {
        dom.canvasStageShell.classList.remove('drag-over');
      }
    });
    dom.canvasStageShell.addEventListener('drop', dropMaterialOnCanvas);

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

  function hasScreenshotDrag(event) {
    return Array.from(event.dataTransfer?.types || []).includes('application/x-designpeek-screenshot');
  }

  async function dropMaterialOnCanvas(event) {
    dom.canvasStageShell.classList.remove('drag-over');
    const screenshotId = event.dataTransfer.getData('application/x-designpeek-screenshot');
    if (!screenshotId) return;
    event.preventDefault();
    const screenshot = workspaceState.screenshotMap.get(screenshotId);
    if (!screenshot) {
      workspaceToast('这张素材暂时无法读取');
      return;
    }
    const rect = dom.canvasStageShell.getBoundingClientRect();
    const screenPoint = { x: event.clientX - rect.left, y: event.clientY - rect.top };
    const worldPoint = screenToWorld(screenPoint);
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
        z_index: getCanvasImageNodes().length,
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
    });
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
      node.width(Math.max(40, node.width() * scaleX));
      node.height(Math.max(40, node.height() * scaleY));
      node.scale({ x: 1, y: 1 });
      workspaceState.transformer.forceUpdate();
      workspaceState.layer.batchDraw();
      scheduleCanvasSave();
    });
    return node;
  }

  function selectCanvasNode(node) {
    workspaceState.selectedNode = node;
    workspaceState.transformer.nodes([node]);
    workspaceState.transformer.moveToTop();
    workspaceState.layer.batchDraw();
  }

  function clearCanvasSelection() {
    if (!workspaceState.transformer) return;
    workspaceState.selectedNode = null;
    workspaceState.transformer.nodes([]);
    workspaceState.layer.batchDraw();
  }

  function removeSelectedCanvasImage() {
    const node = workspaceState.selectedNode;
    if (!node) return;
    clearCanvasSelection();
    node.destroy();
    workspaceState.layer.batchDraw();
    updateCanvasEmptyState();
    scheduleCanvasSave();
    workspaceToast('已从画布移除，原素材仍然保留');
  }

  async function loadCanvas() {
    setSaveState('saving', '正在载入');
    try {
      const response = await fetch('/api/canvases');
      if (!response.ok) throw new Error('画布读取失败');
      const documentData = await response.json();
      const canvasId = documentData.active_canvas_id || DEFAULT_CANVAS_ID;
      workspaceState.canvas = documentData.canvases?.[canvasId] || emptyCanvas();
      const viewport = workspaceState.canvas.viewport || {};
      workspaceState.stage.position({ x: Number(viewport.x) || 0, y: Number(viewport.y) || 0 });
      const scale = clamp(Number(viewport.scale) || 1, MIN_SCALE, MAX_SCALE);
      workspaceState.stage.scale({ x: scale, y: scale });
      updateCanvasGrid();
      updateZoomLabel();
      setSaveState('saved', '已保存');
    } catch (_) {
      workspaceState.canvas = emptyCanvas();
      setSaveState('error', '使用空白画布');
    }
  }

  async function renderCanvasElements() {
    const elements = [...(workspaceState.canvas?.elements || [])].sort((a, b) => a.z_index - b.z_index);
    const loaded = await Promise.all(elements.map(async element => {
      const screenshot = workspaceState.screenshotMap.get(element.screenshot_id);
      if (!screenshot) return null;
      try {
        const image = await loadImage(screenshotUrl(screenshot.path));
        return createCanvasImageNode(image, element);
      } catch (_) {
        return null;
      }
    }));
    loaded.filter(Boolean).forEach(node => workspaceState.layer.add(node));
    workspaceState.transformer.moveToTop();
    workspaceState.layer.batchDraw();
    updateCanvasEmptyState();
  }

  function updateCanvasEmptyState() {
    dom.canvasEmptyState.hidden = getCanvasImageNodes().length > 0;
  }

  function fitCanvasContent() {
    const nodes = getCanvasImageNodes();
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
      const response = await fetch(`/api/canvases/${DEFAULT_CANVAS_ID}`, {
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
    fetch(`/api/canvases/${DEFAULT_CANVAS_ID}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(serializeCanvas()),
      keepalive: true,
    }).catch(() => {});
  }

  function serializeCanvas() {
    return {
      id: DEFAULT_CANVAS_ID,
      name: workspaceState.canvas?.name || '默认画布',
      viewport: {
        x: workspaceState.stage.x(),
        y: workspaceState.stage.y(),
        scale: workspaceState.stage.scaleX(),
      },
      elements: getCanvasImageNodes().map((node, index) => ({
        id: node.id(),
        type: 'image',
        screenshot_id: node.getAttr('screenshotId'),
        x: node.x(),
        y: node.y(),
        width: node.width(),
        height: node.height(),
        rotation: node.rotation(),
        z_index: index,
      })),
    };
  }

  function setSaveState(type, text) {
    if (!dom.canvasSaveState) return;
    dom.canvasSaveState.className = `canvas-save-state ${type === 'saved' ? '' : type}`.trim();
    const icon = dom.canvasSaveState.querySelector('i');
    const label = dom.canvasSaveState.querySelector('span');
    if (icon) icon.className = type === 'saving' ? 'ri-loader-4-line' : type === 'error' ? 'ri-error-warning-line' : 'ri-checkbox-circle-line';
    if (label) label.textContent = text;
  }

  function getCanvasImageNodes() {
    return workspaceState.layer ? workspaceState.layer.find('.canvas-image') : [];
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

  function emptyCanvas() {
    return { id: DEFAULT_CANVAS_ID, name: '默认画布', viewport: { x: 0, y: 0, scale: 1 }, elements: [] };
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
