---
name: radare2-for-agent
description: |
  当需要通过 radare2-for-agent v1 进行逆向分析时触发本 Skill。
  适用场景包括：
  - 使用传统批命令模式：`r2 -q -c 'cmd' file`
  - 使用交互式循环模式：`r2 --daemon` + `r2 --send`，需要多次 bash 调用共享同一个 r2 状态
  - 需要无头方式执行 `open`、`afl`、`pdf`、`s`、`f`、`e` 等 r2 命令
  - 用户要求使用 radare2-for-agent、r2 daemon、r2 --send、R2_AGENT_SOCK 等关键词
  不适用于多会话、动态调试 daemon 化、Visual/TUI 交互等 v1 非目标场景。
version: 1.1.0
author: jin
license: MIT
metadata:
  dextra:
    tags: [radare2, r2, reverse, daemon, headless, persistent, agent, batch]
    related_skills: [ctf-reverse-solver]
    cli: r2
---

# radare2-for-agent Skill

本 Skill 帮助 AI Agent 正确使用 `radare2-for-agent` v1。它包含两种主要使用模式：

1. **命令行批命令模式**：适合一次性分析，每次命令独立，不保留状态。
2. **交互式循环模式**：适合持续分析，通过 `r2 --daemon` + `r2 --send` 在多次 bash 调用之间保留同一个 `RCore` 状态。

---

## 1. 两种模式总览

| 模式 | 典型命令 | 状态是否保留 | 适合场景 |
|---|---|---|---|
| 命令行批命令模式 | `r2 -q -c 'cmd' file` | 不保留 | 快速查看、一次性脚本、CI |
| 交互式循环模式（TTY） | `r2 file`，进入 `>` 提示符 | 保留（进程内） | 人工交互调试 |
| 交互式循环模式（Agent 常驻） | `r2 --daemon` + `r2 --send` | 保留（daemon 内） | AI Agent 多轮分析、跨 bash 调用 |

---

## 2. 命令行批命令模式

适合“打开文件、执行命令、退出”的一次性流程。

### 2.1 基本用法

```bash
# 打开文件并执行一条命令
r2 -q -c 'afl' /bin/ls

# 执行多条命令，用分号分隔
r2 -q -c 'aaa; afl' /bin/ls

# 执行多条 -c
r2 -q -c 'aaa' -c 'afl' -c 'pdf @ main' /bin/ls

# 自动执行 aaa 分析后再执行命令
r2 -A -c 'afl' /bin/ls

# 不加载 bin 头信息，按纯文件读取
r2 -n -c 'px 16' /bin/ls

# 设置配置项
r2 -q -e asm.bytes=false -c 'pdf @ main' /bin/ls

# 初始 seek
r2 -q -s main -c 'pdf' /bin/ls
```

### 2.2 常用批命令示例

```bash
# 函数列表
r2 -q -c 'aaa' -c 'afl' /bin/ls

# 函数 JSON
r2 -q -c 'aaa' -c 'aflj' /bin/ls

# 反汇编 main
r2 -q -c 'aaa' -c 'pdf @ main' /bin/ls

# 字符串
r2 -q -c 'izz' /bin/ls

# 导入表
r2 -q -c 'ii' /bin/ls

# 段/映射
r2 -q -c 'iS' /bin/ls

# 文件信息
r2 -q -c 'iI' /bin/ls

# 配置项读写
r2 -q -c 'e asm.bytes' /bin/ls
```

### 2.3 特点与局限

- 每次进程退出后状态丢失。
- 适合快速、无状态、可重复执行的命令。
- 不适合需要“先分析一次，再多次查询/修改状态”的 AI 工作流。

---

## 3. 交互式循环模式

### 3.1 人工 TTY 模式

```bash
r2 /bin/ls
```

进入交互提示符后直接输入 r2 命令：

```text
[0x00000000]> aaa
[0x00000000]> afl
[0x00000000]> pdf @ main
[0x00000000]> q
```

- 状态在进程内保留。
- 需要 TTY/交互界面，不适合 AI 每次新开 bash 的场景。

### 3.2 Agent 常驻模式（v1 核心）

使用 `r2 --daemon` 启动常驻服务，`r2 --send` 发送命令。

