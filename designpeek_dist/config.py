import os

# Server
HOST = "0.0.0.0"
PORT = 8765

# Paths
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Load .env file
env_path = os.path.join(BASE_DIR, ".env")
if os.path.exists(env_path):
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

SCREENSHOTS_DIR = os.path.join(BASE_DIR, "screenshots")
INBOX_DIR = os.path.join(SCREENSHOTS_DIR, "_inbox")
DATA_DIR = os.path.join(BASE_DIR, "data")
ANALYSIS_FILE = os.path.join(DATA_DIR, "analysis.json")
PROJECTS_FILE = os.path.join(DATA_DIR, "projects.json")

# AI Analysis — 支持 gemini / claude / openai(含公司 GPT 网关)
AI_PROVIDER = os.environ.get("AI_PROVIDER", "gemini")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")

# 可选:走公司网关 / 自建代理时填,留空走官方端点
ANTHROPIC_BASE_URL = os.environ.get("ANTHROPIC_BASE_URL", "")
OPENAI_BASE_URL = os.environ.get("OPENAI_BASE_URL", "")

# Page type options
PAGE_TYPES = ["首页", "详情页", "列表页", "设置页", "弹窗", "个人中心", "搜索页", "其他"]
