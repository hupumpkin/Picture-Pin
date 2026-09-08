#!/usr/bin/env python3
"""DesignPeek — 竞品截图整理分析工具"""

import base64
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import time
import uuid
from datetime import datetime
from pathlib import Path

from fastapi import BackgroundTasks, FastAPI, File, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image

from config import (
    ANALYSIS_FILE,
    DATA_DIR,
    HOST,
    INBOX_DIR,
    PAGE_TYPES,
    PORT,
    PROJECTS_FILE,
    SCREENSHOTS_DIR,
)
from ai_settings import public_ai_settings, save_ai_settings
from analyzer import (
    _require_key,
    analyze_screenshot,
    analyze_screenshot_evidence,
    suggest_dimensions,
    synthesize_project,
    test_ai_connection,
)

# OCR via macOS Vision framework
try:
    import Quartz
    import Vision
    import Foundation
    _PYOBJC_OCR_AVAILABLE = True
except ImportError:
    _PYOBJC_OCR_AVAILABLE = False


import threading

OCR_SWIFT_SOURCE = os.path.join(os.path.dirname(__file__), "ocr.swift")
OCR_BINARY = os.path.join(DATA_DIR, "designpeek_ocr")
_OCR_BUILD_LOCK = threading.Lock()
_ANALYSIS_WRITE_LOCK = threading.Lock()
_PROJECTS_WRITE_LOCK = threading.Lock()
_OCR_AVAILABLE = _PYOBJC_OCR_AVAILABLE or bool(shutil.which("swiftc") or shutil.which("xcrun"))
_OCR_INDEX_STATE = {"running": False, "processed": 0, "total": 0, "error": None}


def _ensure_ocr_binary():
    if _PYOBJC_OCR_AVAILABLE:
        return None
    with _OCR_BUILD_LOCK:
        source_mtime = os.path.getmtime(OCR_SWIFT_SOURCE)
        if os.path.exists(OCR_BINARY) and os.path.getmtime(OCR_BINARY) >= source_mtime:
            return OCR_BINARY
        result = subprocess.run(
            ["xcrun", "swiftc", OCR_SWIFT_SOURCE, "-o", OCR_BINARY],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "无法编译本地文字识别程序")
        return OCR_BINARY


def _ocr_async(filepath: str):
    """Run OCR in background thread and save result."""
    text = ocr_image(filepath)
    sid = os.path.splitext(os.path.basename(filepath))[0]
    _save_ocr_result(sid, text)


def _schedule_ocr(filepath: str):
    """Fire-and-forget OCR in a background thread."""
    t = threading.Thread(target=_ocr_async, args=(filepath,), daemon=True)
    t.start()


def ocr_image(filepath: str) -> str:
    """Extract text from an image using macOS Vision framework."""
    if not _OCR_AVAILABLE:
        return ""

    try:
        if not _PYOBJC_OCR_AVAILABLE:
            binary = _ensure_ocr_binary()
            result = subprocess.run(
                [binary, filepath],
                capture_output=True,
                text=True,
                timeout=90,
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or "文字识别失败")
            return result.stdout.strip()

        with open(filepath, "rb") as f:
            img_data = f.read()

        nsdata = Foundation.NSData.dataWithBytes_length_(img_data, len(img_data))
        handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(nsdata, None)
        if handler is None:
            return ""

        request = Vision.VNRecognizeTextRequest.alloc().init()
        request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
        request.setRecognitionLanguages_(["zh-Hans", "en"])

        success, error = handler.performRequests_error_([request], None)
        if not success:
            return ""

        results = request.results()
        if results is None:
            return ""

        texts = []
        for observation in results:
            top = observation.topCandidates_(1)
            if top and len(top) > 0:
                texts.append(str(top[0].string()))

        return "\n".join(texts)
    except Exception as e:
        print(f"  ⚠ OCR 失败: {filepath} — {e}")
        return ""

app = FastAPI(title="DesignPeek")
FOLDERS_FILE = os.path.join(DATA_DIR, "folders.json")
SCREENSHOT_METADATA_FILE = os.path.join(DATA_DIR, "screenshot_metadata.json")
STORAGE_LAYOUT_FILE = os.path.join(DATA_DIR, "storage_layout_v2.json")
IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".webp", ".heic", ".heif")


# ── ensure directories ──────────────────────────────────────────────
os.makedirs(INBOX_DIR, exist_ok=True)
os.makedirs(DATA_DIR, exist_ok=True)

if not os.path.exists(ANALYSIS_FILE):
    with open(ANALYSIS_FILE, "w") as f:
        json.dump({}, f)

if not os.path.exists(PROJECTS_FILE):
    with open(PROJECTS_FILE, "w") as f:
        json.dump({}, f)

if not os.path.exists(FOLDERS_FILE):
    with open(FOLDERS_FILE, "w") as f:
        json.dump({}, f)

if not os.path.exists(SCREENSHOT_METADATA_FILE):
    with open(SCREENSHOT_METADATA_FILE, "w") as f:
        json.dump({}, f)


def load_analysis():
    with open(ANALYSIS_FILE, "r") as f:
        return json.load(f)


