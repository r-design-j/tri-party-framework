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

公开访问地址：

https://r-design-j.github.io/tri-party-framework/

![triparty 工具台首屏](assets/triparty-home-first-screen.png)

当前阶段页面刻意保持静态。默认视图面向普通用户：解释 `triparty` 是什么，提供一段可直接交给 AI agent 的安装委托，并说明安装后会如何回报结果。状态检查、CLI 命令、失败恢复、案例详情和接入清单被折叠在“高级工具与排查台”里，供安装失败、开发接入或需要核验 true / partial 时使用。

本地安装：

如果用户不想自己看步骤，可以直接把这段话复制给能操作本机终端的 AI agent：

```text
请在这台机器上安装 triparty。
目标仓库：https://github.com/r-design-j/tri-party-framework
执行要求：
1. clone 仓库并进入目录。
2. 补齐必要脚本权限。
3. 运行项目自检。
4. 安装全局发现规则和 triparty 命令。
5. 运行 triparty preflight 验证。
6. 如果缺少 Claude Code、Gemini CLI、认证或权限，请明确报告缺失项；不要把 partial run / 未完成协作说成 true tri-party / 完整三方。
完成后告诉我本机安装路径和 preflight 结果。
```

```bash
git clone https://github.com/r-design-j/tri-party-framework.git
cd tri-party-framework
chmod +x scripts/*.sh adapters/http/triparty_http_adapter.py adapters/mcp/triparty_mcp_adapter.py
scripts/triparty-lint.sh
scripts/install-triparty-global-bootstrap.sh
triparty preflight
open web/index.html
```

已实现交互：

- 首页主按钮复制给 AI agent 的安装委托。
- “给 Agent 的安装指令”同时提供自然语言委托和终端命令，两者都可复制。
- “高级工具与排查台”默认折叠，顶部导航或展开按钮可打开。
- 安装后检查支持粘贴 `state.json` 并检查 JSON 有效性、true_triparty_ready、Gemini auth、review / cross-audit 和 errors。
- 四张命令卡片都能复制真实 CLI 命令。
- UI 前置 checklist 会更新完成度、下一步提示和进度条。
- 每个案例卡片都跳转到自己的详情卡，不是装饰链接。
- 排查工具会生成 shell-safe 单引号命令，避免 `$(...)` 被 shell 展开。
- 错误恢复路由会根据错误码给出下一条恢复动作。
- 桌面和移动端都有状态反馈 toast。

页面结构覆盖：

- 首页：说明 `triparty` 是 Codex、Claude、Gemini 的本机协作流程，并把主要动作收敛成“复制给 Agent”。
- 普通用户说明：解释用户、agent、网页各自负责什么。
- 给 Agent 的安装指令：提供可复制的自然语言安装委托和终端命令。
- 三步说明：用“拉取项目 / 写入规则 / 回报结果”解释安装过程。
- 高级工具与排查台：默认折叠，保留安装后检查、命令卡片、证据案例、排查工具和开发者接入。
- 安装后检查：粘贴 `state.json` 后判断 true / partial。
- 可信证据：展示运行状态检查、发布前检查、失败恢复、本地服务接入四个产品化模块。
- 排查工具：提供命令生成器和错误恢复建议。
- 开发者接入：列出 contract、fixtures、只读本地服务接入工作。
