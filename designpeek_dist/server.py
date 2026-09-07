#!/usr/bin/env python3
"""DesignPeek — 竞品截图整理分析工具"""

import base64
import json
import os
import re
import socket
import subprocess
import time
import uuid
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, File, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image

from config import (
    ANALYSIS_FILE,
    AI_PROVIDER,
    DATA_DIR,
    HOST,
    INBOX_DIR,
    PAGE_TYPES,
    PORT,
    PROJECTS_FILE,
    SCREENSHOTS_DIR,
)
from analyzer import analyze_project, analyze_screenshot, _require_key

# OCR via macOS Vision framework
try:
    import Quartz
    import Vision
    import Foundation
    _OCR_AVAILABLE = True
except ImportError:
    _OCR_AVAILABLE = False


import threading


def _ocr_async(filepath: str):
    """Run OCR in background thread and save result."""
    text = ocr_image(filepath)
    if not text:
        return
    sid = os.path.splitext(os.path.basename(filepath))[0]
    analysis = load_analysis()
    entry = analysis.get(sid, {})
    entry["ocr_text"] = text
    analysis[sid] = entry
    save_analysis(analysis)


def _schedule_ocr(filepath: str):
    """Fire-and-forget OCR in a background thread."""
    t = threading.Thread(target=_ocr_async, args=(filepath,), daemon=True)
    t.start()


def ocr_image(filepath: str) -> str:
    """Extract text from an image using macOS Vision framework."""
    if not _OCR_AVAILABLE:
        return ""

    try:
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


def load_analysis():
    with open(ANALYSIS_FILE, "r") as f:
        return json.load(f)


