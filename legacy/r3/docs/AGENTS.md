# r3 — 给 AI agent 用的 radare2 常驻外包装

r3 是一个"传声筒 + 常驻 daemon"：daemon 抱着 radare2（r2）进程不撒手，分析状态
和工程缓存跨 bash 调用存活。你每次调用 `r3` 只是一个短命客户端，把命令发给 daemon，
拿回结果——不再需要每次 `r2 -q -c ...` 从零分析。v1.2 起 daemon 是**文件级会话池**：
每个目标文件一个独立 r2 会话，配置与分析状态各自常驻、互不干扰。
当前实现版本 v2.1.0（`r3 help` / `r3 status` 显示）。

## 快速上手

```bash
r3 open /bin/ls          # 先打开文件（自动 aaa 分析并落盘缓存；同文件第二次秒开）
r3 "afl"                 # 函数列表（作用于当前会话）
r3 "pdf @ main"          # 反汇编 main
r3 "izz~password"        # 字符串 + 过滤
r3 sessions              # 列出所有会话
r3 --session /bin/true "afl"   # 在指定会话里执行命令
```

## 命令一览

| 命令 | 作用 |
|---|---|
| `r3 "<任意 r2 命令>"` | 透传给常驻 r2（默认入口，作用于当前会话） |
| `r3 --session <目标> "<命令>"` | 指定会话执行（目标 = 文件路径或已开会话 basename 别名） |
| `r3 --json "<命令>"` | 声明 JSON 输出：保证不截断、原样完整（不校验合法性） |
| `r3 --full "<命令>"` | 输出不截断，看全量（与 `--json` 正交） |
| `r3 open <文件>` | 打开并分析；有缓存秒开（缓存键 = 内容 SHA-256 + realpath 维 + r2 版本）；同文件复用常驻会话 |
| `r3 open <文件> --no-analyze` | 只打开不分析（快速看字符串/节区），不落缓存 |
| `r3 open <文件> --gitignore` | 打开；若缓存落在锚点目录 `.r3cache/` 且锚点目录处于 git 仓库，幂等追加 `.r3cache/` 到**锚点目录** `.gitignore` |
| `r3 open <文件> --debug [--stdin <输入文件>]` | 拉起式动态调试（r2 -d）；目标启动后停在 r2 初始断点；`--stdin` 从文件注入目标 stdin（仅与 `--debug` 组合，拉起时快照）；分析只留会话内存，不写工程缓存 |
| `r3 sessions` | 列出所有会话（sid、文件、已分析、缓存命中）；加 `--json` 结构化 |
| `r3 close [<目标>]` | 关闭当前/指定会话，释放 r2 进程（不删磁盘缓存） |
| `r3 status [--json]` | daemon 存活、当前会话、会话列表、缓存模式/位置/回退原因、缓存占用 |
| `r3 restart` | 杀 daemon → 重启 → 按缓存自动恢复上次打开的文件（沙箱恢复走这里） |
| `r3 kill` | 杀 daemon（下次任何 r3 调用自动再拉起） |
| `r3 cache-clean` | 删除全部工程缓存（含 meta）、econf/ 与 state.json |
| `r3 help` | 用法说明 |

保留字 `open/status/restart/kill/cache-clean/sessions/close/help`，其余一律按 r2 命令
透传（r2 原生开文件是 `o`，与保留字无冲突）。daemon 不需要手动管理：连不上会自动拉起。

## agent 必知的几件事

1. **先 `r3 open <文件>` 再干活**；同文件第二次秒开，大文件（>50MB）自动降级 `aa`。
2. **多会话、配置按文件常驻**：每个文件一个常驻 r2 会话；`e asm.bytes=false` 等配置
   跨切换、close 重开、看门狗自愈、daemon 重启恢复（磁盘缓存模式）。
3. **输出默认截断到 20000 字符**（`R3_MAX_OUT` 可调）：收窄用 r2 的 `~` 过滤，
   或 `r3 --full "<cmd>"`。要完整 JSON 就显式 `r3 --json "<cmd>"`（不校验合法性，
   请自行 `json.loads`）。`izzj~过滤` 是整行全有或全无——正确姿势是 `--json` 全量 + 本地过滤。
4. **不要发交互式命令**（`V`、`Vv`、`Vi`、`ve` 等 visual 模式）——会被拒绝（退出码 2）。
5. **看门狗默认 900 秒**（`R3_CMD_TIMEOUT` 可覆盖）：超时杀该会话 r2、自动重启并按缓存
   恢复现场（含 e 配置重放）。
6. **退出码**：0 成功 / 1 连接或 daemon 故障 / 2 黑名单拒绝 / 3 超时 / 4 截断 /
   5 无当前会话 / 6 会话目标不存在或有歧义。看到 5 先 `r3 open <文件>` 或
   `r3 --session <目标>`；看到 6 用 `r3 sessions` 核对目标；看到 4 用 `--full`
   或收窄过滤。r2 层面的"报错"体现在输出文本里（r2 的习惯）。
7. **版本自检**：`r3 help` 与 `r3 status` 均显示 r3 自身版本；怀疑部署断档时先看
   这两处，再和仓库 `r3` 文件头版本比对。
