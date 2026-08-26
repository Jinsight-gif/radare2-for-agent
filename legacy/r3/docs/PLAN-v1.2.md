# r3 v1.2 开发方案 —— 多会话与机器可读（goal 模式）

> 本文是 v1.2 的定稿开发规格，在 v1.1（`PLAN-v1.1.md`）之上增量修订。
> v1.1 决策（#9–#14）与 v1 决策（#1–#8）继续有效，本文只追加、修订。
> 实现 agent 按本文档直接实现，无需再做架构决策。
> 配套：`DESIGN.md`、`PLAN.md`（v1）、`PLAN-v1.1.md`（v1.1）。

---

## 0. Goal 模式执行须知

**目标**：交付 r3 v1.2，解决评测缺陷 ①（单会话单文件切换摩擦）、②（机器可读性不足）、
③（JSON 判定启发式不可靠）、⑤（截断退出码恒 0、故障报错过粗）。缺陷 ④（socket 安全）
本次不修（决策 #20）。完成定义 = `bash tests/acceptance.sh`（仓库根、WSL bash）退出码 0。

**执行环境**（同 v1.1 §0）：WSL 原生文件系统；r2 6.1.9 `/usr/local/bin/r2`；Python 3.12.3；
`r3` 部署 `~/.local/bin/r3`。

**规则**：
1. 本文档是唯一需求来源，自足。
2. §2 决策表是硬约束，不得重设计、不得扩范围。
3. 事实类出入以实测为准并写进代码注释；架构级分歧停下问用户。
4. 范围护栏：只用 Python 3 标准库；不 fork/不修改 r2；不做 TCP；不做动态调试。
5. §3 现状/根因是实测结论，直接采信，不重探；矛盾时以实测为准并更新注释。

---

## 1. 背景：v1.1 评测缺陷清单

| # | 缺陷 | 定性 | 处理 |
|---|---|---|---|
| ① | 单会话单文件：daemon 只抱一个 r2、只开一个文件；切文件重置 `e` 配置；交叉对照只能排队切或手工 `R3_SOCK_PATH`/`R3_CACHE_DIR` 多实例；CLI 无会话选择器 | 易用性/上限 | 修（#15–#17） |
| ② | 机器可读性不足：status/help 无 `--json`；agent 靠正则抠缓存位置/回退原因；截断横幅/超时提示都是自然语言无结构化字段 | 易用性 | 修（#18） |
| ③ | JSON 判定启发式：只看 `{`/`[` 开头，`izzj~password` 过滤后变文本误走截断；无 `--json` 强制开关兜底 | 正确性隐患 | 修（#19） |
| ④ | socket 安全：`/tmp/r3.sock` 可预测；0700 挡跨用户、同 uid 可注入 r2 命令；无 SO_PEERCRED/auth token。低危 | 安全（低危） | 不修（#20） |
| ⑤ | 小瑕疵：截断时退出码仍 0（忽略 banner 会误当完整）；daemon 故障靠 socket 超时兜底、报错偏粗 | 健壮性 | 修（#21、#22） |

---

## 2. 决策表（硬约束）

| # | 决策 |
|---|---|
| 15 | **多会话 = 文件级会话池**。daemon 从「单一 r2+单一文件」升级为「会话表：每个目标文件一个 r2 会话，各自保留 `e` 配置与分析状态」。无会话参数时行为与 v1.1 一致。 |
| 16 | **CLI 加 `--session <目标>`**：指定本次命令作用的会话；未指定作用于当前会话。daemon 复用协议预留的 `sid` 字段作会话主键。 |
| 17 | **会话按 `realpath` 自动汇聚**：同一文件永远映射同一 sid。切文件不再杀进程丢配置，而是切到该文件自己的常驻会话（开着复用、没开新建）。 |
| 18 | **机器可读 = 结构化元信息，命令输出本体原样透传**。`status` 加 `--json`；CLI 透传加全局 `--json`；所有元事件（截断/超时/错误/恢复）附带结构化字段。不包信封、不改写输出。 |
| 19 | **废除「输出以 `{`/`[` 开头即 JSON」启发式，改显式 `--json`**。`--json` 承诺「不截断 + 原样完整」，不校验合法性（agent 自查 `json.loads`）。不加 `--json` 一律按文本截断。 |
| 20 | **socket 安全本次不修**。接受低危暴露；文档标注已知风险（§7）。 |
| 21 | **截断给退出码 4**：0 成功 / 1 连接故障 / 2 黑名单拒绝 / 3 超时 / 4 截断。 |
| 22 | **细化 daemon 故障报错**：区分「连不上/拒连/超时」三类，带结构化错误字段；退出码统一 1。 |