def save_analysis(data):
    with open(ANALYSIS_FILE, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _save_ocr_result(sid, text):
    with _ANALYSIS_WRITE_LOCK:
        analysis = load_analysis()
        entry = analysis.get(sid, {})
        entry["ocr_text"] = text
        entry["ocr_indexed_at"] = datetime.now().isoformat()
        analysis[sid] = entry
        save_analysis(analysis)


def load_projects():
    with open(PROJECTS_FILE, "r") as f:
        return json.load(f)


def save_projects(data):
    with open(PROJECTS_FILE, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def update_project_record(pid, updater):
    """Update one project without overwriting changes made by another request."""
    with _PROJECTS_WRITE_LOCK:
        projects = load_projects()
        if pid not in projects:
            return None
        updater(projects[pid])
        save_projects(projects)
        return projects[pid]


def load_folders():
    with open(FOLDERS_FILE, "r") as f:
        return json.load(f)


def save_folders(data):
    with open(FOLDERS_FILE, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_screenshot_metadata():
    with open(SCREENSHOT_METADATA_FILE, "r") as f:
        return json.load(f)


def save_screenshot_metadata(data):
    with open(SCREENSHOT_METADATA_FILE, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _is_image_file(path):
    return os.path.splitext(str(path))[1].lower() in IMAGE_EXTENSIONS


def _validate_folder_name(name):
    name = (name or "").strip()
    if not name:
        raise ValueError("文件夹名称不能为空")
    if name in (".", "..", "新添加截图", "_inbox") or "/" in name or "\\" in name:
        raise ValueError("文件夹名称不可用")
    return name


def _folder_path(folder):
    return os.path.join(SCREENSHOTS_DIR, folder["name"])


def _find_screenshot_path(sid):
    for root, _, files in os.walk(SCREENSHOTS_DIR):
        for filename in files:
            if _is_image_file(filename) and os.path.splitext(filename)[0] == sid:
                return os.path.join(root, filename)
    return None


def _move_screenshot(path, target_dir):
    os.makedirs(target_dir, exist_ok=True)
    target = os.path.join(target_dir, os.path.basename(path))
    if os.path.abspath(path) == os.path.abspath(target):
        return target
    if os.path.exists(target):
        raise FileExistsError(f"目标文件已存在: {os.path.basename(target)}")
    os.replace(path, target)
    return target


def _remove_empty_screenshot_dirs():
    preserved = {os.path.abspath(SCREENSHOTS_DIR), os.path.abspath(INBOX_DIR)}
    preserved.update(os.path.abspath(_folder_path(folder)) for folder in load_folders().values())
    for root, _, _ in os.walk(SCREENSHOTS_DIR, topdown=False):
        if os.path.abspath(root) in preserved:
            continue
        try:
            finder_metadata = os.path.join(root, ".DS_Store")
            if os.path.exists(finder_metadata):
                os.remove(finder_metadata)
            if not os.listdir(root):
                os.rmdir(root)
        except FileNotFoundError:
            pass


def sync_material_folders():
    """Make folder references match the real material-folder directories."""
    folders = load_folders()
    changed = False
    for folder in folders.values():
        path = _folder_path(folder)
        os.makedirs(path, exist_ok=True)
        screenshot_ids = sorted(
            p.stem for p in Path(path).iterdir()
            if p.is_file() and _is_image_file(p)
        )
        if folder.get("screenshots", []) != screenshot_ids:
            folder["screenshots"] = screenshot_ids
            changed = True
    if changed:
        save_folders(folders)
    return folders


def migrate_to_material_folder_storage():
    """One-time migration from App directories to physical material folders."""
    if os.path.exists(STORAGE_LAYOUT_FILE):
        return

    folders = load_folders()
    metadata = load_screenshot_metadata()
    ordered_folders = sorted(folders.values(), key=lambda f: f.get("created_at", ""))
    owner_by_sid = {}
    for folder in ordered_folders:
        for sid in folder.get("screenshots", []):
            if isinstance(sid, str) and "\n" not in sid:
                owner_by_sid[sid] = folder["id"]

    images = [
        p for p in Path(SCREENSHOTS_DIR).rglob("*")
        if p.is_file() and _is_image_file(p)
    ]
    planned_targets = set()
    for path in images:
        owner = folders.get(owner_by_sid.get(path.stem))
        target_dir = Path(_folder_path(owner)) if owner else Path(INBOX_DIR)
        target = target_dir / path.name
        key = str(target.resolve())
        if key in planned_targets or (target.exists() and target.resolve() != path.resolve()):
            raise RuntimeError(f"迁移中发现同名文件: {path.name}")
        planned_targets.add(key)

    folder_names = {folder["name"] for folder in folders.values()}
    for path in images:
        parts = path.relative_to(SCREENSHOTS_DIR).parts
        top_dir = parts[0] if len(parts) > 1 else ""
        if top_dir not in folder_names and top_dir not in ("_inbox", "新添加截图"):
            metadata.setdefault(path.stem, {})["app"] = top_dir

        owner = folders.get(owner_by_sid.get(path.stem))
        target_dir = _folder_path(owner) if owner else INBOX_DIR
        _move_screenshot(str(path), target_dir)

    valid_ids = {path.stem for path in images}
    for folder in folders.values():
        folder["screenshots"] = sorted(
            sid for sid, fid in owner_by_sid.items()
            if fid == folder["id"] and sid in valid_ids
        )
    save_folders(folders)
    save_screenshot_metadata(metadata)
    _remove_empty_screenshot_dirs()
    with open(STORAGE_LAYOUT_FILE, "w") as f:
        json.dump({"version": 2, "migrated_at": datetime.now().isoformat()}, f, ensure_ascii=False, indent=2)


migrate_to_material_folder_storage()


def _backfill_ocr_index():
    if _OCR_INDEX_STATE["running"] or not _OCR_AVAILABLE:
        return
    analysis = load_analysis()
    pending = [
        path for path in Path(SCREENSHOTS_DIR).rglob("*")
        if path.is_file() and _is_image_file(path)
        and not analysis.get(path.stem, {}).get("ocr_indexed_at")
    ]
    _OCR_INDEX_STATE.update(running=True, processed=0, total=len(pending), error=None)
    try:
        for index, path in enumerate(pending, 1):
            _save_ocr_result(path.stem, ocr_image(str(path)))
            _OCR_INDEX_STATE["processed"] = index
            if index % 10 == 0:
                print(f"  OCR 索引进度: {index}/{len(pending)}")
    except Exception as exc:
        _OCR_INDEX_STATE["error"] = str(exc)
        print(f"  OCR 索引失败: {exc}")
    finally:
        _OCR_INDEX_STATE["running"] = False


def start_ocr_backfill():
    thread = threading.Thread(target=_backfill_ocr_index, daemon=True)
    thread.start()


@app.on_event("startup")
async def startup_ocr_index():
    start_ocr_backfill()


def get_local_ip():
    """Get the local network IP address."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def _detect_image_ext(content: bytes, filename: str = "", content_type: str = "") -> str:
    """Detect the real image extension from bytes, with filename/content-type fallback."""
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if content.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if content.startswith(b"RIFF") and content[8:12] == b"WEBP":
        return ".webp"
    if content.startswith((b"GIF87a", b"GIF89a")):
        return ".gif"
    if len(content) >= 12 and content[4:8] == b"ftyp":
        brand = content[8:12].lower()
        compatible = content[8:64].lower()
        if brand in (b"heic", b"heix", b"hevc", b"hevx", b"heif", b"mif1", b"msf1") or b"heic" in compatible or b"heif" in compatible:
            return ".heic"

    ct = (content_type or "").lower()
    if "png" in ct:
        return ".png"
    if "jpeg" in ct or "jpg" in ct:
        return ".jpg"
    if "webp" in ct:
        return ".webp"
    if "heic" in ct or "heif" in ct:
        return ".heic"

    ext = os.path.splitext(filename or "")[1].lower()
    if ext in (".png", ".jpg", ".jpeg", ".webp", ".heic", ".heif"):
        return ".jpg" if ext == ".jpeg" else ext
    return ".png"


def _with_ext(path: str, ext: str) -> str:
    root, _ = os.path.splitext(path)
    return root + ext


def save_uploaded_image(content: bytes, target_path: str, filename: str = "", content_type: str = "") -> str:
    """Save uploaded image bytes, converting iPhone HEIC/HEIF to browser-friendly PNG."""
    ext = _detect_image_ext(content, filename, content_type)

    if ext in (".heic", ".heif"):
        final_path = _with_ext(target_path, ".png")
        tmp_path = final_path + f".{uuid.uuid4().hex[:6]}.heic"
        with open(tmp_path, "wb") as f:
            f.write(content)
        try:
            result = subprocess.run(
                ["sips", "-s", "format", "png", tmp_path, "--out", final_path],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode == 0 and os.path.exists(final_path):
                print("  ↳ 已将 iPhone HEIC 图片转换为 PNG")
                return final_path
            print(f"  ⚠ HEIC 转 PNG 失败，保留原图: {result.stderr.strip() or result.stdout.strip()}")
            fallback_path = _with_ext(target_path, ".heic")
            os.replace(tmp_path, fallback_path)
            return fallback_path
        finally:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)

    final_path = _with_ext(target_path, ext)
    with open(final_path, "wb") as f:
        f.write(content)
    return final_path


def remember_source_app(path, app_name):
    if not app_name or app_name == "安卓截图":
        return
    metadata = load_screenshot_metadata()
    metadata.setdefault(Path(path).stem, {})["app"] = app_name
    save_screenshot_metadata(metadata)


# ── API: Upload (auto from iPhone shortcut & manual from web) ────────

@app.post("/api/upload")
async def api_upload(file: UploadFile = File(...)):
    """Receive a screenshot from iPhone shortcut or web upload."""
    ext = os.path.splitext(file.filename or "screenshot.png")[1] or ".png"
    name = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}{ext}"
    path = os.path.join(INBOX_DIR, name)

    content = await file.read()
    path = save_uploaded_image(content, path, file.filename, file.content_type or "")
    name = os.path.basename(path)

    print(f"  ✓ 收到截图: {name}  ({len(content) / 1024:.0f} KB)")
    _schedule_ocr(path)

    return {"ok": True, "filename": name}


@app.post("/api/upload/base64")
async def api_upload_base64(req: Request):
    """Receive a screenshot as base64-encoded JSON (iPhone Shortcut fallback)."""
    body = await req.json()
    data = body.get("image", "")
    filename = body.get("filename", f"screenshot_{uuid.uuid4().hex[:6]}.png")

    if not data:
        return JSONResponse({"ok": False, "error": "缺少 image 字段"}, status_code=400)

    content = base64.b64decode(data)
    ext = os.path.splitext(filename)[1] or ".png"
    name = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}{ext}"
    path = os.path.join(INBOX_DIR, name)

    path = save_uploaded_image(content, path, filename)
    name = os.path.basename(path)

    print(f"  ✓ 收到截图(base64): {name}  ({len(content) / 1024:.0f} KB)")
    _schedule_ocr(path)

    return {"ok": True, "filename": name}


@app.post("/api/upload/image")
async def api_upload_image(req: Request):
    """Receive raw binary image body. Optional ?app=AppName for auto-naming."""
    content = await req.body()

    if not content:
        return JSONResponse({"ok": False, "error": "请求体为空"}, status_code=400)

    # Try query param first, then header
    app_name = req.query_params.get("app", "").strip()
    if not app_name:
        app_name = req.headers.get("X-App-Name", "").strip()

    print(f"  → 收到请求: app={app_name!r}, query={dict(req.query_params)}, size={len(content)}")

    if app_name:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        name = f"{app_name}_{ts}.png"
        path = os.path.join(INBOX_DIR, name)
    else:
        name = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}.png"
        path = os.path.join(INBOX_DIR, name)

    path = save_uploaded_image(content, path, name, req.headers.get("content-type", ""))
    name = os.path.basename(path)
    remember_source_app(path, app_name)

    print(f"  ✓ 收到截图: {name}  ({len(content) / 1024:.0f} KB)")
    _schedule_ocr(path)

    return {"ok": True, "filename": name}


@app.post("/api/upload/raw")
async def api_upload_raw(req: Request):
    """Receive raw base64 text body (simplest Shortcut integration)."""
    data = (await req.body()).decode("utf-8").strip()

    if not data:
        return JSONResponse({"ok": False, "error": "请求体为空"}, status_code=400)

    content = base64.b64decode(data)
    name = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}.png"
    path = os.path.join(INBOX_DIR, name)

    path = save_uploaded_image(content, path, name)
    name = os.path.basename(path)

    print(f"  ✓ 收到截图(raw): {name}  ({len(content) / 1024:.0f} KB)")
    _schedule_ocr(path)

    return {"ok": True, "filename": name}


# ── API: List screenshots ───────────────────────────────────────────

@app.get("/api/screenshots")
async def api_list(limit: int = 200):
    """List all screenshots with their metadata."""
    results = []
    analysis = load_analysis()
    metadata = load_screenshot_metadata()
    folders = sync_material_folders()
    folder_by_name = {folder["name"]: folder for folder in folders.values()}

    for root, _, files in os.walk(SCREENSHOTS_DIR):
        for fname in sorted(files):
            if not _is_image_file(fname):
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, SCREENSHOTS_DIR)
            parts = rel.split(os.sep)
            folder = folder_by_name.get(parts[0]) if len(parts) >= 2 else None
            stem = os.path.splitext(fname)[0]
            results.append({
                "id": stem,
                "path": rel,
                "status": "organized" if folder else "inbox",
                "folder_id": folder["id"] if folder else None,
                "app": metadata.get(stem, {}).get("app"),
                "page_type": None,
                "analysis": analysis.get(stem),
                "mtime": os.path.getmtime(fpath),
            })

    results.sort(key=lambda x: x["mtime"], reverse=True)
    return results[:limit]


# ── API: Classify screenshots ────────────────────────────────────────

@app.post("/api/classify")
async def api_classify(req: Request):
    """Update source-App metadata without changing physical storage."""
    body = await req.json()
    ids = body.get("ids", [])
    app_name = body.get("app", "").strip()

    if not ids or not app_name:
        return JSONResponse({"ok": False, "error": "缺少参数"}, status_code=400)
    metadata = load_screenshot_metadata()
    updated = []
    for sid in ids:
        if _find_screenshot_path(sid):
            metadata.setdefault(sid, {})["app"] = app_name
            updated.append(sid)
    save_screenshot_metadata(metadata)
    return {"ok": True, "updated": updated}


# ── API: Delete screenshots ─────────────────────────────────────────

@app.post("/api/delete")
async def api_delete(req: Request):
    """Delete selected screenshots."""
    body = await req.json()
    ids = body.get("ids", [])

    if not ids:
        return JSONResponse({"ok": False, "error": "未选择截图"}, status_code=400)

    deleted = []
    for sid in ids:
        for root, _, files in os.walk(SCREENSHOTS_DIR):
            for f in files:
                if _is_image_file(f) and os.path.splitext(f)[0] == sid:
                    os.remove(os.path.join(root, f))
                    deleted.append(sid)
                    break
            else:
                continue
            break

    _remove_empty_screenshot_dirs()

    # Also remove from analysis
    analysis = load_analysis()
    for sid in deleted:
        analysis.pop(sid, None)
    save_analysis(analysis)

    metadata = load_screenshot_metadata()
    for sid in deleted:
        metadata.pop(sid, None)
    save_screenshot_metadata(metadata)

    # Also remove deleted screenshots from projects to avoid stale empty cards.
    projects = load_projects()
    projects_changed = False
    for proj in projects.values():
        screenshots = proj.get("screenshots", {})
        for sid in deleted:
            if sid in screenshots:
                screenshots.pop(sid, None)
                projects_changed = True
    if projects_changed:
        save_projects(projects)

    folders = load_folders()
    folders_changed = False
    deleted_set = set(deleted)
    for folder in folders.values():
        before = folder.get("screenshots", [])
        after = [sid for sid in before if sid not in deleted_set]
        if len(after) != len(before):
            folder["screenshots"] = after
            folders_changed = True
    if folders_changed:
        save_folders(folders)

    return {"ok": True, "deleted": deleted}


@app.post("/api/reveal")
async def api_reveal_screenshots(req: Request):
    """Open Finder at the selected screenshot or its containing folders."""
    body = await req.json()
    ids = body.get("ids", [])
    if not ids:
        return JSONResponse({"ok": False, "error": "未选择截图"}, status_code=400)

    found_paths = []
    wanted = set(ids)
    for root, _, files in os.walk(SCREENSHOTS_DIR):
        for filename in files:
            if os.path.splitext(filename)[0] in wanted:
                found_paths.append(os.path.join(root, filename))

    if not found_paths:
        return JSONResponse({"ok": False, "error": "未找到截图文件"}, status_code=404)

    try:
        if len(found_paths) == 1:
            subprocess.run(["open", "-R", found_paths[0]], check=True, timeout=10)
            opened = 1
        else:
            folders = sorted({os.path.dirname(path) for path in found_paths})
            for folder in folders:
                subprocess.run(["open", folder], check=True, timeout=10)
            opened = len(folders)
        return {"ok": True, "opened": opened}
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return JSONResponse({"ok": False, "error": "无法打开访达"}, status_code=500)


# ── API: AI Analyze ─────────────────────────────────────────────────

@app.post("/api/analyze")
async def api_analyze(req: Request):
    """Run vision analysis on selected screenshots."""
    try:
        _require_key()
    except ValueError as e:
        return JSONResponse({"ok": False, "error": str(e)}, status_code=400)

    body = await req.json()
    ids = body.get("ids", [])

    if not ids:
        return JSONResponse({"ok": False, "error": "未选择截图"}, status_code=400)

    analysis = load_analysis()
    results = {}

    for sid in ids:
        # find the screenshot file
        found = None
        for root, _, files in os.walk(SCREENSHOTS_DIR):
            for f in files:
                if os.path.splitext(f)[0] == sid:
                    found = os.path.join(root, f)
                    break
            if found:
                break

        if not found:
            results[sid] = {"error": "文件未找到"}
            continue

        print(f"  🔍 分析中: {os.path.basename(found)} ...")
        try:
            result = analyze_screenshot(found)
            analysis[sid] = result
            results[sid] = result
            print(f"  ✓ 分析完成: {os.path.basename(found)}")
        except Exception as e:
            results[sid] = {"error": str(e)}
            print(f"  ✗ 分析失败: {e}")

    save_analysis(analysis)
    return {"ok": True, "results": results, "analysis": analysis}


# ── API: Custom folders ──────────────────────────────────────────────

@app.get("/api/folders")
async def api_list_folders():
    """List material folders backed by real directories."""
    folders = sync_material_folders()
    return list(folders.values())


@app.post("/api/folders")
async def api_create_folder(req: Request):
    """Create a material folder and its real directory."""
    body = await req.json()
    try:
        name = _validate_folder_name(body.get("name", ""))
    except ValueError as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

    folders = load_folders()
    if any(folder["name"] == name for folder in folders.values()) or os.path.exists(os.path.join(SCREENSHOTS_DIR, name)):
        return JSONResponse({"ok": False, "error": "同名素材文件夹已存在"}, status_code=409)
    fid = f"folder_{uuid.uuid4().hex[:8]}"
    folders[fid] = {
        "id": fid,
        "name": name,
        "screenshots": [],
        "created_at": datetime.now().isoformat(),
    }
    os.makedirs(_folder_path(folders[fid]), exist_ok=False)
    save_folders(folders)
    return {"ok": True, "folder": folders[fid]}


@app.put("/api/folders/{fid}")
async def api_update_folder(fid: str, req: Request):
    """Rename a material folder or physically move screenshots into/out of it."""
    folders = sync_material_folders()
    if fid not in folders:
        return JSONResponse({"ok": False, "error": "文件夹不存在"}, status_code=404)

    body = await req.json()
    folder = folders[fid]

    if "name" in body:
        try:
            name = _validate_folder_name(body.get("name", ""))
        except ValueError as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        if name != folder["name"]:
            if any(item["name"] == name for key, item in folders.items() if key != fid):
                return JSONResponse({"ok": False, "error": "同名素材文件夹已存在"}, status_code=409)
            old_path = _folder_path(folder)
            new_path = os.path.join(SCREENSHOTS_DIR, name)
            if os.path.exists(new_path):
                return JSONResponse({"ok": False, "error": "同名目录已存在"}, status_code=409)
            os.rename(old_path, new_path)
            folder["name"] = name

    current = list(dict.fromkeys(folder.get("screenshots", [])))
    if "add_screenshots" in body:
        ids = list(dict.fromkeys(sid for sid in body.get("add_screenshots", []) if sid))
        paths = {sid: _find_screenshot_path(sid) for sid in ids}
        missing = [sid for sid, path in paths.items() if not path]
        if missing:
            return JSONResponse({"ok": False, "error": f"有 {len(missing)} 张截图未找到"}, status_code=404)
        target_dir = _folder_path(folder)
        for sid, path in paths.items():
            target = os.path.join(target_dir, os.path.basename(path))
            if os.path.abspath(path) != os.path.abspath(target) and os.path.exists(target):
                return JSONResponse({"ok": False, "error": f"目标中已有同名图片: {os.path.basename(path)}"}, status_code=409)
        for other in folders.values():
            other["screenshots"] = [sid for sid in other.get("screenshots", []) if sid not in ids]
        for sid, path in paths.items():
            _move_screenshot(path, target_dir)
            if sid not in current:
                current.append(sid)
    if "remove_screenshots" in body:
        remove = set(body.get("remove_screenshots", []))
        for sid in remove:
            path = _find_screenshot_path(sid)
            if path and os.path.dirname(path) == _folder_path(folder):
                _move_screenshot(path, INBOX_DIR)
        current = [sid for sid in current if sid not in remove]

    folder["screenshots"] = current
    save_folders(folders)
    _remove_empty_screenshot_dirs()
    return {"ok": True, "folder": folder}


@app.delete("/api/folders/{fid}")
async def api_delete_folder(fid: str):
    """Delete a material folder and return its screenshots to New Screenshots."""
    folders = sync_material_folders()
    if fid in folders:
        folder = folders[fid]
        source_dir = _folder_path(folder)
        paths = [p for p in Path(source_dir).iterdir() if p.is_file() and _is_image_file(p)]
        for path in paths:
            target = os.path.join(INBOX_DIR, path.name)
            if os.path.exists(target):
                return JSONResponse({"ok": False, "error": f"新添加截图中已有同名图片: {path.name}"}, status_code=409)
        for path in paths:
            _move_screenshot(str(path), INBOX_DIR)
        del folders[fid]
        save_folders(folders)
        _remove_empty_screenshot_dirs()
    return {"ok": True}


# ── API: Projects ────────────────────────────────────────────────────

@app.get("/api/ai-settings")
async def api_get_ai_settings():
    return public_ai_settings()


@app.put("/api/ai-settings")
async def api_save_ai_settings(req: Request):
    body = await req.json()
    try:
        settings = save_ai_settings(
            body.get("provider", ""), body.get("model", ""), body.get("base_url", ""),
            api_key=body.get("api_key"), clear_key=bool(body.get("clear_key")),
        )
        return {"ok": True, "settings": settings}
    except (ValueError, RuntimeError) as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)


@app.post("/api/ai-settings/test")
async def api_test_ai_settings():
    try:
        test_image = os.path.join(os.path.dirname(__file__), "static", "icons", "com.tencent.mm.png")
        test_ai_connection(test_image)
        return {"ok": True}
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)


@app.get("/api/projects")
async def api_list_projects():
    """List all projects."""
    projects = load_projects()
    return list(projects.values())


@app.post("/api/projects")
async def api_create_project(req: Request):
    """Create a new project."""
    body = await req.json()
    name = body.get("name", "").strip()
    description = body.get("description", "").strip()

    if not name:
        return JSONResponse({"ok": False, "error": "项目名称不能为空"}, status_code=400)

    projects = load_projects()
    pid = f"proj_{uuid.uuid4().hex[:8]}"
    projects[pid] = {
        "id": pid,
        "name": name,
        "description": description,
        "screenshots": {},
        "analysis": None,
        "analysis_brief": None,
        "analysis_status": {"state": "draft", "processed": 0, "total": 0},
        "analysis_runs": [],
        "created_at": datetime.now().isoformat(),
    }
    save_projects(projects)
    return {"ok": True, "project": projects[pid]}


@app.put("/api/projects/{pid}")
async def api_update_project(pid: str, req: Request):
    """Update a project — add/remove screenshots, rename, etc."""
    projects = load_projects()
    if pid not in projects:
        return JSONResponse({"ok": False, "error": "项目不存在"}, status_code=404)

    body = await req.json()
    proj = projects[pid]
    screenshots_changed = False

    if "name" in body:
        proj["name"] = body["name"].strip()
    if "description" in body:
        proj["description"] = body["description"].strip()
    if "add_screenshots" in body:
        screenshots_changed = True
        for item in body["add_screenshots"]:
            sid = item["id"]
            proj["screenshots"][sid] = {
                "module": item.get("module", ""),
                "added_at": datetime.now().isoformat(),
            }
    if "remove_screenshots" in body:
        screenshots_changed = True
        for sid in body["remove_screenshots"]:
            proj["screenshots"].pop(sid, None)
    if "update_modules" in body:
        for item in body["update_modules"]:
            sid = item["id"]
            if sid in proj["screenshots"]:
                proj["screenshots"][sid]["module"] = item.get("module", "")

    if screenshots_changed and proj.get("analysis"):
        proj["analysis_status"] = {
            "state": "stale", "processed": 0, "total": len(proj["screenshots"]),
            "updated_at": datetime.now().isoformat(),
        }

    save_projects(projects)
    return {"ok": True, "project": proj}


@app.delete("/api/projects/{pid}")
async def api_delete_project(pid: str):
    """Delete a project."""
    projects = load_projects()
    if pid not in projects:
        return JSONResponse({"ok": False, "error": "项目不存在"}, status_code=404)

    del projects[pid]
    save_projects(projects)
    return {"ok": True}


@app.post("/api/projects/{pid}/dimensions")
async def api_suggest_project_dimensions(pid: str, req: Request):
    """Turn the required research question into dimensions for user confirmation."""
    projects = load_projects()
    if pid not in projects:
        return JSONResponse({"ok": False, "error": "项目不存在"}, status_code=404)
    project = projects[pid]
    body = await req.json()
    question = (body.get("question") or "").strip()
    context = (body.get("context") or "").strip()
    if len(question) < 4:
        return JSONResponse({"ok": False, "error": "请写下一个更具体的分析问题"}, status_code=400)
    if not project.get("screenshots"):
        return JSONResponse({"ok": False, "error": "项目中没有截图"}, status_code=400)
    try:
        settings = _require_key()
        metadata = load_screenshot_metadata()
        apps = sorted({metadata.get(sid, {}).get("app") for sid in project["screenshots"]
                       if metadata.get(sid, {}).get("app")})
        framework = suggest_dimensions(project["name"], question, context, apps, settings)
        brief = {"question": question, "context": context, "framework": framework,
                 "confirmed": False, "updated_at": datetime.now().isoformat()}
        project["analysis_brief"] = brief
        project["analysis_status"] = {"state": "dimensions_ready", "processed": 0,
                                      "total": len(project["screenshots"])}
        save_projects(projects)
        return {"ok": True, "brief": brief}
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)


def _set_analysis_status(pid, **values):
    def apply(project):
        project.setdefault("analysis_status", {}).update(values)
        project["analysis_status"]["updated_at"] = datetime.now().isoformat()
    update_project_record(pid, apply)


def _fact_signature(path, question, dimensions, settings):
    raw = json.dumps({"question": question, "dimensions": dimensions,
                      "mtime": os.path.getmtime(path), "provider": settings["provider"],
                      "model": settings["model"]}, ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()


def _sanitize_result_evidence(result, valid_ids):
    """Prevent model-generated evidence links from pointing at unknown screenshots."""
    def clean(item):
        item["evidence_ids"] = [sid for sid in item.get("evidence_ids", []) if sid in valid_ids]
    for row in result.get("comparison_board", []):
        for item in row.get("apps", []):
            clean(item)
    for item in result.get("key_findings", []):
        clean(item)
    for item in result.get("report", {}).get("recommendations", []):
        clean(item)
    return result


def _run_project_analysis(pid, run_id, brief, settings):
    try:
        project = load_projects().get(pid)
        if not project:
            return
        metadata = load_screenshot_metadata()
        indexed = load_analysis()
        dimensions = brief["framework"]["dimensions"]
        project_ids = list(project.get("screenshots", {}))
        requested_order = brief.get("screenshot_order") or project_ids
        ordered_ids = [sid for sid in requested_order if sid in project.get("screenshots", {})]
        ordered_ids.extend(sid for sid in project_ids if sid not in ordered_ids)
        items = [(sid, _find_screenshot_path(sid)) for sid in ordered_ids]
        items = [(sid, path) for sid, path in items if path]
        if not items:
            raise ValueError("未找到任何截图文件")
        _set_analysis_status(pid, state="analyzing", phase="evidence", processed=0,
                             total=len(items), failed=0, error=None, run_id=run_id)
        facts, failures = [], []
        cache = project.get("fact_cache", {})
        for index, (sid, path) in enumerate(items, 1):
            signature = _fact_signature(path, brief["question"], dimensions, settings)
            cached = cache.get(sid, {})
            try:
                if cached.get("signature") == signature and cached.get("fact"):
                    fact = cached["fact"]
                else:
                    fact = analyze_screenshot_evidence(
                        path, sid, metadata.get(sid, {}).get("app", ""), brief["question"],
                        dimensions, indexed.get(sid, {}).get("ocr_text", ""), settings,
                    )
                    fact["screenshot_id"] = sid
                    fact["app"] = metadata.get(sid, {}).get("app") or "未归类"
                    allowed_dimensions = {item.get("id") for item in dimensions}
                    fact["evidence"] = [item for item in fact.get("evidence", [])
                                        if item.get("dimension_id") in allowed_dimensions]
                    cache[sid] = {"signature": signature, "fact": fact,
                                  "analyzed_at": datetime.now().isoformat()}
                fact["sequence_index"] = index
                facts.append(fact)
            except Exception as exc:
                failures.append({"screenshot_id": sid, "error": str(exc)})
                print(f"  ✗ 截图分析失败 [{sid}]: {type(exc).__name__}: {exc}")

            def save_progress(current, processed=index):
                current["fact_cache"] = cache
                current.setdefault("analysis_status", {}).update({
                    "state": "analyzing", "phase": "evidence", "processed": processed,
                    "total": len(items), "failed": len(failures), "run_id": run_id,
                    "failed_items": failures[-10:],
                    "updated_at": datetime.now().isoformat(),
                })
            update_project_record(pid, save_progress)

        if not facts:
            first_error = failures[0]["error"] if failures else "未知错误"
            raise ValueError(f"所有截图都分析失败。首个错误：{first_error}")
        _set_analysis_status(pid, state="analyzing", phase="synthesis", processed=len(items),
                             failed=len(failures))
        result = synthesize_project(project["name"], brief["question"], brief.get("context", ""),
                                    brief["framework"], facts, settings)
        result = _sanitize_result_evidence(result, {item["screenshot_id"] for item in facts})
        completed_at = datetime.now().isoformat()
        result["meta"] = {"run_id": run_id, "provider": settings["provider"],
                          "model": settings["model"], "completed_at": completed_at,
                          "analyzed_count": len(facts), "failed_items": failures}
        result["facts"] = facts

        def finish(current):
            current["analysis"] = result
            current["analysis_brief"] = {**brief, "confirmed": True}
            runs = current.setdefault("analysis_runs", [])
            runs.insert(0, {"run_id": run_id, "completed_at": completed_at,
                            "question": brief["question"], "provider": settings["provider"],
                            "model": settings["model"], "analysis": result})
            current["analysis_runs"] = runs[:5]
            current["analysis_status"] = {
                "state": "complete", "phase": "complete", "processed": len(items),
                "total": len(items), "failed": len(failures), "run_id": run_id,
                "updated_at": datetime.now().isoformat(),
            }
        update_project_record(pid, finish)
    except Exception as exc:
        print(f"  ✗ 项目分析失败: {exc}")
        _set_analysis_status(pid, state="failed", phase="failed", error=str(exc), run_id=run_id,
                             failed_items=locals().get("failures", [])[-10:])


@app.post("/api/projects/{pid}/analyze")
async def api_analyze_project(pid: str, req: Request, background_tasks: BackgroundTasks):
    """Start evidence extraction and synthesis after dimensions are confirmed."""
    projects = load_projects()
    if pid not in projects:
        return JSONResponse({"ok": False, "error": "项目不存在"}, status_code=404)
    project = projects[pid]
    body = await req.json()
    brief = project.get("analysis_brief") or {}
    question = (body.get("question") or brief.get("question") or "").strip()
    context = (body.get("context") or brief.get("context") or "").strip()
    dimensions = body.get("dimensions") or brief.get("framework", {}).get("dimensions", [])
    screenshot_order = body.get("screenshot_order") or list(project.get("screenshots", {}))
    if len(question) < 4:
        return JSONResponse({"ok": False, "error": "分析问题为必填项"}, status_code=400)
    if not 1 <= len(dimensions) <= 8:
        return JSONResponse({"ok": False, "error": "请保留 1-8 个分析维度"}, status_code=400)
    project_ids = set(project.get("screenshots", {}))
    if set(screenshot_order) != project_ids or len(screenshot_order) != len(project_ids):
        return JSONResponse({"ok": False, "error": "截图顺序与项目内容不一致，请刷新后重试"}, status_code=400)
    if project.get("analysis_status", {}).get("state") == "analyzing":
        return JSONResponse({"ok": False, "error": "项目正在分析中"}, status_code=409)
    try:
        settings = _require_key()
    except ValueError as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
    framework = dict(brief.get("framework") or {})
    framework["dimensions"] = dimensions
    confirmed = {"question": question, "context": context, "framework": framework,
                 "screenshot_order": screenshot_order,
                 "confirmed": True, "updated_at": datetime.now().isoformat()}
    run_id = f"run_{uuid.uuid4().hex[:8]}"
    project["analysis_brief"] = confirmed
    project["analysis_status"] = {"state": "queued", "phase": "queued", "processed": 0,
                                  "total": len(project.get("screenshots", {})), "run_id": run_id}
    save_projects(projects)
    background_tasks.add_task(_run_project_analysis, pid, run_id, confirmed, settings)
    return {"ok": True, "run_id": run_id}


@app.get("/api/projects/{pid}/analysis-status")
async def api_project_analysis_status(pid: str):
    project = load_projects().get(pid)
    if not project:
        return JSONResponse({"ok": False, "error": "项目不存在"}, status_code=404)
    return {"ok": True, "status": project.get("analysis_status", {"state": "draft"}),
            "has_analysis": bool(project.get("analysis"))}


# ── API: Favorites & Notes ───────────────────────────────────────────

@app.post("/api/favorite")
async def api_toggle_favorite(req: Request):
    """Toggle favorite status for a screenshot."""
    body = await req.json()
    sid = body.get("id", "").strip()
    if not sid:
        return JSONResponse({"ok": False, "error": "缺少 id"}, status_code=400)

    with _ANALYSIS_WRITE_LOCK:
        analysis = load_analysis()
        entry = analysis.get(sid, {})
        entry["favorite"] = not entry.get("favorite", False)
        analysis[sid] = entry
        save_analysis(analysis)
    return {"ok": True, "id": sid, "favorite": entry["favorite"]}


@app.post("/api/note")
async def api_save_note(req: Request):
    """Save a note for a screenshot."""
    body = await req.json()
    sid = body.get("id", "").strip()
    note = body.get("note", "").strip()
    if not sid:
        return JSONResponse({"ok": False, "error": "缺少 id"}, status_code=400)

    analysis = load_analysis()
    entry = analysis.get(sid, {})
    entry["note"] = note
    if not note and "note" in entry:
        del entry["note"]
    analysis[sid] = entry
    save_analysis(analysis)
    return {"ok": True, "id": sid, "note": note}


# ── API: OCR & Search ───────────────────────────────────────────────

@app.post("/api/ocr")
async def api_ocr(req: Request):
    """Run OCR on selected screenshots and store the text."""
    body = await req.json()
    ids = body.get("ids", [])
    if not ids:
        return JSONResponse({"ok": False, "error": "未选择截图"}, status_code=400)

    if not _OCR_AVAILABLE:
        return JSONResponse({"ok": False, "error": "本机文字识别组件不可用"}, status_code=500)

    analysis = load_analysis()
    results = {}

    for sid in ids:
        found = None
        for root, _, files in os.walk(SCREENSHOTS_DIR):
            for f in files:
                if os.path.splitext(f)[0] == sid:
                    found = os.path.join(root, f)
                    break
            if found:
                break
        if not found:
            results[sid] = {"error": "文件未找到"}
            continue

        text = ocr_image(found)
        _save_ocr_result(sid, text)
        results[sid] = {"text": text}

    return {"ok": True, "results": results}


@app.get("/api/search")
async def api_search(q: str = ""):
    """Search screenshots by OCR text, note, source App, or material folder."""
    q = re.sub(r"\s+", "", q).casefold()
    if not q:
        return {"ids": [], "indexing": _OCR_INDEX_STATE["running"]}

    analysis = load_analysis()
    metadata = load_screenshot_metadata()
    folders = sync_material_folders()
    folder_by_name = {folder["name"]: folder for folder in folders.values()}
    results = []

    def match_screenshot(sid, app, folder_name):
        entry = analysis.get(sid, {})

        def contains(value):
            return q in re.sub(r"\s+", "", value or "").casefold()

        if contains(entry.get("ocr_text")):
            return True

        if contains(entry.get("note")):
            return True

        if contains(app):
            return True

        if contains(folder_name):
            return True

        if contains(sid):
            return True

        return False

    for root, _, files in os.walk(SCREENSHOTS_DIR):
        for fname in sorted(files):
            if not _is_image_file(fname):
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, SCREENSHOTS_DIR)
            parts = rel.split(os.sep)
            stem = os.path.splitext(fname)[0]
            folder_name = parts[0] if len(parts) >= 2 and parts[0] in folder_by_name else None
            app_name = metadata.get(stem, {}).get("app")
            if match_screenshot(stem, app_name, folder_name):
                results.append(stem)

    return {
        "ids": results,
        "indexing": _OCR_INDEX_STATE["running"],
        "processed": _OCR_INDEX_STATE["processed"],
        "total": _OCR_INDEX_STATE["total"],
        "error": _OCR_INDEX_STATE["error"],
    }


@app.post("/api/ocr/all")
async def api_ocr_all():
    """Run OCR on all screenshots that don't have OCR text yet."""
    if not _OCR_AVAILABLE:
        return JSONResponse({"ok": False, "error": "本机文字识别组件不可用"}, status_code=500)

    analysis = load_analysis()
    to_ocr = []

    valid_ext = (".png", ".jpg", ".jpeg", ".webp", ".heic")
    for root, _, files in os.walk(SCREENSHOTS_DIR):
        for f in files:
            if os.path.splitext(f)[1].lower() in valid_ext:
                sid = os.path.splitext(f)[0]
                entry = analysis.get(sid, {})
                if not entry.get("ocr_indexed_at"):
                    to_ocr.append((sid, os.path.join(root, f)))

    processed = 0
    for sid, fpath in to_ocr:
        text = ocr_image(fpath)
        _save_ocr_result(sid, text)
        processed += 1
        if processed % 10 == 0:
            print(f"  OCR 进度: {processed}/{len(to_ocr)}")

    return {"ok": True, "processed": processed, "total": len(to_ocr)}


# ── API: Stats ──────────────────────────────────────────────────────

@app.get("/api/stats")
async def api_stats():
    """Get overview stats without coupling source Apps to disk folders."""
    apps = {}
    metadata = load_screenshot_metadata()
    all_images = [p for p in Path(SCREENSHOTS_DIR).rglob("*") if p.is_file() and _is_image_file(p)]
    for path in all_images:
        app_name = metadata.get(path.stem, {}).get("app")
        if app_name:
            bucket = apps.setdefault(app_name, {})
            bucket["_total"] = bucket.get("_total", 0) + 1

    inbox_count = len([p for p in Path(INBOX_DIR).iterdir() if p.is_file() and _is_image_file(p)])
    organized_count = len(all_images) - inbox_count
    analysis = load_analysis()
    analyzed_count = len([k for k, v in analysis.items() if v and not v.get("error")])

    return {
        "apps": apps,
        "inbox_count": inbox_count,
        "organized_count": organized_count,
        "analyzed_count": analyzed_count,
    }


# ── Android ADB Capture ────────────────────────────────────────────

ADB_PATH = os.path.expanduser("~/platform-tools/adb")
TOUCH_DEVICE = "/dev/input/event7"
# goodix_ts raw coordinate range: X 0-14400, Y 0-32000
# Screen: 1080x2400 → scale factors
TOUCH_SCALE_X = 14400 / 1080
TOUCH_SCALE_Y = 32000 / 2400


def adb_tap(x, y):
    """Tap at screen coordinates using sendevent (bypasses INJECT_EVENTS permission)."""
    rx = int(x * TOUCH_SCALE_X)
    ry = int(y * TOUCH_SCALE_Y)
    # Touch down
    subprocess.run([ADB_PATH, "shell", "sendevent", TOUCH_DEVICE, "3", "57", "1"], capture_output=True)      # ABS_MT_TRACKING_ID = 1
    subprocess.run([ADB_PATH, "shell", "sendevent", TOUCH_DEVICE, "3", "53", str(rx)], capture_output=True)  # ABS_MT_POSITION_X
    subprocess.run([ADB_PATH, "shell", "sendevent", TOUCH_DEVICE, "3", "54", str(ry)], capture_output=True)  # ABS_MT_POSITION_Y
    subprocess.run([ADB_PATH, "shell", "sendevent", TOUCH_DEVICE, "0", "0", "0"], capture_output=True)       # SYN_REPORT
    # Touch up
    subprocess.run([ADB_PATH, "shell", "sendevent", TOUCH_DEVICE, "3", "57", "-1"], capture_output=True)     # ABS_MT_TRACKING_ID = -1
    subprocess.run([ADB_PATH, "shell", "sendevent", TOUCH_DEVICE, "0", "0", "0"], capture_output=True)       # SYN_REPORT


def adb_screenshot():
    """Take a screenshot from connected Android device, save to inbox."""
    try:
        result = subprocess.run([ADB_PATH, "exec-out", "screencap", "-p"],
                                capture_output=True, timeout=10)
        if result.returncode != 0 or not result.stdout:
            return None, "ADB 截图失败"
        return result.stdout, None
    except FileNotFoundError:
        return None, "ADB 未安装，请安装 Android Platform Tools"
    except subprocess.TimeoutExpired:
        return None, "ADB 连接超时，请检查设备"


def adb_current_app():
    """Get the current foreground app name on Android."""
    try:
        # Get package name of the foreground window
        result = subprocess.run(
            [ADB_PATH, "shell", "dumpsys", "window"],
            capture_output=True, timeout=5, text=True
        )
        for line in result.stdout.split("\n"):
            if "mCurrentFocus" in line or "mFocusedApp" in line:
                # Extract package name like com.tencent.mm
                m = re.search(r'(\S+)/(\S+)', line)
                if m:
                    pkg = m.group(1)
                    # Map common package names to app names
                    PKG_MAP = {
                        "com.tencent.mm": "微信",
                        "com.tencent.mobileqq": "QQ",
                        "com.ss.android.ugc.aweme": "抖音",
                        "com.xingin.xhs": "小红书",
                        "com.sina.weibo": "微博",
                        "com.taobao.taobao": "淘宝",
                        "com.jingdong.app.mall": "京东",
                        "com.sankuai.meituan": "美团",
                        "com.ctrip.android.viewhome": "携程旅行",
                        "com.alibaba.android.rimet": "钉钉",
                        "com.ss.android.lark": "飞书",
                        "com.eg.android.AlipayGphone": "支付宝",
                        "com.kuaishou": "快手",
                        "tv.danmaku.bili": "B站",
                        "com.xunmeng.pinduoduo": "拼多多",
                        "com.meituan.grocery": "小象超市",
                        "com.dianping.v1": "大众点评",
                    "com.taobao.idlefish": "闲鱼",
                    "com.netease.cloudmusic": "网易云音乐",
                    "com.hunantv.imgo.activity": "芒果TV",
                    }
                    return PKG_MAP.get(pkg, pkg.split(".")[-1])
        return "安卓截图"
    except Exception:
        return "安卓截图"


@app.post("/api/capture/android")
async def api_capture_android(req: Request = None):
    """Capture screenshot from connected Android device."""
    data, error = adb_screenshot()
    if error:
        return JSONResponse({"ok": False, "error": error}, status_code=500)

    # Auto-detect app name from device
    app_name = adb_current_app()

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    if app_name and app_name != "安卓截图":
        name = f"{app_name}_{ts}.png"
    else:
        name = f"{ts}.png"
    path = os.path.join(INBOX_DIR, name)

    with open(path, "wb") as f:
        f.write(data)
    remember_source_app(path, app_name)

    print(f"  📱 安卓截图: {name}")
    _schedule_ocr(path)

    return {"ok": True, "filename": name, "path": os.path.relpath(path, SCREENSHOTS_DIR), "app": app_name}


# ── Capture Paths ──────────────────────────────────────────────────

PATHS_FILE = os.path.join(DATA_DIR, "capture_paths.json")


def load_paths():
    if not os.path.exists(PATHS_FILE):
        return {}
    with open(PATHS_FILE, "r") as f:
        return json.load(f)


def save_paths(data):
    with open(PATHS_FILE, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


@app.get("/api/capture/paths")
async def api_list_paths():
    return list(load_paths().values())


@app.post("/api/capture/paths")
async def api_create_path(req: Request):
    """Save a capture path with steps like [{"action":"tap","x":540,"y":1200},{"action":"wait","sec":2},{"action":"screenshot"}]"""
    body = await req.json()
    name = body.get("name", "").strip()
    app = body.get("app", "").strip()
    steps = body.get("steps", [])

    if not name or not steps:
        return JSONResponse({"ok": False, "error": "缺少名称或步骤"}, status_code=400)

    paths = load_paths()
    pid = f"path_{uuid.uuid4().hex[:8]}"
    paths[pid] = {
        "id": pid,
        "name": name,
        "app": app,
        "steps": steps,
        "created_at": datetime.now().isoformat(),
    }
    save_paths(paths)
    return {"ok": True, "path": paths[pid]}


@app.delete("/api/capture/paths/{pid}")
async def api_delete_path(pid: str):
    paths = load_paths()
    if pid in paths:
        del paths[pid]
        save_paths(paths)
    return {"ok": True}


@app.post("/api/capture/paths/{pid}/run")
async def api_run_path(pid: str):
    """Execute a saved capture path: replay taps/swipes and capture screenshots."""
    paths = load_paths()
    path = paths.get(pid)
    if not path:
        return JSONResponse({"ok": False, "error": "路径不存在"}, status_code=404)

    results = []
    for i, step in enumerate(path["steps"]):
        action = step.get("action", "")
        try:
            if action == "tap":
                x, y = step["x"], step["y"]
                subprocess.run(
                    [ADB_PATH, "shell", "input", "tap", str(x), str(y)],
                    capture_output=True, timeout=5)
                print(f"  👆 tap {x},{y}")
                time.sleep(1.5)

            elif action == "swipe":
                x1, y1, x2, y2 = step["x1"], step["y1"], step["x2"], step["y2"]
                subprocess.run(
                    [ADB_PATH, "shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), "300"],
                    capture_output=True, timeout=5)
                print(f"  👆 swipe {x1},{y1} → {x2},{y2}")
                time.sleep(1.5)  # Wait for scroll animation

            elif action == "wait":
                time.sleep(min(step.get("sec", 2), 10))

            elif action == "screenshot":
                data, err = adb_screenshot()
                if data:
                    app_name = adb_current_app()
                    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
                    name = f"{app_name}_{ts}.png" if app_name and app_name != "安卓截图" else f"{ts}.png"
                    filepath = os.path.join(INBOX_DIR, name)
                    with open(filepath, "wb") as f:
                        f.write(data)
                    remember_source_app(filepath, app_name)
                    _schedule_ocr(filepath)
                    results.append({"step": i, "filename": name, "app": app_name})
                    print(f"  📸 {name}")

            elif action == "back":
                subprocess.run([ADB_PATH, "shell", "input", "keyevent", "4"], capture_output=True, timeout=5)
                time.sleep(0.5)

            elif action == "home":
                subprocess.run([ADB_PATH, "shell", "input", "keyevent", "3"], capture_output=True, timeout=5)
                time.sleep(0.5)

        except Exception as e:
            print(f"  ⚠ 步骤 {i} 失败: {e}")

    return {"ok": True, "results": results, "total": len(results)}


# ── Continuous Capture ─────────────────────────────────────────────

_cont_capture_running = False
_cont_capture_count = 0
_cont_capture_last_data = None
_cont_capture_mode = "interval"  # "interval" or "change"


def _listen_volume_stop():
    """Monitor volume down key events, return True if 3 quick presses detected."""
    try:
        proc = subprocess.Popen(
            [ADB_PATH, "shell", "getevent", "-l", "/dev/input/event2"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
        presses = []
        start = time.time()
        while time.time() - start < 60:  # timeout after 60s
            line = proc.stdout.readline()
            if not line:
                break
            if "KEY_VOLUMEDOWN" in line and "DOWN" in line:
                presses.append(time.time())
                # Keep only last 3 presses within 2 seconds
                presses = [t for t in presses if time.time() - t < 2]
                if len(presses) >= 3:
                    proc.kill()
                    return True
            if not _cont_capture_running:
                break
        proc.kill()
    except Exception:
        pass
    return False


def _image_similarity(data1, data2):
    """Compare two PNG images by sampling center pixels. Returns 0-1 similarity."""
    try:
        from io import BytesIO
        img1 = Image.open(BytesIO(data1))
        img2 = Image.open(BytesIO(data2))
        w, h = img1.size
        # Sample center 60% of the image (skip status bar + nav bar)
        left, top = int(w * 0.05), int(h * 0.1)
        right, bottom = int(w * 0.95), int(h * 0.85)
        region1 = img1.crop((left, top, right, bottom))
        region2 = img2.crop((left, top, right, bottom))
        # Resize to 100x100 for fast comparison
        region1 = region1.resize((100, 100), Image.LANCZOS)
        region2 = region2.resize((100, 100), Image.LANCZOS)
        pixels1 = list(region1.getdata())
        pixels2 = list(region2.getdata())
        same = sum(1 for a, b in zip(pixels1, pixels2) if a == b)
        return same / len(pixels1)
    except Exception:
        return 0


def _cont_capture_loop(interval=2.5):
    """Background thread: capture screenshots, skip duplicates."""
    global _cont_capture_running, _cont_capture_count, _cont_capture_last_data, _cont_capture_mode

    last_capture_time = 0
    while _cont_capture_running:
        try:
            data, _ = adb_screenshot()
            if data:
                is_new = True
                if _cont_capture_last_data:
                    sim = _image_similarity(_cont_capture_last_data, data)
                    if _cont_capture_mode == "interval":
                        is_new = sim < 0.92
                    else:
                        # Change mode: capture when clearly different, min 2s gap
                        is_new = sim < 0.80 and (time.time() - last_capture_time > 2.0)

                if is_new:
                    _cont_capture_last_data = data
                    last_capture_time = time.time()
                    app_name = adb_current_app()
                    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
                    name = f"{app_name}_{ts}.png"
                    filepath = os.path.join(INBOX_DIR, name)
                    with open(filepath, "wb") as f:
                        f.write(data)
                    remember_source_app(filepath, app_name)
                    _schedule_ocr(filepath)
                    _cont_capture_count += 1
                    print(f"  📸 [{_cont_capture_count}] {name}")
        except Exception as e:
            print(f"  ⚠ 连续采集错误: {e}")

        for _ in range(int(interval * 10)):
            if not _cont_capture_running:
                break
            time.sleep(0.1)


@app.post("/api/capture/start")
async def api_capture_start(req: Request = None):
    """Start capture mode. mode: 'interval' (default) or 'change' (hands-free, screen-change triggered)."""
    global _cont_capture_running, _cont_capture_count, _cont_capture_last_data, _cont_capture_mode
    if _cont_capture_running:
        return {"ok": False, "error": "已在采集中"}

    body = {}
    if req:
        try:
            body = await req.json()
        except Exception:
            pass
    _cont_capture_mode = body.get("mode", "interval")

    _cont_capture_running = True
    _cont_capture_count = 0
    _cont_capture_last_data = None

    interval = 1.5 if _cont_capture_mode == "change" else 2.5
    t = threading.Thread(target=_cont_capture_loop, args=(interval,), daemon=True)
    t.start()

    msg = "免提采集已开启（屏幕变化时自动截图）" if _cont_capture_mode == "change" else "开始连续采集"
    return {"ok": True, "message": msg, "mode": _cont_capture_mode}


@app.post("/api/capture/stop")
async def api_capture_stop():
    """Stop capture mode."""
    global _cont_capture_running, _cont_capture_count
    if not _cont_capture_running:
        return {"ok": False, "error": "未在采集中"}
    _cont_capture_running = False
    count = _cont_capture_count
    _cont_capture_count = 0
    _cont_capture_last_data = None
    return {"ok": True, "captured": count}


@app.get("/api/capture/status")
async def api_capture_status():
    """Check if an Android device is connected."""
    try:
        result = subprocess.run([ADB_PATH, "devices"], capture_output=True, timeout=5, text=True)
        lines = result.stdout.strip().split("\n")[1:]
        devices = [l.split("\t")[0] for l in lines if "\tdevice" in l]
        return {"ok": True, "connected": len(devices) > 0, "count": len(devices), "cont_captured": _cont_capture_count, "cont_running": _cont_capture_running}
    except Exception:
        return {"ok": True, "connected": False, "count": 0, "cont_captured": 0, "cont_running": False}


# ── Static files ────────────────────────────────────────────────────

@app.get("/screenshots/{path:path}")
async def serve_screenshot(path: str):
    """Serve screenshot files."""
    full = os.path.join(SCREENSHOTS_DIR, path)
    if os.path.isfile(full):
        return FileResponse(full)
    return JSONResponse({"error": "not found"}, status_code=404)


# ── Pages ───────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def page_index():
    return HTMLResponse(open("static/index.html").read())


@app.get("/upload", response_class=HTMLResponse)
async def page_upload():
    return HTMLResponse(open("static/upload.html").read())


# ── Static files ────────────────────────────────────────────────────

static_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
app.mount("/static", StaticFiles(directory=static_dir), name="static")

# ── Startup ─────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    local_ip = get_local_ip()
    print()
    print("  ╔══════════════════════════════════════════╗")
    print("  ║       DesignPeek / 设计透视              ║")
    print("  ╚══════════════════════════════════════════╝")
    print()
    print(f"  📱 iPhone 快捷指令 URL:")
    print(f"     http://{local_ip}:{PORT}/api/upload")
    print()
    print(f"  💻 Mac 管理页面:")
    print(f"     http://localhost:{PORT}")
    print()
    print(f"  按 Ctrl+C 停止服务")
    print()

    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
