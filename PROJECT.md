# radare2-for-agent 项目记忆

> 本文档是 AI agent 修改本仓库时的“项目记忆 / 目标 / 原则 / 当前状态”。
> 它比 AGENTS.md 更偏项目层；AGENTS.md 偏编码规范。

## 一句话定位

把 radare2 改造成 **AI agent 友好的逆向工具**：让 r2 原生的交互式循环模式具备
**无头（headless）+ 守护进程（daemon）+ 持久化（persistent）** 能力，同时保留
传统的命令行批处理模式，二者无缝配合。

## 当前基线

- 上游源码：radare2 **6.2.0**（tag `upstream-6.2.0`）
- 开发分支：`r2-agent`
- 旧 r3 封存：`legacy/r3` 分支 + `legacy/r3/` 目录 + tag `legacy/r3-v2.1.0`
- 当前状态：**v1 基础闭环已实现（`--daemon` + `--send`），自动化验收脚本见 `test/acceptance-agent-daemon.sh`**
- 本机参考 r2：`6.1.9+48`（旧 r3 的实测结论基于该版本；新开发以 6.2.0 源码为准）

## 项目目标

1. 去掉 r3 这种“外部 Python 包装器”对 r2 完整性的破坏。
2. 在 r2 源码内实现“无头 + 守护进程 + 持久化”的交互式命令模式：
   - 每次 AI agent 新开 bash，都能连接同一个常驻 r2 状态；
   - 分析结果、配置、会话状态跨调用存活；
   - 支持超时自愈、崩溃恢复、现场还原。
3. 让 r2 的两种模式自然配合：
   - 传统批处理：`r2 -q -c '...' file`；
   - 无头常驻交互：类似 r3 的 `r3 open file` / `r3 'afl'`，但由 r2 自身提供。
4. 保持 r2 原有 CLI、API、插件生态尽量不变，方便后续同步上游或上传 GitHub。

## 项目原则

1. **在 r2 源码里做，不另起炉灶**。
2. **默认无头**：AI agent 场景不需要 TUI/Visual 面板，但也不能破坏交互式 TTY 用户。
3. **输出可信**：命令输出必须准确、完整、可机器解析；JSON 不应被截断。
4. **稳定优先**：不能因为守护进程导致 r2 挂死；要有看门狗、黑名单、自愈、日志。
5. **透明透传**：r2 命令方言不翻译；守护进程只负责传输、会话、状态和边界保护。
6. **旧 r3 是经验库，不是代码依赖**：可以参考它的协议结论、缓存/会话/调试设计，
   但不把 Python 包装器作为最终交付。

## 目录导航

```text
AGENTS.md                     # AI agent 编码规范 + fork 项目约定
PROJECT.md                    # 本文件：项目记忆/目标/原则/状态
docs/
  PLAN-v1-agent-daemon.md     # v1 开发方案（DSH goal mode 可执行蓝图）
  agent-daemon-design.md      # 内置无头守护进程/持久化交互模式的设计草案
  r3-legacy-summary.md        # r3 关键经验与可复用设计总结
legacy/
  r3/                         # 旧 r3 完整存档：脚本、验收、原始文档
    r3
    install.sh
    tests/acceptance.sh
    docs/                     # 旧 AGENTS/DESIGN/PLAN*
```

## Git 分支约定

- `r2-agent`：当前开发基线，基于 radare2 6.2.0。
- `legacy/r3`：旧 r3 完整历史分支，不再开发。
- `master` / `v1.*` / `v2.0.0-dev`：旧 r3 历史分支，仅供追溯。
- `upstream-6.2.0`：上游 radare2 6.2.0 导入标记。

## 当前执行计划（v1）

- 按 `docs/PLAN-v1-agent-daemon.md` 执行，开发模式为 DSH goal mode。
- v1 目标：实现 `r2 --daemon` + `r2 --send` 的单会话无头常驻闭环。
- 任务顺序：G1 CLI 参数 → G2 Socket Server → G3 RCore 透传 → G4 管理命令 → G5 稳定性 → G6 测试与文档 → G7 验收。
- 不进入 v1 范围：多会话、磁盘缓存、动态调试、e 配置持久化。

### 开发前建议先读

1. `docs/PLAN-v1-agent-daemon.md` — v1 开发方案。
2. `docs/agent-daemon-design.md` — 架构草案。
3. `docs/r3-legacy-summary.md` — r3 经验。
4. `libr/main/radare2.c` — 主入口。
5. `libr/core/core.c` 的 `r_core_prompt_loop()` — 交互命令循环。

## 给 AI agent 的注意事项

- 不要修改 `legacy/` 下的旧 r3 代码；那是存档。
- 所有新功能应尽可能在 `libr/` 和 `binr/radare2/` 内以可编译的 C 实现。
- 改动前先读 `docs/PLAN-v1-agent-daemon.md`、`docs/agent-daemon-design.md` 和 `docs/r3-legacy-summary.md`。
- 提交前遵守 `AGENTS.md` 中的 radare2 官方编码规范、构建方式和提交信息约定。
