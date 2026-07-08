"""AI screenshot analysis — supports Gemini / Claude / OpenAI(含公司 GPT 网关)."""

import base64
import json
import os

from config import (
    AI_PROVIDER,
    ANTHROPIC_API_KEY,
    ANTHROPIC_BASE_URL,
    GEMINI_API_KEY,
    OPENAI_API_KEY,
    OPENAI_BASE_URL,
)


def _mime_for(path):
    ext = os.path.splitext(path)[1].lower()
    return {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".webp": "image/webp"}.get(ext, "image/png")


def _require_key():
    """按当前 provider 校验对应 Key 是否已配置,缺失抛中文错误。"""
    if AI_PROVIDER == "gemini" and not GEMINI_API_KEY:
        raise ValueError("当前 AI_PROVIDER=gemini,请在 .env 填入 GEMINI_API_KEY")
    if AI_PROVIDER == "claude" and not ANTHROPIC_API_KEY:
        raise ValueError("当前 AI_PROVIDER=claude,请在 .env 填入 ANTHROPIC_API_KEY")
    if AI_PROVIDER == "openai" and not OPENAI_API_KEY:
        raise ValueError("当前 AI_PROVIDER=openai,请在 .env 填入 OPENAI_API_KEY")
    if AI_PROVIDER not in ("gemini", "claude", "openai"):
        raise ValueError(f"不支持的 AI_PROVIDER={AI_PROVIDER},请改为 gemini / claude / openai")

ANALYSIS_PROMPT = """你是一名资深交互设计师和视觉设计师。请仔细分析这张App截图，用中文输出以下内容。

## 输出格式（严格按此JSON格式输出，不要输出其他内容）

{
  "app_name": "识别出的App名称，如无法识别填写'未知'",
  "page_type": "页面类型：首页/详情页/列表页/设置页/弹窗/个人中心/搜索页/其他",
  "tags": {
    "components": ["识别到的UI组件，从以下列表中选择：导航栏/标签页/卡片列表/搜索框/底部弹窗/浮层/轮播Banner/表单/按钮组/空状态/骨架屏/Toast提示/下拉菜单/分段控制器/步进器/评分组件/头像/徽章"],
    "visual_style": ["识别到的视觉风格，从以下列表中选择：深色模式/毛玻璃/大圆角/弥散阴影/新拟态/线性图标/面性图标/渐变背景/留白设计/粗字体/插画风格/3D元素"],
    "layout": ["识别到的布局模式，从以下列表中选择：单列Feed/双列网格/瀑布流/顶部固定/底部固定/侧边栏/卡片堆叠/横向滚动/全屏沉浸"]
  },
  "visual": {
    "primary_colors": ["#主色调1", "#主色调2"],
    "color_scheme": "配色风格描述",
    "typography": "字体风格特征",
    "icon_style": "图标风格",
    "spacing": "间距特征"
  },
  "interaction": {
    "primary_actions": ["主要操作入口"],
    "gesture_areas": "手势交互区域",
    "form_patterns": "表单相关设计",
    "special_components": ["特殊组件"]
  },
  "summary": "一句话总结这个页面的设计特点和亮点"
}

## 标签选择注意事项
- tags中的每个维度只选择截图中明确可见的标签，不确定的不要选
- 每个维度最多选3个最显著的标签
- 如果某个维度没有匹配项，返回空数组[]
"""


def _parse_response(text):
    text = text.strip()
    if text.startswith("```"):
        lines = text.split("\n")
        text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text}


def _analyze_gemini(image_path):
    from google import genai

    client = genai.Client(api_key=GEMINI_API_KEY)

    with open(image_path, "rb") as f:
        image_data = f.read()

    resp = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=[
            {"inline_data": {"mime_type": _mime_for(image_path), "data": image_data}},
            ANALYSIS_PROMPT,
        ],
    )
    return _parse_response(resp.text)


