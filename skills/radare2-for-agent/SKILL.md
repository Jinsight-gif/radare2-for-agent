---
name: radare2-for-agent
description: |
  当需要通过 radare2-for-agent v1 的 `r2 --daemon` + `r2 --send` 进行持久化、无头、单会话逆向分析时触发。
  适用场景包括：
  - 需要多次 bash 调用共享同一个 r2 分析状态（函数、flags、seek、配置）
  - 需要以无头方式执行 `open`、`afl`、`pdf`、`s`、`f`、`e` 等 r2 命令
  - 用户要求使用 radare2-for-agent、r2 daemon、r2 --send、R2_AGENT_SOCK 等关键词
  - 逆向工程中希望避免每次重新打开文件、重新分析的场景
  不适用于需要多会话、动态调试 daemon 化、可视化交互模式的场景。
version: 1.0.0
author: jin
license: MIT
metadata:
  dextra:
    tags: [radare2, r2, reverse, daemon, headless, persistent, agent]
    related_skills: [ctf-reverse-solver]
    cli: r2
---

# radare2-for-agent Skill

本 Skill 教 Agent 使用 `radare2-for-agent` v1 提供的无头常驻 r2 服务：
`r2 --daemon` 启动一个 Unix socket daemon，`r2 --send` 向它发送命令并取回输出。
它解决“每次新开 bash 都丢失 r2 分析状态”的问题。

## 何时使用

- 需要跨多次命令调用保留 `RCore` 状态（如先 `open`，再多次 `afl` / `pdf` / `s` / `e`）。
- 需要在脚本或 Agent 工作流中以无头方式驱动 r2。
- 用户明确提到 `r2 --daemon`、`r2 --send`、`radare2-for-agent`、`R2_AGENT_SOCK`。
- 逆向分析一个文件并希望避免反复重新加载、重新分析。

**不要用于**：

- 多会话/多文件并行隔离（v1 只维护单个 RCore）。
- 动态调试（`-d` 的 daemon 化不在 v1 范围）。
- Visual/TUI 交互（会被黑名单拒绝）。
- 需要工程缓存、配置落盘持久化的场景（v1 非目标）。

## 环境与全局安装

完成 v1 全局安装后，`r2` 应指向本仓库构建的版本：

```bash
r2 -v
# 应输出 radare2 6.x/本机 fork 版本
command -v r2
# 通常是 /usr/local/bin/r2
```

Socket 默认路径：

- `/tmp/r2-agent.sock`
- 或环境变量 `R2_AGENT_SOCK` 指定的路径

日志默认路径：`/tmp/r2-agent.log`

## 基本用法

### 1. 启动 daemon

后台常驻（默认 daemon 化）：

```bash
r2 --daemon --socket /tmp/r2-agent.sock --log /tmp/r2-agent.log
```

前台调试（适合测试，不会 fork）：

```bash
r2 --daemon --foreground --socket /tmp/r2-agent.sock --log /tmp/r2-agent.log
```

### 2. 发送命令

```bash
r2 --send "?e hello" --socket /tmp/r2-agent.sock
r2 --send "status" --socket /tmp/r2-agent.sock
r2 --send 'afl' --socket /tmp/r2-agent.sock
r2 --send 'pdf @ main' --socket /tmp/r2-agent.sock
```

### 3. JSON 信封

需要 daemon 元信息（错误、超时、截断）时加 `--json`：

```bash
r2 --send 'aflj' --socket /tmp/r2-agent.sock --json
```

返回：

```json
{"ok":true,"output":"...","truncated":false,"timed_out":false,"error":null}
```

注意：想拿 r2 原生 JSON（如 `aflj`）时**不要**加 `--json`，直接发送命令即可得到原始 JSON 文本。

### 4. 管理命令

| 命令 | 作用 |
|---|---|
| `open <file>` | 关闭当前文件并打开新文件，自动执行 `aaa` 分析 |
| `close` | 关闭当前文件，daemon 保持存活 |
| `status` | 查看 daemon pid、socket、当前文件、分析状态 |
| `quit` | 退出 daemon 并清理 socket |

```bash
r2 --send 'open /bin/ls' --socket /tmp/r2-agent.sock
r2 --send 'afl~main' --socket /tmp/r2-agent.sock
r2 --send 'pdf @ main' --socket /tmp/r2-agent.sock
r2 --send 'status' --socket /tmp/r2-agent.sock
r2 --send 'quit' --socket /tmp/r2-agent.sock
```

## 常用 r2 命令透传

daemon 只是透传普通 r2 命令，状态在多次 `--send` 之间保留：

```bash
r2 --send 'e asm.bytes=false' --socket /tmp/r2-agent.sock
r2 --send 'e asm.bytes' --socket /tmp/r2-agent.sock
# false

r2 --send 's main' --socket /tmp/r2-agent.sock
r2 --send 's' --socket /tmp/r2-agent.sock
# 当前地址

r2 --send 'f foo @ main' --socket /tmp/r2-agent.sock
r2 --send 'f~foo' --socket /tmp/r2-agent.sock
```

## 边界与限制

- **单会话**：一个 daemon 只维护一个 RCore；换文件用 `open`，它会先关闭旧文件。
- **无并发**：daemon 单线程串行处理客户端。
- **无调试 daemon 化**：`-d` 相关能力不在 v1 daemon 范围。
- **无磁盘缓存**：不提供 `Ps/Po` 秒开缓存。
- **无 e 配置持久化**：`e k=v` 只在当前 daemon 生命周期内保留。
- **Visual 黑名单**：`V`、`Vv`、`Vi`、`v`、`vv`、`vvi` 等命令会被拒绝，避免挂死。
- **Unix Socket only**：默认 `/tmp/r2-agent.sock` 或 `$R2_AGENT_SOCK`。
- **stderr 不进响应**：r2 的 stderr 写入 daemon 日志，不混入命令输出。
- **超时**：客户端可用 `--timeout N`；超时后 daemon 应可恢复（长命令结束后）。
- **退出码**：成功为 `0`；连接失败、命令被拒、超时等返回非零。

## 推荐工作流

```bash
# 1. 启动 daemon（后台）
r2 --daemon --socket /tmp/r2-agent.sock --log /tmp/r2-agent.log

# 2. 打开目标
r2 --send 'open ./target' --socket /tmp/r2-agent.sock

# 3. 分析
r2 --send 'aaa' --socket /tmp/r2-agent.sock
r2 --send 'afl' --socket /tmp/r2-agent.sock
r2 --send 'pdf @ main' --socket /tmp/r2-agent.sock

# 4. 查询/配置
r2 --send 's main' --socket /tmp/r2-agent.sock
r2 --send 'e asm.bytes=false' --socket /tmp/r2-agent.sock

# 5. 结束
r2 --send 'quit' --socket /tmp/r2-agent.sock
```

## 故障排查

- `error: cannot connect to ...`：daemon 未启动或 socket 路径不对。
- `error: command rejected ...`：发送了 visual/黑名单命令。
- `error: timeout waiting for daemon`：客户端等待超时；稍后重试或检查 daemon 是否仍在执行长命令。
- 如果 daemon 异常退出留下 stale socket，重启 daemon 会自动清理。
- 需要调试 daemon 时用 `--foreground` 并观察日志。
