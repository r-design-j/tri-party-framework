# 三方协作框架说明书：从协议到产品化闭环

<callout emoji="bulb" background-color="light-blue" border-color="blue">
本文用于把当前 Codex + Claude + Gemini 三方框架从头到尾串起来：它解决什么问题、三方各自负责什么、一次任务如何执行、如何判断结果可信、失败后如何恢复、为什么先做 UI 前底座，以及后续 UI/产品化应该怎么接。
</callout>

## 1. 一句话定义

三方框架不是“让一个模型假装成三个专家”，而是让 **Codex、Claude、Gemini 三个可核验来源**围绕同一个任务独立产出、相互审计，最后由 Codex 在当前项目环境中合并为一个可追溯、可复验、可迭代的结果。

它的核心目标是：

| 目标 | 解释 |
| --- | --- |
| 避免单模型盲区 | 让不同模型从实现、推理、外部上下文等角度互补。 |
| 避免伪三方结论 | 每一方必须有真实来源，不能用 Codex 子代理冒充 Claude/Gemini。 |
| 保留证据链 | 每次 review、cross-audit、merge 都落盘，有 hash、metadata、状态文件。 |
| 把经验变标准 | 每天从真实工作问题中提炼可复用规范，持续优化框架。 |
| 先打牢底座再做 UI | UI 只消费稳定协议和状态，不把恢复、鉴权、审计逻辑写死在前端。 |

---

## 2. 为什么要有三方框架

单模型协作最大的问题不是“能力不够”，而是 **无法稳定证明这个结论是怎么来的**。

常见风险包括：

- 一个模型给出看似完整的结论，但没有外部复核。
- Codex 子代理被误认为 Claude 或 Gemini，形成“伪三方”。
- Claude/Gemini CLI 探针能通，但实际 review 长提示词时挂起。
- 手工复制某方输出后，无法追踪这段文本来源、时间、hash 是否一致。
- UI 如果直接读一堆 Markdown 文件，会把底层不稳定语义固化成界面。

所以这个框架的设计原则是：**先保证来源真实、流程完整、状态可读、失败可恢复，再谈 UI 和产品体验。**

---

## 3. 三方角色分工

当前三方能力范式已经固化到 `docs/framework/model-binding.yaml`。

| 模型方 | 默认角色 | 主要擅长 | 在框架里的责任 |
| --- | --- | --- | --- |
| Codex GPT-5.5 | 实现负责人 | 真实项目代码、仓库修改、测试、调试、在工作区执行命令 | 落地代码、维护脚本、跑验证、最终综合三方结果。 |
| Claude Opus 4.8 / 4.7 | 推理与自治负责人 | 复杂推理、架构权衡、长链路 agent、自治规划 | 审架构、找逻辑漏洞、提出系统性风险。 |
| Gemini 3.1 Pro Preview | 多模态与 Google 上下文负责人 | PDF、视频、音频、图片、Google 搜索/地图/URL、Google 生态信息 | 审外部上下文、多模态材料、发现跨资料或长上下文风险。 |

<callout emoji="warning" background-color="light-yellow" border-color="yellow">
分工不是替代来源验证。即使某个任务主要由 Codex 实现，只要最终叫“三方结论”，Claude 和 Gemini 就必须有真实产物，并通过互审门禁。
</callout>

---

## 4. 一次三方任务的完整链路

| 步骤 | 阶段 | 输入 | 输出 | 不通过时 |
| --- | --- | --- | --- | --- |
| 1 | 用户提出任务 | 用户目标、上下文文件、交付要求 | 任务边界 | 先澄清任务，不进入三方执行。 |
| 2 | 能力分派 | 任务类型 | 主责方、支持方、挑战方 | 重新按 Codex/Claude/Gemini 擅长点分派。 |
| 3 | Preflight 来源检查 | 本地 CLI、连接状态、model binding | `source-status.md` 初始状态 | 降级为 partial，生成 handoff prompt。 |
| 4 | Independent Review | 同一任务上下文 | `claude-review.md`、`gemini-review.md` | 超时/失败/空文件则 partial。 |
| 5 | Mutual Cross-audit | 两份独立 review | `claude-cross-audit.md`、`gemini-cross-audit.md` | 缺一不可，失败则 partial。 |
| 6 | Merge Gate | review、cross-audit、metadata、hash | `merge-status.md`、`state.json` | 生成 `partial-report.md`。 |
| 7 | Codex Final Synthesis | 门禁通过后的证据包 | true tri-party conclusion | 不得称为真三方结论。 |
| 8 | 标准沉淀 | 本次问题、修复、审计意见 | 标准候选、决策日志、反模式、日总结 | 暂不固化，只记录为观察项。 |

