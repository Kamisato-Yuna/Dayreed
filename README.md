# Dayreed

[![CI](https://github.com/Kamisato-Yuna/Dayreed/actions/workflows/ci.yml/badge.svg)](https://github.com/Kamisato-Yuna/Dayreed/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

个人工作记录与回顾工具，面向 macOS 26。用原生界面检查时间线、日报和周报，通过本地 CLI/MCP 向本人使用的 Agent 提供记录。

**目前处于全新开发阶段，尚无正式可用版本。** 已提供原生导航与设置外壳、App 打包入口和 CLI 版本/能力查询；采集、持久化、报告、MCP、正式 VI 与自动更新尚未接入。界面不显示虚构记录，CLI 会明确报告未实现的能力。

## 产品方向

- 原生 Liquid Glass、系统字体和控件，支持浅色/深色；直接进入主界面。
- 时间线、日报、周报，以及独立设置窗口；不提供 App 内 Chat。
- 定期截图与应用切换/窗口标题/可访问性文本分别可选；允许仅启用一个来源或全部关闭。
- 本地优先。已启用来源可由用户明确选定的 AI Provider 分析；Agent 默认不输出原始内容。
- 不提供遥测、内置反馈、账号或多设备同步。公开 Issues 用于开源项目协作。
- 正式制品仅来自本仓库的 [Releases](https://github.com/Kamisato-Yuna/Dayreed/releases)。

## 开发

需要 macOS 26+、Xcode 26+（Swift 6.2+），并将命令行工具指向相应 Xcode。

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
Sources/DayreedCLI/    命令行入口
Tests/                有关本轮实现的测试
script/               构建、运行与公证工具
docs/                 对外使用和维护文档
```

临时计划、实验、验收记录放入被忽略的 `docs/local/`；Agent 配置、构建产物和凭据也不进入 Git。旧 Dayflow 仓库已退役，仅作参考；此仓库使用独立历史、身份和目录，不自动访问或迁移旧应用数据。

## 参与与发布

由 [@Kamisato-Yuna](https://github.com/Kamisato-Yuna) 个人维护。请先阅读 [贡献指南](CONTRIBUTING.md)、[安全说明](SECURITY.md)和[发布说明](docs/RELEASING.md)。功能计划通过 Issues 和 1.0 milestone 管理。

代码使用 [MIT License](LICENSE)。今后如引入第三方代码或资源，保留相应版权和许可说明。
