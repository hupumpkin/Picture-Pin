#!/bin/bash
# DesignPeek / 设计透视 — 首次安装脚本
cd "$(dirname "$0")"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       DesignPeek / 设计透视              ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""
echo "  正在安装..."

# Create .env if not exists
if [ ! -f .env ]; then
    cp .env.example .env
    echo "  ✓ 已创建 .env 配置文件"
    echo "  ⚠️  请编辑 .env,按文件内注释三选一填入 AI Key"
    echo "     (Gemini / 公司 Claude / 公司 GPT,任选其一)"
else
    echo "  ✓ .env 已存在"
fi

# Create virtual environment
if [ ! -d venv ]; then
    python3 -m venv venv
    echo "  ✓ 已创建虚拟环境"
fi

# Install dependencies
source venv/bin/activate
pip install -q -r requirements.txt
echo "  ✓ 依赖已安装"

# OCR module (macOS only, may fail on other OS)
python3 -c "import Vision; print('  ✓ OCR 模块可用')" 2>/dev/null || echo "  ⚠ OCR 模块未安装（仅影响文字搜索，不影响分析功能）"

# Ensure directories
mkdir -p screenshots/新添加截图 data
echo "  ✓ 目录已就绪"

echo ""
echo "  ──────────────────────────────────────────"
echo "  安装完成！"
echo ""
echo "  1. 编辑 .env,三选一填入 AI Key"
echo "  2. 运行 ./start.sh 启动服务"
echo "  ──────────────────────────────────────────"
echo ""
