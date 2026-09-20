# Web Capture Spike：最低成本验证网页采集闭环

> 文档用途：直接交给实现 AI 执行。
>
> 任务性质：一次性可行性实验，不是 Pin 正式功能开发。
>
> 核心问题：用户能否在 Pin 的单个 macOS 窗口中浏览花瓣与 Pinterest，并通过一次拖拽或复制/粘贴，把正在看的图片带进 Pin。

## 0. 开工结论与停止规则

当前先暂停画布精修。这个 Spike 只验证网页采集，使用独立小程序和临时数据，不接入 Pin 正式画布、素材库或数据库。

按以下顺序执行：

1. 先实现 **A 层：系统原生复制/粘贴与拖拽**。
2. A 层跑完花瓣和 Pinterest 的真实测试后再判断。
3. 只有 A 层达不到验收标准，才实现 **B 层：用户单次点击触发的图片提取**。
4. B 层不得发展成整页扫描、批量下载或站点爬虫。
5. 完成 A 层或 B 层的真实测试报告后停止，不进入正式画布集成。

完成标准不是“代码写完”，而是产出本文件 §8 要求的证据，并能依据 §9 得出 `PASS`、`CONDITIONAL` 或 `FAIL`。

## 1. 固定工作区与修改边界

- 仓库：`/Users/huwenhao12/Documents/截图分析管理工具-native`
- 当前产品线：Pin 原生 macOS
- 本任务建立独立目录：`pin-macos/Spikes/WebCaptureSpike/`
- 使用独立 Swift Package；不得把 Spike target 加进现有 `pin-macos/Package.swift`。
- 运行数据只允许进入系统临时目录和 WebKit 自己的数据目录，不读写：
  - Pin production 数据；
  - `dev-cc` / `dev-codex` 数据；
  - 现有 SQLite 素材库；
  - DesignPeek / Pin Web 数据。
- 保留工作区现有所有未提交修改，不回退、不覆盖、不格式化正式项目文件。
- 不提交、不推送、不打标签。完成后报告分支、提交号和工作区状态。

允许创建的内容：

```text
pin-macos/Spikes/WebCaptureSpike/
├── Package.swift
├── README.md
├── Sources/WebCaptureSpike/
│   ├── WebCaptureSpikeApp.swift
│   ├── WebWorkspaceView.swift
│   ├── WebViewHost.swift
│   ├── CaptureReceiver.swift
│   ├── CaptureResult.swift
│   └── CaptureLog.swift
└── WEB_CAPTURE_SPIKE_REPORT.md
```

文件可以合并，但职责必须保持清楚。Spike 外只允许按仓库规则更新版本记录；正式业务代码不在本任务范围内。

## 2. 明确不做

本任务不实现：

- 无限画布接入；
- 素材数据库与长期落盘；
- 浏览器标签、收藏夹、历史记录、下载管理；
- Finder 面板、手机上传、浏览器扩展；
- 批量采集、整页扫描、自动翻页、自动滚动；
- 绕过登录、验证码、付费、地区或防爬限制；
- 站点专用账号系统、Pinterest API 或花瓣私有接口；
- AI 分析、视觉搜索、OCR；
- 正式 UI、品牌视觉、动画和发布打包；
- 自动登录或在代码、日志中保存账号、密码、Cookie、Token。

遇到以上需求时，将其记录到报告的“正式产品候选项”，然后继续完成当前验证，不扩大实现。

## 3. 实验界面

做一个单窗口、左右分栏的 macOS 应用：

```text
┌──────────────────────────────────────────────────────────┐
│ [后退] [前进] [刷新] [地址栏________________] [打开]    │
├──────────────────────────────┬───────────────────────────┤
│                              │  图片接收区               │
│        WKWebView             │                           │
│                              │  [从剪贴板采集]           │
│  花瓣 / Pinterest 真实网页   │                           │
│                              │  最近一次图片预览         │
│                              │  像素 / 字节 / 类型       │
│                              │  当前页面来源 URL         │
├──────────────────────────────┴───────────────────────────┤
│ 状态：成功 / 失败原因 / 耗时 / 接收到的 Pasteboard 类型 │
└──────────────────────────────────────────────────────────┘
```

界面要求：

- 默认提供 `https://huaban.com/` 与 `https://www.pinterest.com/` 两个快捷入口。
- 地址栏允许输入任意 `http` / `https` 地址。
- 使用系统默认 WKWebView User-Agent，不伪装 Chrome 或 Safari。
- 使用 `WKWebsiteDataStore.default()`，以验证 Cookie 与登录状态能否跨启动保留。
- `target="_blank"` 或新窗口导航先尝试在当前 WebView 打开；如果登录流程要求系统浏览器，如实记录，不绕过。
- 图片接收区同时支持按钮读取剪贴板和拖放。
- Spike 只保留当前接收到的图片；不需要图库和列表。

完成标准：应用能通过 `swift run WebCaptureSpike` 启动，左右两区可见，两个快捷网站都能发起加载。

## 4. A 层：只使用系统原生能力

### 4.1 剪贴板采集