这条链路里最关键的是：**探针成功不等于评审完成，评审完成不等于可合并，可合并还需要互审和硬门禁。**

---

## 5. 每个阶段到底做什么

### 5.1 任务定义

用户提出一个任务后，先明确：

| 问题 | 目的 |
| --- | --- |
| 这次要交付什么？ | 避免三方讨论发散。 |
| 哪个模型主责？ | 按能力而不是平均分配。 |
| 需要外部资料吗？ | 决定 Gemini 是否作为主要上下文方。 |
| 结果是否要进仓库？ | 决定 Codex 是否直接改代码并跑测试。 |

### 5.2 Preflight 来源检查

Preflight 的作用是确认 Claude/Gemini 不是“想象出来的参与方”。

当前检查方式：

```bash
scripts/triparty.sh preflight
```

它会检查：

- `claude` CLI 是否存在。
- `gemini` CLI 是否存在。
- 最小非交互探针是否能返回预期文本。
- Gemini 使用指定模型 `gemini-3.1-pro-preview`。
- Gemini 默认禁用可能挂起的本地 MCP：`--allowed-mcp-server-names __none__`。
- 当前 `model-binding.yaml` 的 SHA256，便于发现模型绑定漂移。

### 5.3 Independent Review 独立评审

当来源可用后，Claude 和 Gemini 会分别收到同一个任务和上下文，独立产出 review。

注意：每个模型只对自己看到的上下文负责。它们不能自行宣称“这是不是完整三方结果”。全局 source status 只能由 runner 写入。

### 5.4 Mutual Cross-audit 相互审计

互审不是形式步骤，而是三方框架的可信核心。

| 审计方向 | 目的 |
| --- | --- |
| Claude 审 Gemini | 找 Gemini 是否过度乐观、遗漏架构风险、误判工程约束。 |
| Gemini 审 Claude | 找 Claude 是否保守过度、遗漏外部上下文、多模态或长上下文问题。 |
| Codex 审整体证据 | 对照用户最新需求、文件状态、测试结果和门禁结果做最终综合。 |

### 5.5 Merge Gate 合并门禁

Merge Gate 是“能不能叫真三方”的硬条件。

必须同时满足：

- Claude review = `Completed`
- Gemini review = `Completed`
- Claude cross-audit = `Completed`
- Gemini cross-audit = `Completed`
- review 和 cross-audit 文件非空
- 文件 hash 与状态记录一致
- artifact metadata 有效
- party/stage 与文件身份一致
- completion marker 存在
- source label 没有污染
- `state.json.true_triparty_ready = true`

当前命令：

```bash
scripts/triparty.sh merge docs/framework/runs/review-YYYYMMDD-HHMMSS
```

---

## 6. 什么情况下才算“真三方结果”

<callout emoji="white_check_mark" background-color="light-green" border-color="green">
真三方结果 = Codex 当前会话 + Claude 真实产物 + Gemini 真实产物 + 双向互审 + 合并门禁通过。
</callout>

如果缺少其中任何一项，都只能叫 partial：

| 场景 | 结果标签 |
| --- | --- |
| 只有 Codex 自己分析 | Codex-only provisional |
| Codex + 子代理 | Codex plus Codex sub-agents |
| Claude 或 Gemini 缺失 | Partial review |
| 某方 timed out / failed / skipped | Partial review |
| 文件 hash 不匹配 | Partial review |
| metadata 或 completion marker 缺失 | Partial review |
| party 自己宣称全局 source status | Partial review |

这套规则解决了我们之前的核心问题：**不是说“三方”，就真的三方；必须拿得出来源、产物、互审和门禁证据。**

---

## 7. 运行目录和证据链

每次执行都会生成一个 run 目录：

```text
docs/framework/runs/review-YYYYMMDD-HHMMSS/
```

主要产物：