def _analyze_openai(image_path):
    """OpenAI 兼容接口(官方或公司 GPT 网关),走 vision 多模态消息。"""
    from openai import OpenAI

    with open(image_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()

    client = OpenAI(api_key=OPENAI_API_KEY, base_url=OPENAI_BASE_URL or None)
    resp = client.chat.completions.create(
        model=os.environ.get("OPENAI_MODEL", "gpt-4o"),
        max_tokens=4096,
        messages=[{"role": "user", "content": [
            {"type": "text", "text": ANALYSIS_PROMPT},
            {"type": "image_url", "image_url": {
                "url": f"data:{_mime_for(image_path)};base64,{b64}"}},
        ]}],
    )
    return _parse_response(resp.choices[0].message.content)


def _analyze_claude(image_path):
    import anthropic

    with open(image_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()

    client = anthropic.Anthropic(
        api_key=ANTHROPIC_API_KEY, base_url=ANTHROPIC_BASE_URL or None)
    msg = client.messages.create(
        model=os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-6"),
        max_tokens=4096,
        messages=[{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": _mime_for(image_path), "data": b64}},
            {"type": "text", "text": ANALYSIS_PROMPT},
        ]}],
    )
    return _parse_response(msg.content[0].text)


def analyze_screenshot(image_path):
    _require_key()
    if AI_PROVIDER == "claude":
        return _analyze_claude(image_path)
    if AI_PROVIDER == "openai":
        return _analyze_openai(image_path)
    return _analyze_gemini(image_path)


PROJECT_ANALYSIS_PROMPT = """你是一名资深交互设计师和视觉设计师。你的任务是分析一组竞品App截图，这些截图围绕同一个设计主题收集而来。

请仔细查看下面所有截图，完成以下分析任务，用中文输出。

## 第一步：核心模块归类
将所有截图归类到 4-6 个核心模块中（不要使用细碎的触点分类）。模块划分应围绕用户在该主题下的核心操作链路，示例：
- 首页与入口模块（各平台的首页展示、入口设计）
- 内容展示模块（列表页、详情页、内容卡片等）
- 转化与操作模块（下单、捐赠、发布、提交等操作流程）
- 个人与管理模块（个人中心、设置、订单管理等）
- 营销与活动模块（弹窗、Banner、活动页等）
- 其他（无法归入以上模块的截图）

请根据截图实际内容灵活确定模块名称，控制在 4-6 个。

## 第二步：综合分析（严格按此JSON格式输出）

{
  "screenshot_tags": {
    "filename1.png": "模块名称",
    "filename2.png": "模块名称"
  },
  "overview": "总体概览：各平台围绕该主题的整体设计策略总结，2-3句话",
  "platform_comparison": [
    {
      "platform": "平台名称",
      "characteristics": "该平台的设计特点",
      "strengths": ["优势1", "优势2"],
      "weaknesses": ["不足1"]
    }
  ],
  "touchpoint_analysis": [
    {
      "touchpoint": "模块名称",
      "comparison": "各平台在该模块的设计差异对比",
      "highlights": ["值得借鉴的设计细节"],
      "best_practice": "最佳实践平台及原因"
    }
  ],
  "design_highlights": [
    {
      "description": "具体设计亮点",
      "platform": "来源平台",
      "why_good": "为什么好"
    }
  ],
  "recommendations": "综合建议：可参考的设计方向和最佳实践，2-3句话"
}

## 注意事项
- 不要输出任何JSON之外的内容
- 模块数量控制在 4-6 个，宁少勿多
- 如果某张截图无法确定模块，标注为"其他"
- platform_comparison 至少包含2个平台的对比
- design_highlights 至少列出3个值得借鉴的设计细节
- 在 overview、characteristics、comparison、recommendations 等文本字段中，用 **关键信息** 标记最重要的关键词和结论（如 **微信采用卡片式布局**、**各平台统一使用底部导航**）
"""


def _intro(project_name):
    return (f"## 设计主题：{project_name}\n\n"
            f"以下是与「{project_name}」相关的竞品App截图，请逐一分析并对比：")


def _project_gemini(image_paths, project_name):
    from google import genai

    client = genai.Client(api_key=GEMINI_API_KEY)
    contents = [_intro(project_name)]
    for path in image_paths:
        with open(path, "rb") as f:
            image_data = f.read()
        contents.append({"inline_data": {"mime_type": _mime_for(path), "data": image_data}})
        contents.append(f"[截图: {os.path.basename(path)}]")
    contents.append(PROJECT_ANALYSIS_PROMPT)

    resp = client.models.generate_content(model="gemini-2.5-flash", contents=contents)
    return _parse_response(resp.text)


def _project_openai(image_paths, project_name):
    from openai import OpenAI

    parts = [{"type": "text", "text": _intro(project_name)}]
    for path in image_paths:
        with open(path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        parts.append({"type": "text", "text": f"[截图: {os.path.basename(path)}]"})
        parts.append({"type": "image_url", "image_url": {
            "url": f"data:{_mime_for(path)};base64,{b64}"}})
    parts.append({"type": "text", "text": PROJECT_ANALYSIS_PROMPT})

    client = OpenAI(api_key=OPENAI_API_KEY, base_url=OPENAI_BASE_URL or None)
    resp = client.chat.completions.create(
        model=os.environ.get("OPENAI_MODEL", "gpt-4o"),
        max_tokens=8192,
        messages=[{"role": "user", "content": parts}],
    )
    return _parse_response(resp.choices[0].message.content)


def _project_claude(image_paths, project_name):
    import anthropic

    parts = [{"type": "text", "text": _intro(project_name)}]
    for path in image_paths:
        with open(path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        parts.append({"type": "text", "text": f"[截图: {os.path.basename(path)}]"})
        parts.append({"type": "image", "source": {
            "type": "base64", "media_type": _mime_for(path), "data": b64}})
    parts.append({"type": "text", "text": PROJECT_ANALYSIS_PROMPT})

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY, base_url=ANTHROPIC_BASE_URL or None)
    msg = client.messages.create(
        model=os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-6"),
        max_tokens=8192,
        messages=[{"role": "user", "content": parts}],
    )
    return _parse_response(msg.content[0].text)


def analyze_project(image_paths, project_name=""):
    """Analyze multiple screenshots together for cross-platform comparison."""
    _require_key()
    if AI_PROVIDER == "claude":
        return _project_claude(image_paths, project_name)
    if AI_PROVIDER == "openai":
        return _project_openai(image_paths, project_name)
    return _project_gemini(image_paths, project_name)
