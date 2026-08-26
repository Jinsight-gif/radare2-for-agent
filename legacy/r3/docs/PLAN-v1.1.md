# r3 v1.1 开发方案 —— 修复 v1 的正确性缺陷（goal 模式）

> 本文是 v1.1 的最终定稿开发方案，由需求访谈 + 实测敲定，是 `PLAN.md`（v1）的增量修订。
> v1 的决策表（PLAN §2 的 #1–#8）仍然有效，本文档只在其上追加、修订。任何 agent 按本文档实现即可，无需再做架构决策。

## 0. Goal 模式执行须知（执行 agent 先读这节）

**目标（一句话）**：交付 r3 v1.1，使 `bash tests/acceptance.sh`（在仓库根目录、WSL 的 bash 内直接执行）退出码为 0（验收标准见第 6 节，A–J 组逐条 PASS，J 组允许有理由的 SKIP）。

**执行环境（v1.1 修订，重要）**：开发、实测、验收**全程在 WSL 的 bash 内直接进行**——本仓库位于 WSL 原生文件系统，**不需要**从 Windows 侧用 `wsl -e bash /mnt/d/...` 发起，所有命令与路径一律用原生形式。r2 6.1.9 在 `/usr/local/bin/r2`，Python 3.12.3，`r3` 部署到 `~/.local/bin/r3`。PLAN.md（v1）中"Windows 侧开发"的表述已过时，以本文档为准。

规则（沿用 PLAN.md §0，增补）：
1. 本文档是 v1.1 的唯一需求来源，自足，不需要任何对话上下文。
2. 第 2 节决策表是**硬约束**，不得重新设计、不得扩大范围。
3. 与文档冲突时的处理：**事实类**出入（r2 某命令的实际行为、路径差异、协议细节）以实测为准，并把结论写进代码注释；**架构级**分歧必须停下来问用户。
4. 范围护栏（沿用 v1）：不装任何第三方依赖（只用 Python 3 标准库）、不 fork/不修改 r2 安装、不做 TCP、不做动态调试（v2）。
5. **第 3 节的"根因分析"是实测结论，直接采信，不要重新探针验证**（探针结果已在第 3 节存档）；实现中如遇到与第 3 节矛盾的现象，以实测为准并更新注释。
6. 完成定义 = 第 6 节全部 PASS（J 允许 SKIP）+ 第 2 节决策表全部未被违反。完成后交付全部文件和验收脚本的完整输出。

## 1. 背景：v1 使用评测与四个缺陷

v1 交付后由使用方 agent 实测评测。好的方面：状态跨 bash 存活、缓存秒开（同文件二次 open 0.12s）、传声筒透明干净、退出码语义明确、文档用心。但评测指出四个缺陷，按严重度：

| # | 缺陷 | 后果（评测原文要点） |
|---|---|---|
| ① | **跨文件分析状态污染** | 打开新文件后 `afl`/`pdf` 返回的是上一个文件的函数（`i~file` 却显示新文件，同一时刻两个视角对不上）；污染被 `Ps` 固化进缓存，`r3 restart` 后依然错。对 agent 等于"函数列表/反汇编静默答错文件"。 |
| ② | **沙箱不友好** | daemon 写 `~/.cache/r3/`（daemon.log、projects/、state.json）并监听 `/tmp/r3.sock`，都在工作区外。workspace-write 沙箱下 `r3 restart` 直接 Permission denied，daemon 拉不起来。 |
| ③ | **输出截断 + JSON 被切断** | 默认 20000 字符截断；`aflj`/`izzj` 超长被切成非法 JSON，`json.loads` 报错。 |
| ④ | **污染连带破坏 pd** | 分析元数据是旧文件的，`pd` 把新文件代码区打成 `.string`。 |

## 2. 已敲定的决策（访谈确认，不可推翻）

v1 决策表（PLAN §2）继续有效。v1.1 追加决策：

