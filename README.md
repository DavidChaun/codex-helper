# Codex Helper

从 [GitHub Releases](https://github.com/DavidChaun/codex-helper/releases/latest) 下载已构建的应用；此仓库同时包含 macOS 源码、图标和构建所需的 Sparkle 依赖。

双击 **Codex Helper.app** 即可运行。应用仅出现在 Mac 顶部菜单栏，不占用 Dock。

应用包含独立的 Codex Helper 图标，便于在 Finder、应用程序目录和系统设置中识别。

本次提供的应用支持 **Apple Silicon（M 系列）Mac，macOS 15 或以上**。接收者需要自行安装 Codex CLI，并用自己的 ChatGPT 账户登录；压缩包不包含发送者的账户凭据。建议先把应用拖入「应用程序」，再双击启动。

应用启动后会分别检测 Codex CLI、OpenCodex 和 WorkBuddy CLI。缺少组件时，点击菜单顶部提示即可复制安装命令；OpenCodex 的命令会先通过 Homebrew 安装 Node.js。WorkBuddy 无命令行安装器，点击提示会复制官网地址，安装后需登录。

应用尚未经过 Apple 开发者签名及公证。若首次打开受到阻止，在确认文件来自可信来源后，可按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 前往「系统设置 → 隐私与安全性 → 仍要打开」。

- 菜单栏采用紧凑的上下两行：`5h: 100%`、`1w: 94%`，表示 5 小时窗口剩余 100%、1 周窗口剩余 94%。窗口长度以接口实际返回为准。
- 点击菜单栏查看剩余进度条、账户套餐、各窗口重置时间（Mac 本地时区）。
- 默认每 10 秒同时刷新 Codex 额度和 WorkBuddy 积分。菜单中的「设置…」可填写 5–3600 秒，并可用「启用 WorkBuddy 功能」「启用 Trae 代理」两个开关分别启停两条代理路由（均默认开启）；保存后会提示成功并将按钮置灰，修改设置后按钮重新启用。关闭「启用 Trae 代理」会立即停用 Trae 路由、隐藏 Trae 菜单区块并清空其临时状态，WorkBuddy 不受影响。唤醒 Mac 后自动刷新；上次请求尚未结束时不会重复发起。
- 读取失败时显示 ⚠，保留并明确标记上次结果，不会将未知额度显示为 0%。
- 当前菜单栏优先显示 `codex` 额度；接口返回多个额度组时，全部列在菜单中。
- 点击「退出 Codex Helper」关闭。
- OpenCodex 状态以单行 `OpenCodex Running` 或 `OpenCodex Stop` 显示。一级操作保留「开启代理」「关闭代理」「控制台」；「更多…」提供「配置 / 刷新 WorkBuddy 代理」（启用 WorkBuddy 功能时）与「配置 / 刷新 Trae 代理」（启用 Trae 代理时），两者都会开启自己的路由、写入 `openai-chat` provider、同步模型（两家 provider 各自动态发现模型），重复点击只刷新配置并保留既有模型选择，首次配置才启用该家的模型。将配置导出到 `~/Downloads/OCX_CONF.json`，或选择 JSON 文件确认后导入。
- 启用 WorkBuddy 功能后，可在菜单中启动 `127.0.0.1:58100` 的 Swift Chat Completions 代理。WorkBuddy 图形界面无需运行，但 `/Applications/WorkBuddy.app` 必须已安装且当前账户已登录。
- 代理提供 `/health`、`/workbuddy/v1/models`、`/workbuddy/v1/chat/completions`，WorkBuddy 的本机 API Key 为 `workbuddy-local`。OpenCodex 的 `workbuddy` provider 使用 `openai-chat` adapter，并指向 `http://127.0.0.1:58100/workbuddy/v1`。旧的无前缀 `/v1` 别名已删除，升级后需重新点击「配置 / 刷新 WorkBuddy 代理」写入新地址。
- 代理按 `workbuddy-cliproxy` 的实现调用 WorkBuddy `/v2/chat/completions`，上游保持强制流式；客户端 `stream: true` 返回 SSE，`stream: false` 或省略时返回标准 Chat Completion JSON，方便接入其他软件。代理还会替换两句上游拦截模板，并将 hy3 系列固定为 `reasoning_effort=high`。
- 同一个 `127.0.0.1:58100` 监听同时提供 Trae：`GET /trae/v1/models`、`POST /trae/v1/chat/completions`，本机 API Key 为 `trae-local`，OpenCodex 的 `trae` provider 指向 `http://127.0.0.1:58100/trae/v1`。登录态从 Trae 账号池取用（见下节），模型表来自 `get_detail_param`，对话走 `llm_utils_chat`（`function=solo_work_lite`）并把 `output.response`/`reasoning_content`/`tool_calls` 转成 OpenAI 格式；客户端 `stream: true` 返回 SSE，`stream: false` 或省略时返回 Chat Completion JSON。Trae 图形界面无需运行，但必须已登录 `/Applications/TRAE SOLO CN.app`；登录态失效会由上游 401 暴露，需要在 Trae 内重新登录。该 `trae` provider 不会写 `max_tokens` 默认值，只转发请求里显式给定的值。
- 两条路由各自独立开关：WorkBuddy 与 Trae 在自己的菜单区块分别显示 `Running` / `Stop`，并在各自「更多…」中提供默认勾选的「启用代理」。关闭其中一个只停用它的路由（该前缀返回 404），另一个照常服务；两个都关闭时才停掉 listener。路径不匹配任何前缀时一律 404，不会在两家 provider 之间回退。`/health` 始终可用，并回报两条路由的开关状态。
- 共享代理的启动条件：WorkBuddy 功能开启且已装 CLI，或 Trae 功能开启且本机装了 `/Applications/TRAE SOLO CN.app` / 留有 Trae 登录态，两者满足其一即可。
- WorkBuddy 一级菜单依次显示代理状态、当前账号剩余积分、账号池、模型列表和「更多…」。余额直接使用 WorkBuddy 新版 `get-user-resource-summary` 口径；「更多…」包含代理开关、curl 示例、签到、自动签到和刷新。Trae 区块采用相同布局。点击聊天模型会发送一条简短请求测速，菜单保持打开并显示完整响应耗时：低于 2 秒绿色、低于 5 秒棕色，其余红色；请求失败标红，测速会消耗少量积分。
- 开启代理执行 `ocx restart`、`ocx restore back`、`ocx sync --restart-codex`；关闭代理先恢复原生配置并重启 Codex app-server，再执行 `ocx stop`、`ocx restore`。切换时会刷新 model list，也可能中断正在运行的 Codex 任务。
- 「控制台」调用 `ocx gui`。

## WorkBuddy 多账号行为

- 在 WorkBuddy 切换并登录新账号后，选择「账号池 → 保存当前 WorkBuddy 登录账号」将其加入账号池。切换 WorkBuddy 当前登录不会退出或覆盖池中已有账号；新账号不会自动加入。
- 菜单可手动指定优先账号。请求成功后，实际使用的账号会成为后续请求的优先账号。
- 代理不是遇到任意 API 错误都切号。只有上游返回 HTTP 429/500，且错误包含「频率限制」「使用量已超出」或 `rate limit` 时，才会为该“账号 + 模型”记录冷却时间并尝试下一个账号。
- HTTP 401 只刷新当前账号 Token 并重试一次；普通 HTTP 500、网络错误不会切号。所有账号均不可用时，错误原样返回。
- SSE 已经开始输出后不会中途切换账号，避免同一条回答混入两个账号的状态。
- 「每日自动签到」会依次检查账号池中的全部账号，每个账号每天最多自动尝试一次；单个账号失败不会阻断其他账号。手动「立即签到」只操作当前优先账号。
- 账号元数据和 Token 明文保存在 `~/Library/Application Support/Codex Helper/wb-accounts.plist`（权限 `0600`）。Codex Helper 不会主动切换或覆盖 WorkBuddy App 当前登录的账号。

## Trae 多账号行为

Trae 使用独立账号池：元数据和 Token 明文保存在 `~/Library/Application Support/Codex Helper/trae-accounts.plist`（权限 `0600`），与 WorkBuddy 完全隔离，两边切号互不影响。

选择「Trae 账号池 → 保存当前 Trae 登录账号」，会解密当前 `storage.json` 并按 `userId` 幂等写入：同一账号只覆盖 Token 与展示名，不产生重复条目。首次使用且池为空时，请求会自动导入当前登录，无需手动点一次。菜单中勾选即设为优先账号。

取用顺序为：优先账号在前，其余按 `lastUsedAt` 从旧到新。仅在请求尚未开始输出、且上游返回 HTTP 401/403/429/5xx 时才尝试下一个账号；SSE 一旦开始输出就绝不切换，避免同一条回答混入两个账号的状态。Trae 没有已知的 Token 刷新接口，因此不做自动刷新，也不臆造余额与限流冷却：Token 过期后请在 Trae 内重新登录，再点一次「保存当前 Trae 登录账号」。

使用本机 Codex CLI 的当前登录状态，通过官方 `account/rateLimits/read` 接口读取账户额度。应用不读取或保存 Token，不发起模型任务，也不消费额度重置次数；子进程关闭 analytics。需要 Codex 使用 ChatGPT 账户登录并能访问网络。第三方模型服务的余额不在此接口范围内。

检测到 OpenCodex 包装器时，额度查询优先调用其保留的原生 Codex 可执行文件，避免定时查询意外启动已关闭的代理。「打开 OpenCodex Dashboard」本身会在代理未运行时按 OpenCodex 的标准行为启动代理。

若希望开机自动运行，可先将应用移到固定目录，再在「系统设置 → 通用 → 登录项」中添加该应用。

源码按 `CodexQuotaBar.swift`、`WorkBuddyAccountPool.swift`、`WorkBuddyClient.swift`、`TraeAccountPool.swift`、`TraeClient.swift` 和 `WorkBuddyProxy.swift` 分层（`WorkBuddyProxy.swift` 承载两条路由共用的 listener）。安装 Xcode Command Line Tools 后，在此目录运行 `sh build.sh` 即可重新编译并运行内置检查；生成的 `.build/` 和 `Codex Helper.app/` 不纳入 Git。`--check` 验证 Codex 额度，`--check-workbuddy` 验证 WorkBuddy 积分和模型，`--serve-proxy` 可单独运行两条代理路由；验证时可用环境变量 `CODEX_HELPER_PROXY_PORT` 换端口、`CODEX_HELPER_WORKBUDDY=0` / `CODEX_HELPER_TRAE=0` 单独关闭某条路由。

参考：[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。
