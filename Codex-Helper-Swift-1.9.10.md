# Codex Helper 1.9.10

- 自动将 11 月 9 日起 OpenCodex 报告的 GPT 用量合并到费用估算。能唯一匹配的原生记录只计一次，缺失的计价字段由 OpenCodex 补齐。
- OpenCodex 请求缺少原生测速时，使用请求开始到最后一次输出的耗时计算 `tok/s avg`。
- 金额大于零但按美分舍入为零时，显示 `<$0.01` 并保留模型行。

支持 Apple Silicon（M 系列）Mac，macOS 15 或以上。
