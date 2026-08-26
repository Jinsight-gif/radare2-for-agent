# r3 开发方案 —— 给 AI agent 用的 radare2 外包装

> 本文是最终定稿的开发方案，由需求访谈敲定。任何 agent 按此文档实现即可，无需再做架构决策。
>
> **环境修订（随 PLAN-v1.1.md 生效）**：开发与执行环境现为 WSL 内的 bash（仓库位于 WSL 原生文件系统），不再从 Windows 侧 `wsl -e bash /mnt/d/...` 发起；本文 §1 的路径描述与 §8 的开发流程中"Windows 侧"表述已过时，执行细节以 PLAN-v1.1.md 为准。

## 0. Goal 模式执行须知（执行 agent 先读这节）

**目标（一句话）**：交付 r3 v1，使 `bash tests/acceptance.sh`（在仓库根目录、WSL 的 bash 内直接执行）退出码为 0（验收标准见第 10 节，逐条 PASS）。

规则：
1. 本文档是唯一需求来源，自足，不需要任何对话上下文。
2. 第 2 节决策表是**硬约束**，不得重新设计、不得扩大范围。
3. 与文档冲突时的处理：**事实类**出入（r2 某命令的实际行为、路径差异、协议细节）以实测为准，并把结论写进代码注释；**架构级**分歧（想改架构、想加功能、想做 v2）必须停下来问用户，不得自行决定。
4. 范围护栏：不装任何第三方依赖（只用 Python 3 标准库）、不 fork/不修改 r2 安装（`r2 -v` 必须保持 6.1.9）、不做 v2 功能（调试模式、多会话）、不做 TCP。破坏 r2 安装 = 直接失败。
5. 完成定义 = 第 10 节全部 PASS（E2 允许有理由的 SKIP）+ 第 2 节决策表全部未被违反。完成后交付全部文件和验收脚本的完整输出。

## 1. 背景与目标

AI agent（运行在 WSL Ubuntu-24.04 里）每次调用工具都会新开一个 bash 进程，进程一退状态就没了。而 radare2（r2）的逆向分析是"重状态"的：打开文件要分析（`aaa`，大文件几分钟）、看了函数列表才好查函数。所以 agent 用裸 r2 只能每次 `r2 -q -c "..."`，每一步都从零开始，完全不可用。

**r3 的定义：一个 CLI 工具 + 一个后台常驻的 daemon。daemon 抱着一个 r2 进程不撒手（状态不丢），CLI 每次调用把 r2 命令发给 daemon，拿回结果。agent 只跟 CLI 打交道。**

环境事实（已验证）：
- WSL：Ubuntu-24.04（WSL2），radare2 6.1.9 装在 `/usr/local/bin/r2`，Python 3.12.3。
- 命名 `r3`：WSL 与 Windows 两侧均无命令冲突，已验证。
- 本仓库位于 WSL 原生文件系统（`/home/jin/Project/radare2-for-agent`），开发与执行都在 WSL 的 bash 内；`bash install.sh` 部署到 `~/.local/bin/r3`。（v1.1 修订）

## 2. 已敲定的决策（访谈结论，不可推翻）

| # | 决策 |
|---|---|
| 1 | 不 fork、不改 r2 源码，纯外包装。以后撞墙再说小补丁（优先插件形式） |
| 2 | agent 与 r3 全部在 WSL 内运行；开发在 Windows 侧本仓库进行 |
| 3 | v1 单会话（daemon 只抱一个 r2、开一个文件）；代码留多会话口子 |
| 4 | CLI 是"传声筒 + 少量管理命令"，不做命令翻译层（agent 本来就会 r2 方言） |
| 5 | `r3 open` 自动：查缓存→命中秒开；未命中则分析并落盘缓存；`--no-analyze` 逃生；文件 >50MB 自动降级为轻量分析 `aa` |
| 6 | v1 只做静态分析；动态调试放 v2，open 命令做成模式化设计 |
| 7 | 输出默认 20KB 截断 + 截断提示（教 agent 自救）；`--full` 看全量；daemon 启动即关颜色/关分页器；不强制 JSON |
| 8 | 工具名 `r3`；用 Python 3 标准库实现，零第三方依赖 |

## 3. 总体架构

