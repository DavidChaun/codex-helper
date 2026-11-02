# Codex Helper

从 [GitHub Releases](https://github.com/DavidChaun/codex-helper/releases/latest) 下载已构建的应用；此仓库同时包含 macOS 源码、图标和构建所需的 Sparkle 依赖。

双击 **Codex Helper.app** 即可运行。应用仅出现在 Mac 顶部菜单栏，不占用 Dock。

应用包含独立的 Codex Helper 图标，便于在 Finder、应用程序目录和系统设置中识别。

本次提供的应用支持 **Apple Silicon（M 系列）Mac，macOS 15 或以上**。接收者需要自行安装 Codex CLI，并用自己的 ChatGPT 账户登录；压缩包不包含发送者的账户凭据。建议先把应用拖入「应用程序」，再双击启动。

应用启动后检测 Codex CLI；仅在设置中启用对应功能后，才检测 OpenCodex 或 WorkBuddy CLI。启用功能所需组件缺失时，点击菜单顶部提示即可复制安装命令；OpenCodex 的命令会先通过 Homebrew 安装 Node.js。WorkBuddy 无命令行安装器，点击提示会复制官网地址，安装后需登录。

应用尚未经过 Apple 开发者签名及公证。若首次打开受到阻止，在确认文件来自可信来源后，可按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 前往「系统设置 → 隐私与安全性 → 仍要打开」。

- 菜单栏采用紧凑的上下两行：`5h: 100%`、`1w: 94%`，表示 5 小时窗口剩余 100%、1 周窗口剩余 94%。窗口长度以接口实际返回为准。 只有一个额度窗口时，标签和百分比各占一行，例如仅有周额度时，上行为 `1w`、下行为 `100%`。
- 点击菜单栏查看剩余进度条、账户套餐、各窗口重置时间（Mac 本地时区）。
- 「费用估算（USD）」一级显示今日和当前周额度周期内累计的美元金额，二级按「模型 · 标准 / Fast / 未知」分别显示金额，同一模型不同档位的 token 分项分别累计，三级显示 token 总量及输入合计、未缓存输入、缓存命中、缓存写入、输出和其中推理分项，每行同时显示对应美元金额。分项金额逐次请求计算后汇总；缓存已含在输入金额中，推理已含在输出金额中，不重复相加。金额显示四舍五入到分；缺失 token 分类显示「未记录」。主菜单移除应用标题和标语，突出显示 Codex 名称及 ProLite 等实际套餐；宽度为 320 点，额度以圆角卡片展示，突出剩余百分比；菜单文字统一左对齐，使用字号、颜色和分组区分层级，并跟随系统浅色 / 深色外观。周额度周期按接口返回的周重置时间减去 7 天至重置时刻计算，不按自然周或自然月归集；模型子菜单底部直接显示周期起止时间，不使用悬停提示，未取得有效周重置时间时显示「周期暂不可用」。
- 「按日期区间查询…」可选择开始和结束日期（按本机时区，包含首尾当天），查询结果作为额外一行显示在今日、当前周额度下方，沿用「区间金额 → 模型金额 → token 分项」布局。可查询保留下来的历史会话和归档；范围变更在后台重算，查询范围仅本次运行有效。
- 金额按 [OpenAI 官方 API 单价](https://developers.openai.com/api/docs/pricing)估算（2026-11-01 核对），缓存写入采用默认 30 分钟价格；超过 272K 输入的请求按长上下文价格逐次计算后汇总，避免把日/月累计输入当成长上下文。读取日志中「已应用设置」事件的 `thread_settings.service_tier`：`default` / `standard` 按标准价，`fast` / `priority` 按标准价 ×2，分别应用于输入、缓存、输出和其中推理费用，原始 token 数量不变；按模型和档位分别汇总，`fast` 与 `priority` 合并为 Fast，标准、Fast、未知各占一行，一级金额为各组之和。
- 当前确认 GPT-6 Astra、GPT-6.1 Sol / Terra、GPT-6 Sol / Luna、GPT-5.6 Sol / Terra / Luna；未确认单价的模型（包括第三方模型）、未记录或不支持的档位，以及缺少计价所需 token 分项的记录，统一按 $0 计入。历史档位以日志事件为准，不用当前配置推测过去。金额是 API 参考价，不按套餐额度的 2.5 倍计算，未计地区附加费和工具费用；日志未记录的服务端回退档位、其他缓存寿命无法还原，不代表订阅实际账单。
- Token 统计只读 `$CODEX_HOME/sessions` 与 `archived_sessions`（默认 `~/.codex`），不依赖 OpenCodex，也不上传会话内容；按每次请求的事件时间归入对应统计区间，日期和周期起止时间以本机时区展示。`codex-auto-review` 完全排除，不显示条目，也不计入任何区间的 token、缓存分项或费用；未确认单价的其他模型仍保留并按 $0 估算。模型标签不能用于还原代理背后的真实模型，也不是官方计费账单。清理、缺失或未写入本机的历史不会被统计；无法读取的文件及缺失/异常用量会在菜单提示。读取在后台执行，已读文件只处理追加内容。
- 默认每 10 秒刷新 Codex 额度，WorkBuddy、Trae 仅在启用后刷新。菜单中的「设置…」可填写 5–3600 秒，并提供「启用 WorkBuddy 功能」「启用 Trae 代理」「启用 OpenCodex 功能」三个开关，未保存过设置时默认均不勾选，已有明确保存的选择继续保留。OpenCodex 不勾选时不检测安装或运行状态，隐藏其安装提示和相关菜单；保存后会提示成功并将按钮置灰，修改设置后按钮重新启用。关闭「启用 Trae 代理」会立即停用 Trae 路由、隐藏 Trae 菜单区块并清空其临时状态，WorkBuddy 不受影响。唤醒 Mac 后自动刷新；上次请求尚未结束时不会重复发起。
- 读取失败时显示 ⚠，保留并明确标记上次结果，不会将未知额度显示为 0%。
- 当前菜单栏优先显示 `codex` 额度；接口返回多个额度组时，全部列在菜单中。
- 点击「退出 Codex Helper」关闭。
- 设置中启用 OpenCodex 功能后，状态以单行 `OpenCodex Running` 或 `OpenCodex Stop` 显示。一级操作保留「开启代理」「关闭代理」「控制台」；「更多…」提供「配置 / 刷新 WorkBuddy 代理」（启用 WorkBuddy 功能时）与「配置 / 刷新 Trae 代理」（启用 Trae 代理时），两者都会开启自己的路由、写入 `openai-chat` provider、同步模型（两家 provider 各自动态发现模型），重复点击只刷新配置并保留既有模型选择，首次配置才启用该家的模型。将配置导出到 `~/Downloads/OCX_CONF.json`，或选择 JSON 文件确认后导入。
- 启用 WorkBuddy 功能后，可在菜单中启动 `127.0.0.1:58100` 的 Swift Chat Completions 代理。WorkBuddy 图形界面无需运行，但 `/Applications/WorkBuddy.app` 必须已安装且当前账户已登录。
- 代理提供 `/health`、`/workbuddy/v1/models`、`/workbuddy/v1/chat/completions`，WorkBuddy 的本机 API Key 为 `workbuddy-local`。OpenCodex 的 `workbuddy` provider 使用 `openai-chat` adapter，并指向 `http://127.0.0.1:58100/workbuddy/v1`。旧的无前缀 `/v1` 别名已删除，升级后需重新点击「配置 / 刷新 WorkBuddy 代理」写入新地址。
- 代理按 `workbuddy-cliproxy` 的实现调用 WorkBuddy `/v2/chat/completions`，上游保持强制流式；客户端 `stream: true` 返回 SSE，`stream: false` 或省略时返回标准 Chat Completion JSON，方便接入其他软件。代理还会替换两句上游拦截模板，并将 hy3 系列固定为 `reasoning_effort=high`。
- 同一个 `127.0.0.1:58100` 监听同时提供 Trae：`GET /trae/v1/models`、`POST /trae/v1/chat/completions`，本机 API Key 为 `trae-local`，OpenCodex 的 `trae` provider 指向 `http://127.0.0.1:58100/trae/v1`。登录态从 Trae 账号池取用（见下节），模型表来自 `get_detail_param`，对话走 `llm_utils_chat`（`function=solo_work_lite`）并把 `output.response`/`reasoning_content`/`tool_calls` 转成 OpenAI 格式；客户端 `stream: true` 返回 SSE，`stream: false` 或省略时返回 Chat Completion JSON。Trae 图形界面无需运行，但必须已登录 `/Applications/TRAE SOLO CN.app`；登录态失效会由上游 401 暴露，需要在 Trae 内重新登录。该 `trae` provider 不会写 `max_tokens` 默认值，只转发请求里显式给定的值。
- 两条路由各自独立开关：WorkBuddy 与 Trae 在自己的菜单区块分别显示 `Running` / `Stop`，并在各自「更多…」中提供默认勾选的「启用代理」。关闭其中一个只停用它的路由（该前缀返回 404），另一个照常服务；两个都关闭时才停掉 listener。路径不匹配任何前缀时一律 404，不会在两家 provider 之间回退。`/health` 始终可用，并回报两条路由的开关状态。
- 共享代理的启动条件：WorkBuddy 功能开启且已装 CLI，或 Trae 功能开启且本机装了 `/Applications/TRAE SOLO CN.app` / 留有 Trae 登录态，两者满足其一即可。
- WorkBuddy 一级菜单依次显示代理状态、当前账号剩余积分、账号池、模型列表和「更多…」。余额直接使用 WorkBuddy 新版 `get-user-resource-summary` 口径；「更多…」包含代理开关、curl 示例、签到、自动签到和刷新。Trae 区块采用相同布局。点击聊天模型会发送一条简短请求测速，菜单保持打开并显示完整响应耗时：低于 2 秒绿色、低于 5 秒棕色，其余红色；请求失败标红，测速会消耗少量积分。
- 开启代理执行 `ocx restart`、`ocx restore back`、`ocx sync --restart-codex`；关闭代理先恢复原生配置并重启 Codex app-server，再执行 `ocx stop`、`ocx restore`。切换时会刷新 model list，也可能中断正在运行的 Codex 任务。
- 「控制台」调用 `ocx gui`。

## 工具与搜索能力

WorkBuddy 和 Trae 两条 Chat Completions 代理均支持普通 `type: "function"` 搜索工具（包括以 function 形式接入的 MCP 工具）。模型返回 `tool_calls` 后，必须由客户端或 MCP 服务执行搜索，再将结果作为工具消息回传；Codex Helper 本身不执行搜索，也不接入 DeepSeek Search / Fetch API。普通 function 工具即使命名为 `web_search`、`WebSearch`、`web_fetch` 或 `mcp__search`，也不会仅因名称而被拒绝。

两条代理都不支持服务端内置 `web_search` / `web_fetch`。请求的 `tools` 或 `tool_choice` 使用这些类型（含 `web_search_preview`、`web_search_20250305` 等下划线后缀变体），或传入非 null 的 `web_search_options` 时，统一在发送上游请求前返回 HTTP 400，错误 `code` 为 `unsupported_server_search`，`param` 指出不支持的字段。不会静默删除工具、忽略搜索配置或返回假成功；流式与非流式请求规则相同。需要搜索时，请关闭客户端的服务端内置搜索配置，改用客户端 / MCP 执行的普通 function 搜索工具。

## WorkBuddy 多账号行为

- 在 WorkBuddy 切换并登录新账号后，选择「账号池 → 保存当前 WorkBuddy 登录账号」将其加入账号池。切换 WorkBuddy 当前登录不会退出或覆盖池中已有账号；新账号不会自动加入。
- 菜单可手动指定优先账号。请求成功后，实际使用的账号会成为后续请求的优先账号。
- 代理不是遇到任意 API 错误都切号。只有上游返回 HTTP 429/500，且错误包含「频率限制」「使用量已超出」或 `rate limit` 时，才会为该“账号 + 模型”记录冷却时间并尝试下一个账号。
- HTTP 401 只刷新当前账号 Token 并重试一次；普通 HTTP 500、网络错误不会切号。所有账号均不可用时，错误原样返回。
- SSE 已经开始输出后不会中途切换账号，避免同一条回答混入两个账号的状态。
- 「每日自动签到」会依次检查账号池中的全部账号，每个账号每天最多自动尝试一次；单个账号失败不会阻断其他账号。手动「立即签到」只操作当前优先账号。
- 账号元数据和 Token 明文保存在 `~/Library/Application Support/Codex Helper/wb-accounts.plist`（权限 `0600`）。Codex Helper 不会主动切换或覆盖 WorkBuddy App 当前登录的账号。

## Debug Mode

菜单中的「Debug Mode」默认关闭，仅本次运行有效，重启应用后恢复关闭。开启后每条经过本地代理的 Chat 请求保存为 `~/Downloads/CodexHelper-Debug/提供商/模型/时间戳_唯一ID.txt`；「打开 Debug 日志目录」可直接查看。

日志包含 Helper 收到的完整文本请求（系统提示词、历史消息、工具定义和参数）、每次上游尝试实际发送的 JSON、HTTP 状态、上游错误正文和响应耗时；不保存完整回答。只能看到 OpenCodex 转换后交给 Helper 的请求，无法还原转换前的 Claude Desktop 原始请求。调用方传入 `X-Request-ID` 或 `X-OCX-Request-ID` 时一并保存，否则使用本地 ID。

鉴权头不记录；结构化凭据字段会隐藏，Base64 图片／文件／音频内容省略。目录与文件权限分别为 `0700` / `0600`。**文本中仍可能含有私人对话、代码或敏感信息**，不要未经检查分享日志。关闭开关立即停止写入，已有文件不会自动删除，请在分析后手动清理。写盘失败会自动关闭 Debug Mode 并提示，不影响代理请求。

## Trae 多账号行为

Trae 代理保留通过共同入口校验的工具顺序与定义，仅将 function 工具的参数 Schema 转成上游要求的 JSON 字符串。转发 `parallel_tool_calls`，但是否实际支持由上游决定。调用方明确指定 `tool_choice: "none"` 时不发送工具列表，因为上游实测会忽略该限制。

Trae 使用独立账号池：元数据和 Token 明文保存在 `~/Library/Application Support/Codex Helper/trae-accounts.plist`（权限 `0600`），与 WorkBuddy 完全隔离，两边切号互不影响。

选择「Trae 账号池 → 保存当前 Trae 登录账号」，会解密当前 `storage.json` 并按 `userId` 幂等写入：同一账号只覆盖 Token 与展示名，不产生重复条目。首次使用且池为空时，请求会自动导入当前登录，无需手动点一次。菜单中勾选即设为优先账号。

取用顺序为：优先账号在前，其余按 `lastUsedAt` 从旧到新。仅在请求尚未开始输出、且上游返回 HTTP 401/403/429/5xx 时才尝试下一个账号；SSE 一旦开始输出就绝不切换，避免同一条回答混入两个账号的状态。Trae 没有已知的 Token 刷新接口，因此不做自动刷新，也不臆造余额与限流冷却：Token 过期后请在 Trae 内重新登录，再点一次「保存当前 Trae 登录账号」。

使用本机 Codex CLI 的当前登录状态，通过官方 `account/rateLimits/read` 接口读取账户额度。应用不读取或保存 Token，不发起模型任务，也不消费额度重置次数；子进程关闭 analytics。需要 Codex 使用 ChatGPT 账户登录并能访问网络。第三方模型服务的余额不在此接口范围内。

检测到 OpenCodex 包装器时，额度查询优先调用其保留的原生 Codex 可执行文件，避免定时查询意外启动已关闭的代理。「打开 OpenCodex Dashboard」本身会在代理未运行时按 OpenCodex 的标准行为启动代理。

若希望开机自动运行，可先将应用移到固定目录，再在「系统设置 → 通用 → 登录项」中添加该应用。

源码按 `CodexQuotaBar.swift`、`CodexTokenUsage.swift`、`CodexUsageSync.swift`、`CodexResponseTiming.swift`、`WorkBuddyAccountPool.swift`、`WorkBuddyClient.swift`、`TraeAccountPool.swift`、`TraeClient.swift` 和 `WorkBuddyProxy.swift` 分层（`WorkBuddyProxy.swift` 承载两条路由共用的 listener）。安装 Xcode Command Line Tools 后，在此目录运行 `sh build.sh` 即可重新编译并运行内置检查；生成的 `.build/` 和 `Codex Helper.app/` 不纳入 Git。`--check` 验证 Codex 额度，`--check-token-usage` 只读查询官方周额度周期并检查本地 Token 分类用量（周期查询失败仍可统计今日），`--check-workbuddy` 验证 WorkBuddy 积分和模型，`--serve-proxy` 可单独运行两条代理路由；验证时可用环境变量 `CODEX_HELPER_PROXY_PORT` 换端口、`CODEX_HELPER_WORKBUDDY=0` / `CODEX_HELPER_TRAE=0` 单独关闭某条路由。

参考：[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。

界面检查：运行 `sh Tests/check-ui.sh`，以隔离设置验证控件和文本边界，并生成浅色 / 深色的设置、日期查询和正常 / 低额度 / 过期额度截图到 `.build/ui-check/`；不启动代理、不保存用户设置。


## iCloud 多端合并统计

在每台使用同一 Apple 账号、同一 Codex／ChatGPT 账号的 Mac 上，打开「设置… → 通过 iCloud 同步用量」并保存。此开关默认关闭；首次开启会回填本机仍保留的历史记录。应用自动使用 iCloud Drive 的 `Codex Helper/Usage/v1` 目录，无需同步整个 `.codex` 目录或部署服务。

- 每台设备只写自己的日期文件，每分钟检查和交换一次；包含稳定事件指纹、时间、模型、档位、token 分项和设备名，不包含对话、提示词、工具内容、登录密钥或 Token。
- 「统计来源」可选全部设备或单台设备，设备项下方直接显示数据更新时间，无需悬停。全部设备按事件指纹去重；复制、分叉历史可能同时出现在多个设备的来源视图，因此各设备小计不能直接相加。设备来源表示哪台机器提供了记录，不能用于还原复制历史的实际执行地点。
- 同步的是每次请求的 token 分项，费用在查看端按当前版本的统一规则重新估算；继续区分标准／Fast、缓存命中／写入等。重复事件元数据不全时优先采用已确认信息，模型或已知档位冲突时无法确认的费用按 $0，并显示提示。
- 本机缓存保存在 `~/Library/Application Support/Codex Helper/UsageCache/v1`。断网、文件尚未下载或云端文件损坏时保留上次有效数据；未上传的本机用量稍后自动重试。系统 iCloud 同步有延迟，设备数据更新时间不等于其他设备已经收到全部记录。
- 关闭开关会恢复仅统计本机原始记录，停止后续收发；不会删除此前已同步的文件或缓存。历史日志缺失、没有稳定事件信息的记录无法凭空补齐。当前版本不区分同一机器历史上的不同 Codex 账号，请勿将不同 Codex 账号的记录混入同一 iCloud 统计目录。

`sh Tests/check-ui.sh` 可检查浅色／深色界面、设置控件与日期查询。内置同步自检覆盖双设备去重、同设备并发写入、离线重启与补传、损坏文件回退、元数据冲突、历史回填及导出字段白名单。测试需要正常 macOS 文件协调服务；受限的自动化沙箱可能需放行该服务。

## 模型输出效率

模型费用旁显示 `tok/s avg`，标准／Fast 分开，随今日、当前周额度、日期区间和设备来源一起筛选。明细显示有效测速样本数／总请求数；平均值为有效样本的输出 token（含推理）总量除以这些样本的响应耗时总和，不对各次速度直接取算术平均。

耗时从 Codex 原生 `logs_*.sqlite` 的请求起始日志，到会话记录中该次模型的最后一次输出，包含首字等待，排除模型输出结束后等待工具执行的时间。只读本地数据库，通过线程、轮次、时间及原生用量记录配对；无数据库、日志被清理、用量不匹配或缺失可靠时序时，该请求不参与测速，没有有效样本显示 `—`。这是客户端响应效率，包含网络和等待时间；不等同于服务端纯解码速度，也不依赖 OpenCodex。

iCloud 仅增加可选的响应秒数字段，事件指纹不变，重复记录仍只算一次；旧版文件和没有测速信息的设备可继续合并。其他设备升级后可贡献测速样本；不额外同步数据库、响应标识或对话内容。