| 文件 | 作用 |
| --- | --- |
| `source-status.md` | 记录 Codex/Claude/Gemini 的来源状态、review 状态、hash、错误码。 |
| `claude-review.md` | Claude 独立评审。 |
| `gemini-review.md` | Gemini 独立评审。 |
| `cross-audit-status.md` | 双向互审状态。 |
| `claude-cross-audit.md` | Claude 对 Gemini 的审计。 |
| `gemini-cross-audit.md` | Gemini 对 Claude 的审计。 |
| `merge-status.md` | 合并门禁结果。 |
| `merge-input.md` | 门禁通过后给 Codex 最终综合使用的证据包。 |
| `partial-report.md` | 门禁失败时生成的 partial 报告。 |
| `state.json` | 给 CLI、HTTP、MCP、未来 UI 使用的机器可读状态。 |

`state.json` 是未来产品化最重要的状态面。UI 不需要自己猜哪个 Markdown 代表成功，只需要读它。

---

## 8. 防伪与可信机制

三方框架目前有四层防伪。

### 8.1 来源层

Preflight 证明 Claude/Gemini 的 CLI 或来源真实存在，而不是 Codex 角色扮演。

### 8.2 产物层

每个有效 review/cross-audit 文件都有 runner 写入的元数据头：

```yaml
triparty_artifact: v1
party: Claude
stage: review
origin: automated_cli
runner: triparty-review.sh
completion_marker: TRIPARTY_REVIEW_COMPLETE
```

人工注入的产物也会被重新包裹 metadata，并记录原始文件路径和 source hash。

### 8.3 Hash 层

所有关键产物都记录 SHA256。merge 时会比对磁盘文件和状态记录。

### 8.4 状态层

核心状态文件采用 temp-file-and-rename 原子写入，减少 UI 或 adapter 读到半截状态的风险。

---

## 9. 失败恢复：inject、resume、structured errors

三方链路调用外部模型，失败是正常事件，所以框架把恢复能力放在 UI 之前实现。

### 9.1 Offline Inject

当 Claude 或 Gemini 自动调用失败，但用户从 GUI/Web/其他客户端拿到了真实输出，可以注入：

```bash
scripts/triparty.sh inject review claude <run-dir> claude-output.md
scripts/triparty.sh inject cross-audit gemini <run-dir> gemini-cross.md
```

注入后系统会：

- 检查文件非空和大小。
- 复制到 run 目录。
- 写入 metadata header。
- 写入 completion marker。
- 记录 `origin=user_supplied`。
- 记录 `source_path`、`source_sha256`、`artifact_sha256`。
- 清理 stale merge/partial 文件。
- 刷新 `state.json`。

### 9.2 Resume

注入或中断后继续：

```bash
scripts/triparty.sh resume <run-dir>
```

系统会根据现有状态继续 cross-audit 或 merge，不要求用户手工判断下一步。

### 9.3 Structured Errors

`state.json.errors` 用结构化方式记录失败，不依赖人去读控制台日志。

常见状态：

| 状态 | 含义 |
| --- | --- |
| `E_OK` | 正常完成。 |
| `E_REVIEW_TIMEOUT` | review 阶段超时。 |
| `E_CROSS_TIMEOUT` | cross-audit 阶段超时。 |
| `E_USER_SUPPLIED` | 由用户人工注入补齐。 |
| `E_MERGE_PARTIAL` | 合并门禁未通过。 |

---

## 10. 产品化形态：portable core + thin adapters

我们最终没有把它封装成“Codex 专属 Skill”，因为不是所有用户都有 Codex。当前决策是：

<callout emoji="memo" background-color="pale-gray" border-color="gray">
核心产品形态 = portable core kit + thin adapters。核心掌握真相，adapter 只负责入口和体验。
</callout>

### 10.1 Portable Core

核心由文件、脚本和契约组成：

| 模块 | 文件 |
| --- | --- |
| 协议 | `docs/framework/tri-party-protocol.md` |
| 模型绑定 | `docs/framework/model-binding.yaml` |
| 状态 schema | `docs/framework/state.schema.json` |
| 适配器契约 | `docs/framework/adapter-contract.md` |
| 统一 CLI | `scripts/triparty.sh` |
| preflight | `scripts/triparty-preflight.sh` |
| review | `scripts/triparty-review.sh` |
| cross-audit | `scripts/triparty-cross-audit.sh` |
| merge gate | `scripts/triparty-merge.sh` |
| regression | `scripts/triparty-regression.sh` |
| lint | `scripts/triparty-lint.sh` |