```
WSL 内部
┌──────────────────────────────────────────────┐
│  agent 的每次 bash 调用（短命进程）              │
│      │                                        │
│      │ r3 "<r2命令>"           r3 open <文件>  │
│      ▼                                        │
│  ┌─────────┐   Unix socket    ┌─────────────┐ │
│  │ r3 CLI  │ ───────────────► │ r3 daemon   │ │
│  │ (薄客户端)│   /tmp/r3.sock  │ (常驻后台)   │ │
│  └─────────┘                  │  ┌────────┐ │ │
│                               │  │ r2 -q0 │ │ │  ← r2 管道模式，
│                               │  └────────┘ │ │    分析状态常驻内存
│                               └──────┬──────┘ │
│                                      │        │
│                               ~/.cache/r3/    │
│                               ├─ projects/    │ ← 分析结果缓存
│                               ├─ state.json   │ ← 最近打开的文件
│                               └─ daemon.log   │
└──────────────────────────────────────────────┘
```

要点：
- **r2 以管道模式运行**：daemon 用 `r2 -q0 -e scr.color=0 -e scr.interactive=0` 启动（不预先打开文件）。协议：向 r2 的 stdin 写命令 + `\n`，从 stdout 读到 NUL（`\x00`）分隔符即为该命令输出结束。r2 启动后会先发一个空 NUL 表示就绪。（实现前用 `r2pipe` 项目的做法对照验证一遍协议细节。）
- **daemon 懒启动**：CLI 连不上 socket 时自动拉起 daemon（`start_new_session=True` 脱离终端，日志重定向到 `~/.cache/r3/daemon.log`），然后轮询连接（上限约 5 秒）。用户/agent 完全不需要手动管理 daemon。daemon 继承拉起它的那次 CLI 的环境变量（`R3_BIGFILE_LIMIT`、`R3_CMD_TIMEOUT` 靠此在 daemon 侧生效）；`R3_MAX_OUT` 建议在 CLI 侧读取，使每次调用可独立覆盖。
- **并发安全**：daemon 串行处理命令（单线程 accept 循环即可）。两个 agent 同时敲 r3 只是排队，不会打架；每条命令对 r2 是原子的。
- **看门狗**：单条命令默认 900 秒超时（大文件 `aaa` 很慢，不能设短），环境变量 `R3_CMD_TIMEOUT`（秒）可覆盖。超时则杀掉 r2、重新拉起、按 state.json 自动重载缓存会话，并向客户端明确报告"命令超时，r2 已重启并恢复现场"。另维护一个已知交互式命令黑名单（`V`、`Vv`、`Vi`、`ve` 等会霸占终端的），命中直接拒绝并输出提示（CLI 退出码 2），防止把管道挂死。

## 4. CLI 规格定稿

```
r3 "<任意 r2 命令>"          # 传声筒（默认入口）。例：r3 "pdf @ main"
r3 --full "<命令>"           # 不做 20KB 截断
r3 open <文件路径>           # 打开文件（详见第 5 节缓存逻辑）
r3 open <文件> --no-analyze  # 只打开不分析（快速看字符串/节区）
r3 status                    # daemon 存活、当前文件、是否已分析、缓存命中情况、r2 版本、最近命令
r3 restart                   # 杀 daemon → 重启 → 按缓存自动恢复上次打开的文件
r3 kill                      # 杀 daemon（不再自动重启，直到下次任何 r3 调用懒启动）
r3 help                      # 打印用法（就是本节内容的精简版）
```

约定：
- 子命令名 `open/status/restart/kill/help` 为保留字，其余一律按 r2 命令透传。r2 原生命令没有与保留字同名冲突（r2 开文件是 `o` 不是 `open`），已核对。
- 透传命令的"报错"体现在输出文本里（r2 的习惯），CLI 退出码非 0 表示 daemon/连接层面故障，或命令被黑名单拒绝（退出码 2）。
- agent 通过透传设置的 r2 配置（如 `e asm.bytes=false`）会一直生效（daemon 有状态）——这是特性，写进用户文档。

## 5. open 的缓存与分析逻辑

`r3 open /path/to/binary` 执行流程：

1. 解析为绝对路径，计算文件内容 SHA-256。
2. **缓存键 = SHA-256(文件内容) + r2 版本号**。r2 升级后旧工程文件可能不兼容，版本号入键自动作废。
3. 查 `~/.cache/r3/projects/<键>/` 下有无已存工程：
   - **命中** → 发 `Po <工程路径>`，秒开，status 里标注"cache hit"。
   - **未命中** → 发 `o <文件路径>` 打开，然后：
     - 文件 ≤ 50MB：跑 `aaa`（全量分析）；
     - 文件 > 50MB：跑 `aa`（轻量分析），并在输出里明确告知："大文件已用轻量分析，如需全量请手动 r3 \"aaa\""；
     - 分析完 `Ps <工程路径>` 落盘。
   - `--no-analyze` 则跳过分析也不落盘。
