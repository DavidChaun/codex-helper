# Codex Helper 1.8.9

- 新增默认关闭的 Debug Mode，仅本次运行有效。开启后按提供商、模型和时间将请求日志保存到 `~/Downloads/CodexHelper-Debug/`。
- 记录 Helper 收到的请求、实际发给上游的 JSON、HTTP 状态、错误正文及耗时，支持 WorkBuddy 和 Trae。不保存完整回答。
- 不记录鉴权头，隐藏结构化凭据字段并省略 Base64 二进制内容；写入失败自动关闭 Debug Mode，不影响代理请求。
- 日志仍可能包含私人对话和代码，分享前请检查，分析后手动清理。记录的是 OpenCodex 转换后的请求，不是 Claude Desktop 的原始请求。