### 10.2 HTTP Adapter

本地 HTTP adapter 用于 UI、CI、其他工具接入：

```bash
python3 adapters/http/triparty_http_adapter.py --host 127.0.0.1 --port 8765
```

设计原则：

- 默认只监听 `127.0.0.1`。
- 非 loopback 必须显式开启并提供 auth token。
- 返回状态前校验 artifact hash。
- 不自己判断 true/partial，只相信 core 生成的 `state.json`。

### 10.3 MCP Adapter

MCP adapter 让其他 agent 工具用 MCP 方式调用 core：

```bash
python3 adapters/mcp/triparty_mcp_adapter.py
```

已暴露工具：

| MCP Tool | 作用 |
| --- | --- |
| `triparty_status` | 刷新并返回状态。 |
| `triparty_run` | 完整执行 review -> cross-audit -> merge。 |
| `triparty_review` | 只跑 review。 |
| `triparty_cross_audit` | 只跑互审。 |
| `triparty_merge` | 只跑合并门禁。 |
| `triparty_inject` | 注入人工产物。 |
| `triparty_resume` | 断点继续。 |
| `triparty_runs` | 查看运行历史。 |
| `triparty_stats` | 查看统计。 |
| `triparty_archive` | 归档旧 run。 |
| `triparty_lint` | 运行框架一致性检查。 |
| `triparty_regression` | 运行回归测试。 |

---

## 11. UI 为什么现在还没做，但已经能做

我们这一步停在 UI 前是合理的。

因为 UI 不应该自己实现：

- 判断三方是否完成。
- 判断哪个产物可信。
- 判断 hash 是否匹配。
- 判断人工注入是否有效。
- 判断 partial 还是 true tri-party。
- 管理 run 归档。
- 解析一堆 Markdown 推断状态。

这些都已经沉到 core/adapter 层。

未来 UI 只需要消费：

| UI 视图 | 数据来源 |
| --- | --- |
| 新建任务 | `POST /run` 或 `triparty_run` |
| 当前状态 | `state.json` / `/status` |
| 三方进度 | `state.parties` |
| 错误提示 | `state.errors` |
| 证据链 | `source-status.md`、`cross-audit-status.md`、`merge-status.md` |
| 人工补交 | `inject` |
| 断点继续 | `resume` |
| 历史列表 | `runs` |
| 健康统计 | `stats` |
| 归档清理 | `archive` |

这意味着 UI 可以比较轻：它是可视化和交互层，不是协议真相层。

---

## 12. 当前完成状态

截至最终验证 run：

```text
docs/framework/runs/review-20260601-141942
```

状态为：

| 字段 | 值 |
| --- | --- |
| `phase` | `merged_ready` |
| `true_triparty_ready` | `true` |
| `conclusion` | `Ready for true tri-party synthesis` |
| Claude review | `Completed` |
| Gemini review | `Completed` |
| Claude cross-audit | `Completed` |
| Gemini cross-audit | `Completed` |
| errors | `[]` |
| core_version | `0.1.0` |

已通过验证：

- Shell 语法检查。
- Python 编译检查。
- `scripts/triparty-regression.sh`。
- `scripts/triparty-adapter-smoke.sh`。
- `scripts/triparty-mcp-smoke.sh`。
- `scripts/triparty-lint.sh`。
- 最终三方 review + cross-audit + merge gate。

---

## 13. 已沉淀出的关键标准

当前已经形成的标准候选中，最重要的是：

| 标准 | 含义 |
| --- | --- |
| 来源必须可核验 | 不能用 Codex 子代理替代 Claude/Gemini。 |
| probe 与 review 分离 | CLI 能返回 OK，不代表长任务 review 能完成。 |
| 互审是硬门禁 | Claude/Gemini 必须互审后才能综合。 |
| portable core 优先 | 不把核心绑定到 Codex Skill，适配器只是薄封装。 |
| UI 前先做恢复与诊断 | inject/resume/errors/runs/stats/archive/MCP 必须先于 UI。 |
| 人工注入必须有 provenance | user supplied 不是一句标签，要有路径、hash、时间、artifact hash。 |
| 合并产物必须有 metadata | 非空文件不等于有效产物，必须校验 party、stage、marker。 |
| 状态文件要原子发布 | adapter/UI 不能读到半截 `state.json`。 |

