"""Question-led visual analysis for DesignPeek projects."""

import base64
import json
import os
import re

from ai_settings import load_ai_settings

OPENAI_COMPATIBLE_PROVIDERS = {"openai", "qwen", "deepseek", "kimi"}

METHOD_LIBRARY = """
只能从下列成熟方法中选择与问题相关的方法，不要自创方法名：
- Nielsen 十项可用性原则：状态可见、现实匹配、用户控制、一致性、防错、识别优于回忆、效率、简约、错误恢复、帮助。
- Cognitive Walkthrough：按任务步骤检查目标、入口可发现性、操作与预期的匹配、反馈与恢复。
- Gestalt 视觉组织原则：接近、相似、连续、围合、图形与背景。
- WCAG 可见项检查：仅评估截图可见的对比、文字可读性、目标尺寸，不声称完成无障碍认证。
- Baymard 电商 UX 研究维度：仅在电商场景使用，围绕导航、列表筛选、商详、购物车和结账任务。
- HEART Goals-Signals-Metrics：仅用于把建议转成待验证的指标假设，不得由截图推断转化率或满意度。
"""


def _mime_for(path):
    ext = os.path.splitext(path)[1].lower()
    return {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".webp": "image/webp"}.get(ext, "image/png")


def _settings(settings=None):
    value = dict(settings or load_ai_settings(include_key=True))
    if not value.get("api_key"):
        raise ValueError("请先在「AI 设置」中配置 API Key")
    return value


def _require_key(settings=None):
    return _settings(settings)


def _parse_response(text):
    text = (text or "").strip()
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])
        if text.lstrip().startswith("json"):
            text = text.lstrip()[4:].lstrip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"\{[\s\S]*\}", text)
        if match:
            try:
                return json.loads(match.group(0))
            except json.JSONDecodeError:
                pass
    raise ValueError("AI 未返回可读取的结构化结果，请重试或更换模型")


def _openai_chat(cfg, messages, max_tokens):
    from openai import OpenAI
    client = OpenAI(api_key=cfg["api_key"], base_url=cfg.get("base_url") or None)
    extra = {}
    if cfg["provider"] == "qwen":
        extra["extra_body"] = {"enable_thinking": False}
    elif cfg["provider"] == "kimi":
        extra["extra_body"] = {"thinking": {"type": "disabled"}}
    response = client.chat.completions.create(
        model=cfg["model"], max_tokens=max_tokens, messages=messages, **extra,
    )
    content = response.choices[0].message.content
    if not content:
        raise ValueError("模型未返回最终内容，可能是思考过程用完了输出额度")
    return content


def _text_request(prompt, settings=None, max_tokens=4096):
    cfg = _settings(settings)
    if cfg["provider"] == "gemini":
        from google import genai
        return genai.Client(api_key=cfg["api_key"]).models.generate_content(
            model=cfg["model"], contents=prompt).text
    if cfg["provider"] == "claude":
        import anthropic
        client = anthropic.Anthropic(api_key=cfg["api_key"], base_url=cfg.get("base_url") or None)
        msg = client.messages.create(model=cfg["model"], max_tokens=max_tokens,
                                     messages=[{"role": "user", "content": prompt}])
        return msg.content[0].text
    if cfg["provider"] in OPENAI_COMPATIBLE_PROVIDERS:
        return _openai_chat(cfg, [{"role": "user", "content": prompt}], max_tokens)
    raise ValueError("不支持的 AI 服务商")


def _vision_request(image_path, prompt, settings=None, max_tokens=4096):
    cfg = _settings(settings)
    with open(image_path, "rb") as f:
        raw = f.read()
    if cfg["provider"] == "gemini":
        from google import genai
        contents = [{"inline_data": {"mime_type": _mime_for(image_path), "data": raw}}, prompt]
        return genai.Client(api_key=cfg["api_key"]).models.generate_content(
            model=cfg["model"], contents=contents).text
    encoded = base64.b64encode(raw).decode()
    if cfg["provider"] == "claude":
        import anthropic
        client = anthropic.Anthropic(api_key=cfg["api_key"], base_url=cfg.get("base_url") or None)
        content = [
            {"type": "image", "source": {"type": "base64", "media_type": _mime_for(image_path), "data": encoded}},
            {"type": "text", "text": prompt},
        ]
        msg = client.messages.create(model=cfg["model"], max_tokens=max_tokens,
                                     messages=[{"role": "user", "content": content}])
        return msg.content[0].text
    if cfg["provider"] in OPENAI_COMPATIBLE_PROVIDERS:
        content = [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": f"data:{_mime_for(image_path)};base64,{encoded}"}},
        ]
        return _openai_chat(cfg, [{"role": "user", "content": content}], max_tokens)
    raise ValueError("不支持的 AI 服务商")