---

## 3. 现状与根因（实测结论，直接采信）

### 3.1 单会话现状

- `Daemon` 持有单一状态：`self.r2`（一个实例）、`self.cur_file`、`self.analyzed`、
  `self.cache_hit`、`self.recent`。
- 切文件代价来自 v1.1 决策 #9：`open_file` 中 `self.cur_file != path` 即 `reset_r2()`
  （杀 r2 → `start_r2(restore=False)`），换文件必然丢 `e` 配置。
- 协议 `sid` 字段（v1 预留）未使用：CLI 硬编码 `"sid":"default"`，`dispatch` 不读 `sid`。

### 3.2 机器可读现状

- `Daemon.status()`（L730–788）返回多行文本，人肉排版「缓存模式/缓存位置/回退原因」，
  agent 只能正则抠。
- `truncate()`（L1015–1019）、`_resp_r2_dead` 超时提示、错误提示均为自然语言。
- `status`/`help` 均无 `--json`；`help` 仅打印 `USAGE`。

### 3.3 JSON 判定现状

- 豁免逻辑在 CLI 透传分支 L1124–1127：
  `if resp.get("ok") and not full and not out.lstrip().startswith(("{", "[")): out = truncate(...)`。
- 缺陷：`izzj~password`（`~` 过滤后为文本）误走截断；以 `{`/`[` 开头的文本输出被误判为 JSON 永不截断。
  判断依据是「输出长相」而非「agent 意图」。

### 3.4 小瑕疵现状

- 截断后退出码：透传分支 `return resp.get("code", 0)`（L1129），daemon 成功返回 0，截断不改退出码。
- daemon 故障：CLI 四处 catch `OSError` 统一打印「无法连接/拉起 daemon」return 1。
  `talk()` 内 `FileNotFoundError`/`ConnectionRefusedError`/`TimeoutError` 均被一锅端。

### 3.5 会话主键设计依据

- sid = `sha256(realpath(文件))` 前 16 位十六进制（或等价稳定短 id）。不用路径原样（含 `/`/空格/
  中文污染日志/协议），不用打开顺序。
- 「当前会话」= daemon 记录 `self.active_sid`；最近一次 `open` 或带 `--session` 的调用更新它；
  未带 `--session` 的调用作用于 `active_sid`。
- 兼容：不传 `--session`/`sid` 落回 `active_sid`，单文件时行为与 v1.1 完全一致。

---

## 4. 设计

### 4.1 多会话（决策 #15–#17）

**数据模型**：

```
self.sessions: dict[sid, Session]
self.active_sid: str | None
```

新增 `Session` 类，持有原散在 daemon 的单文件状态：r2 进程句柄、`cur_file`、`analyzed`、
`cache_hit`、`bigfile_downgraded`、`recent`。（`e` 配置随 r2 进程自然存活，不单独存。）

**open 流程**：

```
open_file(path, ...):
  sid = session_id(path)          # 稳定 hash(realpath)
  if sid not in self.sessions:
      新建 Session；跑 v1.1 既有「open→分析→缓存/meta」完整流程（逻辑不变，作用对象改为 Session）
  else:
      复用 Session（不杀、不重开 → e 配置保留）
  self.active_sid = sid
  输出会话建立/切换提示
```

**语义变化**：v1.1「换文件 = 杀进程 = 配置重置」约束解除。同一文件会话一旦建立，切走再切回，
其 `e` 配置与分析状态均保留。仅全新文件才从零分析。

**协议层**：
- CLI 请求 `sid` 改为「显式传入，不传则 daemon 落回 `active_sid`」。
- `dispatch(req)`：`sid = req.get("sid") or self.active_sid`；`pass`/`open`/`status`/
  `cache_clean` 按 sid 定位会话（`cache_clean` 仍清全局磁盘缓存，与会话无关）。
- 新增 action `list`：返回所有会话（sid、文件、analyzed、cache_hit）；新增 action `close`：
  释放指定会话的 r2 进程（不删磁盘缓存）。

**资源控制**：daemon 仍单线程串行处理。会话数上限 `MAX_SESSIONS=16`，超限先关最久未用的非活跃
会话（LRU）。