---

## 14. 后续路线图

### P1：进入 UI 前后优先补强

- 运行期角色契约校验：让 model-binding 不只是 YAML 声明，还能被 preflight/adapter 硬校验。
- pipeline DAG 文档：把 preflight -> review -> cross-audit -> merge -> standard extraction 显式化。
- 挂起熔断回归：把 probe-success-then-hang 做成固定 fixture。
- 更多污染负样本：覆盖伪造 stage、伪造 marker、过期 timestamp、错位 hash。
- resume 语义文档：明确从 atomic snapshot 恢复，还是从 stage 起点重放。

### P2：产品体验增强

- UI 状态面板：三方进度、错误、证据、补交入口。
- run 目录与核心文档解耦：长期可考虑把动态 run 移出 docs。
- adapter playbook：HTTP/MCP 的接入、调试、鉴权、错误处理说明。
- 自动失败复盘：从 runs/stats 中自动生成每日标准候选。

---

## 15. 新设备安装与迁移

三方框架的核心不是某个 app 插件，而是一套 portable core。换新设备时，本质上要迁移三类东西：

| 类别 | 内容 | 是否必须 |
| --- | --- | --- |
| Core 文件 | `AGENTS.md`、`scripts/`、`docs/framework/`、`adapters/`、`VERSION`、`CHANGELOG.md` | 必须 |
| 模型入口 | `claude` CLI、`gemini` CLI、各自登录状态 | 必须 |
| 历史证据 | `docs/framework/runs/`、`docs/daily/` | 建议迁移，便于审计和标准沉淀 |

### 15.1 新设备前置条件

新设备至少需要：

- macOS 或 Linux shell 环境。
- `bash`、`python3`、`awk`、`sed`、`find`、`shasum`。
- 可执行的 Claude CLI：`claude`。
- 可执行的 Gemini CLI：`gemini`。
- Claude/Gemini CLI 已登录，且当前网络能访问对应模型服务。

检查命令：

```bash
python3 --version
type -a claude
type -a gemini
```

### 15.2 安装 portable core

推荐从 GitHub 获取 portable core：

```text
https://github.com/r-design-j/tri-party-framework
```

克隆安装：

```bash
git clone https://github.com/r-design-j/tri-party-framework.git
cd tri-party-framework
chmod +x scripts/*.sh adapters/http/triparty_http_adapter.py adapters/mcp/triparty_mcp_adapter.py
scripts/triparty-lint.sh
```

如果不使用 git，也可以下载 ZIP：

```text
https://github.com/r-design-j/tri-party-framework/archive/refs/heads/main.zip
```

下载后解压，进入目录执行同样的 `chmod` 和 `triparty-lint.sh` 检查。

最小目录结构应包含：

```text
AGENTS.md
README.md
VERSION
CHANGELOG.md
scripts/
adapters/
docs/framework/
```

进入目录后执行：

```bash
chmod +x scripts/*.sh
chmod +x adapters/http/triparty_http_adapter.py
chmod +x adapters/mcp/triparty_mcp_adapter.py
scripts/triparty-lint.sh
```

如果 `triparty-lint.sh` 通过，说明 core 文件结构和基本契约是完整的。

### 15.3 绑定和验证 Claude/Gemini

模型版本和调用参数在这里维护：

```text
docs/framework/model-binding.yaml
```

新设备首次验证：

```bash
scripts/triparty.sh preflight
```

如果通过，会生成 source status，并记录：

- Claude 是否可用。
- Gemini 是否可用。
- Gemini 当前模型名。
- Gemini MCP allowlist。
- `model-binding.yaml` 的 SHA256。

如果失败，不要直接进入三方结论。先修 CLI 登录、PATH、网络或模型参数。

### 15.4 跑一轮安装验收

建议新设备第一次安装后跑完整验收：

```bash
scripts/triparty-lint.sh
scripts/triparty-regression.sh
scripts/triparty-adapter-smoke.sh
scripts/triparty-mcp-smoke.sh
```

