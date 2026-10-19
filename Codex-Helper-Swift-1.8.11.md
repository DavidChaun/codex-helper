# Codex Helper 1.8.11

- 统一 WorkBuddy 与 Trae 的搜索能力声明：支持由客户端 / MCP 执行的普通 function 搜索工具，不支持服务端内置搜索与抓取。
- 服务端 `web_search` / `web_fetch` 工具及相关搜索配置统一返回 HTTP 400，错误码为 `unsupported_server_search`，并指出不支持的字段；流式与非流式请求行为一致，不再静默忽略。
- 普通 function 工具即使命名为 `web_search`、`WebSearch` 或 `mcp__search` 也不会被误拦；Trae 保留工具定义，仅执行必要的参数格式转换。
- 修复 Trae 忽略 `tool_choice: "none"` 的问题：调用方明确禁用工具时，不向上游发送工具列表。

使用搜索时，请关闭调用软件的服务端内置搜索配置，改用客户端 / MCP 执行的普通 function 搜索工具。Codex Helper 本身不执行搜索。