### 4.2 机器可读（决策 #18）

输出本体原样透传；结构化的是元信息（`resp` 增补字段）。

**status --json**：`Daemon.status(structured=False)`，structured 时返回 JSON：
```json
{
  "ok": true, "code": 0,
  "daemon": {"pid": 123, "uptime_s": 41.2, "r2_version": "6.1.9"},
  "active_session": "9f3c2a1b...",
  "sessions": [
    {"sid": "9f3c2a1b...", "file": "/bin/ls", "analyzed": true,
     "cache_hit": true, "bigfile_downgraded": false}
  ],
  "cache": {"mode": "disk", "path": "/home/u/.cache/r3",
            "fallback_reason": null, "projects": 3, "bytes": 123456}
}
```
`r3 status --json` 输出此 JSON；无 `--json` 保持原文本。

**元事件结构化**：CLI 透传时，`resp` 带 `truncated`/`timed_out`/`rejected`/`error` 字段，
`--json` 时一并机器可读；无 `--json` 打印自然语言横幅，向后兼容。

### 4.3 显式 --json（决策 #19）

**CLI 透传分支改写**（替换 L1124–1127）：

`--full` 与 `--json` 为正交开关：
- `--full`：要全量（不截断），与文本/JSON 无关。
- `--json`：声明「JSON 输出」，等价「不截断」+ 回执机器可读；不校验合法性。

```
if resp["ok"]:
    if --json:              truncated = False
    elif not --full and len(out) > R3_MAX_OUT:
        out = truncate(...); truncated = True
    else:                   truncated = False
退出码按 §4.5（truncated 时 4）
```

- 删除 `startswith(("{", "["))` 豁免判断。
- `--json` 与 `--full` 可同用（`--json` 隐含不截断，`--full` 冗余无害）。
- AGENTS.md 同步：JSON 完整性从「被动豁免」改为「主动声明」；明确 `--json` 是「保证不截断」
  而非「保证合法 JSON」，agent 仍需 `json.loads`。

### 4.4 CLI 表面

| 命令/参数 | 作用 |
|---|---|
| `r3 --session <路径或别名>` | 选择本次命令作用的会话 |
| `r3 sessions` | 列出所有会话（action `list`）；支持 `--json` |
| `r3 close [<目标>]` | 关当前/指定会话，释放 r2（不删缓存） |
| `r3 status --json` | 结构化 status |
| `r3 --json "<命令>"` | 显式 JSON 声明（不截断） |
| `r3 --full "<命令>"` | 全量（既有） |

新增保留字 `sessions`/`close`（r2 无同名，无冲突）。`--session` 接受文件路径或已开会话的
basename 别名：先精确路径/realpath 匹配，再 basename 模糊匹配（冲突时报错列出候选）。basename
层为可选便利；精确路径匹配是硬要求。

### 4.5 截断退出码（决策 #21）

截断发生时透传分支 `return 4`（覆盖 daemon 的 0）。其余：0 成功 / 1 连接或 daemon 故障 /
2 黑名单拒绝 / 3 超时。`--json` 下不截断，不触发 4。

### 4.6 故障报错细化（决策 #22）

`talk()`/CLI catch 按底层异常分类：

| 异常 | 结构化 code | 消息要点 |
|---|---|---|
| `FileNotFoundError`（socket 无） | `daemon_not_running` | daemon 未运行，尝试拉起 |
| `ConnectionRefusedError` | `daemon_refused` | daemon 存在但拒连（可能启动中），建议 `r3 restart` |
| `TimeoutError` / 读超时 | `daemon_timeout` | daemon 无响应，建议 `r3 kill` 后重试 |

`--json` 时输出 `{"ok":false, "error":"<code>", "message":...}`；无 `--json` 打印带分类词的自然语言。
退出码统一 1。

---

## 5. 代码改动点清单（r3 单文件，~1133 行）