用户在网页中使用网页/WebKit 自带的“复制图像”或 `⌘C`，然后点击右侧“从剪贴板采集”。

按以下优先级读取 `NSPasteboard.general`：

1. PNG / TIFF / 可解码图片字节；
2. 文件 URL；
3. 普通 `http` / `https` 图片 URL；
4. 其他类型判定为不支持，并完整列出 Pasteboard 类型名。

约束：

- 有图片字节时优先使用字节，不重复下载 URL。
- URL 只在用户明确执行本次采集后下载。
- URL 下载只接受 `http` / `https`，限制重定向次数、最大响应体 50 MB，设置合理超时。
- 响应必须能由 ImageIO 解码；不能只相信扩展名或 `Content-Type`。
- 所有处理放在内存或 Spike 临时目录，不写 Pin 正式素材库。
- 成功后显示图片预览、像素尺寸、字节数、媒体类型、采集耗时和当前页面 URL。
- 失败必须显示具体阶段：剪贴板无图片、URL 无效、网络失败、超过大小、解码失败。

完成标准：本地测试页中的 PNG、JPEG、透明 PNG 均可通过复制进入右侧预览；非图片文本会明确失败，不崩溃。

### 4.2 拖拽采集

用户直接从 WKWebView 中把一张图片拖到右侧接收区。

接收并记录拖拽提供者声明的全部类型，处理优先级与剪贴板一致：图片字节 → 文件 URL → 网络 URL。

约束：

- 同一次拖拽只生成一个结果，避免字节和 URL 被当成两张图。
- 必须显示到底收到了字节、文件还是 URL。
- 拖拽失败时保留类型清单与失败原因，供判断是 WebKit、网站还是接收代码的问题。

完成标准：本地测试页的三类图片均可拖入；重复类型不会产生重复结果。

### 4.3 本地对照页

为排除网站因素，在 Spike 包内生成或内嵌一个最小 HTML 对照页，包含：

- 普通 `<img src="...png">`；
- JPEG；
- 透明 PNG；
- `srcset` 图片；
- CSS `background-image`；
- Canvas 绘制图片；
- `blob:` 图片。

测试顺序固定为：先跑本地对照页，再跑花瓣，再跑 Pinterest。只有本地对照页通过后，网站失败才可归因于网站/WebKit组合。

本地图片必须由代码生成或使用明确可公开分发的夹具；不得加入用户真实图片或网站截图。

## 5. A 层真实网站测试

AI 负责把程序准备到可测试状态；账号登录必须由用户本人手动完成。AI 不读取凭据，不录制键盘输入，不导出 Cookie。

对花瓣和 Pinterest 分别执行：

1. 未登录首页能否加载、滚动、打开详情页。
2. 用户手动登录；记录邮箱登录、第三方登录、验证码或弹窗的结果。
3. 退出并重新启动 Spike，确认登录状态是否保留。
4. 随机选择 10 张视觉上不同的图片。
5. 每张先尝试直接拖拽；失败后再尝试复制/粘贴。
6. 记录成功方式、操作步数、耗时、所得像素尺寸、页面 URL和失败原因。
7. 至少覆盖首页瀑布流与详情页两个位置。

禁止为了让数字好看而只挑选确认可复制的图片。选择顺序应在操作前确定，例如按当前视口从左上到右下取前 10 张非广告图片。

每个网站的 A 层通过标准：

- 页面核心浏览可用；
- 登录状态能保留，或明确证明该网站无需登录即可完成核心测试；
- 10 张中至少 8 张能通过拖拽或复制/粘贴进入右侧；
- 成功采集最多两次用户动作；
- 采集结果不是肉眼明显不可用的占位图、图标或极小缩略图；
- 单张正常图片从动作发生到预览出现，正常网络下目标小于 3 秒；
- 没有站点专用 DOM 选择器和自动扫描。

## 6. B 层：A 层不足时才允许实现

只有出现以下任一结果，才进入 B 层：

- 网站允许正常浏览，但 WebKit 默认菜单没有复制图片；
- 拖拽只提供网页链接，没有图片；
- A 层成功率低于 80%，且失败集中在可见图片的承载方式。

B 层增加一个“采集当前指向图片”的显式动作。实现原则是 **用户点一下，只处理点中的一个元素**。

可使用 `WKUserScript` / `WKScriptMessageHandler` 完成：

1. 用户在网页中右键或点击明确的“采集到 Pin”动作；
2. 脚本从事件坐标调用 `document.elementFromPoint`；
3. 只检查该元素及有限父子层级中的：
   - `img.currentSrc` / `img.src`；
   - `picture/source`；
   - 当前元素的 `background-image`；
   - 可直接导出的同源 Canvas；
4. 把一个候选 URL 或一份图片数据交给原生层；
5. 原生层仍复用 A 层的校验、下载和解码入口。

B 层硬边界：

