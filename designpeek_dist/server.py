#!/usr/bin/env python3
"""DesignPeek — 竞品截图整理分析工具"""

import base64
import hashlib
import json
import io
import math
import os
import re
import secrets
import shutil
import socket
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from fastapi import BackgroundTasks, FastAPI, File, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image
import qrcode

from config import (
    ANALYSIS_FILE,
    BASE_DIR,
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
    observe_screenshot,
    suggest_dimensions,
    synthesize_project,
    synthesize_quick_brief,
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
_CONVERSATIONS_WRITE_LOCK = threading.Lock()
_MOBILE_UPLOAD_LOCK = threading.Lock()
_CANVASES_WRITE_LOCK = threading.Lock()
_OCR_AVAILABLE = _PYOBJC_OCR_AVAILABLE or bool(shutil.which("swiftc") or shutil.which("xcrun"))
_OCR_INDEX_STATE = {"running": False, "processed": 0, "total": 0, "error": None}
_MOBILE_UPLOAD_SESSIONS = {}
MOBILE_UPLOAD_SESSION_TTL = 30 * 60
MOBILE_UPLOAD_MAX_BYTES = 30 * 1024 * 1024


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
CONVERSATIONS_FILE = os.path.join(DATA_DIR, "conversations.json")
OBSERVATIONS_FILE = os.path.join(DATA_DIR, "screenshot_observations.json")
CANVASES_FILE = os.path.join(DATA_DIR, "canvases.json")
# 用户上传的字体文件独立存放，不与 screenshots 素材目录混在一起
FONTS_DIR = os.path.join(BASE_DIR, "fonts")
FONTS_INDEX_FILE = os.path.join(DATA_DIR, "fonts.json")
FONT_EXTENSIONS = (".ttf", ".otf", ".woff", ".woff2")
FONT_MAX_BYTES = 20 * 1024 * 1024


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

for local_file in (CONVERSATIONS_FILE, OBSERVATIONS_FILE):
    if not os.path.exists(local_file):
        with open(local_file, "w") as f:
            json.dump({}, f)


def _default_canvas_document():
    now = datetime.now().isoformat()
    return {
        "version": 1,
        "active_canvas_id": "canvas_default",
        "canvases": {
            "canvas_default": {
                "id": "canvas_default",
                "name": "默认画布",
                "created_at": now,
                "updated_at": now,
                "viewport": {"x": 0, "y": 0, "scale": 1},
                "elements": [],
            }
        },
    }


def load_canvas_document():
    if not os.path.exists(CANVASES_FILE):
        return _default_canvas_document()
    try:
        with open(CANVASES_FILE, "r") as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get("canvases"), dict):
            raise ValueError("画布文件结构无效")
        return data
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"  ⚠ 画布数据读取失败，使用空白默认画布: {exc}")
        return _default_canvas_document()


def save_canvas_document(data):
    temp_path = f"{CANVASES_FILE}.tmp"
    with open(temp_path, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp_path, CANVASES_FILE)


# ── 字体素材 ─────────────────────────────────────────────────────────
# 字体文件存在 fonts/，索引存在 data/fonts.json；两者都与 screenshots 素材目录分开。

_FONTS_WRITE_LOCK = threading.Lock()


def ensure_fonts_dir():
    os.makedirs(FONTS_DIR, exist_ok=True)


def load_fonts():
    ensure_fonts_dir()
    if not os.path.exists(FONTS_INDEX_FILE):
        return []
    try:
        with open(FONTS_INDEX_FILE, "r") as f:
            data = json.load(f)
        if not isinstance(data, list):
            raise ValueError("字体索引结构无效")
        return [item for item in data if isinstance(item, dict) and item.get("id")]
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"  ⚠ 字体索引读取失败，按空列表处理: {exc}")
        return []


def save_fonts(fonts):
    ensure_fonts_dir()
    temp_path = f"{FONTS_INDEX_FILE}.tmp"
    with open(temp_path, "w") as f:
        json.dump(fonts, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp_path, FONTS_INDEX_FILE)