---

## 4. `r2 --daemon` 启动参数

```bash
# 后台常驻（默认 daemon 化）
r2 --daemon \
  --socket /tmp/r2-agent.sock \
  --log /tmp/r2-agent.log

# 前台调试（不 fork）
r2 --daemon --foreground \
  --socket /tmp/r2-agent.sock \
  --log /tmp/r2-agent.log

# 使用环境变量指定 socket
export R2_AGENT_SOCK=/tmp/my-agent.sock
r2 --daemon --foreground --log /tmp/my-agent.log
```

参数说明：

| 参数 | 说明 | 默认值 |
|---|---|---|
| `--daemon` | 启动 daemon 模式 | 无 |
| `--socket PATH` | Unix socket 路径 | `$R2_AGENT_SOCK` 或 `/tmp/r2-agent.sock` |
| `--log PATH` | 日志文件路径 | `/tmp/r2-agent.log` |
| `--foreground` | 前台运行，不 fork | 默认后台 |
| `--timeout N` | 客户端超时秒数 | 30 |

---

## 5. `r2 --send` 发送命令

```bash
r2 --send '命令' \
  --socket /tmp/r2-agent.sock \
  [--json] \
  [--timeout 30]
```

参数说明：

| 参数 | 说明 |
|---|---|
| `--send 'CMD'` | 要执行的 r2 命令 |
| `--socket PATH` | daemon socket 路径 |
| `--json` | 返回 JSON 信封 |
| `--timeout N` | 客户端等待秒数 |

### 5.1 普通文本输出

```bash
r2 --send '?e hello' --socket /tmp/r2-agent.sock
# hello

r2 --send 'status' --socket /tmp/r2-agent.sock
r2 --send 'open /bin/ls' --socket /tmp/r2-agent.sock
r2 --send 'afl' --socket /tmp/r2-agent.sock
```

### 5.2 JSON 信封

```bash
r2 --send 'aflj' --socket /tmp/r2-agent.sock --json
```

返回：

```json
{"ok":true,"output":"...","truncated":false,"timed_out":false,"error":null}
```

字段说明：

| 字段 | 类型 | 说明 |
|---|---|---|
| `ok` | bool | 命令是否成功 |
| `output` | string | 命令输出文本 |
| `truncated` | bool | 是否被截断 |
| `timed_out` | bool | 是否超时 |
| `error` | string/null | 错误信息 |

> 注意：想拿 r2 原生 JSON（如 `aflj`）时**不要**加 `--json`，直接发送命令即可得到原始 JSON。

---

## 6. 管理命令

| 命令 | 行为 |
|---|---|
| `open <path>` | 关闭当前文件并打开新文件，自动执行 `aaa` |
| `close` | 关闭当前文件，daemon 保持存活 |
| `status` | 显示 daemon pid、socket、当前文件、分析状态 |
| `quit` | 退出 daemon 并清理 socket |

```bash
r2 --send 'open /bin/ls' --socket /tmp/r2-agent.sock
r2 --send 'status' --socket /tmp/r2-agent.sock
r2 --send 'close' --socket /tmp/r2-agent.sock
r2 --send 'quit' --socket /tmp/r2-agent.sock
```

---

## 7. 常用 r2 命令速查（daemon 透传）

以下命令都可以通过 `r2 --send '...' --socket ...` 执行，状态会保留。

### 7.1 分析与函数

```bash
r2 --send 'aaa' --socket /tmp/r2-agent.sock
r2 --send 'afl' --socket /tmp/r2-agent.sock
r2 --send 'aflj' --socket /tmp/r2-agent.sock
r2 --send 'afl~main' --socket /tmp/r2-agent.sock
r2 --send 'pdf @ main' --socket /tmp/r2-agent.sock
r2 --send 'pdr @ main' --socket /tmp/r2-agent.sock
r2 --send 's main' --socket /tmp/r2-agent.sock
```

### 7.2 文件与信息

```bash
r2 --send 'iI' --socket /tmp/r2-agent.sock
r2 --send 'iS' --socket /tmp/r2-agent.sock
r2 --send 'ii' --socket /tmp/r2-agent.sock
r2 --send 'izz' --socket /tmp/r2-agent.sock
r2 --send 'o' --socket /tmp/r2-agent.sock
```