| # | 决策（v1.1 新增） |
|---|---|
| 9 | **修污染 = 换文件时杀掉 r2 进程重开一个新的**（从零开始，100% 干净）。接受代价：切换目标文件后 agent 用 `e ...` 设过的 r2 配置会重置（同文件会话内不受影响）。不采用"清理旧分析状态"的软重置方案（实测 r2 没有可靠的全清命令，见 §3）。 |
| 10 | **缓存加归属校验（meta 文件）**：每个工程缓存旁写 `meta.json` 记录"这份缓存属于哪个文件（SHA-256）"；校验不过一律视为未命中、重新分析，并删除脏缓存。**v1 的旧缓存（无 meta）自动作废**，不用手动删。 |
| 11 | **JSON 输出永不截断**：输出以 `{` 或 `[` 开头即判定为 JSON，跳过截断逻辑，保证 agent 拿到的 JSON 一定完整可解析。普通文本仍按 `R3_MAX_OUT`（默认 20000）截断。 |
| 12 | **沙箱友好 = 路径可配置 + 纯内存模式都要**：新增环境变量 `R3_CACHE_DIR`（默认 `~/.cache/r3`）、`R3_SOCK_PATH`（默认 `/tmp/r3.sock`）、`R3_NO_CACHE`（=1 时纯内存模式，不落盘）；CACHE_DIR 不可写时 daemon 自动降级为纯内存模式。 |
| 13 | **新增 `r3 cache-clean` 命令（可选项）**：删除全部工程缓存 + meta + state.json。J 组验收允许 SKIP；若 SKIP，F7 检查也 SKIP。 |
| 14 | **v1.1 只修缺陷 + 最小配套，不加其他新功能**（调试/多会话/TCP 仍是 v2+）。命令用法保持 v1 兼容（open/status/restart/kill/help/透传），只新增 cache-clean。 |

## 3. 根因分析（实测结论存档，r2 6.1.9 管道模式）

以下全部在本会话用 `r2 -q0 -e scr.color=0 -e scr.interactive=0 -e scr.pager=cat -` 实测复现。开发 agent 直接采信。

### 3.1 缺陷①的根因（跨文件污染）

复现序列（每次输出均为 NUL 分帧后的命令输出）：

```
o /bin/ls   → aaa  →  afl~main   → ls 的 main（0x4da0，381 字节，8029 反汇编字节）  ✓ 正常
o /bin/true                        （注意：并没有关掉 ls！）
i~file      → file /bin/true       （bin 层：当前文件已切到 true）                  ✓ 对
afl~main    → 仍是 ls 的 main（0x4da0）                                             ✗ 错
aaa（再分析）→ 仍是 ls 的 main                                                      ✗ 错
o 列表      → ls(fd4) 与 true(fd7*) 同时在开                                         ← 铁证
```

三条硬事实（决定修复方案）：
1. **r2 的 `o 新文件` = "再开一个文件并切到它"**：旧文件 fd 不关、旧分析原封不动。
2. **`aaa` 不会清空既有分析**：重复 `aaa` 后 `afl~main` 仍是旧文件的数据。
3. **r2 没有可靠的"清空全部分析"命令**：实测 `af-`（无参）只删除当前地址一个函数（207→206）；`aa-` 实测无效（207 不变）。因此"软重置"不可行，只能**杀进程重开**。

连带机制（解释评测现象）：
- `i~file` / `iS` / `izz` 读"当前 bin"（显示新文件）；`afl` / `pdf` / `pd` 读"分析核心"（还是旧数据）→ 同一时刻两个视角对不上。
- `Ps <新文件缓存路径>` 把含旧数据的分析核心原样落盘 → 污染固化进缓存，`restart` + `Po` 后依旧。
- 分析元数据错 → `pd` 把新文件代码区当数据打成 `.string`（缺陷④）。

### 3.2 缺陷②的根因（沙箱）

`spawn_daemon()` 里 `lf = open(LOG_PATH, "a")` 与 `Daemon.__init__` 里 `os.makedirs(CACHE_DIR)` 写 `~/.cache/r3`，`serve()` 里 `srv.bind("/tmp/r3.sock")`——全在工作区外。workspace-write 沙箱下第一步就 Permission denied，daemon 起不来（本会话已实测复现：`[Errno 13] Permission denied: '/home/jin/.cache/r3/daemon.log'`）。

### 3.3 缺陷③的根因（JSON 切断）

`cli_main` 透传分支对输出无条件 `truncate(out, R3_MAX_OUT, ...)`，不区分输出类型。`aflj`/`izzj` 等 JSON 命令输出超长时被拦腰切断，横幅追加后更不可能解析。

### 3.4 其他实测结论（v1.1 实现要用，存档）