再跑一次真实三方调用：

```bash
scripts/triparty.sh run "安装验收：请检查当前三方框架在这台新设备上是否可用。"
```

验收通过标准：

| 检查项 | 通过标准 |
| --- | --- |
| lint | `triparty lint passed` |
| regression | `triparty regression passed` |
| HTTP smoke | `triparty adapter smoke passed` |
| MCP smoke | `triparty mcp smoke passed` |
| 最终 state | `true_triparty_ready=true` 或明确 partial 原因 |

### 15.5 配置 HTTP Adapter

本地使用：

```bash
python3 adapters/http/triparty_http_adapter.py --host 127.0.0.1 --port 8765
```

读取状态：

```bash
curl http://127.0.0.1:8765/status
```

安全规则：

- 默认只允许本机访问。
- 如果绑定到非本机地址，必须加 `--allow-non-loopback` 和 auth token。
- UI 或外部服务只应相信 HTTP adapter 返回的 `state_validation.ok=true` 状态。

### 15.6 配置 MCP Adapter

MCP adapter 命令：

```bash
python3 /absolute/path/to/adapters/mcp/triparty_mcp_adapter.py
```

通用 MCP 客户端配置形态：

```json
{
  "mcpServers": {
    "triparty": {
      "command": "python3",
      "args": ["/absolute/path/to/adapters/mcp/triparty_mcp_adapter.py"]
    }
  }
}
```

配置后，MCP 客户端应能看到：

- `triparty_run`
- `triparty_status`
- `triparty_inject`
- `triparty_resume`
- `triparty_runs`
- `triparty_stats`
- `triparty_archive`
- `triparty_lint`
- `triparty_regression`

---

## 16. 新会话中如何触发调用

新会话里触发三方框架有三种方式：自然语言触发、CLI 触发、Adapter/MCP 触发。

### 16.1 Codex 新会话自然语言触发

只要当前 workspace 根目录有 `AGENTS.md`，Codex 新会话会继承其中的工作约定。为了避免误触发或半触发，建议用户明确说：

```text
请读取当前 workspace 的 AGENTS.md 和 README，然后用三方框架处理这个任务：
<你的任务>

要求：
1. 先做 preflight。
2. 真实调用 Claude 和 Gemini，不允许用 Codex 子代理替代。
3. 完成 independent review、mutual cross-audit 和 merge gate。
4. 最终汇报 source status、run 目录和是否 true_triparty_ready。
```

更短的触发语也可以：

```text
用三方框架审查这个问题：<问题>
```

```text
按 Codex + Claude + Gemini 三方协议跑一遍：<任务>
```

```text
调用我们已有三方框架，完成后给我 true/partial 状态和证据链。
```

### 16.2 Codex 收到触发后应该做什么

新会话触发后，Codex 应按这个顺序执行：

| 顺序 | 动作 | 目的 |
| --- | --- | --- |
| 1 | 读取 `AGENTS.md`、`README.md` | 恢复工作约定和入口命令。 |
| 2 | 检查 `scripts/triparty.sh` 是否存在 | 确认当前目录是 portable core。 |
| 3 | 运行 `scripts/triparty.sh preflight` | 确认 Claude/Gemini 来源真实可用。 |
| 4 | 运行 `scripts/triparty.sh run "<任务>" [context-files...]` | 执行 review、cross-audit、merge。 |
| 5 | 读取 `state.json` 和 `merge-status.md` | 判断 true/partial。 |
| 6 | 最终汇报 run 目录、source status、门禁结果 | 保留可追溯证据。 |

### 16.3 CLI 直接触发

不依赖 Codex 聊天，也可以直接在终端执行：

```bash
scripts/triparty.sh run "请三方审查这个方案是否成立" docs/framework/tri-party-protocol.md
```

查看最新状态：

```bash
scripts/triparty.sh status
```

### 16.4 HTTP 触发

启动 HTTP adapter 后：

```bash
curl -X POST http://127.0.0.1:8765/run \
  -H "Content-Type: application/json" \
  -d '{"question":"请三方审查当前框架是否可以进入 UI 阶段","context_files":["README.md"]}'
```

这适合未来 UI、CI、自动化平台调用。

### 16.5 MCP 触发

