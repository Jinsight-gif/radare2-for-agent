# radare2-for-agent v1 开发方案

> 状态：已确认，待开发  
> 目标读者：负责开发本功能的 AI agent（DSH goal mode）  
> 基线：radare2 6.2.0 / 分支 `r2-agent`  
> 开发模式：DSH goal mode（每个 Goal 有明确验收标准，完成一个再进下一个）

---

## 1. 文档目的

本文档定义 radare2-for-agent 的 **v1 最小可用闭环**：

- 在 radare2 源码内实现一个 **单会话、无头、常驻守护进程**。
- 让 AI agent 每次新开 bash 都可以通过短命客户端连接同一个常驻 r2 状态。
- 不再依赖旧的外部 Python 包装器 r3。

本文档不是完整产品设计，而是 **v1 开发蓝图**。所有超出 v1 的能力都明确列为“非目标”。

---

## 2. 背景与问题

### 2.1 现状

- AI agent 每次运行命令都会新开 bash。
- 传统 `r2 -q -c "cmd" file` 每次都会重新打开文件、重新分析，状态不保留。
- r2 交互式 TTY 模式虽然状态常驻，但无法被无头 agent 直接使用。

### 2.2 旧 r3 的教训

- r3 用 Python daemon 包住 `r2 -q0 -`，解决了状态常驻。
- 但 r3 是外部包装器，破坏了 r2 的完整性，且命令行模式与交互模式切换不自然。
- 因此 v1 改为在 r2 源码内提供 daemon 能力，同时保留 r3 已验证的协议经验。

---

## 3. v1 目标（Goal）

### 主目标 G0

> 让 `r2 --daemon` 能启动一个常驻 r2 服务，让 `r2 --send "<命令>"` 能把命令发给它并拿到输出。

### 子目标拆解

| 编号 | 子目标 | 一句话描述 |
|---|---|---|
| G1 | CLI 参数识别 | 支持 `--daemon`、`--send`、`--socket`、`--log`、`--json`、`--timeout` |
| G2 | Daemon 生命周期 | 能启动、监听、退出；支持前台调试与后台守护 |
| G3 | 单会话 RCore | 一个 daemon 只维护一个 RCore，命令状态跨调用保留 |
| G4 | 命令透传 | 普通 r2 命令原样执行，输出原样返回 |
| G5 | 管理命令 | 支持 `open`、`close`、`status`、`quit` |
| G6 | 稳定性 | 超时、visual 黑名单、日志、异常恢复 |
| G7 | 验收测试 | 有可重复的自动化验收脚本与文档 |

---

## 4. 非目标（Non-goals）

以下内容 **v1 明确不做**：

- ❌ 多会话池：一个 daemon 只服务一个文件/一个 RCore。
- ❌ 磁盘工程缓存：不实现 `Ps/Po` 秒开缓存。
- ❌ 动态调试：不做 `-d` 相关 daemon 化。
- ❌ e 配置持久化：不把 `e k=v` 配置落盘回放。
- ❌ Visual 模式：继续禁止。
- ❌ 多客户端并发：v1 单线程串行处理。
- ❌ 用户认证/权限模型：只做 Unix socket 基本文件权限。

这些内容放入 v1.1 / v2 规划。

---

## 5. 总体架构

```text
AI agent / DSH goal mode
        │
        ▼
r2 --send "afl" --socket /tmp/r2-agent.sock     ← 短命客户端
        │
        ▼
Unix Domain Socket
        │
        ▼
r2 --daemon --socket /tmp/r2-agent.sock         ← 常驻守护进程
        │
        ▼
RCore（单会话，状态常驻内存）
```

要点：

- daemon 是 **r2 自身进程**，不是外部 Python 脚本。
- 客户端每次调用都是短命进程，发一条命令后退出。
- daemon 单线程 accept，串行处理命令，避免并发竞争。

---

## 6. CLI 设计

### 6.1 启动 daemon