- `o-*` 能关闭全部文件（实测：`o-*` 后 `o` 列表为空）。
- **`Ps <路径>` 会同时生成 `<路径>`（工程文件本体，git 仓库形态）和 `<路径>.d`（目录）**。缓存命中判断用 `os.path.isfile(<路径>)` 是正确的（v1 代码已如此，可沿用）；`cache-clean` 清理时必须**两者都删**。
- `Po <路径>` 正常恢复，会向 stderr 打 deprecation warning（无副作用，daemon 的 stderr 本来就导进日志）。
- `i~file` 输出格式：`file     /bin/ls`（多个空格分隔），取 `split()[1]` 即文件路径。**`oqq` 只输出当前 fd 的编号（如 `4`），不是路径，不能用于文件校验**。
- 无文件打开时 `i~file` 没有 `file` 行（校验函数要处理"找不到 file 行 = 校验失败"）。
- `!sleep N` 在管道模式精确阻塞 N 秒（看门狗验收可用，v1 已确认）。
- 判别器（验收 G 组用）：`/bin/ls` 的 `pdf @ main` 输出含 `LS_COLORS`、`src/ls.c`（main 8029 字节 @ 0x4da0）；`/bin/true` 的 main 只有 1364 字节 @ 0x1490，**不含** `LS_COLORS`。两个都是 coreutils，其余函数名高度重叠，所以必须用字符串判别而不是函数名。

### 3.5 实现陷阱（务必读）

`Daemon.start_r2()` 目前自带"按 state.json 自动恢复现场"（`_restore_state`）。**换文件重置 r2 时绝不能走自动恢复**，否则刚杀掉的旧文件会被 `_restore_state` 又"恢复"回来，重置白做。必须给 `start_r2` 加 `restore` 参数（默认 True），重置路径传 `restore=False`。看门狗/restart 的自愈路径仍用默认 True（恢复是对的）。

## 4. 修复设计

### 4.1 修复一：跨文件污染（决策 #9 #10）

**open_file 流程改造**（命中/未命中两条路径都要改）：

```
open_file(path):
  path = realpath(path)
  # ① 重置：只要"逻辑当前文件"不是目标，就杀 r2 重开（从零开始）
  if self.cur_file != path:
      reset_r2()          # kill r2 → start_r2(restore=False)
  key = cache_key(path, version)
  projdir = PROJECTS_DIR/key
  meta_path = PROJECTS_DIR/key + ".meta.json"

  # ② 缓存命中判定（v1 判定 + meta 归属校验，决策 #10）
  if isfile(projdir) and meta 存在 and meta["sha256"] == sha256(path):
      发 Po projdir → e scr.pager=cat
      verify_current_file(path) 失败 → reset_r2() → 发 o path（不分析）
                                    → 报告"缓存校验失败，已回退为重新打开（未分析）"
      cur_file/analyzed/cache_hit 置位，_save_state_with_key
  else:
      if isfile(projdir):   # 有工程文件但 meta 缺失/不符 → 脏缓存，删除
          删 projdir、projdir.d、meta_path
      发 o path → e scr.pager=cat
      verify_current_file(path) 失败 → 报错（code 1，不分析、不落缓存）
      if analyze:
          aaa 或 aa（大文件降级，逻辑不变）
          verify_current_file(path) 再校验一次，失败 → 报错（code 1，不落缓存）
          Ps projdir → 成功后写 meta_path（meta 内容见下）
      _save_state_with_key
  切文件发生过 reset 时，输出追加提示："已切换目标文件：r2 已重启，之前的 e 配置已重置"
```

**verify_current_file(path)**：发 `i~file`，解析输出取 `split()[1]`，与 `path`（realpath）比较；无 `file` 行或不等 → 校验失败。返回 bool。校验失败的响应要明确报"当前文件不是目标"，防止 agent 误读。

**meta 文件**：`<projdir>.meta.json`，JSON 内容：`{"key": key, "sha256": <文件SHA-256>, "path": <realpath>, "version": <r2版本>, "analysis": "aaa"|"aa", "ts": <时间戳>}`。写序：`Ps` 成功之后才写 meta（Ps 失败则无 meta → 下次视为未命中重分析，安全方向）。

**_restore_state 改造**（daemon 启动恢复现场）：
```
读取 state.json → last_file / key → projdir
重算 last_file 的 SHA-256，校验 meta["sha256"] == 它 且 meta 存在
  通过 → Po projdir → e scr.pager=cat → verify_current_file(last_file)
          verify 失败 → 回退为 o last_file（不分析），analyzed=False，报告
  不通过 → 回退为 o last_file（不分析），analyzed=False，报告
```

### 4.2 修复二：沙箱（决策 #12）