4. 输出打开耗时（让 agent 对"要不要等"有预期），并把本次 open 的参数记入 `state.json`（供 restart 恢复用）。
5. 大小阈值由环境变量 `R3_BIGFILE_LIMIT`（字节）控制，默认 52428800（50MB）；验收测试用它造小阈值来触发降级分支。

已知坑（实现时注意）：
- r2 工程文件内部记录的是二进制的绝对路径。同一内容、不同路径打开时缓存仍按内容命中，`Po` 后 r2 指向的路径可能是旧的——影响很小，接受即可，但要在实现时实测确认无副作用。
- `Ps`/`Po` 对文件名是否自动加 `.r2` 后缀、报 warning 的行为，实现时实测后固定写法。
- 缓存目录提供 `r3 status` 里的统计（多少个工程、占多大空间）；清理缓存 v1 手动删目录即可，不做命令。

## 6. 输出处理

- daemon 启动参数固定带 `-e scr.color=0 -e scr.interactive=0 -e scr.pager=`（无色、无交互、无分页器）。
- 截断：默认 20000 字符（按解码后字符数计，UTF-8 errors=replace）。截断时在结尾追加一行：
  `⚠️ Output truncated at 20000 chars. Narrow it down with r2 ~filter (e.g. izz~password), or use: r3 --full "<cmd>"`
- 环境变量 `R3_MAX_OUT` 可覆盖默认值（也用于测试）。
- 不改写、不解析 agent 发来的 r2 命令的输出内容——传声筒保持透明。

## 7. v1 范围与非目标

**做**：上述全部（透传、open+缓存、status、restart、kill、截断、懒启动、看门狗、install.sh、文档）。

**不做（但留口子）**：
- **多会话**：客户端-daemon 的通信协议（单行 JSON：`{"sid": "default", "cmd": "...", "full": false}`）中已含会话字段 `sid`，v1 恒为 `"default"`、daemon 单 r2 实例；将来多会话只动 daemon，CLI 参数加 `--session` 即可，协议不变。
- **动态调试（v2）**：`open` 内部实现为 `open_file(path, mode)`，mode 枚举 `static|debug`，v1 只有 static。v2 加 `r3 open --debug ./crackme`（daemon 以 `-d` 模式重启 r2，注意被调试目标的输入输出转发与进程死亡后的状态清理；Ubuntu 的 yama ptrace_scope=1 允许 r2 调试自己 spawn 的子进程，无需改内核参数）。
- **改 r2 源码 / fork**：明确不做。
- TCP/远程访问：不做，Unix socket 限本机。

## 8. 代码结构与开发工作流

```
radare2-for-agent/
├── PLAN.md          # 本文档
├── r3               # 唯一的程序文件（Python 3，标准库，无依赖）
│                    #   CLI 入口 + 内部子命令 __daemon（daemon 就是它自己后台再跑一次）
├── install.sh       # cp r3 → WSL ~/.local/bin/r3 && chmod +x；校验 PATH 生效
├── AGENTS.md        # 给 agent 看的使用说明（见第 9 节）
└── tests/
    └── acceptance.sh # 第 10 节的验收脚本
```

- 开发：在 WSL 的 bash 内直接改本仓库；`bash install.sh` 一键部署到 `~/.local/bin/r3`。（v1.1 修订）
- 所有实测命令直接在 WSL 的 bash 内执行。（v1.1 修订）
- socket 权限 600，daemon.log 记录启动/命令/异常，供排查。

## 9. AGENTS.md（给使用方 agent 的说明，随工具交付）

内容要点（中文写，agent 直接读）：
- r3 是什么：常驻 r2 的传声筒，分析状态和缓存跨 bash 调用存活。
- 先 `r3 open <file>` 再干活；同文件第二次打开走缓存秒开。
- 直接 `r3 "<r2 命令>"`；配置命令（`e ...`）也会常驻生效。
- 输出被截断时按提示收窄（`~` 过滤器）或 `--full`。
- 不要发交互式命令（`V` 系列等）。
- `r3 status` 查看现场；`r3 restart` 恢复上次现场。

## 10. 验收标准（Definition of Done）

由 `tests/acceptance.sh` 逐条实现：每项打印 `PASS` / `FAIL` / `SKIP(原因)`，末尾汇总；任一 FAIL 退出码 1，全部通过（含允许的 SKIP）退出码 0。脚本从干净状态起跑：先 `r3 kill`（若在跑）再清空 `~/.cache/r3/`，并按 A→F 顺序执行（C 组内部有时序依赖，见各条说明）。假定 `r3` 已在 PATH。

