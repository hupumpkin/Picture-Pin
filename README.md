# 截图分析管理工具 - AI 设计规范工作流

本项目采用 `App-Design-System/README.md` 中的 AI 辅助设计规范流程，并按当前项目调整为：

1. 灵感挖掘与风格探索
2. 设计 Token 系统化生成
3. 可视化验证
4. 生成 `DESIGN.md`
5. 根据 `DESIGN.md` 实现页面
6. 迭代、测试与交付

核心原则：用户担任设计决策者，AI 负责分析、生成、整理和代码落地。所有视觉规则最终沉淀到 `DESIGN.md`，作为后续页面实现的单一真实来源。

## 当前状态

- 当前阶段：阶段一 / 步骤 1，建立灵感参考库
- 下一步：收集 10-15 张参考截图，并按页面类型放入 `exploration/references/`
- 关键产物：先产出 `exploration/dna-analysis.md`，再生成 `tokens/`、`specs/` 和 `DESIGN.md`

## 目录说明

```text
.
├── DESIGN.md
├── tokens/
├── specs/
├── exploration/
│   ├── references/
│   ├── moodboards/
│   ├── dna-analysis.md
│   └── style-directions.md
├── pages/
└── assets/
```

## 参考截图建议

请优先收集这些类型：

- 首页 / 工作台 / 列表页
- 图片详情 / 分析结果页
- 任务管理 / 历史记录页
- 设置 / 个人中心

如果没有同类产品参考，也可以放跨行业参考，例如 Notion、Linear、Airbnb、Mobbin 上的高质量 iOS / Web 管理工具界面。
