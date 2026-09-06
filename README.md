# Dayreed

[![CI](https://github.com/Kamisato-Yuna/Dayreed/actions/workflows/ci.yml/badge.svg)](https://github.com/Kamisato-Yuna/Dayreed/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

个人工作记录与回顾工具，面向 macOS 26。用原生界面检查时间线、日报和周报，通过本地 CLI/MCP 向本人使用的 Agent 提供记录。

**0.1 是早期开发版本，尚无正式 Release。** 已实现独立多源采集、SQLite 证据存储、原生回顾界面、可编辑日报周报和只读 CLI/MCP；正式图标由 Icon Composer 分层制作，更新与签名分发工具仅面向本仓库。已接入 OpenAI 兼容接口及 Codex/Claude CLI 分析 Provider，自动分析需单独开启。真实采集、Provider 配置与分析体验、安装更新仍需持续验证和完善；已实现功能不代表达到 1.0 的可用性。

## 产品方向

- 原生 Liquid Glass、系统字体和控件，支持浅色/深色；直接进入主界面。
- 时间线、日报、周报，以及独立设置窗口；不提供 App 内 Chat。
- 定期截图与应用切换/窗口标题/可访问性文本分别可选；允许仅启用一个来源或全部关闭。
- 本地优先。已启用来源可由用户明确选定的 AI Provider 分析；Agent 默认不输出原始内容。
- 不提供遥测、内置反馈、账号或多设备同步。公开 Issues 用于开源项目协作。
- 正式制品仅来自本仓库的 [Releases](https://github.com/Kamisato-Yuna/Dayreed/releases)。

## 开发

需要 macOS 26+、支持 Icon Composer 的 Xcode 26+（Swift 6.2+），并将命令行工具指向相应 Xcode。

```sh
swift build
swift test
./script/build_and_run.sh --verify
swift run dayreed status --json
```

GUI 应通过生成的 `build/debug/Dayreed.app` 启动，避免直接运行 SwiftPM GUI 二进制。`dayreed` CLI 同时随 App 放在 `Contents/Helpers/dayreed`。

```text
Sources/DayreedApp/    原生 App、页面与设置
Sources/DayreedCore/   App 与 CLI 共享的本地能力
Sources/DayreedCapture/ 独立截图与计算机历史采集
Sources/DayreedAnalysis/ 用户选定 Provider 与自动分析
Sources/DayreedAgent/  只读查询与 stdio MCP
Sources/DayreedUpdate/ 本仓库签名更新
Sources/DayreedCLI/    命令行入口
Tests/                有关本轮实现的测试
script/               构建、运行与公证工具
docs/                 对外使用和维护文档
```

临时计划、实验、验收记录放入被忽略的 `docs/local/`；Agent 配置、构建产物和凭据也不进入 Git。旧 Dayflow 仓库已退役，仅作参考；此仓库使用独立历史、身份和目录，不自动访问或迁移旧应用数据。

## 使用说明

- [App 回顾与设置](docs/APP_GUIDE.md)
- [采集、隐私与本地存储](docs/CAPTURE_AND_STORAGE.md)
- [时间线与可编辑报告](docs/REPORTS_AND_QUERY.md)
- [分析 Provider 配置](docs/ANALYSIS_PROVIDERS.md)
- [CLI 安装与 MCP 配置](docs/AGENT.md)
- [Icon Composer 图标源与编译](Resources/Branding/README.md)

## 参与与发布

由 [@Kamisato-Yuna](https://github.com/Kamisato-Yuna) 个人维护。请先阅读 [贡献指南](CONTRIBUTING.md)、[安全说明](SECURITY.md)和[发布说明](docs/RELEASING.md)。功能计划通过 Issues 和 0.1 milestone 管理。

代码使用 [MIT License](LICENSE)。Sparkle 使用其独立许可，分发包保留相应版权和许可说明。
