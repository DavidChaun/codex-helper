# Codex Helper 1.11.0

- 移除「自动网页搜索」开关及其全部实现。代理不再注入 `WebSearch`/`WebFetch` 定义，也不再代执行工具调用或自行续轮。
- 模型返回的 `tool_calls` 现在原样透传给客户端，工具循环完全交给客户端（T3 Code、Claude Desktop 等）。这同时修掉了开启该功能后流式输出失效的问题。
- `POST /workbuddy/v1/search` 与 `POST /workbuddy/v1/fetch` 保留，作为客户端可自行调用的搜索与抓取后端。

支持 Apple Silicon（M 系列）Mac，macOS 15 或以上。