### 7.3 配置项

```bash
r2 --send 'e asm.bytes' --socket /tmp/r2-agent.sock
r2 --send 'e asm.bytes=false' --socket /tmp/r2-agent.sock
r2 --send 'e asm.bits=64' --socket /tmp/r2-agent.sock
r2 --send 'e io.va=true' --socket /tmp/r2-agent.sock
```

### 7.4 Flags 与 Seek

```bash
r2 --send 's main' --socket /tmp/r2-agent.sock
r2 --send 's' --socket /tmp/r2-agent.sock
r2 --send 'f foo @ main' --socket /tmp/r2-agent.sock
r2 --send 'f~foo' --socket /tmp/r2-agent.sock
r2 --send 'fs' --socket /tmp/r2-agent.sock
```

### 7.5 内存与打印

```bash
r2 --send 'px 64' --socket /tmp/r2-agent.sock
r2 --send 'p8 16' --socket /tmp/r2-agent.sock
r2 --send 'pxq 16' --socket /tmp/r2-agent.sock
r2 --send 'pd 10' --socket /tmp/r2-agent.sock
```

---

## 8. 推荐 AI 工作流

```bash
# 1. 启动 daemon
r2 --daemon --socket /tmp/r2-agent.sock --log /tmp/r2-agent.log

# 2. 打开目标并分析
r2 --send 'open ./target' --socket /tmp/r2-agent.sock
r2 --send 'aaa' --socket /tmp/r2-agent.sock

# 3. 信息收集
r2 --send 'iI' --socket /tmp/r2-agent.sock
r2 --send 'iS' --socket /tmp/r2-agent.sock
r2 --send 'ii' --socket /tmp/r2-agent.sock
r2 --send 'izz' --socket /tmp/r2-agent.sock

# 4. 函数与反汇编
r2 --send 'afl' --socket /tmp/r2-agent.sock
r2 --send 'pdf @ main' --socket /tmp/r2-agent.sock

# 5. 定位与状态修改
r2 --send 's main' --socket /tmp/r2-agent.sock
r2 --send 'e asm.bytes=false' --socket /tmp/r2-agent.sock
r2 --send 'f foo @ main' --socket /tmp/r2-agent.sock

# 6. 结束
r2 --send 'quit' --socket /tmp/r2-agent.sock
```

---

## 9. 能力边界

- **单会话**：一个 daemon 只维护一个 RCore；换文件用 `open`。
- **无并发**：daemon 单线程串行处理客户端。
- **无调试 daemon 化**：`-d` 相关能力不在 v1 daemon 范围。
- **无磁盘缓存**：不提供 `Ps/Po` 秒开缓存。
- **无 e 配置持久化**：`e k=v` 只在当前 daemon 生命周期内保留。
- **Visual 黑名单**：`V`、`Vv`、`Vi`、`v`、`vv`、`vvi` 等命令会被拒绝。
- **Unix Socket only**：默认 `/tmp/r2-agent.sock` 或 `$R2_AGENT_SOCK`。
- **stderr 不进响应**：r2 的 stderr 写入 daemon 日志。
- **超时**：可用 `--timeout N`；超时后 daemon 应可恢复（长命令结束后）。
- **退出码**：成功为 `0`；连接失败、命令被拒、超时等返回非零。

---

## 10. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `error: cannot connect to ...` | daemon 未启动或 socket 路径不对 | 启动 daemon，检查 `--socket`/`R2_AGENT_SOCK` |
| `error: command rejected ...` | 发送 visual/黑名单命令 | 改用非 visual 命令 |
| `error: timeout waiting for daemon` | 客户端等待超时 | 稍后重试，或检查 daemon 是否仍在执行长命令 |
| 命令输出缺失 | 可能使用了 `--json` 包装 | 需要原生 JSON 时不要加 `--json` |
| daemon 异常退出留下 socket | 上次未正常清理 | 重启 daemon 会自动清理 stale socket |
| 需要观察 daemon 日志 | 日志路径不对 | 使用 `--log PATH`，或前台 `--foreground` 调试 |
