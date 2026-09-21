# Pin CC 开发工作区

你正在操作的是 Pin 的独立 CC 工作区，不要修改原工作区：

`/Users/huwenhao12/Documents/截图分析管理工具`

当前工作区路径：

`/Users/huwenhao12/Documents/截图分析管理工具-cc`

## 当前基线

- 分支：`cc/pin-webview-experiment`
- 基线提交：`3a168a9 Float analysis workspace over canvas`
- 产品：Pin Web（原 DesignPeek Web 的新工作台）
- 下一项实验：在 Pin 内嵌花瓣浏览，并支持复制图片后粘贴到画布

## 运行方式

进入 `designpeek_dist` 后运行：

```bash
./setup.sh
PIN_PORT=8766 ./start.sh
```

原 Pin 默认使用 `8765`，CC 工作区默认使用 `8766`，不要停止或覆盖原 Pin 服务。

浏览器访问：`http://localhost:8766`

如果已经有可用的 Python 环境，也可以直接执行：

```bash
PIN_PORT=8766 python3 server.py
```

## 数据与素材

- 本工作区有一份独立的素材和运行数据快照。
- 图片数量和原 Pin 快照一致；不要删除、重命名或批量移动素材来做测试。
- `.env` 和真实 API Key 不在工作区快照中，需要时由用户在本地单独配置。
- 不要读取、输出或提交任何真实 Key。
- 不要把花瓣 Cookie 发送到后端或写入 Pin 数据文件。

## 修改规则

- 先阅读 `designpeek_dist/CLAUDE.md` 和 `designpeek_dist/AGENTS.md`。
- 保持现有本地素材文件夹规则：素材文件夹决定 Finder 位置，竞品 App 只用于前台筛选。
- 每次产品迭代更新根目录 `VERSION_HISTORY.md`。
- Pin 网页版本使用 `P` 编号，DesignPeek 网页版本使用 `DP` 编号，原生草案使用 `N` 编号。
- 当前 Pin 版本为 `P0.2.0`；下一次完成花瓣内嵌浏览实验后使用 `P0.3.0`。
- 任何改动完成后先运行语法检查，再做浏览器验证，再提交 Git。

## 推荐验证顺序

1. 不改动用户数据，先验证页面和 iframe 能否加载花瓣。
2. 在 Pin 内的花瓣页面手动登录，确认登录状态是否能保持。
3. 从花瓣复制一张图片，在 Pin 画布按 `Command + V`。
4. 确认图片进入本工作区的“新添加截图”并出现在画布。
5. 确认原 Pin 的 `8765` 服务和素材完全不受影响。