**A 部署**
- A1：在仓库根目录 `bash install.sh` 退出码 0；随后 `bash -lc 'which r3'` 返回 `~/.local/bin/r3`（或 `/usr/local/bin/r3`）。
- A2：`r3 help` 退出码 0，输出含全部保留子命令名（open / status / restart / kill）。

**B daemon 生命周期**
- B1 冷启动：`r3 status` 自动拉起 daemon，退出码 0，输出含 r2 版本号和"当前无文件"含义的信息。
- B2：`r3 kill` 后 socket 文件（`/tmp/r3.sock`）消失；随后 `r3 "?t"` 自动重启 daemon 并正常返回非空输出。

**C 打开与分析缓存**（本组开始前确保缓存目录已清空）
- C1：`r3 open /bin/ls` 输出含耗时信息；`~/.cache/r3/projects/` 出现新工程目录；随后 `r3 status` 显示当前文件为 /bin/ls 且已分析。
- C2：`r3 kill` 后再 `r3 open /bin/ls`，real 耗时 < 3 秒，且输出或 status 标注缓存命中。
- C3：`r3 kill` + 清空缓存目录后，`r3 open /bin/ls --no-analyze` 耗时 < 2 秒、未产生工程文件、随后 `r3 "aflj"` 无函数条目（证明确实没分析）。
- C4 降级（紧接 C3，缓存仍为空）：取 `SZ=$(stat -c %s /bin/ls)`，以 `R3_BIGFILE_LIMIT=$((SZ/2)) r3 open /bin/ls` 打开，输出含"轻量分析"提示字样。

**D 传声筒与输出处理**
- D1：`r3 "afl"` 输出非空且不含 ANSI 转义（输出中 grep 不到 `\x1b`）。
- D2：`r3 "aflj"` 返回合法 JSON；脚本从中取第一个函数名 FN，`r3 "pdf @ FN"` 输出非空。
- D3 状态驻留：文件打开状态下 `r3 "e asm.bytes=false"` 后，`r3 "e asm.bytes"` 输出含 `false`。
- D4 截断：`r3 open <libc> --no-analyze`（libc 路径由脚本从 `/usr/lib/x86_64-linux-gnu/libc.so.6` 或 `/lib/x86_64-linux-gnu/libc.so.6` 解析），`r3 "izz"` 输出含截断横幅关键字且总长不超过 截断上限+横幅+1KB；`r3 --full "izz"` 输出长度大于截断上限。
- D5 并发：两个 `r3 "?t"` 后台同时发起（`&` + `wait`），均退出码 0 且输出非空。

**E 防挂死**
- E1 黑名单：`r3 "V"` 被拒绝——退出码 2、输出含拒绝提示，且随后 `r3 status` 仍正常（daemon 存活）。
- E2 看门狗：`R3_CMD_TIMEOUT=2 r3 "!sleep 5"` 返回超时说明，随后 `r3 status` 正常（daemon 自愈）。若 r2 管道模式不支持 `!sleep`，可换成任一实测耗时 >2 秒的命令；仍不可测则打 `SKIP(原因)`，这是唯一允许 SKIP 的条目。

**F 交付物与约束**（由脚本静态检查或代码审查判定）
- F1：仓库含 `PLAN.md`、`r3`、`install.sh`、`AGENTS.md`、`tests/acceptance.sh`。
- F2：`r3` 为单文件，`grep -E "^\s*(import|from)\s+\w+" r3` 提到的模块全部属于 Python 3 标准库。
- F3：`r2 -v` 仍为 6.1.9，仓库内无 r2 源码。
- F4：代码含预留口子：协议里有 `sid` 字段、open 实现有 `mode` 参数（static/debug 枚举）。
- F5：acceptance.sh 汇总逻辑正确——全绿时退出码 0，任一 FAIL 时退出码 1。

## 11. 实现顺序建议（给开发 agent，验收驱动）

先搭 `tests/acceptance.sh` 骨架（允许全红），随实现逐项变绿。顺序：

1. 先写一个 20 行的探针脚本，实测 `r2 -q0` 的 NUL 分帧协议（含启动空 NUL、`-e` 参数生效），把结论写进代码注释。
2. daemon 骨架：socket + r2 子进程 + 单线程请求循环 + `__daemon` 内部子命令 + 懒启动。
3. 透传 + 截断 + 保留子命令解析。
4. open/缓存/state.json/restart。
5. 看门狗 + 交互命令黑名单。
6. install.sh + AGENTS.md + acceptance.sh，跑通全部验收项。
