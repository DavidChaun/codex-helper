# Codex Helper 1.11.1

- 移除 `POST /workbuddy/v1/search` 与 `POST /workbuddy/v1/fetch` 两个端点，以及背后的整个搜索客户端。这两个端点返回的内容质量不稳定，实际价值有限。
- 代理现在只负责模型转发：`/health`、`/model`、`/workbuddy/v1/models`、`/workbuddy/v1/chat/completions`、`/workbuddy/v1/messages`。

支持 Apple Silicon（M 系列）Mac，macOS 15 或以上。
