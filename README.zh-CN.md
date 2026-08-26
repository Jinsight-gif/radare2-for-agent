# radare2-for-agent（中文说明）

> 本项目基于 [radare2](https://github.com/radareorg/radare2) 二次开发。
> 上游仓库：https://github.com/radareorg/radare2
> 初心：让 radare2 原生支持 AI agent 所需的“无头 + 守护进程 + 持久化”交互模式，使 AI 每次新开 bash 都能连接同一个常驻 r2 状态，不再依赖旧的外部 Python 包装器 r3。

## 如果你是一个 AI Agent

请优先阅读 [README-AI.md](README-AI.md)，里面有面向 AI 的安装步骤、使用方法和能力边界。

## v1 功能

- `r2 --daemon`：启动 Unix socket 常驻 daemon
- `r2 --send "cmd"`：向 daemon 发送 r2 命令并取回输出
- 单会话 RCore：多次调用之间保留分析状态、flags、seek、配置
- 管理命令：`open` / `close` / `status` / `quit`
- 稳定保护：visual 黑名单、超时恢复、日志、stale socket 清理

## 快速开始

```bash
./configure
make -j$(nproc)
sudo make symstall
```

启动 daemon：

```bash
r2 --daemon --socket /tmp/r2-agent.sock --log /tmp/r2-agent.log
```

发送命令：

```bash
r2 --send '?e hello' --socket /tmp/r2-agent.sock
r2 --send 'status' --socket /tmp/r2-agent.sock
r2 --send 'open /bin/ls' --socket /tmp/r2-agent.sock
r2 --send 'afl' --socket /tmp/r2-agent.sock
r2 --send 'quit' --socket /tmp/r2-agent.sock
```

## Skill

AI Agent 使用说明见 [`skills/radare2-for-agent/SKILL.md`](skills/radare2-for-agent/SKILL.md)。

## 致谢

尊重上游 radare2 作者与社区：

- 上游仓库：https://github.com/radareorg/radare2
- 上游官网：https://radare.org/