| 位置 | 改动 |
|---|---|
| 头部常量 | 新增 `MAX_SESSIONS=16` 等；`hashlib` 已 import |
| 新增 `Session` 类 | 抽出单文件状态（r2、cur_file、analyzed、cache_hit、bigfile_downgraded、recent） |
| `Daemon.__init__` | `self.sessions={}`、`self.active_sid=None`；回退链逻辑不动 |
| `start_r2`/`reset_r2`/`_restore_state` | 作用对象改为某 `Session`；`reset_r2` 改为关指定会话 |
| `Daemon.open_file` | 按 §4.1：`session_id` 定位 → 有无分支 → 设 active_sid → 切换提示 |
| 新增 `session_id(path)` | realpath 后稳定 hash |
| 新增 `list_sessions`/`close_session` | 供 `sessions`/`close`；LRU 上限 |
| `Daemon.status(structured=False)` | 加 `--json` 输出；文本版兼容 |
| `Daemon.dispatch` | 读 `sid`（落 active_sid）；加 `list`/`close` action |
| `talk()`/CLI catch | §4.6 三类错误区分 |
| `cli_main` | `--session`/`--json` 解析、`sessions`/`close` 保留字、透传截断与退出码 |
| `truncate()` | 返回是否真截断信号，供退出码 4 判定 |
| 文件头注释 | 追加 v1.2 结论存档 |

---

## 6. 验收标准

沿用 v1.1 脚本隔离要求（顶部 export `R3_CACHE_DIR`/`R3_SOCK_PATH` 到 `mktemp -d` 临时目录，
所有调用走这两个变量；先 `r3 kill` 再清缓存）。A–E（v1）、F–J（v1.1）既有语义保持，
但 **[旧验收修订]**：§4.1 解除「换文件必丢配置」，故 v1.1 的 G4「切文件提示配置已重置」断言删除，
D3 保留（同会话内 `e` 驻留）。新增 K–O 组：

**K 多会话（核心）**
- K1 交叉会话不混：`open /bin/ls` → `open /bin/true` → `--session /bin/ls "pdf @ main"`
  含 `LS_COLORS`，`--session /bin/true "pdf @ main"` 不含。
- K2 配置按会话留存：`--session /bin/ls "e asm.bytes=false"` → 切走切回 `--session /bin/ls
  "e asm.bytes"` 仍含 `false`。
- K3 `sessions` 列出两会话及路径；`status --json` 的 `sessions` 长度 ≥2。
- K4 `close /bin/true` 后 `sessions` 不含 true；`open /bin/true` 再秒开（缓存命中）。

**L 机器可读**
- L1 `status --json` 合法 JSON，含 `cache.mode`/`cache.path`/`cache.fallback_reason`。
- L2 `R3_MAX_OUT=100 r3 --json "izz"` 长度 > 100，无截断横幅。

**M 显式 --json**
- M1 `R3_MAX_OUT=100 r3 "izzj~password"` 被截断（有横幅）；不加 `--json` 不再因首字符豁免。
- M2 `R3_MAX_OUT=100 r3 --json "aflj"` 合法 JSON 且长度 > 100；对照同上限不加 `--json` 的
  `aflj` 被截断。

**N 截断退出码**
- N1 `R3_MAX_OUT=100 r3 "afl"` 退出码 4；`r3 "afl~main"` 退出码 0。
- N2 `R3_MAX_OUT=100 r3 --json "aflj"` 退出码 0。

**O 故障报错细化**
- O1 无 daemon 时 `--json` status 错误含 `daemon_not_running` 类，退出码 1。
- O2（可选，可 SKIP）制造超时，`--json` 报错含 `daemon_timeout`。

---

## 7. 已知风险（本次不修）

- **④ socket 安全（#20）**：`/tmp/r3.sock` 可预测；0700 挡跨用户，同 uid 可注入 r2 命令。
  低危，本地单用户可接受。缓解：`R3_SOCK_PATH` 指向用户专属目录。何时修：上 TCP 或多用户共享
  daemon 时引入 auth token + SO_PEERCRED。
- `--session` basename 模糊匹配在冲突时需 agent 改判精确路径，不影响正确性。

---

## 8. 实现顺序建议

先搭 `tests/acceptance.sh` v1.2 骨架（全红），随实现逐项变绿：

1. `Session` 抽取 + `session_id` + `sid` 落 `active_sid` → 回归 A–J 仍绿，K 组骨架。
2. `--session` + `sessions`/`close` → K 组绿。
3. 显式 `--json` + 废首字符 → M 组绿。
4. `status --json` → L 组绿。
5. 截断退出码 4 + 故障报错细化 → N、O 组绿。
6. 旧验收修订（G4 删除）→ 全量回归。
7. 文档配套：更新 AGENTS.md（`--session`/`--json`/新退出码/新保留字/socket 风险标注）、
   文件头注释存档 v1.2 结论。

（全文完）