```bash
r2 --daemon \
  --socket /tmp/r2-agent.sock \
  --log /tmp/r2-agent.log \
  [--foreground]
```

参数说明：

| 参数 | 含义 | 默认值 |
|---|---|---|
| `--daemon` | 启动守护进程模式 | 无 |
| `--socket PATH` | Unix socket 路径 | `$R2_AGENT_SOCK` 或 `/tmp/r2-agent.sock` |
| `--log PATH` | daemon 日志文件 | `/tmp/r2-agent.log` |
| `--foreground` | 前台运行，不 fork 到后台 | 默认后台 |

设计说明：

- 默认 daemon 化：fork + setsid，标准输出/错误重定向到日志。
- `--foreground` 供开发调试和自动化测试使用。
- 如果 socket 已存在，先检查是否可连接；可连接则报“已在运行”，不可连接则清理 stale socket 后启动。

### 6.2 发送命令

```bash
r2 --send "afl" \
  --socket /tmp/r2-agent.sock \
  [--json] \
  [--timeout 30]
```

参数说明：

| 参数 | 含义 | 默认值 |
|---|---|---|
| `--send "CMD"` | 发送一条 r2 命令 | 无 |
| `--socket PATH` | 指定 daemon socket | 与 daemon 相同默认 |
| `--json` | 返回 JSON 信封（含 output/ok/truncated 等） | 文本原样输出 |
| `--timeout N` | 客户端等待超时秒数 | 30 |

### 6.3 退出 daemon

```bash
r2 --send "quit" --socket /tmp/r2-agent.sock
```

### 6.4 与现有参数的关系

- `--daemon` / `--send` 是 v1 新增的长选项。
- 由于 r2 现有 `RGetopt` 只支持短选项，v1 需要在 `r_main_radare2()` 开头增加一个 **轻量长选项预扫描**，只识别上述参数，不影响其他短选项。
- 保留 `-q`、`-c`、`-` 等原有模式不变。

---

## 7. 通信协议

### 7.1 传输层

- 使用 **Unix Domain Socket**。
- 客户端连接后发送 **一个请求**，daemon 处理后返回 **一个响应**，然后关闭连接。
- daemon 单线程串行处理，天然避免并发问题。

### 7.2 分帧

沿用 r3 验证过的 **NUL 分帧**：

- 请求以 `\0` 结尾。
- 响应以 `\0` 结尾。
- 这样不需要依赖换行转义，r2 输出中的换行不会破坏分帧。

### 7.3 请求格式

请求使用一行 JSON：

```json
{"cmd":"afl","json":false,"timeout":30}
```

字段：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `cmd` | string | 是 | 要执行的 r2 命令，或 daemon 管理命令 |
| `json` | bool | 否 | 是否返回 JSON 信封，默认 false |
| `timeout` | int | 否 | 命令超时秒数，默认 30 |

### 7.4 响应格式

#### 文本模式（默认）

```text
<r2 命令输出>\0
```

- 输出为 r2 原样 stdout。
- stderr 不进响应，统一写入 daemon 日志。
- 如果超时/被拒，响应为约定的错误文本 + NUL。

#### JSON 模式（`--json`）

```json
{"ok":true,"output":"...","truncated":false,"timed_out":false,"error":null}\0
```

字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `ok` | bool | 是否成功 |
| `output` | string | 命令输出文本 |
| `truncated` | bool | 是否被截断 |
| `timed_out` | bool | 是否超时 |
| `error` | string/null | 错误信息 |

注意：

- 如果用户想拿 r2 原生 JSON（如 `aflj`），**不要加 `--json`**，直接发 `aflj`，响应就是原始 JSON 文本。
- `--json` 只用于需要 daemon 元信息（截断/超时/错误）的场景。

### 7.5 管理命令