def test_ai_connection(image_path=None, settings=None):
    if image_path:
        reply = _vision_request(image_path, "请确认你能读取这张图片，只回复 OK。",
                                settings=settings, max_tokens=16)
    else:
        reply = _text_request("只回复 OK。", settings=settings, max_tokens=16)
    return bool((reply or "").strip())


def suggest_dimensions(project_name, question, context="", apps=None, settings=None):
    prompt = f"""
你是负责竞品研究方案的资深 UX 研究员。只设计分析框架，不要开始分析截图。
项目：{project_name}
用户必答问题：{question}
使用场景：{context or '未填写'}
已知 App：{'、'.join(apps or []) or '待识别'}
{METHOD_LIBRARY}
选择最少且足够的方法，生成 4-8 个不重复的维度。维度必须直接服务用户问题。
严格返回 JSON：
{{"analysis_type":"页面视觉/模块评估/动线对比/整体可用性/电商体验/综合分析之一",
"methods":["方法名"],
"dimensions":[{{"id":"dimension_1","name":"简洁维度名","focus":"具体观察内容"}}],
"limitations":"截图分析能回答和不能回答的边界"}}
"""
    result = _parse_response(_text_request(prompt, settings=settings))
    dimensions = result.get("dimensions", [])
    if not 4 <= len(dimensions) <= 8:
        raise ValueError("AI 生成的分析维度数量不合适，请重试")
    return result


def analyze_screenshot_evidence(image_path, screenshot_id, app_name, question, dimensions,
                                ocr_text="", settings=None):
    prompt = f"""
你是资深交互设计师和视觉设计师。围绕用户问题分析这张截图，只记录画面可支持的证据。
用户问题：{question}
截图 ID：{screenshot_id}
来源 App：{app_name or '未归类'}
本机 OCR：{ocr_text[:5000] or '无'}
已确认维度：{json.dumps(dimensions, ensure_ascii=False)}

要求：严格区分可见事实和专业解读；不得断言真实转化率或满意度；每条证据只关联一个已确认维度；region 指出画面位置。
严格返回 JSON：
{{"screenshot_id":"{screenshot_id}","app":"{app_name or '未归类'}","page_role":"页面或模块作用",
"journey_stage":"无法确定填未知","visible_summary":"一句话客观概括",
"evidence":[{{"dimension_id":"dimension_1","fact":"可直接看到的事实","interpretation":"基于方法的解读",
"possible_impact":"使用可能/或许限定的影响","region":"证据所在位置","confidence":"high/medium/low"}}]}}
"""
    return _parse_response(_vision_request(image_path, prompt, settings=settings))


def observe_screenshot(image_path, screenshot_id, app_name, ocr_text="", settings=None):
    """Extract reusable, question-independent visual facts from one screenshot."""
    prompt = f"""
你是严谨的资深产品设计研究员。请只观察这张静态截图中明确可见的内容，供后续多个问题复用。
截图 ID：{screenshot_id}
来源 App：{app_name or '未归类'}
本机 OCR：{ocr_text[:5000] or '无'}

不得推断点击率、转化率、流量、用户偏好或截图外的操作结果。scene_label 要用人能读懂的页面/场景名称，不能写截图 ID。
严格返回 JSON：
{{"screenshot_id":"{screenshot_id}","app":"{app_name or '未归类'}","scene_label":"简短场景名",
"page_role":"页面或模块作用","visible_summary":"一句话客观概括",
"visible_elements":["可见元素"],"information_hierarchy":["信息层级事实"],
"actions_and_feedback":["可见入口、按钮、状态或反馈"],"trust_and_decision_cues":["可见决策或信任线索"],
"continuity_cues":["可见的跨页面连续线索"]}}
"""
    return _parse_response(_vision_request(image_path, prompt, settings=settings, max_tokens=2048))