- 代码头部常量改为环境变量读取：
  - `CACHE_DIR = os.environ.get("R3_CACHE_DIR", os.path.expanduser("~/.cache/r3"))`
  - `SOCK_PATH = os.environ.get("R3_SOCK_PATH", "/tmp/r3.sock")`
  - `NO_CACHE = os.environ.get("R3_NO_CACHE") == "1"`
  所有引用点（`log`、`PROJECTS_DIR`/`STATE_PATH`/`LOG_PATH` 派生、`spawn_daemon`、`talk`/`_sock_ping`、`serve`、`kill`/`restart` 的 socket 清理）统一走这两个变量。
- **纯内存模式**（`NO_CACHE` 或自动降级）：
  - 不写 state.json（`_save_state_with_key` 跳过）、不 `Ps`、不写 meta；open 每次都真实分析。
  - `status` 输出加"缓存模式"行：`内存模式（R3_NO_CACHE，无落盘缓存）` 或 `磁盘缓存: <CACHE_DIR>`。
  - daemon 启动时 `_restore_state` 跳过。
- **自动降级**：`Daemon.__init__` 里 `os.makedirs(CACHE_DIR, exist_ok=True)` 抛异常 → `self.memory_mode = True`（`log()` 本身已吞 OSError）。
- **spawn_daemon 容错**：`lf = open(LOG_PATH, "a", ...)` 必须 try/except，失败时 stdout/stderr 用 `subprocess.DEVNULL`，否则 PermissionError 直接抛、daemon 拉不起来（本会话实测复现）。daemon 子进程天然继承环境变量，`R3_CACHE_DIR`/`R3_SOCK_PATH`/`R3_NO_CACHE` 自动生效，无需显式传递。
- **CLI 侧**：`talk` 的 socket 路径、`spawn_daemon` 的路径全走 `SOCK_PATH`；`kill`/`restart` 里检查"socket 文件消失"改为检查 `SOCK_PATH`。

### 4.3 修复三：JSON 永不截断（决策 #11）

CLI 透传分支，截断前判断：

```
raw = resp.get("out", "")
if resp.get("ok") and not full and not raw.lstrip().startswith(("{", "[")):
    out = truncate(raw, R3_MAX_OUT, command)
```

`--full` 逻辑不变（对 JSON 无意义但无害）。`R3_MAX_OUT` 只影响非 JSON 文本。文档写明：JSON 命令（aflj/izzj/ij/...）输出永不截断，agent 可放心 `json.loads`；嫌大请用 r2 端过滤（如 `izzj~password`，注意过滤后是文本不是 JSON）。

### 4.4 修复四：pd 连带坏

随 4.1 自动修复（分析核心干净了，`pd`/`pdf` 自然正确），无需单独代码。G1 验收覆盖。

### 4.5 新增：r3 cache-clean（决策 #13，可选项）

- 保留字：`cache-clean`（r2 无同名命令，不冲突）。
- daemon 新 action `cache_clean`：删除 `PROJECTS_DIR` 下全部内容（工程文件 `<key>`、目录 `<key>.d`、meta `<key>.meta.json`，**`.d` 目录必须删**）+ 删除 `STATE_PATH`；返回清理统计（删了几个工程）。内存模式下无缓存可删，直接返回 0。
- CLI：`r3 cache-clean` 走 talk 转发。
- 顺手修正 v1 status 的缓存统计 bug：现在 `n_projects - 1 if n_projects else 0` 且把目录也计数——改为"按工程文件（`isfile`）计数"，`cache-clean` 后应显示 0 个。

## 5. 代码改动点清单（r3 单文件，700 行）

| 位置 | 改动 |
|---|---|
| 头部常量（L48-52） | `CACHE_DIR`/`SOCK_PATH` 改读环境变量；新增 `NO_CACHE` 与 `meta` 相关路径函数 |
| `log()` | 路径跟随 `CACHE_DIR`（已有 try/except，OK） |
| `R2Process` | 无需改动（reset 用 `kill()` + 新建实例即可） |
| `Daemon.start_r2()` | 加参数 `restore=True`；`restore=False` 时跳过 `_restore_state`（陷阱见 §3.5） |
| `Daemon.__init__` | `makedirs` 失败 → `memory_mode=True`；新增 `reset_r2()` 方法（kill + `start_r2(False)`） |
| `Daemon.open_file()` | 按 §4.1 全流程改造：重置、verify、meta 读写、脏缓存删除、切文件提示 |
| `Daemon._restore_state()` | 按 §4.1 改造：meta 校验 + verify + 回退 |
| 新增 `verify_current_file(path)` | `i~file` 解析比较（§3.4 格式） |
| 新增 `cache_clean()` | §4.5 |
| `Daemon.status()` | 加缓存模式行；修正缓存计数 |
| `Daemon.dispatch()` | 加 `cache_clean` action |
| `spawn_daemon()` | LOG_PATH 打开容错（§4.2） |
| `cli_main()` | 加 `cache-clean` 保留字分支；透传截断前 JSON 判断（§4.3） |
| 文件头注释 | 追加 v1.1 协议/行为结论存档（§3 要点精简版） |

