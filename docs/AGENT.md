# 在 Agent 中使用 Dayreed

CLI 与 App 查询同一份本地记录。CLI/MCP 只读，包含分析后的时间线、已保存报告及来源标识，不返回截图、窗口标题或辅助功能正文，不启动采集或调用 AI Provider。报告和时间线正文仍属于个人内容；只把 MCP 配置添加到本人信任的 Agent。

## 安装和发现

将 Dayreed.app 放在准备长期使用的位置，再运行随包的安装脚本：

```sh
bash /Applications/Dayreed.app/Contents/Resources/install_cli.sh install --app /Applications/Dayreed.app
```

默认创建 `~/.local/bin/dayreed` 链接，不修改 shell 配置，不使用 sudo。若该目录不在 PATH，可直接使用 `~/.local/bin/dayreed`。开发目录也可运行 `script/install_cli.sh install --app build/debug/Dayreed.app`，但重建或移动开发 App 会影响链接。

`--bin-dir` 可指定自己的安装目录。重复安装到同一 App 不会覆盖其他目标；同名普通文件或其他链接会报错。卸载只移除属于所选 App 的链接，保留 App 与数据：

```sh
bash /Applications/Dayreed.app/Contents/Resources/install_cli.sh uninstall --app /Applications/Dayreed.app
```

## 查询

```sh
~/.local/bin/dayreed status --json
~/.local/bin/dayreed timeline --date 2026-09-06 --timezone Asia/Shanghai --json
~/.local/bin/dayreed report daily --date 2026-09-06 --timezone Asia/Shanghai --markdown
~/.local/bin/dayreed report weekly --date 2026-09-06 --timezone Asia/Shanghai --json
```

日期使用 `YYYY-MM-DD`；必须明确指定，时区默认本机时区。时间区间为左闭右开，周报按指定时区从 ISO 周一开始，包含夏令时日期的实际长度。

时间线默认每页 100 项，可用 `--limit 1...500` 调整。`nextCursor` 非空表示还有后续页，将它作为 `--cursor` 传回并保持相同日期和时区；只有返回 null 才到末页。JSON 的 `observedSeconds` 表示相邻观测支持的区间，零时长是单次观测，不代表该活动没有发生。记录缺失处不会补算活动时长。

日报/周报读取已经保存的正文，不会隐式生成报告。`isEdited` 表示手工编辑，`needsReview` 表示来源之后发生变化。App 中查看、生成与确认替换报告。

错误写到 stderr，格式为 `{"error":{"code":"...","message":"..."}}`；不含底层数据库正文或路径。退出码：0 成功，1 运行或输出失败，2 参数/日期错误，3 本地数据或查询不可用，4 报告尚不存在。`status` 在尚未初始化时返回 `dataAvailable: false`，能力字段不等于实时采集正在运行。

## MCP 配置

运行以下命令取得当前 helper 的完整路径配置：

```sh
~/.local/bin/dayreed mcp-config
```

对于使用 `mcpServers` 的客户端，配置形如：

```json
{
  "mcpServers": {
    "dayreed": {
      "command": "/Applications/Dayreed.app/Contents/Helpers/dayreed",
      "args": ["mcp"]
    }
  }
}
```

路径直接作为进程参数传递，包含空格也不需要自行拼接 shell。Codex 使用其 MCP 设置添加同一 command 与 args；具体配置格式以所用客户端为准。

可用工具只有三个：

| 工具 | 输入 | 结果 |
| --- | --- | --- |
| `dayreed_status` | 无 | 本地可用性、配置来源和分析状态 |
| `dayreed_timeline` | `date`，可选 `timezone`、`limit`、`cursor` | 派生时间线分页及来源 ID |
| `dayreed_report` | `kind: daily/weekly`、`date`，可选 `timezone` | 已保存报告及编辑状态 |

工具拒绝 raw、路径、SQL、任意文件和修改参数。整个进程以 SQLite 只读模式打开固定的 Dayreed 数据目录，不提供远程监听端口。stdout 仅输出换行分隔的 JSON-RPC，不记录原始请求或个人内容。

实现兼容 2024-11-05、2025-03-26、2025-06-18 和 2025-11-25 的初始化握手。采用新版协议的客户端可按 [MCP 官方 stdio 兼容规则](https://modelcontextprotocol.io/specification/2026-07-28/server/discover) 回退到这些版本；本服务器未声明实现 2026-07-28 的全部新协议。