def _public_font(record):
    filename = str(record.get("filename") or "")
    return {
        "id": record.get("id"),
        "family": record.get("family") or "",
        "original_name": record.get("original_name") or "",
        "size": record.get("size") or 0,
        "uploaded_at": record.get("uploaded_at") or "",
        "url": f"/fonts/{filename}",
    }


def _unique_font_family(desired, fonts):
    """展示名同时用作 FontFace 注册名，重名会让后加载的字体覆盖前面的，所以要去重。"""
    taken = {item.get("family") for item in fonts}
    family = desired
    suffix = 2
    while family in taken:
        family = f"{desired} {suffix}"
        suffix += 1
    return family


def _finite_number(value, default, minimum, maximum):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(number):
        return default
    return max(minimum, min(maximum, number))


def _sanitize_canvas(canvas_id, payload, existing=None):
    existing = existing or {}
    viewport = payload.get("viewport") if isinstance(payload.get("viewport"), dict) else {}
    raw_elements = payload.get("elements") if isinstance(payload.get("elements"), list) else []
    elements = []
    seen_ids = set()
    for raw in raw_elements[:2000]:
        if not isinstance(raw, dict):
            continue
        element_id = str(raw.get("id") or "")[:100]
        if not element_id or element_id in seen_ids:
            continue
        geometry = {
            "id": element_id,
            "x": _finite_number(raw.get("x"), 0, -10_000_000, 10_000_000),
            "y": _finite_number(raw.get("y"), 0, -10_000_000, 10_000_000),
            "width": _finite_number(raw.get("width"), 240, 40, 20_000),
            "height": _finite_number(raw.get("height"), 320, 40, 20_000),
            "rotation": _finite_number(raw.get("rotation"), 0, -360, 360),
            "z_index": int(_finite_number(raw.get("z_index"), len(elements), 0, 100_000)),
        }
        if raw.get("type") == "image":
            screenshot_id = str(raw.get("screenshot_id") or "")[:255]
            if not screenshot_id:
                continue
            elements.append({**geometry, "type": "image", "screenshot_id": screenshot_id})
        elif raw.get("type") == "text":
            # 字体元素：文字内容 + 渲染字体，样式细节由前端内置预设决定，不在这里校验
            text = str(raw.get("text") or "")[:200]
            if not text:
                continue
            elements.append({
                **geometry,
                "type": "text",
                "text": text,
                "font_family": str(raw.get("font_family") or "")[:120],
                "style_key": str(raw.get("style_key") or "")[:40],
                "font_id": str(raw.get("font_id") or "")[:100],
            })
        else:
            continue
        seen_ids.add(element_id)
    now = datetime.now().isoformat()
    return {
        "id": canvas_id,
        "name": str(payload.get("name") or existing.get("name") or "默认画布")[:80],
        "created_at": existing.get("created_at") or now,
        "updated_at": now,
        "viewport": {
            "x": _finite_number(viewport.get("x"), 0, -10_000_000, 10_000_000),
            "y": _finite_number(viewport.get("y"), 0, -10_000_000, 10_000_000),
            "scale": _finite_number(viewport.get("scale"), 1, 0.05, 8),
        },
        "elements": elements,
    }


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


def _load_json_object(path):
    with open(path, "r") as f:
        return json.load(f)