def synthesize_quick_brief(question, angle, observations, ordered=False, settings=None):
    """Create a compact decision brief from reusable screenshot observations."""
    apps = sorted({item.get("app") or "未归类" for item in observations})
    analysis_kind = "对比" if len(apps) > 1 else "竞品诊断"
    prompt = f"""
你是资深产品设计负责人。请把截图客观观察整理成一份用于快速迭代决策的「{analysis_kind}」速览。
用户问题：{question}
用户选择角度：{angle or '未指定，由你自动选择'}
是否按用户确认顺序还原路径：{'是' if ordered else '否'}
截图观察（顺序即用户顺序，仅 ordered=是时可视为路径）：{json.dumps(observations, ensure_ascii=False)}

规则：
1. 自动选择最多 3 个最能回答问题的成熟设计观察角度，不展示方法论堆砌。
2. 首屏只给 1 句结论、最多 3 条核心发现、1-3 条高/中优先级行动和证据缺口。
3. 每条发现严格拆为「竞品观察」「对我的启示」「建议行动」，并附真实截图 ID；证据标签使用 observation 的 scene_label。
4. 静态截图不能证明点击率、转化率、流量、真实操作结果或用户心理。推测必须放在「待验证」。
5. 单 App 标题与 kind 必须是「竞品诊断」；多 App 才能使用「对比」。
6. 详细逐图证据、扩展观察角度、方法说明和验证指标放入 details。

严格返回 JSON：
{{"kind":"{analysis_kind}","conclusion":"一句话结论","perspectives":["最多3个角度"],
"findings":[{{"title":"发现标题","observation":"竞品观察","implication":"对我的启示","action":"建议行动",
"evidence":[{{"screenshot_id":"真实ID","scene_label":"可读场景名"}}],"confidence":"high/medium/low","to_validate":"待验证内容"}}],
"priority_actions":[{{"priority":"high/medium","action":"行动","reason":"原因"}}],
"evidence_gaps":[{{"gap":"证据缺口","suggested_screenshot":"建议补充的截图"}}],
"details":{{"per_image":[{{"screenshot_id":"真实ID","scene_label":"场景名","observation":"客观观察"}}],
"expanded_dimensions":[{{"name":"角度","insight":"扩展洞察"}}],"methodology":"简短方法说明",
"validation_metrics":[{{"hypothesis":"待验证假设","metric":"建议指标"}}]}}}}
"""
    result = _parse_response(_text_request(prompt, settings=settings, max_tokens=4096))
    result["kind"] = analysis_kind
    return result


def synthesize_project(project_name, question, context, framework, facts, settings=None):
    prompt = f"""
你是资深竞品 UX 研究员。只基于下面的逐张截图证据生成对比看板和辅助报告。
项目：{project_name}
用户问题：{question}
使用场景：{context or '未填写'}
已确认框架：{json.dumps(framework, ensure_ascii=False)}
逐张证据：{json.dumps(facts, ensure_ascii=False)}

每个判断必须附真实 evidence_ids。将观察、解读、建议分开。证据不足时明确说明。单 App 或单图时输出诊断，不伪造竞品差异。
如果是动线分析，按 sequence_index 识别用户确认的截图先后顺序，同时按 App 分组比较；不得自行猜测缺失的步骤。
严格返回 JSON：
{{"answer":"对问题的 2-4 句直接回答",
"comparison_board":[{{"dimension_id":"dimension_1","dimension_name":"维度名","apps":[{{"app":"App 名","finding":"观察与解读","strengths":["优势"],"risks":["风险"],"evidence_ids":["截图ID"],"confidence":"high/medium/low"}}],"comparison":"横向差异和共性","opportunity":"机会点"}}],
"key_findings":[{{"title":"核心发现","observation":"证据概括","implication":"意义","recommendation":"建议","evidence_ids":["截图ID"],"confidence":"high/medium/low"}}],
"report":{{"summary":"结构化摘要","recommendations":[{{"priority":"high/medium/low","action":"建议","reason":"原因","evidence_ids":["截图ID"]}}],"measurement_hypotheses":[{{"goal":"目标","signal":"可观察信号","metric":"待验证指标"}}],"limitations":"本次分析边界"}}}}
"""
    return _parse_response(_text_request(prompt, settings=settings, max_tokens=8192))


def analyze_screenshot(image_path):
    """Compatibility entry point for the existing single-image endpoint."""
    prompt = """
请作为交互与视觉设计师分析这张 App 截图。只输出 JSON：
{"app_name":"App 名或未知","page_type":"页面类型","tags":{"components":[],"visual_style":[],"layout":[]},
"visual":{"primary_colors":[],"color_scheme":"","typography":"","icon_style":"","spacing":""},
"interaction":{"primary_actions":[],"gesture_areas":"","form_patterns":"","special_components":[]},
"summary":"一句话概括"}
只写截图中能明确确认的信息，不确定时使用空值。
"""
    return _parse_response(_vision_request(image_path, prompt))


def analyze_project(image_paths, project_name=""):
    """Compatibility entry point retained for older callers."""
    question = f"分析「{project_name}」的页面设计差异"
    framework = suggest_dimensions(project_name, question)
    facts = [analyze_screenshot_evidence(
        path, os.path.splitext(os.path.basename(path))[0], "", question, framework["dimensions"]
    ) for path in image_paths]
    return synthesize_project(project_name, question, "", framework, facts)