8. **动态调试（v2.1，拉起式）**：`r3 open <文件> --debug` 用 `r2 -d` 自己 spawn 目标，
   停在 r2 初始断点。断点工作流就是透传 r2 调试命令：`r3 "db main"` →
   `r3 "dc"` → `r3 "drj"` → `r3 "wx 90 @ rsp"`；无断点长跑用
   `R3_CMD_TIMEOUT=30 r3 "dcu <addr>"` 做有界等待。**attach 不可用**：内核 yama
   ptrace_scope=1 会拒绝 attach 非子进程（Operation not permitted），错误文本原样透出。
   **目标程序 stdout/stderr 被 dbg.profile 静音到 /dev/null**：`dc` 后看不到目标
   printf；需要输出让目标自己写文件。**r3 会主动清理 debuggee**：close、命令超时、
   daemon 退出都会 killpg 全组清理（勿假设 r2 会带走 debuggee）。不要自己改
   `e dbg.profile`，否则分帧可能被目标输出污染。debug 会话不落 `Ps`/工程缓存，
   每次新建/切换/自愈都现场 `aaa`，首次较慢属预期。
   **stdin 注入（--stdin）**：`r3 open <文件> --debug --stdin <输入文件>` 把输入
   文件在**拉起时快照式**喂给目标（运行中向文件追加无效）；换输入 = 重新
   `r3 open --debug --stdin 新文件`（会重新拉起目标，进程 PID 会变）。`--stdin`
   只能和 `--debug` 一起用。status/sessions 会显示 `[输入文件: 路径]`。
   **排错看富化报错与待重开标记**：open --debug 失败时先看报错里的
   `r2 stderr 尾行`（真实病因，r2 6.1.9 的 "Cannot open ... for writing" 实际
   常是 execv EACCES）与预检提示；目标无执行权限会直接说 `chmod +x`。模式切换
   失败会回滚为原模式并标 `[启动失败待重开]`；**普通命令会自动重建，无需手动
   处理**，重建成功后标记消失。status/sessions 显示 `[输入文件]`/
   `[启动失败待重开]`。

## 环境噪声

- `landlock-run: partial enforcement (older Landlock ABI)` 是宿主 WSL 沙箱层打到
  **stderr** 的警告，不是 r3 输出；agent 解析管道 stdout 时忽略 stderr 即可。

## 路径规则（v1.3）

- `--session` 与 `open` 的路径样目标（绝对路径，或含 `/` 的相对路径）按**调用方
  cwd** 展开为绝对 realpath 后发送；纯裸名（不含 `/`）才作为 basename 别名。
- 绝对路径精确未命中直接报"会话不存在"，**不回退 basename**；裸名歧义报错列候选。
- 旧客户端若直接发送含 `/` 的相对路径会被 daemon 安全拒绝，请改用绝对路径。

## 缓存与文件（三句话版）

- 缓存位置看 `r3 status`（含 r3/r2 版本与 `cache.path`/`mode`/`fallback_reason`）；
  `r3 restart` 沿用旧缓存目录时，`fallback_reason` 会标注“restart 沿用上次生效缓存目录”，
  不会再误标成显式 `R3_CACHE_DIR`。清理用 `r3 cache-clean`。
- `R3_NO_CACHE=1` 强制纯内存模式：不落盘、open 每次真实分析、econf 与 restart 恢复
  等磁盘语义自然失效。
- 沙箱下若缓存落在文件目录 `.r3cache/`，会话恢复走 `r3 restart`（restart 会把旧缓存
  目录传给新 daemon）；`r3 kill` 后再普通调用找不回该锚点。

## 附录：缓存与文件细节

- **回退链四档**：`R3_CACHE_DIR` → `$XDG_CACHE_HOME/r3`（未设置则 `~/.cache/r3`）→
  首次 open 文件目录下的 `.r3cache/`（锚定首次 open，切换文件不换锚）→ 纯内存兜底。
- **写探针**：每级 `makedirs` + `mkstemp`/`unlink` 实写探测，已存在但只读的目录也会被跳过。
- **工程缓存**：`<生效缓存目录>/projects/<key>` + `<key>.d` 目录 + `<key>.meta.json`；
  key = SHA-256(文件内容) + SHA-256(realpath)[:12] + r2 版本；meta 记录 key/sha256/
  path/version/analysis，命中需同时通过内容与 path 归属校验。同内容不同路径副本**不共享
  缓存**（各用各的 key）。
- **econf**：`<生效缓存目录>/econf/<sid>.json` 按文件保存 agent 设过的 `e 名=值`
  配置，r2 每次新建/复活后重放；close 不删，cache-clean 连带清理。
- **state/daemon.log**：`<生效缓存目录>/state.json`（最近打开记录）、
  `<生效缓存目录>/daemon.log`（daemon 与 r2 stderr 日志）。
- `.r3cache/` 若落在 git 仓库内请加入 `.gitignore`，或直接
  `r3 open <文件> --gitignore` 自动追加。**追加落点是缓存锚点目录**（首次 open
  文件的目录，也就是 `.r3cache/` 的父目录），不是本次打开文件所在目录。

## 已知风险

- **socket 无鉴权（低危，暂不修）**：socket 路径可预测；0700 权限挡跨用户，但同 uid
  进程可注入 r2 命令。缓解：`R3_SOCK_PATH` 指向用户专属目录。
- `--session` 的 basename 别名在重名冲突时会报错并列出候选，改用精确路径即可。
- 纯内存模式固有边界：econf 不落盘（close/daemon 重启即失）、restart 无锚点可传。
- **调试边界（v2.1）**：只做拉起式；attach 受 yama 限制、ESIL/远程/内核调试均不在范围。
  目标自行 setsid/daemonize 改进程组时 killpg 可能漏杀；沙箱 landlock 环境会继承给
  debuggee，可能影响目标行为。`--stdin` 是拉起时快照（运行中追加无效）；自愈/boot
  重建时输入文件已被删会预检失败并标待重开，重新 open 指定新输入文件即恢复。
