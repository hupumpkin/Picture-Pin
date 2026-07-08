#!/bin/bash
# DesignPeek / 设计透视 — 启动脚本
cd "$(dirname "$0")"

# Activate venv if exists
if [ -f venv/bin/activate ]; then
    source venv/bin/activate
fi

# Check API key
if [ -f .env ]; then
    source .env
fi

if [ -z "$GEMINI_API_KEY" ] && [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$OPENAI_API_KEY" ]; then
    echo "⚠️  未检测到任何 AI Key，AI 分析功能不可用"
    echo "   请编辑 .env，按注释三选一填入 Key(Gemini / Claude / GPT)"
    echo ""
fi

python3 server.py