def _save_json_object(path, data):
    with open(path, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_conversations():
    return _load_json_object(CONVERSATIONS_FILE)


def save_conversations(data):
    _save_json_object(CONVERSATIONS_FILE, data)


def update_conversation_record(cid, updater):
    with _CONVERSATIONS_WRITE_LOCK:
        conversations = load_conversations()
        if cid not in conversations:
            return None
        updater(conversations[cid])
        save_conversations(conversations)
        return conversations[cid]


def _legacy_conversations():
    """Expose old analysis projects without modifying their saved data."""
    legacy = {}
    for pid, project in load_projects().items():
        ids = list(project.get("screenshots", {}))
        if not ids:
            continue
        cid = f"legacy_{pid}"
        brief = project.get("analysis_brief") or {}
        legacy[cid] = {
            "id": cid, "title": project.get("name") or "旧分析", "screenshot_ids": ids,
            "project_id": pid, "question": brief.get("question", ""),
            "angle": "", "mode": "quick", "screenshot_order": ids,
            "status": project.get("analysis_status") or {"state": "draft"},
            "result": project.get("analysis"), "created_at": project.get("created_at"),
            "updated_at": project.get("created_at"), "legacy": True,
        }
    return legacy


def all_conversations():
    merged = _legacy_conversations()
    merged.update(load_conversations())
    return merged


def migrate_legacy_analysis_projects():
    """Split old analysis records from their containers without touching image files."""
    with _PROJECTS_WRITE_LOCK, _CONVERSATIONS_WRITE_LOCK:
        projects = load_projects()
        conversations = load_conversations()
        changed = False
        for pid, project in projects.items():
            if project.get("parent_id") is not None:
                project["parent_id"] = None
                changed = True
            screenshot_ids = list(project.get("screenshots", {}))
            if not screenshot_ids:
                continue
            cid = f"conv_migrated_{pid.removeprefix('proj_')}"
            if cid not in conversations:
                brief = project.get("analysis_brief") or {}
                conversations[cid] = {
                    "id": cid,
                    "title": project.get("name") or "旧分析",
                    "screenshot_ids": screenshot_ids,
                    "project_id": pid,
                    "question": brief.get("question", ""),
                    "angle": "",
                    "mode": "quick",
                    "screenshot_order": screenshot_ids,
                    "sort_order": None,
                    "status": project.get("analysis_status") or {"state": "draft"},
                    "result": project.get("analysis"),
                    "runs": project.get("analysis_runs") or [],
                    "created_at": project.get("created_at") or datetime.now().isoformat(),
                    "updated_at": project.get("created_at") or datetime.now().isoformat(),
                    "migrated_from": pid,
                }
            project["screenshots"] = {}
            project["analysis"] = None
            project["analysis_brief"] = None
            project["analysis_status"] = {"state": "draft", "processed": 0, "total": 0}
            project["analysis_runs"] = []
            changed = True
        if changed:
            save_conversations(conversations)
            save_projects(projects)


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
    ensure_fonts_dir()
    migrate_legacy_analysis_projects()
    start_ocr_backfill()


def get_local_ip():
    """Get the local network IP address."""
    for interface in ("en0", "en1", "en2"):
        try:
            result = subprocess.run(
                ["ipconfig", "getifaddr", interface], capture_output=True,
                text=True, timeout=2,
            )
            candidate = result.stdout.strip()
            if candidate and not candidate.startswith("169.254."):
                return candidate
        except (FileNotFoundError, subprocess.TimeoutExpired):
            break
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def _mobile_upload_session(token):
    with _MOBILE_UPLOAD_LOCK:
        session = _MOBILE_UPLOAD_SESSIONS.get(token)
        if not session:
            return None
        if session["expires_at"] <= time.time():
            _MOBILE_UPLOAD_SESSIONS.pop(token, None)
            return None
        return dict(session)


def _mobile_upload_public_session(session):
    return {
        "token": session["token"],
        "url": session["url"],
        "expires_at": session["expires_at"],
        "received": session["received"],
        "last_filename": session.get("last_filename"),
    }


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


@app.post("/api/mobile-upload/session")
async def api_create_mobile_upload_session():
    token = secrets.token_urlsafe(24)
    local_ip = get_local_ip()
    session = {
        "token": token,
        "url": f"http://{local_ip}:{PORT}/upload?token={token}",
        "expires_at": time.time() + MOBILE_UPLOAD_SESSION_TTL,
        "received": 0,
        "last_filename": None,
    }
    with _MOBILE_UPLOAD_LOCK:
        now = time.time()
        expired = [key for key, value in _MOBILE_UPLOAD_SESSIONS.items()
                   if value["expires_at"] <= now]
        for key in expired:
            _MOBILE_UPLOAD_SESSIONS.pop(key, None)
        _MOBILE_UPLOAD_SESSIONS[token] = session
    return {"ok": True, "session": _mobile_upload_public_session(session)}


@app.get("/api/mobile-upload/session/{token}")
async def api_get_mobile_upload_session(token: str):
    session = _mobile_upload_session(token)
    if not session:
        return JSONResponse({"ok": False, "error": "连接已过期"}, status_code=404)
    return {"ok": True, "session": _mobile_upload_public_session(session)}


@app.delete("/api/mobile-upload/session/{token}")
async def api_delete_mobile_upload_session(token: str):
    with _MOBILE_UPLOAD_LOCK:
        _MOBILE_UPLOAD_SESSIONS.pop(token, None)
    return {"ok": True}


@app.get("/api/mobile-upload/session/{token}/qr")
async def api_mobile_upload_qr(token: str):
    session = _mobile_upload_session(token)
    if not session:
        return JSONResponse({"ok": False, "error": "连接已过期"}, status_code=404)
    image = qrcode.make(session["url"])
    output = io.BytesIO()
    image.save(output, format="PNG")
    output.seek(0)
    return StreamingResponse(output, media_type="image/png",
                             headers={"Cache-Control": "no-store"})


@app.post("/api/mobile-upload/{token}")
async def api_mobile_upload(token: str, file: UploadFile = File(...)):
    if not _mobile_upload_session(token):
        return JSONResponse({"ok": False, "error": "连接已过期，请在电脑上重新打开二维码"}, status_code=403)
    content = await file.read()
    if not content:
        return JSONResponse({"ok": False, "error": "图片内容为空"}, status_code=400)
    if len(content) > MOBILE_UPLOAD_MAX_BYTES:
        return JSONResponse({"ok": False, "error": "单张图片不能超过 30 MB"}, status_code=413)

    ext = os.path.splitext(file.filename or "screenshot.png")[1] or ".png"
    name = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}{ext}"
    target = os.path.join(INBOX_DIR, name)
    try:
        path = save_uploaded_image(content, target, file.filename, file.content_type or "")
    except Exception as exc:
        return JSONResponse({"ok": False, "error": f"图片保存失败：{exc}"}, status_code=400)

    name = os.path.basename(path)
    _schedule_ocr(path)
    with _MOBILE_UPLOAD_LOCK:
        session = _MOBILE_UPLOAD_SESSIONS.get(token)
        if session:
            session["received"] += 1
            session["last_filename"] = name
    print(f"  ✓ 手机相册上传: {name}  ({len(content) / 1024:.0f} KB)")
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