- 不遍历整页图片；
- 不自动滚动或翻页；
- 不调用未公开接口；
- 不截获网站请求、响应或账号信息；
- 不绕过跨域 iframe、CORS、登录、验证码、付费或访问控制；
- 不为花瓣/Pinterest写易碎的 class 名、XPath 或 CSS selector；
- 不在后台持续注入采集逻辑；用户动作之外不产生下载。

如果通用 element hit-test 无法达到 80%，停止 B 层，不进入站点专用适配。

## 7. 代码结构与接口

保持 Spike 很浅，不建立正式插件架构。至少保留以下单一职责：

- `WebViewHost`：WKWebView 创建、导航、Cookie 数据存储、新窗口处理。
- `CaptureReceiver`：剪贴板、拖拽和 B 层消息统一进入这里。
- `CapturePayload`：`.bytes` / `.fileURL` / `.remoteURL`。
- `CaptureResult`：成功图片与可展示的失败原因。
- `CaptureLog`：只记录非敏感验证数据。

核心接口建议：

```swift
enum CapturePayload {
    case bytes(Data, declaredType: String?)
    case fileURL(URL)
    case remoteURL(URL)
}

struct CaptureSuccess {
    let image: CGImage
    let byteCount: Int
    let pixelSize: CGSize
    let mediaType: String?
    let sourcePageURL: URL?
    let transport: CaptureTransport
    let elapsed: Duration
}

enum CaptureResult {
    case success(CaptureSuccess)
    case failure(CaptureFailure)
}
```

剪贴板、拖拽和 B 层都必须调用同一个 `receive(_:)`，避免三条路径出现不同的格式、大小和失败口径。

## 8. 必须交付的报告

创建 `pin-macos/Spikes/WebCaptureSpike/WEB_CAPTURE_SPIKE_REPORT.md`，包含：

### 环境

- 日期；
- macOS / Xcode / Swift 版本；
- 构建模式；
- 网络环境的简单描述；
- 测试网站 URL；
- 是否登录，不记录账号。

### 功能矩阵

| 网站/页面 | 浏览 | 登录 | 重启保持 | 拖拽成功数 | 粘贴成功数 | 总成功数/10 | 主要失败 |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |

### 逐图记录

| # | 网站位置 | 首选动作 | 结果 | 操作步数 | 像素 | 字节 | 耗时 | 收到的数据类型 | 失败原因 |
| --- | --- | --- | --- | ---: | --- | ---: | ---: | --- | --- |

### 失败分类

- 网站/登录阻止；
- WebKit 不提供图片数据；
- 只提供网页 URL；
- `blob:` / Canvas / CSS 背景；
- 网络或重定向；
- 解码失败；
- 仅得到不可用缩略图；
- 未知。

### 安全检查

- 日志和 Git 差异中无账号、Cookie、Token、网站截图和用户素材；
- 没有自动批量采集；
- 没有绕过网站限制；
- 临时下载目录和文件数量已记录并清理。

不得用“看起来可以”代替表格数据；未由用户完成的登录测试写“未验证”。

## 9. 最终决策规则

报告结尾只能给出以下一个结论：

### `PASS`

花瓣与 Pinterest 均达到 A 层或通用 B 层的 80% 标准，登录/浏览没有阻断。建议继续 Pin 原生开发，并把 `CaptureReceiver` 的概念接到正式 `ImportCoordinator`，不要复制 Spike 代码中的临时 UI。

### `CONDITIONAL`

至少一个网站达到标准，另一个网站因登录或 WebKit 交互受限，但浏览器扩展或截图兜底具有明确可行路径。报告必须指出产品承诺需要怎样调整，例如“部分网站内嵌，受限网站通过扩展发送到 Pin”。

### `FAIL`

两个核心网站都达不到 80%，或者只有依靠站点专用 selector、批量页面扫描、接口逆向或绕过限制才能完成。建议暂停画布扩建，不进入正式网页采集开发。

不得因为已经写了代码而降低标准。

## 10. 验证命令与人工检查

实现 AI 应在 Spike 目录中提供实际可用的命令，至少覆盖：

```bash
swift build
swift run WebCaptureSpike
swift test
```

自动测试至少覆盖：

- 非图片剪贴板；
- 图片字节优先于 URL；
- 重复 Pasteboard 类型只生成一次结果；
- 非 HTTP(S) URL 被拒绝；
- 响应超过大小限制；
- 图片解码失败；
- 失败文案对应正确阶段；
- CaptureLog 不包含敏感字段。

人工检查至少覆盖：

- 本地 HTML 全部样本；
- 花瓣 10 张；
- Pinterest 10 张；
- 登录后重启；
- 窄窗口下左右区域仍可操作；
- 退出后临时文件已清理。

## 11. 收尾纪律

完成后执行并报告：

1. `git status`、`git diff --check`、`git diff --stat`；
2. Spike 构建和自动测试结果；
3. 两个真实网站的人工测试结果与未验证项；
4. 当前分支和提交号；
5. GitHub 未同步、未打标签；
6. `PASS` / `CONDITIONAL` / `FAIL`；
7. 下一步建议，但不直接开始正式集成。

本任务的价值是尽快得到可信的产品判断。代码是实验工具，报告才是最终交付物。
