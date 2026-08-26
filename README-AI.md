# README-AI：给 AI Agent 的安装与使用说明

> 本项目是 [radare2](https://github.com/radareorg/radare2) 的二次开发分支。
> 上游仓库：https://github.com/radareorg/radare2
> 初心：让 radare2 原生支持 AI agent 所需的“无头 + 守护进程 + 持久化”交互模式，使 AI 每次新开 bash 都能连接同一个常驻 r2 状态。

本文件专门给 AI Agent 阅读，用于快速完成以下事情：

1. 安装 radare2-for-agent v1
2. 验证安装是否成功
3. 使用 `r2 --daemon` + `r2 --send` 进行持久化逆向分析
4. 了解 v1 的能力边界，避免误用

---

## 1. 这是什么

radare2-for-agent v1 在 radare2 源码内实现了：

- `r2 --daemon`：启动一个 Unix socket 常驻 daemon
- `r2 --send`：向 daemon 发送 r2 命令并取回输出
- 单会话 RCore：多次 `--send` 之间保留分析状态、flags、seek、配置
- 管理命令：`open` / `close` / `status` / `quit`
- 稳定保护：visual 黑名单、超时恢复、日志、stale socket 清理

它不是外部 Python 包装器，而是 r2 自身的原生能力。

---

## 2. 安装

### 2.1 依赖

- Linux/macOS（Unix socket 是 v1 的基础）
- `make`、`gcc`、`git`
- 可选：`meson` / `ninja`

### 2.2 从源码安装

```bash
git clone <你的仓库地址> radare2-for-agent
cd radare2-for-agent

./configure
make -j$(nproc)
sudo make symstall
```

`make symstall` 会把 `r2` 和 radare2 相关工具软链到 `/usr/local/bin`，并把库文件软链到 `/usr/local/lib`。

### 2.3 验证安装

```bash
hash -r
r2 -v
# 应看到 radare2 6.2.0 或本 fork 对应版本

r2 --help | grep -- '--daemon'
# 应看到：
# --daemon     start headless agent daemon
```

### 2.4 DSH / Agent Skill（可选）

本项目同时提供一个 DSH Skill，放在：

```text
~/.dsh/skills/radare2-for-agent/SKILL.md
```

如果使用 DSH，把该 Skill 目录放到 `~/.dsh/skills/` 下，或在 DSH 的 skill 目录中创建软链即可被自动发现。

---

## 3. 快速使用

### 3.1 启动 daemon

后台常驻：

```bash
r2 --daemon --socket /tmp/r2-agent.sock --log /tmp/r2-agent.log
```

前台调试（不 fork，适合测试）：

```bash
r2 --daemon --foreground --socket /tmp/r2-agent.sock --log /tmp/r2-agent.log
```

### 3.2 发送命令

```bash
r2 --send '?e hello' --socket /tmp/r2-agent.sock
r2 --send 'status' --socket /tmp/r2-agent.sock
r2 --send 'open /bin/ls' --socket /tmp/r2-agent.sock
r2 --send 'afl' --socket /tmp/r2-agent.sock
r2 --send 'pdf @ main' --socket /tmp/r2-agent.sock
r2 --send 'quit' --socket /tmp/r2-agent.sock
```

### 3.3 JSON 信封

需要 daemon 元信息时使用 `--json`：

```bash
r2 --send 'aflj' --socket /tmp/r2-agent.sock --json
```

返回：

```json
{"ok":true,"output":"...","truncated":false,"timed_out":false,"error":null}
```

注意：如果只是想拿 r2 原生 JSON（如 `aflj`），**不要**加 `--json`，直接发送命令即可。

---

## 4. 管理命令

| 命令 | 作用 |
|---|---|
| `open <file>` | 关闭当前文件并打开新文件，自动执行 `aaa` 分析 |
| `close` | 关闭当前文件，daemon 保持存活 |
| `status` | 查看 daemon pid、socket、当前文件、分析状态 |
| `quit` | 退出 daemon 并清理 socket |

---

## 5. 能力边界（AI 必须知道）

- **单会话**：一个 daemon 只维护一个 RCore，换文件用 `open`。
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

## 6. 推荐 AI 工作流

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

---

## 7. 故障排查

- `error: cannot connect to ...`：daemon 未启动或 socket 路径不对。
- `error: command rejected ...`：发送了 visual/黑名单命令。
- `error: timeout waiting for daemon`：客户端等待超时；稍后重试或检查 daemon 是否仍在执行长命令。
- 如果 daemon 异常退出留下 stale socket，重启 daemon 会自动清理。
- 需要调试 daemon 时用 `--foreground` 并观察日志。

---

## 8. 致谢与版权

本项目基于 [radare2](https://github.com/radareorg/radare2) 二次开发，尊重上游作者与社区：

- 上游仓库：https://github.com/radareorg/radare2
- 上游官网：https://radare.org/
- 本项目仅新增 AI agent 友好的 daemon/send 能力，不改变 radare2 原有 CLI 与插件生态的精神。