## 6. 验收标准（Definition of Done）

由 `tests/acceptance.sh` 逐条实现：每项打印 `PASS`/`FAIL`/`SKIP(原因)`，末尾汇总；任一 FAIL 退出码 1，全部通过（含允许的 SKIP）退出码 0。

**脚本隔离要求（新增，重要）**：脚本顶部 export `R3_CACHE_DIR`、`R3_SOCK_PATH` 到脚本自建的临时目录（默认 `mktemp -d`，可用环境变量覆盖），**所有 r3 调用与路径断言都使用这两个变量**——验收自身不依赖 `~/.cache` 与 `/tmp/r3.sock` 的写权限（这也正是缺陷②的修复目标）。从干净状态起跑：先 `r3 kill` 再清空 `$R3_CACHE_DIR`。假定 `r3` 已在 PATH（无则先跑 install.sh）。

**A 部署（v1 保持）**
- A1：仓库根 `bash install.sh` 退出码 0；`which r3` 指向 `~/.local/bin/r3`。
- A2：`r3 help` 退出码 0，输出含全部保留子命令名（open/status/restart/kill/cache-clean）。

**B daemon 生命周期（v1 保持，路径改用 $R3_SOCK_PATH）**
- B1 冷启动：`r3 status` 自动拉起 daemon，退出码 0，输出含 r2 版本号。
- B2：`r3 kill` 后 `$R3_SOCK_PATH` 消失；随后 `r3 "?t"` 自动重启 daemon 并正常返回非空输出。

**C 打开与分析缓存（v1 保持，路径改用 $R3_CACHE_DIR）**
- C1：`r3 open /bin/ls` 输出含耗时；`$R3_CACHE_DIR/projects/` 出现工程文件与 meta；`r3 status` 显示当前文件为 /bin/ls 且已分析。
- C2：`r3 kill` 后 `r3 open /bin/ls` real 耗时 < 3 秒且标注缓存命中。
- C3：`r3 kill` + 清空缓存后 `r3 open /bin/ls --no-analyze` 耗时 < 2 秒、未产生工程文件、`r3 "aflj"` 无函数条目。
- C4 降级：`SZ=$(stat -c %s /bin/ls)`，`R3_BIGFILE_LIMIT=$((SZ/2)) r3 open /bin/ls` 输出含"轻量分析"提示。
- **C5（新增）meta 归属校验**：手动篡改 `$R3_CACHE_DIR/projects/*.meta.json` 里的 sha256（或删掉 meta），再 `r3 kill` + `r3 open /bin/ls` → 不命中缓存（输出无"缓存命中"字样或耗时 > 阈值），且重新生成正确 meta。

**D 传声筒与输出处理（v1 保持）**
- D1：`r3 "afl"` 非空且无 ANSI 转义。
- D2：`r3 "aflj"` 合法 JSON；取第一个函数名 FN，`r3 "pdf @ FN"` 非空。
- D3 状态驻留：`r3 "e asm.bytes=false"` 后 `r3 "e asm.bytes"` 含 `false`（注意：必须在同一文件会话内测，不要跨 open，见决策 #9）。
- D4 截断：`r3 open <libc> --no-analyze` 后 `r3 "izz"` 含截断横幅且总长 ≤ 上限+横幅+1KB；`r3 --full "izz"` 长度 > 上限。
- D5 并发：两个 `r3 "?t"` 后台同时发起，均退出码 0 且非空。

**E 防挂死（v1 保持）**
- E1 黑名单：`r3 "V"` 退出码 2、输出含拒绝提示、随后 `r3 status` 正常。
- E2 看门狗：`R3_CMD_TIMEOUT=2 r3 "!sleep 5"` 返回超时说明，随后 `r3 status` 正常。