配置 MCP adapter 后，在支持 MCP 的客户端中调用：

```text
tool: triparty_run
arguments:
  question: "请三方审查当前方案"
  context_files:
    - "README.md"
```

MCP 客户端不应自己判断 true/partial，必须读取工具返回的 stdout 或 run 目录里的 `state.json`。

### 16.6 新会话里的人工补交

如果新设备或新会话中 Claude/Gemini 某一方不可用，但用户可以从 GUI/Web 拿到真实输出，可以这样补：

```bash
scripts/triparty.sh inject review claude <run-dir> claude-output.md
scripts/triparty.sh inject review gemini <run-dir> gemini-output.md
scripts/triparty.sh resume <run-dir>
```

这时仍然可以形成真三方，但前提是：

- 用户补交的内容确实来自对应模型。
- `inject` 记录了 provenance。
- 后续 cross-audit 和 merge gate 通过。

### 16.7 每日汇总触发

如果用户想在新会话里继续“每日总结 + 标准提炼”，可以这样触发：

```text
请基于今天的对话、run 目录和已完成代码变更，按 Daily Work Standard Extraction 做每日总结。
要求：
1. 总结今天完成的工作和关键决策。
2. 提炼可复用、可落地的三方框架标准。
3. 标出优化机会、缺失能力和可产品化功能点。
4. 必要时用三方框架审计这些标准，再写入 docs/daily/ 或标准候选表。
```

---

## 17. 快速操作手册

完整执行：

```bash
scripts/triparty.sh run "你的任务描述" [context-files...]
```

查看状态：

```bash
scripts/triparty.sh status [run-dir]
```

手动分阶段：

```bash
scripts/triparty.sh preflight
scripts/triparty.sh review "你的任务描述" [context-files...]
scripts/triparty.sh cross-audit [run-dir]
scripts/triparty.sh merge [run-dir]
```

失败恢复：

```bash
scripts/triparty.sh inject review claude <run-dir> claude-output.md
scripts/triparty.sh inject review gemini <run-dir> gemini-output.md
scripts/triparty.sh resume <run-dir>
```

运行管理：

```bash
scripts/triparty.sh runs
scripts/triparty.sh stats
scripts/triparty.sh archive --keep 20 --dry-run
```

本地 HTTP adapter：

```bash
python3 adapters/http/triparty_http_adapter.py --host 127.0.0.1 --port 8765
```

MCP adapter：

```bash
python3 adapters/mcp/triparty_mcp_adapter.py
```

验证：

```bash
scripts/triparty-lint.sh
scripts/triparty-regression.sh
scripts/triparty-adapter-smoke.sh
scripts/triparty-mcp-smoke.sh
```

---

## 18. 术语表

| 术语 | 解释 |
| --- | --- |
| Party | 三方中的一个真实模型来源：Codex、Claude、Gemini。 |
| Preflight | 正式开始前的来源可用性检查。 |
| Review | Claude/Gemini 对任务的独立评审。 |
| Cross-audit | Claude 审 Gemini，Gemini 审 Claude。 |
| Merge Gate | 判断是否允许称为真三方结论的硬门禁。 |
| Provenance | 来源血缘，说明产物来自自动 CLI 还是用户注入，以及原始文件/hash。 |
| Artifact Metadata | 写在产物头部的机器可读身份信息。 |
| Completion Marker | 表示产物完整生成的完成标记。 |
| Partial Review | 来源、互审或门禁不完整时的降级结果。 |
| Portable Core | 不依赖某个 agent 平台的核心协议、脚本、状态和证据链。 |
| Thin Adapter | HTTP、MCP、UI、Skill 等入口层，只包装 core，不重定义真相。 |

---

## 19. 最终判断

<callout emoji="white_check_mark" background-color="light-green" border-color="green">
当前三方框架已经从“工作流约定”升级为“可执行、可验证、可恢复、可产品化”的底层协议。UI 前的核心链路已经闭合：三方来源可核验，互审可落盘，合并有硬门禁，失败可注入和恢复，状态可被 HTTP/MCP/UI 消费。
</callout>

下一步不应重写核心协议，而应围绕这个 portable core 建 UI：让用户更容易发起任务、观察进度、补齐失败方、查看证据链、沉淀标准。
