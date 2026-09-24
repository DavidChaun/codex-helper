# Codex Helper 1.8.6

- WorkBuddy 与 Trae 的 Chat Completions 接口支持非流式响应：省略 `stream` 或设为 `false` 时返回 JSON，`true` 保持 SSE。
- 非流式结果保留正文、工具调用、结束原因及上游提供的用量；流内错误返回 JSON 错误。