def save_analysis(data):
    with open(ANALYSIS_FILE, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_projects():
    with open(PROJECTS_FILE, "r") as f:
        return json.load(f)


def save_projects(data):
    with open(PROJECTS_FILE, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_folders():
    with open(FOLDERS_FILE, "r") as f:
        return json.load(f)


def save_folders(data):
    with open(FOLDERS_FILE, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


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
        dest_dir = os.path.join(SCREENSHOTS_DIR, app_name)
        os.makedirs(dest_dir, exist_ok=True)
        path = os.path.join(dest_dir, name)
    else:
        name = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}.png"
        path = os.path.join(INBOX_DIR, name)

    path = save_uploaded_image(content, path, name, req.headers.get("content-type", ""))
    name = os.path.basename(path)

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

    # Inbox screenshots
    for f in sorted(Path(INBOX_DIR).iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
        if f.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp", ".heic"):
            rel = os.path.relpath(f, SCREENSHOTS_DIR)
            results.append({
                "id": f.stem,
                "path": rel,
                "status": "inbox",
                "app": None,
                "page_type": None,
                "analysis": analysis.get(f.stem),
                "mtime": f.stat().st_mtime,
            })

    # Organized screenshots
    for root, dirs, files in os.walk(SCREENSHOTS_DIR):
        if "_inbox" in root:
            continue
        for fname in sorted(files):
            if os.path.splitext(fname)[1].lower() not in (".png", ".jpg", ".jpeg", ".webp", ".heic"):
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, SCREENSHOTS_DIR)
            parts = rel.split(os.sep)
            app_name = parts[0] if len(parts) >= 2 else None
            page_type = parts[1] if len(parts) >= 3 else None
            stem = os.path.splitext(fname)[0]
            results.append({
                "id": stem,
                "path": rel,
                "status": "organized",
                "app": app_name,
                "page_type": page_type,
                "analysis": analysis.get(stem),
                "mtime": os.path.getmtime(fpath),
            })

    results.sort(key=lambda x: x["mtime"], reverse=True)
    return results[:limit]


# ── API: Classify screenshots ────────────────────────────────────────

@app.post("/api/classify")
async def api_classify(req: Request):
    """Move screenshots from inbox to organized folders."""
    body = await req.json()
    ids = body.get("ids", [])
    app_name = body.get("app", "").strip()
    page_type = body.get("page_type", "").strip()

    if not ids or not app_name or not page_type:
        return JSONResponse({"ok": False, "error": "缺少参数"}, status_code=400)

    moved = []
    for sid in ids:
        for f in Path(INBOX_DIR).iterdir():
            if f.stem == sid:
                # Extract capture date from EXIF
                date_str = datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y%m%d_%H%M%S")
                try:
                    img = Image.open(f)
                    exif = img._getexif()
                    if exif:
                        for tag, value in exif.items():
                            if tag == 36867:  # DateTimeOriginal
                                date_str = value.replace(":", "").replace(" ", "_")
                                break
                except Exception:
                    pass

                ext = f.suffix
                new_name = f"{app_name}_{page_type}_{date_str}{ext}"
                dest_dir = os.path.join(SCREENSHOTS_DIR, app_name, page_type)
                os.makedirs(dest_dir, exist_ok=True)
                dest = os.path.join(dest_dir, new_name)
                os.rename(str(f), dest)
                moved.append({"id": sid, "name": new_name})
                break

    return {"ok": True, "moved": moved}


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
                if os.path.splitext(f)[0] == sid:
                    os.remove(os.path.join(root, f))
                    deleted.append(sid)
                    break
            else:
                continue
            break

    # Clean up empty dirs
    for root, dirs, files in os.walk(SCREENSHOTS_DIR, topdown=False):
        if root != SCREENSHOTS_DIR and root != INBOX_DIR:
            if not os.listdir(root):
                os.rmdir(root)

    # Also remove from analysis
    analysis = load_analysis()
    for sid in deleted:
        analysis.pop(sid, None)
    save_analysis(analysis)

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
    """List custom screenshot folders. Folders store references only."""
    folders = load_folders()
    return list(folders.values())


@app.post("/api/folders")
async def api_create_folder(req: Request):
    """Create a custom screenshot folder."""
    body = await req.json()
    name = body.get("name", "").strip()
    if not name:
        return JSONResponse({"ok": False, "error": "文件夹名称不能为空"}, status_code=400)

    folders = load_folders()
    fid = f"folder_{uuid.uuid4().hex[:8]}"
    folders[fid] = {
        "id": fid,
        "name": name,
        "screenshots": [],
        "created_at": datetime.now().isoformat(),
    }
    save_folders(folders)
    return {"ok": True, "folder": folders[fid]}


@app.put("/api/folders/{fid}")
async def api_update_folder(fid: str, req: Request):
    """Rename a folder or add/remove screenshot references."""
    folders = load_folders()
    if fid not in folders:
        return JSONResponse({"ok": False, "error": "文件夹不存在"}, status_code=404)

    body = await req.json()
    folder = folders[fid]

    if "name" in body:
        name = body.get("name", "").strip()
        if not name:
            return JSONResponse({"ok": False, "error": "文件夹名称不能为空"}, status_code=400)
        folder["name"] = name

    current = list(dict.fromkeys(folder.get("screenshots", [])))
    if "add_screenshots" in body:
        for sid in body.get("add_screenshots", []):
            if sid and sid not in current:
                current.append(sid)
    if "remove_screenshots" in body:
        remove = set(body.get("remove_screenshots", []))
        current = [sid for sid in current if sid not in remove]

    folder["screenshots"] = current
    save_folders(folders)
    return {"ok": True, "folder": folder}


@app.delete("/api/folders/{fid}")
async def api_delete_folder(fid: str):
    """Delete a custom folder only. Screenshot files are preserved."""
    folders = load_folders()
    if fid in folders:
        del folders[fid]
        save_folders(folders)
    return {"ok": True}


# ── API: Projects ────────────────────────────────────────────────────

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

    if "name" in body:
        proj["name"] = body["name"].strip()
    if "description" in body:
        proj["description"] = body["description"].strip()
    if "add_screenshots" in body:
        for item in body["add_screenshots"]:
            sid = item["id"]
            proj["screenshots"][sid] = {
                "module": item.get("module", ""),
                "added_at": datetime.now().isoformat(),
            }
    if "remove_screenshots" in body:
        for sid in body["remove_screenshots"]:
            proj["screenshots"].pop(sid, None)
    if "update_modules" in body:
        for item in body["update_modules"]:
            sid = item["id"]
            if sid in proj["screenshots"]:
                proj["screenshots"][sid]["module"] = item.get("module", "")

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


@app.post("/api/projects/{pid}/analyze")
async def api_analyze_project(pid: str):
    """Run cross-platform competitive analysis on all screenshots in a project."""
    try:
        _require_key()
    except ValueError as e:
        return JSONResponse({"ok": False, "error": str(e)}, status_code=400)

    projects = load_projects()
    if pid not in projects:
        return JSONResponse({"ok": False, "error": "项目不存在"}, status_code=404)

    proj = projects[pid]
    if not proj["screenshots"]:
        return JSONResponse({"ok": False, "error": "项目中没有截图"}, status_code=400)

    # Find all screenshot files
    image_paths = []
    for sid in proj["screenshots"]:
        found = None
        for root, _, files in os.walk(SCREENSHOTS_DIR):
            for f in files:
                if os.path.splitext(f)[0] == sid:
                    found = os.path.join(root, f)
                    break
            if found:
                break
        if found:
            image_paths.append(found)
        else:
            print(f"  ⚠ 截图未找到: {sid}")

    if not image_paths:
        return JSONResponse({"ok": False, "error": "未找到任何截图文件"}, status_code=400)

    print(f"  🔍 项目分析中: {proj['name']} ({len(image_paths)} 张截图)...")

    try:
        result = analyze_project(image_paths, proj["name"])
        proj["analysis"] = result
        save_projects(projects)

        # Write screenshot_tags back to individual screenshot analysis
        tags = result.get("screenshot_tags", {})
        if tags:
            analysis = load_analysis()
            # Map filename → sid
            path_to_sid = {os.path.basename(p): os.path.splitext(os.path.basename(p))[0] for p in image_paths}
            for filename, touchpoint in tags.items():
                sid = path_to_sid.get(filename)
                if sid:
                    existing = analysis.get(sid, {})
                    existing["page_type"] = touchpoint
                    existing["source"] = "project_analysis"
                    analysis[sid] = existing
            save_analysis(analysis)

        print(f"  ✓ 项目分析完成: {proj['name']}")
        return {"ok": True, "analysis": result}
    except Exception as e:
        print(f"  ✗ 项目分析失败: {e}")
        return JSONResponse({"ok": False, "error": str(e)}, status_code=500)


# ── API: Favorites & Notes ───────────────────────────────────────────

@app.post("/api/favorite")
async def api_toggle_favorite(req: Request):
    """Toggle favorite status for a screenshot."""
    body = await req.json()
    sid = body.get("id", "").strip()
    if not sid:
        return JSONResponse({"ok": False, "error": "缺少 id"}, status_code=400)

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
        return JSONResponse({"ok": False, "error": "OCR 模块未安装，请运行: pip install pyobjc-framework-Vision"}, status_code=500)

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
        entry = analysis.get(sid, {})
        entry["ocr_text"] = text
        analysis[sid] = entry
        results[sid] = {"text": text}

    save_analysis(analysis)
    return {"ok": True, "results": results}


@app.get("/api/search")
async def api_search(q: str = ""):
    """Search screenshots by OCR text, note, or app name."""
    q = q.strip().lower()
    if not q:
        return []

    analysis = load_analysis()
    results = []
    valid_ext = (".png", ".jpg", ".jpeg", ".webp", ".heic")

    def match_screenshot(sid, path_rel, status, app, page_type, mtime):
        entry = analysis.get(sid, {})

        # Search in OCR text
        ocr = (entry.get("ocr_text") or "").lower()
        if q in ocr:
            return True

        # Search in note
        note = (entry.get("note") or "").lower()
        if q in note:
            return True

        # Search in app name
        if app and q in app.lower():
            return True

        # Search in page_type
        if page_type and q in page_type.lower():
            return True

        return False

    # Inbox
    for f in sorted(Path(INBOX_DIR).iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
        if f.suffix.lower() in valid_ext:
            if match_screenshot(f.stem, os.path.relpath(f, SCREENSHOTS_DIR), "inbox", None, None, f.stat().st_mtime):
                results.append(f.stem)

    # Organized
    for root, dirs, files in os.walk(SCREENSHOTS_DIR):
        if "_inbox" in root:
            continue
        for fname in sorted(files):
            if os.path.splitext(fname)[1].lower() not in valid_ext:
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, SCREENSHOTS_DIR)
            parts = rel.split(os.sep)
            app_name = parts[0] if len(parts) >= 2 else None
            page_type = parts[1] if len(parts) >= 3 else None
            stem = os.path.splitext(fname)[0]
            if match_screenshot(stem, rel, "organized", app_name, page_type, os.path.getmtime(fpath)):
                results.append(stem)

    return results


@app.post("/api/ocr/all")
async def api_ocr_all():
    """Run OCR on all screenshots that don't have OCR text yet."""
    if not _OCR_AVAILABLE:
        return JSONResponse({"ok": False, "error": "OCR 模块未安装"}, status_code=500)

    analysis = load_analysis()
    to_ocr = []

    valid_ext = (".png", ".jpg", ".jpeg", ".webp", ".heic")
    for root, _, files in os.walk(SCREENSHOTS_DIR):
        for f in files:
            if os.path.splitext(f)[1].lower() in valid_ext:
                sid = os.path.splitext(f)[0]
                entry = analysis.get(sid, {})
                if not entry.get("ocr_text"):
                    to_ocr.append((sid, os.path.join(root, f)))

    processed = 0
    for sid, fpath in to_ocr:
        text = ocr_image(fpath)
        entry = analysis.get(sid, {})
        entry["ocr_text"] = text
        analysis[sid] = entry
        processed += 1
        if processed % 10 == 0:
            print(f"  OCR 进度: {processed}/{len(to_ocr)}")

    save_analysis(analysis)
    return {"ok": True, "processed": processed, "total": len(to_ocr)}


# ── API: Stats ──────────────────────────────────────────────────────

@app.get("/api/stats")
async def api_stats():
    """Get overview stats: apps and counts."""
    apps = {}
    valid_ext = (".png", ".jpg", ".jpeg", ".webp", ".heic")

    for root, dirs, files in os.walk(SCREENSHOTS_DIR):
        if "_inbox" in root:
            continue
        parts = os.path.relpath(root, SCREENSHOTS_DIR).split(os.sep)
        if len(parts) == 1 and parts[0] != ".":
            # Top-level app dir: screenshots/{app}/
            count = len([f for f in files if os.path.splitext(f)[1].lower() in valid_ext])
            if count:
                apps.setdefault(parts[0], {})["_total"] = count
        elif len(parts) >= 2:
            # Subdir: screenshots/{app}/{page_type}/
            app_name = parts[0]
            page_type = parts[1]
            count = len([f for f in files if os.path.splitext(f)[1].lower() in valid_ext])
            if count:
                apps.setdefault(app_name, {})[page_type] = count

    inbox_count = len([
        f for f in os.listdir(INBOX_DIR)
        if os.path.splitext(f)[1].lower() in valid_ext
    ])

    # Count organized and analyzed
    organized_count = sum(
        apps[a].get("_total", 0) + sum(v for k, v in apps[a].items() if k != "_total")
        for a in apps
    )
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
        dest_dir = os.path.join(SCREENSHOTS_DIR, app_name)
        os.makedirs(dest_dir, exist_ok=True)
        path = os.path.join(dest_dir, name)
    else:
        name = f"{ts}.png"
        path = os.path.join(INBOX_DIR, name)

    with open(path, "wb") as f:
        f.write(data)

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
                    dest_dir = os.path.join(SCREENSHOTS_DIR, app_name) if app_name and app_name != "安卓截图" else INBOX_DIR
                    os.makedirs(dest_dir, exist_ok=True)
                    filepath = os.path.join(dest_dir, name)
                    with open(filepath, "wb") as f:
                        f.write(data)
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
                    dest_dir = os.path.join(SCREENSHOTS_DIR, app_name) if app_name and app_name != "安卓截图" else INBOX_DIR
                    os.makedirs(dest_dir, exist_ok=True)
                    filepath = os.path.join(dest_dir, name)
                    with open(filepath, "wb") as f:
                        f.write(data)
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
