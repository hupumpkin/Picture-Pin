# WebCaptureSpike

一次性可行性实验，验证「在 Pin 的单个 macOS 窗口里浏览国内素材站，把正在看的图片带进 Pin」是否
只靠系统原生能力就能成立。**不是 Pin 正式功能**，不接画布、不接素材库、不写数据库。

任务书见 `../WEB_CAPTURE_SPIKE_TASK.md`，结论见 `WEB_CAPTURE_SPIKE_REPORT.md`。

## 命令

```bash
cd pin-macos/Spikes/WebCaptureSpike

swift build                 # 构建
swift test                  # 18 个自动测试：载荷优先级、大小上限、失败阶段、日志脱敏
swift run WebCaptureSpike   # 直接跑（裸可执行文件）
./build-app.sh              # 打成 .app（推荐用于人工测试，见下）
```

### 为什么人工测试要用 .app

WKWebView 的默认数据存储（也就是花瓣登录态）按 bundle identifier 找容器目录。`swift run` 出来的
是裸可执行文件，没有 bundle id，登录能不能跨启动保留就不可信。`./build-app.sh` 会生成
`build/WebCaptureSpike.app`，双击即可运行——**人工测试请用这个**。

### 无头自检

```bash
"$(swift build --show-bin-path)/WebCaptureSpike" --self-check            # 只查本地夹具 + 剪贴板
"$(swift build --show-bin-path)/WebCaptureSpike" --self-check --online   # 额外确认花瓣首页能否加载
```

自检不提取任何网页图片，只回答「WebKit 能不能加载这个页面」和「剪贴板解码链路通不通」。

## 界面

左边 WKWebView（系统默认 User-Agent，`WKWebsiteDataStore.default()`），右边图片接收区。

- **快捷入口** 菜单里选「本地对照页」先跑回归，再跑花瓣。
- 拖拽：直接从网页把图片拖到右侧接收区。
- 粘贴：网页里右键「拷贝图像」或 `⌘C`，再点「从剪贴板采集」（快捷键 `⌥⌘V`）。
- **复制记录** 把右侧的采集记录导成 Markdown 表格放回剪贴板，直接贴进报告即可。

## 边界

不做整页扫描、批量下载、自动翻页、站点专用选择器，不绕过登录/验证码/风控，不在代码或日志里
保存账号、Cookie、Token。运行数据只在系统临时目录和 WebKit 自己的数据目录里；退出时会清掉
临时夹具目录 `$TMPDIR/WebCaptureSpikeFixture`。
