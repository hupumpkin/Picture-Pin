# SVG 画布内编辑方案调研（2026-09-21）

## 目标

让用户在**可见 SVG 画布**中选中外部导入的线条、形状与文本，并直接修改几何、描边/填充、端点、文本样式和分组；保存后仍为 SVG。源码编辑器不是该目标的交付形态。

## 候选

| 方案 | 已覆盖能力 | 缺口 / 风险 | 许可证 | 接入判断 |
| --- | --- | --- | --- | --- |
| SVG-Edit 的 `@svgedit/svgcanvas` | 成熟 SVG 编辑画布，可作为自定义 UI 的底层；上游同时提供完整 editor 与独立 canvas。 | 需要本地打包 JS，并建立 WKWebView ↔ Swift 的保存/撤销桥接；外观需按 Pin 重做。 | MIT | **推荐**：最接近 Figma 式节点级编辑，避免重造 path/文本/选择逻辑。 |
| SVG-Edit 完整 editor | 现成选择、形状、文本、路径编辑和属性 UI。 | UI 体量及风格与 Pin 不一致；定制范围大。 | MIT | 用于 1–2 天的 Spike 验证，不建议原样作为最终体验。 |
| SVG.js + select/resize 插件 | DOM 级 SVG 操作；鼠标选择、控制柄缩放、旋转、网格吸附。 | 线条端点、贝塞尔节点、文字编辑、撤销/属性面板仍需自研。 | MIT | 仅适合把 MVP 收窄为矩形/圆/文本/普通 path 的变换和样式。 |
| Paper.js | SVG 导入/导出、路径 segments、命中和向量几何。 | 会转换为 Paper 自己的场景模型，保真保存外部 SVG 和 CSS/marker/defs 的风险高。 | MIT | 不适合「保留 Figma 导出 SVG 结构」这一目标。 |

## 原始证据

- SVG-Edit 官方仓库说明：编辑器由可独立使用的 `svgcanvas` 和 UI editor 构成；支持本地构建，也说明了集成入口。<https://github.com/SVG-Edit/svgedit>
- SVG-Edit 采用 MIT 许可证。<https://github.com/SVG-Edit/svgedit/blob/master/LICENSE-MIT.txt>
- SVG.js 官方插件文档演示了 `select().resize()`、控制柄、等比/中心缩放和网格吸附。<https://svgjs.dev/svg.resize.js/>
- Paper.js 官方 `Project` 文档说明其有独立项目场景树，并支持 SVG import/export。<https://paperjs.org/reference/project/>

## 建议的实现路径与工作量

### 推荐：`svgcanvas` 本地打包 + Pin 原生壳

1. **Spike（约 1–2 个工作日）**：固定上游版本，构建本地资源，放入应用 bundle；用 `WKWebView` 加载真实 Figma SVG，验证线/文本/嵌套组选择与 SVG round-trip。
2. **可用 MVP（约 5–8 个工作日）**：Pin 编辑窗口只暴露选择、移动/缩放/旋转、fill/stroke、线宽与端点、文字内容/字号/字重、进入/退出编组、删除、撤销/重做和保存。Swift 仅负责会话、文件原子替换、素材缓存刷新与快捷键。
3. **接近 Figma 的补全（另约 2–4 周）**：路径锚点/贝塞尔手柄、布尔运算、复杂 transform、文字样式继承、CSS/defs/marker 的保真回写、裁剪/蒙版、图层面板与跨 SVG 选择。

### 为什么不继续自研当前窗口

当前 Swift 源码窗口缺少真正的 SVG DOM、命中测试、几何控制柄、浏览器级文字编辑与撤销历史。继续补会把复杂性散落到 Swift 字符串替换、渲染缓存和手势层，既不能可靠处理外部 SVG，也无法快速达到图示体验。`svgcanvas` 将这些复杂性收在一个深 Module 内；Pin 的 Interface 只需「载入 SVG、接收选中/保存结果、设置受限工具集」。

## 下一步决策

建议采用 `svgcanvas`，并先做 Spike。Spike 的退出条件是：对真实 Figma SVG，能在 Pin 的可见编辑画布中选中一条线并改变线宽/颜色/端点，选中一个文本并改变字号/字重，双击进入 `<g>`，保存后重开仍保留修改。若上游对 macOS WKWebView 的兼容性或 round-trip 不达标，再退回 SVG.js MVP，而不是继续扩张源码编辑器。
