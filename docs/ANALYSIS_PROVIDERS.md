# 配置分析 Provider

`DayreedAnalysis` 提供可实际调用的 OpenAI 兼容 HTTP Provider、本机 Codex CLI Provider 与 Claude CLI Provider。初始没有选定配置，不读取其他项目的环境变量、密钥或记录。CLI 是外部客户端，通常仍发送数据到它的服务商，**不等同于本地推理**。

App 中添加 `DayreedAnalysis` 依赖，保留一个 `AnalysisService` 实例：

```swift
import DayreedCore
import DayreedAnalysis

let settings = ProviderSettingsService(store: store)
let configuration = ProviderConfiguration(
    name: "我的接口", kind: .openAICompatible, model: userModel,
    endpoint: userEndpoint, supportsImages: false
)
try settings.save(configuration)
// 仅使用用户在 Dayreed 明确输入的密钥；不要从环境或其他项目探测。
try settings.setAPIKey(userSuppliedKey, for: configuration.id)
try settings.select(id: configuration.id)
let analysis = try AnalysisService(store: store)
try await analysis.updateCaptureContext(settings: captureSettings, paused: captureIsPaused)
// 用户点击分析后：
try await analysis.analyze(in: selectedDateInterval)
```

`endpoint` 是完整的 Chat Completions URL，例如 `https://example.com/v1/chat/completions`。模型名由用户指定；仅 HTTPS 和显式 loopback HTTP 可用，不接受 URL 内用户名、密码、查询串。HTTP 会话禁用缓存、Cookie、凭据缓存和重定向；请求不提供任何工具定义。Keychain service 是独立的 `YunaBuild.Dayreed.providers`，按配置 UUID 保存，不同步跨设备。配置数据不含密钥。

仅把当前启用且实际可用的来源交给选定 Provider。历史应用名、窗口标题、AX 文本和截图分别筛选；只有文字的历史不需要截图或视觉模型。包含截图时用户需声明模型支持图像，Claude CLI 当前只提供文字输入。每条观测有 recordID 和 evidenceID，模型不能生成计时时间段。

Provider 不成功、拒绝、空响应、格式不完整、超时、取消或意外工具调用都返回内容无关的 `AnalysisError`。不会把响应体、密钥或原文写入日志。单次输入最多 16 MiB，服务批次原始证据最多 8 MiB，输出最多 1 MiB；超过限制明确失败，不静默截去观测。已完成批次保留，后续批次失败时整轮状态仍为失败，`processedRecords` 显示此前成功数量。

切换 Provider、修改配置、关闭来源、暂停/停止和删除都会使相关在途结果失效。App 在变更采集状态之前调用并等待 `updateCaptureContext(settings:paused:)`；删除前先按采集文档暂停。服务在提交事务中再次核对上下文 revision、来源和记录存在性。`cancel()` 取消本轮，`status` 和 Core `query.analysisStatus()` 提供同一内容安全的状态。

周期分析是独立的显式选择：

```swift
try await analysis.configureSchedule(AnalysisSchedule(
    enabled: true, everySeconds: 300, currentDayOnly: true,
    timeZoneIdentifier: "Asia/Shanghai"
))
```

调度设置持久化，默认仅处理指定时区当天，第一次执行在设置间隔后；可显式设 `currentDayOnly: false` 并通过 `lookbackSeconds` 改用回看区间。重启 App 后先恢复采集状态，再显式调用 `restoreSchedule()` 恢复此前启用的调度。`stopSchedule()` 只停止当前计时任务及它发起的在途请求；保存 `enabled: false` 才关闭持久化选择。初始化服务不会启动计时器或联网。常规分析会跳过已有匹配配置/来源的标注；`reanalyze: true` 可重新分析，但保留用户纠正。

## 本机 CLI

用户选择明确的可执行文件，设置 `kind: .codexCLI` 或 `.claudeCLI` 及模型名。不运行拼接的 shell；原生 `Process` 使用独立 argv、stdin、stdout/stderr 大小限制、超时和取消。采集内容不出现在命令参数中。进程忽略 SIGTERM 时会对该进程发送 SIGKILL。CLI 执行目录是只含本轮必要内容的私有临时目录，结束后清理。

认证方式由用户选择：

- `.dayreedAPIKey`：从本应用 Keychain 取用户明确提供的 key，只为该进程设置 `CODEX_API_KEY` 或 `ANTHROPIC_API_KEY`。CLI 的 HOME/配置目录均使用临时目录。
- `.existingLogin`：用户明确同意使用本机 CLI 当前身份，并提供该 CLI 的 `cliConfigurationDirectory`（例如其日常使用的配置目录）。Dayreed 不读取/复制里面的认证文件，CLI 自行处理认证；其项目配置、规则、工具和持久化会话仍被关闭。此选择可能使用对应订阅配额。

Codex 需要支持 `--ignore-user-config`、`--ignore-rules`、`--strict-config`、`--ephemeral` 的版本。调用禁用 shell、MCP、插件、浏览器、计算机、图像读取和多 Agent 等功能，并通过官方支持的 `model_catalog_json` 指定禁用 shell、无 patch 工具、无模型扩展工具的元数据；同时关闭计划与询问工具。保留只读沙箱。仅关 shell 不会移除 `apply_patch`，因此模型工具设置也是必需的。参数不支持就报错，不自动改用更宽松模式。

Claude 的 API Key 模式使用 `--bare`；复用现有登录使用 `--safe-mode`。两种模式都传入 `--tools ""`、`--disallowedTools "*"`、空 MCP 配置及 `--strict-mcp-config`、空 setting sources、关闭 hooks、不保存会话和最大 1 轮。不同 CLI 版本不支持所需选项时明确失败。运行前先读取用户选定可执行文件的 help，不向 help 调用传密钥或观测。

核对依据：[Codex CLI](https://developers.openai.com/codex/cli/reference/)、[Codex 配置](https://developers.openai.com/codex/config-reference/)、[Codex 工具装配源码](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/spec_plan.rs)、[模型元数据源码](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/openai_models.rs)、[Claude CLI](https://code.claude.com/docs/en/cli-reference)、[Claude 非交互调用](https://code.claude.com/docs/en/headless)。

验证区分：自动测试使用临时目录与合成样本，覆盖真实本机 HTTP 传输、原生进程、解析和取消；本机 Codex 加 loopback 合成 Responses 已实测请求 `tools=[]` 并完成。0.1 另已完成 MiniMax 文本/组合合成样本受控请求，以及真实 TextEdit 合成采集到 Qwen 分析、时间线和报告保存。上述结果不代表独立视觉准确率或所有模型质量；用户现有 CLI 登录身份与 Claude 安装实例未验。详见 [0.1 验收范围](ACCEPTANCE_0.1.md)。
