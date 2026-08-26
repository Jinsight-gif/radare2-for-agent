# 内置无头守护进程 / 持久化交互模式 — 设计草案

> 状态：草案，尚未实现。v1 执行方案见 `docs/PLAN-v1-agent-daemon.md`。
> 目标：在 radare2 源码内实现 `r2` 自身的“无头 + 守护进程 + 持久化”模式，
> 替代旧 r3 外部 Python 包装器。

## 1. 背景与动机

- AI agent 每次新开 bash，传统 `r2 -q -c ...` 都要重新加载/分析，成本高。
- r3 用外部 daemon 抱 `r2 -q0 -` 管道进程，解决了状态常驻，但破坏了 r2 的完整性：
  - 命令行批处理与交互式循环切换不自然；
  - 需要额外安装/部署 Python 脚本；
  - 与 r2 原生命令、配置、插件体系割裂。
- 我们希望在 r2 中直接提供一个可选的 daemon 模式：
  - 保留批处理：`r2 -q -c 'cmd' file`；
  - 保留交互 TTY：`r2 file`；
  - 新增无头常驻：`r2 --daemon [options]` 或类似入口，通过 socket/stdio 接受命令。

## 2. 设计目标

1. **零外部依赖**：由 `r2` 二进制自身提供 daemon 能力。
2. **状态常驻**：分析、e 配置、flag、session、undo 等在多次客户端调用间存活。
3. **双模式无缝**：
   - 批处理模式仍可随时用于一次性命令；
   - daemon 模式用于 AI agent 的长期连续分析。
4. **稳定可观测**：
   - 命令超时看门狗；
   - visual/交互命令黑名单或安全拒绝；
   - 崩溃/超时后自动恢复现场；
   - 日志与状态查询。
5. **可扩展**：支持多会话/多文件，每个文件独立 `RCore`，避免 r3 踩过的跨文件污染。

## 3. 候选架构

### 方案 A：r2 内建 Unix socket server（推荐）

```
r2 --daemon --socket /tmp/r2-agent.sock --project-dir ~/.cache/r2-agent
```

- 进程启动后不进入 TTY 交互循环，而是监听 Unix socket。
- 每个客户端连接发送一行命令（或采用 NUL 分帧），r2 执行后返回输出。
- r2 进程内部持有 `RCore`（可多个 session），状态天然常驻。
- 客户端可以是一个新的薄 shell 脚本或直接 `r2 -c '...'`？初期可提供 `r2 -q -c` 连接命令，或独立的 `r2c` 工具。

优点：
- 最符合“r2 自身提供守护进程”；
- 不依赖 Python；
- 可精确控制协议、权限、超时、多会话。

缺点：
- 需要新增 socket 监听、协议解析、并发/串行调度；
- 需要处理 daemon 生命周期、权限、清理。

### 方案 B：扩展 `r2 -q0 -` 管道模式

- 保留 r2 现有“stdin 命令 + NUL 分帧”能力，作为无头管道模式；
- 由外部 supervisor 负责 daemon 化、socket 转发、状态恢复。

优点：
- 改动最小，r3 已验证。
缺点：
- 仍是外部包装器思路，不符合“r2 内建”目标；
- 无法优雅支持多客户端/多会话。

### 方案 C：复用 r2 已有远程服务（r2p / rap / http）

- r2 已有 `r2 -c=H` / rap server / http server。
- 但它们的协议面向远程/网页，命令语义和 AI agent 需要的有差距。
- 可作为补充，不作为主方案。

**结论**：先按方案 A 设计最小闭环；方案 B 可作为兼容过渡。

## 4. 需要改动的关键源码位置

| 文件 | 作用 |
|---|---|
| `libr/main/radare2.c` | 主入口，增加 `--daemon` / `--socket` 等参数分支 |
| `libr/core/core.c` | `r_core_prompt_loop()`：交互循环入口，可抽象为“执行一条命令” |
| `libr/core/prompt.c` | 提示符/行编辑；daemon 模式可绕过 |
| `libr/cons` | 输出抽象；daemon 模式需要把输出捕获为字节流，避免 TTY 依赖 |
| `libr/core/project.c` | 工程保存/恢复；用于持久化 session 状态 |
| `libr/core/cmd.c` | 命令分发；需要保证单命令执行后不退出 |
| `binr/radare2/radare2.c` | 二进制包装/参数解析（若主逻辑在 libr/main） |

## 5. 协议草案（参考 r3 实测）

- 连接建立后，server 先发一个 NUL 表示就绪。
- Request：`<命令>\n`
- Response：`<stdout 内容>\0`
- 可选元信息：JSON header 或在独立通道返回状态（超时/拒绝/截断）。
- stderr 单独进日志，不混入 stdout。
- 默认禁止 visual 命令。

## 6. 最小可行闭环（MVP）

1. 新增 `r2 --daemon` 参数，启动后监听 Unix socket。
2. 客户端发送命令，r2 执行并返回完整输出。
3. 支持 `open <file>` 等价操作：打开文件并分析，状态保留。
4. 支持 `close` / `sessions` / `status` 等管理命令。
5. 实现超时看门狗和日志。
6. 提供验收脚本（可参考 `legacy/r3/tests/acceptance.sh`）。

## 7. 后续增强

- 多会话池：每文件独立 `RCore`。
- 缓存秒开：参考 r3 的 `Ps`/`Po` + meta 校验。
- e 配置持久化与回放。
- 拉起式调试。
- JSON 输出完整性保证。
- 权限与 socket 安全。

## 8. 需要进一步决策的问题

- daemon 模式入口命名：`--daemon` / `--server` / `-D`？
- socket 路径默认值：`/tmp/r2-agent.sock` 还是 XDG？
- 多会话是否需要一开始就做，还是先做单会话？
- 协议是否直接兼容 r3 的 socket/请求格式，以便复用旧客户端？
- 是否继续保留 `r2 -q0 -` 作为底层兼容？

## 9. 与旧 r3 的对应关系

| r3 概念 | 新实现建议 |
|---|---|
| `r3 open file` | r2 daemon 内建 `open` 命令，或客户端 `r2 --daemon open file` |
| `r3 "cmd"` | socket 发送命令 |
| 多会话池 | RCore session 池 |
| econf 持久化 | 配置保存/回放 |
| 看门狗/自愈 | daemon 线程/定时器 + 重启恢复 |
| 黑名单 | 命令过滤 |
| 调试边界 | 复用 r2 原生调试能力，只做拉起式 |
