# Codex Helper 1.10.0

- 移除 Trae 相关内容：不再有 Trae 代理路由、账号池、签到、积分与模型菜单，也去掉了设置里的「启用 Trae 代理」开关。`/trae/v1` 现在直接返回 404。
- WorkBuddy「更多…」新增「导入到 T3 Code」。一键写入 Pi 的 `models.json` 和 T3 Code 的 Pi provider，T3 Code 里直接出现 WorkBuddy 的全部对话模型。
- 只导对话模型，上下文、图像输入和推理档位按上游能力标注；本机没有 Pi 时用 npm 安装到 `~/.pi/workbuddy-runtime`。
- 导入只替换 `workbuddy` 自己的配置，其他 provider、provider 实例和设置原样保留，重复导入只刷新模型列表。

支持 Apple Silicon（M 系列）Mac，macOS 15 或以上。