# ── API: Canvas workspace ───────────────────────────────────────────

@app.get("/api/canvases")
async def api_list_canvases():
    """Return the versioned multi-canvas document."""
    return load_canvas_document()


@app.get("/api/canvases/{canvas_id}")
async def api_get_canvas(canvas_id: str):
    document = load_canvas_document()
    canvas = document.get("canvases", {}).get(canvas_id)
    if canvas is None:
        return JSONResponse({"ok": False, "error": "画布不存在"}, status_code=404)
    return canvas


@app.put("/api/canvases/{canvas_id}")
async def api_save_canvas(canvas_id: str, req: Request):
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", canvas_id):
        return JSONResponse({"ok": False, "error": "画布 ID 不可用"}, status_code=400)
    payload = await req.json()
    if not isinstance(payload, dict):
        return JSONResponse({"ok": False, "error": "画布数据无效"}, status_code=400)
    with _CANVASES_WRITE_LOCK:
        document = load_canvas_document()
        existing = document.setdefault("canvases", {}).get(canvas_id)
        canvas = _sanitize_canvas(canvas_id, payload, existing)
        document["version"] = 1
        document["active_canvas_id"] = canvas_id
        document["canvases"][canvas_id] = canvas
        save_canvas_document(document)
    return {"ok": True, "canvas": canvas}


# ── API: Fonts ───────────────────────────────────────────────────────

@app.get("/api/fonts")
async def api_list_fonts():
    """Return user-uploaded fonts. Built-in sample fonts live in the frontend."""
    return {"ok": True, "fonts": [_public_font(item) for item in load_fonts()]}