**F 交付物与约束（v1 更新）**
- F1：仓库含 `PLAN.md`、`PLAN-v1.1.md`、`DESIGN.md`、`r3`、`install.sh`、`AGENTS.md`、`tests/acceptance.sh`。
- F2：`r3` 单文件，import 全部属 Python 3 标准库。
- F3：`r2 -v` 仍为 6.1.9，仓库无 r2 源码。
- F4：v1 预留口子仍在（协议 `sid` 字段、open `mode` 参数）。
- F5：acceptance.sh 汇总逻辑正确（全绿退出码 0，任一 FAIL 退出码 1）。
- F6（新增，静态检查）：r3 代码含 `R3_CACHE_DIR`/`R3_SOCK_PATH`/`R3_NO_CACHE` 处理、open 路径含 r2 重置 + `verify_current_file` + meta 校验、透传截断含 JSON 豁免判断。
- F7（新增，随 J 组）：`cache-clean` 保留字与 daemon action 存在。J 组 SKIP 时本条一并 SKIP。

**G 跨文件污染回归（新增，核心）**
- G1 切换不污染：`r3 open /bin/ls`（分析完成）→ `r3 open /bin/true` → `r3 "i~file"` 显示 /bin/true，且 `r3 "pdf @ main"` **不含** `LS_COLORS` 与 `src/ls.c`（判别器见 §3.4）。
- G2 缓存不被污染：接 G1，`r3 kill` → `r3 open /bin/true`（缓存命中）→ `r3 "pdf @ main"` 仍**不含** `LS_COLORS`（验证落盘缓存归属正确）。
- G3 能切回：`r3 open /bin/ls` → `r3 "pdf @ main"` **含** `LS_COLORS`（切回正常）。
- G4 切文件提示：G1 的 open 输出含"r2 已重启"/"配置已重置"字样（决策 #9 的提示）。

**H 沙箱友好（新增）**
- H1 路径可配置生效：open /bin/ls 后，`$R3_CACHE_DIR` 下存在 `daemon.log` 与 `projects/`，`$R3_SOCK_PATH` 存在，且默认 `/tmp/r3.sock` 不存在。
- H2 纯内存模式：`R3_NO_CACHE=1 r3 open /bin/ls` → `r3 status` 输出含"内存模式"或"无落盘缓存"；`$R3_CACHE_DIR/projects/` 下无工程文件（或目录为空）；`r3 "afl"` 仍有函数（分析正常只是不缓存）。
- H3 不可写自动降级：`R3_CACHE_DIR=/proc/r3-nonexistent r3 open /bin/ls`（/proc 下不可创建目录）退出码 0、`r3 "afl"` 非空、`r3 status` 正常（daemon 未崩、降级为内存模式）。

**I JSON 不截断（新增）**
- I1：`R3_MAX_OUT=100 r3 "aflj"`（上限压到 100，输出远超）→ 输出是合法 JSON（`python3 -c 'import json,sys; json.load(sys.stdin)'` 成功）且长度 > 100（未被截断）。
- I2 对照组：`R3_MAX_OUT=100 r3 "afl"` → 输出含截断横幅（文本仍截断）。

**J cache-clean（新增，允许 SKIP）**
- J1：`r3 open /bin/ls`（产生缓存）→ `r3 cache-clean` 退出码 0 → `r3 status` 缓存计数为 0 → `$R3_CACHE_DIR/projects/` 为空（含 `.d` 目录与 meta 一并清掉）。

## 7. 实现顺序建议（给开发 agent，验收驱动）

先搭 `tests/acceptance.sh` v1.1 骨架（允许全红），随实现逐项变绿。顺序：

1. **环境变量化 + spawn 容错**（§4.2）→ H 组先绿；同时把脚本的路径断言改为 `$R3_CACHE_DIR`/`$R3_SOCK_PATH`。
2. **reset_r2 + verify_current_file + meta 校验**（§4.1，含 `start_r2(restore=...)` 陷阱）→ G 组、C5 绿。
3. **JSON 豁免**（§4.3）→ I 组绿。
4. **cache-clean + status 统计修正**（§4.5）→ J 组、F7 绿。
5. **文档配套**：更新 AGENTS.md（新环境变量、JSON 不截断、切文件配置重置、cache-clean）；补齐 install.sh（v1 未入库）；文件头注释存档 v1.1 实测结论。
6. **全量回归**：A–J 全部跑通（J 允许 SKIP），F 组静态检查通过。
