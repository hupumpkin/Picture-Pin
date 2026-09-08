"""Local AI provider settings with macOS Keychain-backed secrets."""

import json
import os
import platform
import subprocess

from config import (
    AI_PROVIDER,
    ANTHROPIC_API_KEY,
    ANTHROPIC_BASE_URL,
    DATA_DIR,
    GEMINI_API_KEY,
    OPENAI_API_KEY,
    OPENAI_BASE_URL,
)


SETTINGS_FILE = os.path.join(DATA_DIR, "ai_settings.json")
KEYCHAIN_SERVICE = "DesignPeek AI"
PROVIDERS = {
    "gemini": {"label": "Google Gemini", "default_model": "gemini-2.5-flash"},
    "claude": {"label": "Anthropic Claude", "default_model": "claude-sonnet-5"},
    "openai": {"label": "OpenAI / 兼容接口", "default_model": "gpt-4.1-mini"},
}


def _env_key(provider):
    return {
        "gemini": GEMINI_API_KEY,
        "claude": ANTHROPIC_API_KEY,
        "openai": OPENAI_API_KEY,
    }.get(provider, "")


def _env_base_url(provider):
    return {"claude": ANTHROPIC_BASE_URL, "openai": OPENAI_BASE_URL}.get(provider, "")


def _keychain_available():
    return platform.system() == "Darwin" and os.path.exists("/usr/bin/security")


def _read_keychain(provider):
    if not _keychain_available():
        return ""
    result = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
         "-a", provider, "-w"], capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def _write_keychain(provider, api_key):
    if not _keychain_available():
        raise RuntimeError("当前系统不支持 macOS 钥匙串，请继续使用 .env 配置 Key")
    result = subprocess.run(
        ["/usr/bin/security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE,
         "-a", provider, "-w", api_key], capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Key 保存失败")


def _delete_keychain(provider):
    if _keychain_available():
        subprocess.run(
            ["/usr/bin/security", "delete-generic-password", "-s", KEYCHAIN_SERVICE,
             "-a", provider], capture_output=True, text=True,
        )


def load_ai_settings(include_key=False):
    saved = {}
    if os.path.exists(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE, "r") as f:
                saved = json.load(f)
        except (json.JSONDecodeError, OSError):
            saved = {}
    provider = saved.get("provider", AI_PROVIDER)
    if provider not in PROVIDERS:
        provider = "gemini"
    env_model = {"gemini": "GEMINI_MODEL", "claude": "ANTHROPIC_MODEL", "openai": "OPENAI_MODEL"}[provider]
    keychain_key = _read_keychain(provider)
    api_key = keychain_key or _env_key(provider)
    settings = {
        "provider": provider,
        "provider_label": PROVIDERS[provider]["label"],
        "model": saved.get("model") or os.environ.get(env_model, PROVIDERS[provider]["default_model"]),
        "base_url": saved.get("base_url", _env_base_url(provider)),
        "key_configured": bool(api_key),
        "key_source": "keychain" if keychain_key else ("env" if api_key else ""),
        "key_preview": f"••••{api_key[-4:]}" if api_key else "",
    }
    if include_key:
        settings["api_key"] = api_key
    return settings


def save_ai_settings(provider, model, base_url="", api_key=None, clear_key=False):
    if provider not in PROVIDERS:
        raise ValueError("不支持的 AI 服务商")
    payload = {
        "provider": provider,
        "model": (model or "").strip() or PROVIDERS[provider]["default_model"],
        "base_url": (base_url or "").strip(),
    }
    if clear_key:
        _delete_keychain(provider)
    elif api_key is not None and api_key.strip():
        _write_keychain(provider, api_key.strip())
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(SETTINGS_FILE, "w") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    return load_ai_settings()


def public_ai_settings():
    settings = load_ai_settings()
    settings["providers"] = [{"id": key, **value} for key, value in PROVIDERS.items()]
    settings["keychain_available"] = _keychain_available()
    return settings
