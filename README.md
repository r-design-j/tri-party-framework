# triparty 工具台

这是 Codex + Claude + Gemini triparty 框架的 UI 前静态网页工具。产品名固定使用 `triparty`，正文默认中文，CLI、Python、HTTP/MCP、state.json 等专有名词保留英文。

macOS 直接打开：

```bash
open web/index.html
```

也可以启动本地服务：

```bash
python3 -m http.server 4187 --bind 127.0.0.1 --directory web
```

然后访问 `http://127.0.0.1:4187`。

当前阶段页面刻意保持静态。它读取粘贴进来的 `state.json`，按核心契约判断真三方 / 部分结果，并提供 CLI 工作流命令卡片、任务命令生成器、失败恢复路由、案例详情和接入清单。

已实现交互：

- 顶部 `真 / 偏` 按钮加载 true / partial 状态样例。
- Run Inspector 支持粘贴 `state.json` 并检查 JSON 有效性、true_triparty_ready、Gemini auth、review / cross-audit 和 errors。
- 四张命令卡片都能复制真实 CLI 命令。
- UI 前置 checklist 会更新完成度、下一步提示和进度条。
- 每个案例卡片都跳转到自己的详情卡，不是装饰链接。
- Playground 会生成 shell-safe 单引号命令，避免 `$(...)` 被 shell 展开。
- 错误恢复路由会根据错误码给出下一条恢复动作。
- 桌面和移动端都有状态反馈 toast。

页面结构覆盖：

- 首页：说明 `triparty` 是状态检查、使用说明和操作向导，不是 agent 替身。
- 产品定位：解释真实执行仍在 Codex、Claude Code、Gemini CLI、HTTP/MCP adapter。
- Run Inspector：粘贴 `state.json` 后判断 true / partial。
- Case study：展示 Run Inspector、发布门禁、失败恢复、Adapter 接入四个产品化模块。
- Case details：按参考站详情页结构展开问题、修法、结果和约束。
- Playground：提供命令生成器和错误恢复建议。
- Contact / 接入：列出下一阶段 contract、fixtures、只读 adapter 接入工作。