@app.post("/api/fonts/upload")
async def api_upload_font(file: UploadFile = File(...)):
    """Receive a font file from the local file picker or a drag-and-drop."""
    original = os.path.basename(file.filename or "font.ttf").strip() or "font.ttf"
    ext = os.path.splitext(original)[1].lower()
    if ext not in FONT_EXTENSIONS:
        return JSONResponse(
            {"ok": False, "error": f"只支持 {'、'.join(FONT_EXTENSIONS)} 格式的字体文件"},
            status_code=400,
        )

    content = await file.read()
    if not content:
        return JSONResponse({"ok": False, "error": "字体文件是空的"}, status_code=400)
    if len(content) > FONT_MAX_BYTES:
        limit_mb = FONT_MAX_BYTES // (1024 * 1024)
        return JSONResponse({"ok": False, "error": f"字体文件超过 {limit_mb} MB"}, status_code=400)

    with _FONTS_WRITE_LOCK:
        ensure_fonts_dir()
        font_id = f"font_{uuid.uuid4().hex[:10]}"
        stored_name = f"{font_id}{ext}"
        try:
            with open(os.path.join(FONTS_DIR, stored_name), "wb") as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno())
        except OSError as exc:
            return JSONResponse({"ok": False, "error": f"字体保存失败: {exc}"}, status_code=500)

        fonts = load_fonts()
        display_name = os.path.splitext(original)[0].strip()[:80] or "未命名字体"
        record = {
            "id": font_id,
            "family": _unique_font_family(display_name, fonts),
            "filename": stored_name,
            "original_name": original[:120],
            "size": len(content),
            "uploaded_at": datetime.now().isoformat(),
        }
        fonts.append(record)
        save_fonts(fonts)

    print(f"  ✓ 收到字体: {record['family']}  ({len(content) / 1024:.0f} KB)")
    return {"ok": True, "font": _public_font(record)}


@app.delete("/api/fonts/{font_id}")
async def api_delete_font(font_id: str):
    with _FONTS_WRITE_LOCK:
        fonts = load_fonts()
        target = next((item for item in fonts if item.get("id") == font_id), None)
        if target is None:
            return JSONResponse({"ok": False, "error": "字体不存在"}, status_code=404)
        save_fonts([item for item in fonts if item.get("id") != font_id])
    # 索引已经更新，文件删不掉也不影响使用，只可能是权限问题
    try:
        os.remove(os.path.join(FONTS_DIR, str(target.get("filename") or "")))
    except OSError:
        pass
    return {"ok": True}


@app.get("/fonts/{path:path}")
async def serve_font(path: str):
    """Serve uploaded font files."""
    root = os.path.realpath(FONTS_DIR)
    full = os.path.realpath(os.path.join(root, path))
    if full.startswith(root + os.sep) and os.path.isfile(full):
        return FileResponse(full)
    return JSONResponse({"error": "not found"}, status_code=404)


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
    deleted_set = set(deleted)

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

    conversations = load_conversations()
    conversations_changed = False
    for conversation in conversations.values():
        before = conversation.get("screenshot_ids", [])
        after = [sid for sid in before if sid not in deleted_set]
        if len(after) != len(before):
            conversation["screenshot_ids"] = after
            conversation["screenshot_order"] = [sid for sid in conversation.get("screenshot_order", [])
                                                if sid not in deleted_set]
            if conversation.get("result"):
                conversation["status"] = {"state": "stale", "processed": 0,
                                          "total": len(after),
                                          "updated_at": datetime.now().isoformat()}
            conversation["updated_at"] = datetime.now().isoformat()
            conversations_changed = True
    if conversations_changed:
        save_conversations(conversations)

    observations = _load_json_object(OBSERVATIONS_FILE)
    if any(sid in observations for sid in deleted):
        for sid in deleted:
            observations.pop(sid, None)
        _save_json_object(OBSERVATIONS_FILE, observations)

    folders = load_folders()
    folders_changed = False
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
    conversations = all_conversations()
    result = []
    for project in projects.values():
        item = dict(project)
        item["conversation_count"] = sum(
            1 for conversation in conversations.values()
            if conversation.get("project_id") == project.get("id")
        )
        result.append(item)
    return result


