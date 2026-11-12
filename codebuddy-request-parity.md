# WorkBuddy 代理 vs CodeBuddy CLI 2.183.0：请求一致性对照

对照基准：`@tencent-ai/codebuddy-code@2.183.0` 通过 `--acp` 运行时的真实线上请求。
抓取方式：在 CLI 启动前用 `NODE_OPTIONS=--require` 预加载钩子替换 `http`/`https` 的 `request`，
落盘 URL、完整请求头与解压后的 body；Token 字段脱敏，抓完即删。
对照对象：本仓库 `WorkBuddyClient.makeRequest(_:route:body:accountAPI:)`。

## 实测请求（原文摘录）

```
POST https://copilot.tencent.com/v2/chat/completions
Content-Type: application/json
Content-Encoding: gzip
Content-Length: 36639          (解压后 34651 字节 JSON)

Accept: application/json
X-Requested-With: XMLHttpRequest
x-codebuddy-request: 1
User-Agent: CLI/2.183.0 CodeBuddy/2.183.0
X-IDE-Type: CLI      X-IDE-Name: CLI      X-IDE-Version: 2.183.0
X-Agent-Intent: craft     X-Agent-Runtime: other
X-Agent-Purpose: conversation     X-Agent-Type: main
X-Private-Data: false
X-Conversation-ID: 01a1cdd0-b9b2-722d-a5e5-0ca733422839
X-Conversation-Message-ID: 01a1cdd0ba8f7ff38cd2b9009ca48fc5
X-Conversation-Request-ID: 01a1cdd0b9d47475ab1b7f2194f90a22
X-Root-Request-ID: 01a1cdd0b9d47475ab1b7f2194f90a22
X-Request-ID: 01a1cdd0ba8f7ff38cd2b9009ca48fc5
traceparent: 00-<trace>-<span>-01
b3: <trace>-<span>-1-<parent>
X-B3-TraceId / X-B3-ParentSpanId / X-B3-SpanId / X-B3-Sampled / X-Trace-ID
baggage: codebuddy.session_id=...,codebuddy.conversation_request_id=...
x-stainless-lang: js   x-stainless-os: MacOS   x-stainless-arch: arm64
x-stainless-runtime: node   x-stainless-runtime-version: v26.x
x-stainless-package-version: 7.39.0   x-stainless-retry-count: 0
Authorization: Bearer <jwt>          (脱敏)
X-User-Id: <uid>
X-Domain: www.codebuddy.cn
X-Product: SaaS
```

会话 ID 使用带连字符的 UUIDv7；其余 ID 使用去掉连字符的 32 位十六进制。首轮的 Conversation-Request-ID 与 Root-Request-ID 相同，会话 ID 独立生成。

body 顶层字段：`model, messages, tools, temperature, max_tokens, stream,
stream_options{include_usage}, reasoning_effort, verbosity, extra_vars,
cache_retention, reasoning_summary`。

`extra_vars` = `{"harnessMetadata":"{\"schemaVersion\":1,\"harnessVersion\":\"2.183.0\",
\"stepIndex\":0,\"contextWindowId\":\"...\",\"agent\":{\"depth\":0}}",
"initiator":"user","interactionType":"prompt"}`。

## 与改造前代理的差异

| # | 项 | CodeBuddy CLI | 改造前 | 影响 |
|---|---|---|---|---|
| 1 | `User-Agent` | `CLI/2.183.0 CodeBuddy/2.183.0` | 硬编码 `CLI/2.63.2 CodeBuddy/2.63.2` | 版本号与真实 CLI 差 120 个小版本，可能被网关按版本做能力/配额分流 |
| 2 | 会话关联 ID | `X-Conversation-ID`、`-Message-ID`、`-Request-ID`、`X-Root-Request-ID` 四件套 | **完全缺失** | 网关据此串联同一会话、做上下文缓存与计费归属；缺失时每请求各自独立 |
| 3 | `X-Agent-*` | `Intent/Runtime/Purpose/Type` 四项 | **完全缺失** | 网关按 intent 选择 system prompt 增强、按 runtime 统计客户端类型 |
| 4 | 追踪头 | `traceparent`、`b3`、`X-B3-*`、`X-Trace-ID`、`baggage` | **完全缺失** | 服务端 trace 断链；`baggage` 里的 session 关联也丢失 |
| 5 | SDK 指纹 | `x-stainless-*` 六项 | **完全缺失** | 客户端识别（Anthropic SDK 派生）消失，可能命中不同的兼容分支 |
| 6 | `X-Request-ID` | 32 位十六进制，与 Message-ID 同值 | **完全缺失** | 上游报错时无法定位；本仓库只在 *接收* 侧读取调用方的 `X-Request-ID` |
| 7 | `x-codebuddy-request` | `1` | **完全缺失** | 网关轻量识别标记 |
| 8 | `X-Private-Data` | `false` | **完全缺失** | 隐私数据通路开关的显式声明 |
| 9 | `extra_vars` | 含 `harnessMetadata` / `initiator` / `interactionType` | **完全缺失** | 网关侧的调用链元数据与发起者归因 |
| 10 | body 字段 | 含 `verbosity`、`cache_retention:"long"`、`reasoning_summary:"auto"`、`stream_options.include_usage` | 原样透传，通常没有 | 缓存寿命与推理摘要行为不同；`include_usage` 缺失会让流式响应没有 usage |
| 11 | `X-Domain` | 来自登录态 `auth.domain` | ✅ 已实现 | — |
| 12 | `X-User-Id` / `X-Product` / `X-IDE-*` | 有 | ✅ 已实现 | — |
| 13 | `Origin` / `Referer` | **没有** | ❌ 额外添加 `https://www.codebuddy.cn` | 真实 CLI 是 Node 进程，不发这两个头；多出的浏览器指纹反而是偏差 |
| 14 | `X-Refresh-Token` | **不在模型请求里发** | ❌ 每个请求都发 | refresh token 随模型请求外泄，且与真实客户端不符 |
| 15 | `Authorization` | `Bearer <accessToken>` | ✅ 已实现 | — |
| 16 | 端点与方法 | `POST /v2/chat/completions` | ✅ 已实现 | — |
| 17 | 请求体压缩 | `Content-Encoding: gzip` | ❌ 明文 | 非必需，但真实的 HTTP 指纹是压缩体 |

## 结论

本仓库的骨架（端点、鉴权、`X-Domain`/`X-User-Id`/`X-Product`/`X-IDE-*`）是对的；
缺失集中在三类：**会话关联 ID**、**客户端/运行时语义头**、**body 适配字段**。
其中 17 条里真正会改变上游行为的核心是 2、3、9、10，其余是提高一致性、降低被识别为异常客户端概率的补全。
第 13、14 条属于**反向偏差**，建议一并收敛。