| 命令 | 行为 |
|---|---|
| `open <path>` | 打开文件；如果已有文件则先关闭再打开；执行 `aaa` 分析 |
| `close` | 关闭当前文件，保留 daemon 进程 |
| `status` | 返回 daemon 与当前 RCore 状态 |
| `quit` | 保存必要状态后退出 daemon |

管理命令由 daemon 拦截，不传给 r2 原生命令层。

---

## 8. 核心改动与新增文件

### 8.1 新增文件

```text
libr/main/r2agent.c       # daemon/client 核心实现
libr/main/r2agent.h       # 内部头文件，不对外暴露 API
libr/main/meson.build     # 注册新源文件（如适用）
libr/main/Makefile        # 注册新源文件（如适用）
```

### 8.2 修改文件

```text
libr/main/radare2.c       # 增加长选项预扫描，接入 r2agent
test/                    # 新增 v1 验收测试
docs/                    # 更新项目文档
```

### 8.3 核心函数设计

```c
// r2agent.h（草案）

typedef struct {
    const char *socket_path;
    const char *log_path;
    bool foreground;
    int timeout;
} R2AgentOptions;

int r2agent_start(RCore *core, R2AgentOptions *opts);
int r2agent_send(const char *cmd, const char *socket_path,
                 bool json, int timeout, char **out);
```

daemon 内部：

```c
static int handle_client(RCore *core, int fd);
static int exec_r2_command(RCore *core, const char *cmd,
                           char **out, bool json, int timeout);
static int mgmt_open(RCore *core, const char *path);
static int mgmt_close(RCore *core);
static int mgmt_status(RCore *core, char **out, bool json);
static int mgmt_quit(RCore *core);
static bool is_blacklisted(const char *cmd);
```

### 8.4 命令执行方式

- 普通 r2 命令使用 `r_core_cmd_str()` 捕获输出。
- `open` 管理命令内部使用 `r_core_file_open()` + `r_core_cmd0("aaa")` 或等价的 r2 原生命令。
- `status` 输出 daemon pid、socket、当前文件、已分析状态等。
- 所有输出统一经过 NUL 分帧写出。

### 8.5 超时与稳定性

v1 采用两层策略：

1. **协作式超时**：执行命令前调用 `r_cons_break_timeout()`，在命令执行过程中通过 `r_cons_is_breaked()` 让可中断的 r2 命令主动退出。
2. **硬兜底**：如果命令仍卡死，客户端等待超时后可以杀掉 daemon 进程并自动重启；daemon 启动时如果检测到 stale socket 会清理。

> 技术预研项：在实现过程中验证 `r_cons_break_timeout` 对长命令的实际中断效果；如果不理想，再考虑独立 watchdog 子进程方案。

### 8.6 黑名单

沿用 r3 经验，daemon 拒绝执行 visual/交互命令：

```text
V, VV, Vv, Vi, Vp, Vk, Vd, Vb, Vm, Vs, Vf, Ve,
v, vv, ve, vp, vk, vvi
```

命中黑名单返回明确错误，不传给 RCore。

---

## 9. DSH Goal Mode 开发任务拆解

### Goal 1：CLI 参数预扫描

- [ ] 在 `r_main_radare2()` 开头增加长选项识别。
- [ ] 支持 `--daemon`、`--send`、`--socket`、`--log`、`--json`、`--timeout`、`--foreground`。
- [ ] 不影响原有短选项行为。

**验收**：
- `r2 --help` 能看到新参数说明。
- `r2 --daemon --foreground --socket /tmp/x.sock` 能进入 daemon 模式。
- 直接用 `r2 -q -c "?e hi" /bin/ls` 仍正常工作。

### Goal 2：Socket Server 最小闭环

- [ ] 实现 `r2agent_start()`。
- [ ] Unix socket bind/listen/accept。
- [ ] 处理客户端连接，读取 NUL 请求，返回 NUL 响应。
- [ ] 支持 `--foreground` 与后台 daemon 化。