@app.post("/api/projects")
async def api_create_project(req: Request):
    """Create a new project."""
    body = await req.json()
    name = body.get("name", "").strip()
    description = body.get("description", "").strip()

    if not name:
        return JSONResponse({"ok": False, "error": "文件夹名称不能为空"}, status_code=400)

    projects = load_projects()
    pid = f"proj_{uuid.uuid4().hex[:8]}"
    projects[pid] = {
        "id": pid,
        "name": name,
        "description": description,
        "parent_id": None,
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
    if "parent_id" in body:
        parent_id = body.get("parent_id")
        if parent_id == pid or parent_id and parent_id not in projects:
            return JSONResponse({"ok": False, "error": "上级项目不存在"}, status_code=400)
        ancestor = parent_id
        while ancestor:
            if ancestor == pid:
                return JSONResponse({"ok": False, "error": "不能移动到自己的下级项目"}, status_code=400)
            ancestor = projects.get(ancestor, {}).get("parent_id")
        proj["parent_id"] = parent_id
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
    for project in projects.values():
        if project.get("parent_id") == pid:
            project["parent_id"] = None
    save_projects(projects)
    conversations = load_conversations()
    changed = False
    for conversation in conversations.values():
        if conversation.get("project_id") == pid:
            conversation["project_id"] = None
            conversation["updated_at"] = datetime.now().isoformat()
            changed = True
    if changed:
        save_conversations(conversations)
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


# ── API: Analysis conversations ─────────────────────────────────────

def _observation_signature(path, settings):
    raw = json.dumps({"mtime": os.path.getmtime(path), "provider": settings["provider"],
                      "model": settings["model"], "schema": 1}, sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()


def _sanitize_quick_result(result, observations):
    labels = {item["screenshot_id"]: item.get("scene_label") or "截图证据"
              for item in observations}
    for finding in result.get("findings", [])[:3]:
        evidence = []
        for item in finding.get("evidence", []):
            sid = item.get("screenshot_id")
            if sid in labels:
                evidence.append({"screenshot_id": sid, "scene_label": labels[sid]})
        finding["evidence"] = evidence
    details = result.setdefault("details", {})
    details["per_image"] = [
        {"screenshot_id": item["screenshot_id"],
         "scene_label": labels[item["screenshot_id"]],
         "observation": item.get("visible_summary", "")}
        for item in observations
    ]
    result["findings"] = result.get("findings", [])[:3]
    result["perspectives"] = result.get("perspectives", [])[:3]
    result["priority_actions"] = result.get("priority_actions", [])[:3]
    result["evidence_gaps"] = result.get("evidence_gaps", [])[:3]
    return result


def _set_conversation_status(cid, **values):
    def apply(conversation):
        conversation.setdefault("status", {}).update(values)
        conversation["status"]["updated_at"] = datetime.now().isoformat()
        conversation["updated_at"] = datetime.now().isoformat()
    update_conversation_record(cid, apply)


def _run_conversation_analysis(cid, run_id, question, angle, mode, ordered_ids, settings):
    failures = []
    try:
        conversation = load_conversations().get(cid)
        if not conversation:
            return
        metadata = load_screenshot_metadata()
        indexed = load_analysis()
        ids = ordered_ids if mode == "journey" else list(conversation.get("screenshot_ids", []))
        items = [(sid, _find_screenshot_path(sid)) for sid in ids]
        items = [(sid, path) for sid, path in items if path]
        if not items:
            raise ValueError("未找到任何截图文件")
        _set_conversation_status(cid, state="analyzing", phase="evidence", processed=0,
                                 total=len(items), failed=0, error=None, run_id=run_id)
        cache = _load_json_object(OBSERVATIONS_FILE)
        observations = [None] * len(items)
        pending = []
        for index, (sid, path) in enumerate(items):
            signature = _observation_signature(path, settings)
            cached = cache.get(sid, {})
            if cached.get("signature") == signature and cached.get("observation"):
                observations[index] = cached["observation"]
            else:
                pending.append((index, sid, path, signature))

        def inspect_one(entry):
            index, sid, path, signature = entry
            observation = observe_screenshot(
                path, sid, metadata.get(sid, {}).get("app", ""),
                indexed.get(sid, {}).get("ocr_text", ""), settings,
            )
            observation["screenshot_id"] = sid
            observation["app"] = metadata.get(sid, {}).get("app") or "未归类"
            return index, sid, signature, observation

        completed = len(items) - len(pending)
        if pending:
            with ThreadPoolExecutor(max_workers=min(3, len(pending))) as pool:
                futures = {pool.submit(inspect_one, entry): entry for entry in pending}
                for future in as_completed(futures):
                    entry = futures[future]
                    try:
                        index, sid, signature, observation = future.result()
                        observations[index] = observation
                        cache[sid] = {"signature": signature, "observation": observation,
                                      "observed_at": datetime.now().isoformat()}
                    except Exception as exc:
                        failures.append({"screenshot_id": entry[1], "error": str(exc)})
                        print(f"  ✗ 截图观察失败 [{entry[1]}]: {type(exc).__name__}: {exc}")
                    completed += 1
                    _save_json_object(OBSERVATIONS_FILE, cache)
                    _set_conversation_status(cid, state="analyzing", phase="evidence",
                                             processed=completed, total=len(items),
                                             failed=len(failures), failed_items=failures[-10:])

        observations = [item for item in observations if item]
        if not observations:
            first_error = failures[0]["error"] if failures else "未知错误"
            raise ValueError(f"所有截图都分析失败。首个错误：{first_error}")
        for index, observation in enumerate(observations, 1):
            observation["sequence_index"] = index if mode == "journey" else None
        _set_conversation_status(cid, state="analyzing", phase="synthesis",
                                 processed=len(items), failed=len(failures))
        result = synthesize_quick_brief(question, angle, observations,
                                        ordered=mode == "journey", settings=settings)
        result = _sanitize_quick_result(result, observations)
        completed_at = datetime.now().isoformat()
        result["meta"] = {"run_id": run_id, "provider": settings["provider"],
                          "model": settings["model"], "completed_at": completed_at,
                          "analyzed_count": len(observations), "failed_items": failures}

        def finish(current):
            current["question"] = question
            current["angle"] = angle
            current["mode"] = mode
            current["screenshot_order"] = ordered_ids if mode == "journey" else []
            current["result"] = result
            if current.get("title") in ("新分析", "未命名分析"):
                current["title"] = question[:24]
            current["status"] = {"state": "complete", "phase": "complete",
                                 "processed": len(items), "total": len(items),
                                 "failed": len(failures), "run_id": run_id,
                                 "updated_at": completed_at}
            current["updated_at"] = completed_at
            runs = current.setdefault("runs", [])
            runs.insert(0, {"run_id": run_id, "question": question,
                            "completed_at": completed_at, "result": result})
            current["runs"] = runs[:5]
        update_conversation_record(cid, finish)
    except Exception as exc:
        print(f"  ✗ 分析对话失败 [{cid}]: {exc}")
        _set_conversation_status(cid, state="failed", phase="failed", error=str(exc),
                                 run_id=run_id, failed_items=failures[-10:])


@app.get("/api/conversations")
async def api_list_conversations():
    return sorted(all_conversations().values(),
                  key=lambda item: (
                      item.get("sort_order") is None,
                      -(item.get("sort_order") or 0),
                      item.get("updated_at") or item.get("created_at") or "",
                  ), reverse=True)


@app.post("/api/conversations")
async def api_create_conversation(req: Request):
    body = await req.json()
    ids = list(dict.fromkeys(body.get("screenshot_ids") or []))
    valid_ids = {sid for sid in ids if _find_screenshot_path(sid)}
    ids = [sid for sid in ids if sid in valid_ids]
    if not ids:
        return JSONResponse({"ok": False, "error": "请至少选择一张截图"}, status_code=400)
    now = datetime.now().isoformat()
    cid = f"conv_{uuid.uuid4().hex[:10]}"
    conversation = {"id": cid, "title": "新分析", "screenshot_ids": ids,
                    "project_id": body.get("project_id"), "question": "", "angle": "",
                    "mode": "quick", "screenshot_order": [], "sort_order": None,
                    "status": {"state": "draft", "processed": 0, "total": len(ids)},
                    "result": None, "runs": [], "created_at": now, "updated_at": now}
    conversations = load_conversations()
    conversations[cid] = conversation
    save_conversations(conversations)
    return {"ok": True, "conversation": conversation}


@app.put("/api/conversations/{cid}")
async def api_update_conversation(cid: str, req: Request):
    conversations = load_conversations()
    if cid not in conversations:
        return JSONResponse({"ok": False, "error": "分析对话不存在"}, status_code=404)
    body = await req.json()
    conversation = conversations[cid]
    if "title" in body:
        title = (body.get("title") or "").strip()
        if not title:
            return JSONResponse({"ok": False, "error": "名称不能为空"}, status_code=400)
        conversation["title"] = title
    if "project_id" in body:
        project_id = body.get("project_id")
        if project_id and project_id not in load_projects():
            return JSONResponse({"ok": False, "error": "文件夹不存在"}, status_code=400)
        conversation["project_id"] = project_id
    if "sort_order" in body:
        sort_order = body.get("sort_order")
        if sort_order is not None and not isinstance(sort_order, (int, float)):
            return JSONResponse({"ok": False, "error": "排序值无效"}, status_code=400)
        conversation["sort_order"] = sort_order
    conversation["updated_at"] = datetime.now().isoformat()
    save_conversations(conversations)
    return {"ok": True, "conversation": conversation}


@app.delete("/api/conversations/{cid}")
async def api_delete_conversation(cid: str):
    conversations = load_conversations()
    if cid not in conversations:
        return JSONResponse({"ok": False, "error": "分析对话不存在"}, status_code=404)
    del conversations[cid]
    save_conversations(conversations)
    return {"ok": True}


@app.post("/api/conversations/{cid}/analyze")
async def api_analyze_conversation(cid: str, req: Request, background_tasks: BackgroundTasks):
    conversations = load_conversations()
    if cid not in conversations:
        return JSONResponse({"ok": False, "error": "分析对话不存在"}, status_code=404)
    conversation = conversations[cid]
    body = await req.json()
    question = (body.get("question") or "").strip()
    angle = (body.get("angle") or "").strip()
    mode = "journey" if angle == "还原关键操作路径" else "quick"
    if len(question) < 4:
        return JSONResponse({"ok": False, "error": "请写下你想借鉴或验证的问题"}, status_code=400)
    ids = list(conversation.get("screenshot_ids", []))
    ordered_ids = body.get("screenshot_order") or ids
    if mode == "journey" and (set(ordered_ids) != set(ids) or len(ordered_ids) != len(ids)):
        return JSONResponse({"ok": False, "error": "截图顺序与对话附件不一致"}, status_code=400)
    if conversation.get("status", {}).get("state") in ("queued", "analyzing"):
        return JSONResponse({"ok": False, "error": "这条分析正在进行中"}, status_code=409)
    try:
        settings = _require_key()
    except ValueError as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
    run_id = f"run_{uuid.uuid4().hex[:8]}"
    conversation["question"] = question
    conversation["angle"] = angle
    conversation["mode"] = mode
    conversation["status"] = {"state": "queued", "phase": "queued", "processed": 0,
                              "total": len(ids), "run_id": run_id}
    conversation["updated_at"] = datetime.now().isoformat()
    save_conversations(conversations)
    background_tasks.add_task(_run_conversation_analysis, cid, run_id, question, angle,
                              mode, ordered_ids, settings)
    return {"ok": True, "run_id": run_id}


@app.get("/api/conversations/{cid}/analysis-status")
async def api_conversation_analysis_status(cid: str):
    conversation = all_conversations().get(cid)
    if not conversation:
        return JSONResponse({"ok": False, "error": "分析对话不存在"}, status_code=404)
    return {"ok": True, "status": conversation.get("status", {"state": "draft"}),
            "has_result": bool(conversation.get("result"))}


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
