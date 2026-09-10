# DesignPeek SwiftUI Draft

DesignPeek 1.0 的纯前端 macOS 原生草案。它使用静态示例数据，不连接现有 FastAPI 服务，也不会读取或修改现有截图素材。

## 运行

在此目录执行：

```bash
swift run DesignPeekDraft
```

或生成可双击的 macOS 应用：

```bash
./scripts/build-app.sh
open "build/DesignPeek Draft.app"
```

当前草案包含：

- 原生 macOS 窗口、侧栏和分栏布局
- 截图 / 分析工作区切换
- 素材文件夹、收藏和竞品 App 导航
- 可缩放截图网格、搜索、批量操作和右键菜单视觉状态
- 待归类分析和分析文件夹框架

`reference/designpeek-html-current.jpg` 是开发前截取的现有 HTML 版本对照图，`reference/designpeek-swiftui-draft.jpg` 是原生草案效果图。