**验收**：
- 用 `socat` 或 Python socket 发送 `{"cmd":"?e hello","json":false}\0`，能收到 `hello\0`。
- socket 文件权限为 `0600` 或 `0700`。
- 已有 stale socket 时能自动清理。

### Goal 3：单会话 RCore 与命令透传

- [ ] daemon 持有唯一 `RCore`。
- [ ] 每条普通命令通过 `r_core_cmd_str()` 执行。
- [ ] 分析状态跨多次客户端调用保留。

**验收**：
- 客户端 1：`open /bin/ls`。
- 客户端 2：`afl~main`。
- 客户端 3：`pdf @ main`。
- 三次调用之间状态不丢失。

### Goal 4：管理命令

- [ ] 实现 `open/close/status/quit`。
- [ ] `open` 能打开文件并执行 `aaa`。
- [ ] `status` 输出机器可读信息。

**验收**：
- `open` 一个真实 ELF 后，`status` 能看到文件路径与已分析状态。
- `close` 后 `status` 显示无当前文件，daemon 仍存活。
- `quit` 后 socket 被清理，进程退出。

### Goal 5：稳定性

- [ ] 实现 visual 黑名单。
- [ ] 实现日志写入。
- [ ] 实现协作式超时。
- [ ] 实现错误响应。

**验收**：
- 发送 `V` 返回黑名单错误，进程不挂。
- 发送长时间命令并设置短 `timeout`，能返回超时错误或客户端超时后 daemon 可恢复。
- daemon 日志记录每次请求与错误。

### Goal 6：测试与文档

- [ ] 写自动化验收脚本（可参考 `legacy/r3/tests/acceptance.sh`）。
- [ ] 更新 `PROJECT.md`。
- [ ] 更新 `AGENTS.md` 导航。

**验收**：
- 新增测试在干净环境可重复通过。
- 文档与实现一致。

---

## 10. 最终验收标准（v1 Done）

以下全部满足，v1 才算完成：

1. `r2 --daemon` 可以启动常驻服务。
2. `r2 --send "afl"` 能拿到当前 RCore 的实时输出。
3. 多次 `r2 --send` 之间，分析状态、flags、seek 等保持不变。
4. `open/close/status/quit` 四个管理命令可用。
5. visual 命令被拒绝，不会挂死。
6. 超时场景有明确错误，daemon 可恢复。
7. 原有 `r2 -q -c` 批处理模式不受影响。
8. 有可重复的自动化验收脚本。

---

## 11. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 长命令超时难以安全中断 | 命令卡死导致 daemon 无响应 | 先协作式超时，再用客户端杀进程+自动重启兜底 |
| `r_core_cmd_str` 输出捕获不完整 | 命令输出缺失 | 用 r3 验收用例回归；必要时改用 `r_cons_push/pop` |
| 长选项预扫描破坏原参数 | r2 原有 CLI 异常 | 预扫描只识别白名单参数，遇未知参数立即交还给原解析器 |
| daemon 化后日志/权限问题 | 无法排查 | 提供 `--foreground` 调试模式，日志默认落盘 |
| socket 安全问题 | 同 uid 可注入 | 默认 `0600` 权限；文档说明风险 |

---

## 12. 后续版本规划（v1 之外）

- v1.1：多会话池，每个文件独立 RCore。
- v1.2：工程缓存秒开（`Ps/Po` + meta 归属校验）。
- v1.3：e 配置持久化与回放。
- v2.0：拉起式动态调试。
- v2.1：stdin 注入、报错富化、失败回滚自愈。

以上均来自 r3 经验，但实现方式改为 r2 原生 C 能力。

---

## 13. 参考文档

- `PROJECT.md` — 项目记忆与总体方向。
- `docs/agent-daemon-design.md` — 架构设计草案。
- `docs/r3-legacy-summary.md` — r3 经验总结。
- `legacy/r3/r3` — 旧 r3 实现（仅参考）。
- `legacy/r3/tests/acceptance.sh` — 旧验收测试（可借鉴）。
