# DesignPeek — 安装与运行指南(给 AI 助手)

> 给 Codex / 其他 AI 助手的安装剧本。用户多为不懂代码的设计师,请用平实中文逐步引导。
> 完整版与安全说明见同目录 `CLAUDE.md`,本文为等价精简版。

## 这是什么
DesignPeek(设计透视):给交互设计师的竞品截图管理 + AI 分析工具。本地 Python 服务 + 浏览器页面,数据全部本地存储。

## 安装流程
1. **跑安装脚本**:`./setup.sh`(建虚拟环境、装依赖、生成 `.env`)。权限报错先 `chmod +x setup.sh start.sh`。
2. **配 AI Key(需主动问用户用哪种)**:截图分析需要一个 AI 服务,主动询问:
   - 公司 Claude Key → `.env` 设 `AI_PROVIDER=claude`,填 `ANTHROPIC_API_KEY`(走公司网关再填 `ANTHROPIC_BASE_URL`)。
   - 公司 GPT Key → 设 `AI_PROVIDER=openai`,填 `OPENAI_API_KEY` + `OPENAI_BASE_URL`(公司网关地址,见 `.env` 注释)。
   - 自己的 Gemini → 设 `AI_PROVIDER=gemini`,填 `GEMINI_API_KEY`(https://aistudio.google.com/apikey )。
   `.env` 每种方案都有注释,只填选中那种,其余留空。
3. **启动**:`./start.sh`,终端会打印管理页地址和 iPhone 上传 URL。
4. **打开页面**:浏览器访问 http://localhost:8765 ,用"💻 本地上传"传图并分析,验证 Key 正确。
5. **(可选)配 iPhone 一键截图**:用户想用手机传截图时,**主动一步步口述带做**(手机操作无法代点,每步等用户确认):
   - ① 让用户在 iPhone 浏览器打开并安装快捷指令:`https://www.icloud.com/shortcuts/e6e454840f5b4efe9285b8454447a309`
   - ② **最关键**:打开快捷指令编辑,把「文本」步骤里的 IP 改成第 3 步终端显示的 Mac IP(如 `192.168.1.10`)——不改传不过来,务必提醒。
   - ③ 若需手动搭快捷指令,5 个动作依次为:获取最新照片(1 张)→ 获取当前 App → 文本=`http://MacIP:8765/api/upload/image` → 获取URL内容(POST、请求体=文件=最新照片)→ 该步「显示更多」加标头 `X-App-Name`=当前 App。
   - ④ 加到控制中心或「轻点背面两下」,截图后触发即自动上传。
   - ⑤ 验证:手机截一张图,Mac 管理页「新添加截图」里应出现。
   前提:两台设备同一 Wi-Fi、`./start.sh` 运行中。图文版见 `designpeek_使用说明.html`。

## 安全红线
- 绝不提交/外传 `.env`(含真实 Key)。
- 不外传用户 `screenshots/` 截图内容。
- Key 只写本地 `.env`,不写入任何会被分享的文件。

## 环境
面向 macOS(OCR 依赖系统能力,其他系统自动跳过);需要 Python 3。功能用法见 `designpeek_使用说明.html`。
