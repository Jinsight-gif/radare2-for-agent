# r3 v2.0.0 开发方案 —— 动态调试适配（goal 模式）

> 本文是 v2.0.0 的定稿开发规格，在 v1.3.1（r3 文件 + AGENTS.md + acceptance W 组）之上增量修订。
> v1/v1.1/v1.2/v1.3 决策（#1–#30）与 v1.3.1 修复继续有效，本文只追加、修订。
> 实现 agent 按本文档直接实现，无需再做架构决策。
> 文中 r3 行号以当前 1847 行版本为基线；实现时若行号因局部调整漂移，以实际代码为准，不按行号硬改。
> 配套：`DESIGN.md`、`PLAN.md`（v1）、`PLAN-v1.1.md`、`PLAN-v1.2.md`、`PLAN-v1.3.md`、`AGENTS.md`、
> SKILL.md（`/home/jin/.dsh/skills/r3/SKILL.md`）。
> 需求已与用户拍板：入口 = `r3 open <文件> --debug`；范围 = 核心透传调试 + attach 只文档注明边界 +
> 子进程输出只静音不捕获 + ESIL 明确排除；超时语义不变（900s + 文档教招）；版本 v2.0.0；
> 验收用 gcc 现场编译小目标（缺 gcc 则该组 SKIP）；文档同步五处（含 SKILL.md）。

---

## 0. Goal 模式执行须知

**目标**：交付 r3 v2.0.0，让 agent 能用 r3 做动态调试（拉起式）。完成定义 =
`bash tests/acceptance.sh`（仓库根、WSL bash）退出码 0。

**执行环境**（同 v1.3 §0）：WSL 原生文件系统；r2 6.1.9 `/usr/local/bin/r2`；Python 3.12.3；
gcc（验收编译调试目标用）；`r3` 部署 `~/.local/bin/r3`（`bash install.sh`）。宿主环境每次 bash
调用可能带 `landlock-run: partial enforcement (older Landlock ABI)` stderr 警告——**非 r3 输出，
忽略即可**。

**规则**：
1. 本文档是唯一需求来源，自足。
2. §2 决策表是硬约束，不得重设计、不得扩范围。
3. 事实类出入以实测为准并写进代码注释；架构级分歧停下问用户。
4. 范围护栏：只用 Python 3 标准库；不 fork/不修改 r2；不做 TCP；不做远程调试（rap://）、
   ESIL 仿真、内核调试；调试只做**拉起式**（r2 自己 spawn 目标），attach 只文档注明边界不写代码。
5. §3 现状/实测是实测结论，直接采信；§3.3 已附复核结论，实现 agent 动手前可快速复跑
   并写进代码注释/存档（可仿 tests/probe_protocol*.py 惯例）；结论不一致才停下问。

---

## 1. 背景：v2 为什么做

逆向 agent 的刚需从"读"升级到"跑"：静态分析只能看到死代码，CTF 题里的自修改、反调试、
运行时解密的 flag 必须跑起来才看得到。r2 的动态调试（`db`/`dc`/`dr`/`wx`/`dbt` 系列）在
管道模式下实测可用，r3 的传声筒架构天然适配；v1 代码已预留 `OpenMode.DEBUG` 口子。v2 把口子接通：

| 现在的痛点 | v2 解法 |
|---|---|
| r3 只能静态分析（open 只支持 static，L906 显式拒绝 debug） | `r3 open <文件> --debug`：会话 r2 以 `-d` 拉起式调试启动 |
| 调试子进程的 stdout 混进 r2 输出流，污染 NUL 分帧 | daemon 管理的 dbg.profile（`stdio=/dev/null`，不能带空格）静音 |
| attach 别的进程被内核 yama 限制 | 文档注明边界；错误文本原样透出（传声筒行为） |
| ESIL/远程调试等大主题混进来做不完 | 明确排除，留给 v3+ |

设计基调与 v1 一致：**调试命令同样只是透传**——r3 不新增翻译层，agent 会什么 r2 调试命令
就发什么；r3 只负责把"调试态"这个会话属性管对（启动方式、自愈保持、输出干净、状态可见）。

---

## 2. 决策表（硬约束）

| # | 决策 |
|---|---|
| 31 | **调试入口 `r3 open <文件> --debug`**。CLI 解析 `--debug` 发 `mode=debug`（OpenMode.DEBUG 占位转正）。同一文件 static/debug 互斥：模式不符时杀旧 r2 以目标模式重开（复用 sid/econf；工程缓存只由 static 会话读写，debug 不 Po 不 Ps），输出注明"已切换"。不新增顶级保留字。 |
| 32 | **R2Process 支持 debug 启动**：`R2Process(debug=False, path=None)`。debug=True 时 spawn `r2 -q0 -d -e scr.color=0 -e scr.interactive=0 -e scr.pager=cat -e dbg.profile=<daemon 管理的 profile> <path>`（不带 `-`；实测 -d 带文件时命令仍从 stdin 读、就绪 NUL 照发）。daemon 用 tempfile 写固定内容 `stdio=/dev/null`（**不能带空格**，实测 `stdio = /dev/null` 不解析、照样漏输出）的 profile；写失败仅 log 并降级（输出可能混入，文档注明）。Popen 加 `start_new_session=True`，`R2Process.kill()` 用 `os.killpg` 全组 SIGKILL（实测 debuggee 与 r2 同进程组；r2 q/裸 SIGKILL 不会自动带走 debuggee）。 |
| 33 | **会话调试态建模与恢复**：Session 加 `debug: bool`。`_restore_session_file` 按 debug 分流：debug 会话**禁止 `o <path>`**（会切走调试 io），恢复 = **禁止 `Po`**（实测 static 工程 Po 进 debug 会话后 dr rip 归 0、断点跑飞）；`_restore_session_file` 只做 verify/pager/econf，**分析由调用方用共享 helper `_debug_aaa(sess)` 决定**（open 按 `analyze` 参数；自愈/复用/boot 按 `sess.analyzed`，`--no-analyze` 自然跳过）。**debug 会话分析不落 `Ps`/不写 meta**（工程缓存只由 static 会话写；实测 r2 也拒绝在 debugged bin 上 `Ps`）。 |
| 34 | **调试态可见**：status/sessions 文本加 `[调试]` 标签，结构化 JSON 加 `"debug": true`；open 成功输出注明"调试会话（拉起式，目标已启动并停在 r2 初始断点）"。 |
| 35 | **自愈/复用复活/daemon 重启恢复均保持调试模式**：`_resp_r2_dead` 与 open 复用分支重建 r2 时带 `debug=sess.debug, path=sess.cur_file`；state.json 增存 debug 字段，`_boot_restore` 据此重建。所有杀 r2 路径（close/自愈/daemon 退出）走 #32 的 `os.killpg` 全组清理——实测 r2 6.1.9 q 退出或被 SIGKILL **不会**自动带走 debuggee（无 PTRACE_O_EXITKILL），不主动清理会留孤儿。超时语义不变（默认 900s、R3_CMD_TIMEOUT 请求级覆盖），触发自愈后的现场 `aaa` 固定用 `DEFAULT_CMD_TIMEOUT`（不继承本次请求的小 timeout），文档教 agent 用 `R3_CMD_TIMEOUT=30 r3 "dcu <addr>"` 有界等待。 |
| 36 | **范围护栏**：黑名单不扩展（调试无新增交互命令）；attach 受 yama ptrace_scope=1 限制仅文档注明（错误文本原样透出）；ESIL/远程调试/内核调试明确排除。 |
| 37 | **版本号 v2.0.0**：R3_VERSION 更新，help/status 展示，acceptance A2/W2 版本断言同步。 |
| 38 | **文档五处同步**：AGENTS.md、r3 内 USAGE、DESIGN.md、SKILL.md（版本、触发词加调试系列、调试工作流段、attach 边界）、tests/acceptance.sh（版本断言 + 新 X 组 + F 组修订）。 |

---

## 3. 现状与实测（直接采信）

### 3.1 代码现状（r3 单文件，1847 行）

| 位置 | 现状 |
|---|---|
| L408–412 `OpenMode` | DEBUG = "debug" 占位，注释写明 v2 口子 |
| L906–908 `open_file` | `mode != STATIC` 显式拒绝 |
| L1732–1755 CLI open 分支 | 固定发 `OpenMode.STATIC.value`；只解析 `--no-analyze`/`--gitignore` |
| L424–434 `R2Process.__init__` | 固定 spawn `r2 -q0 -e … -`，无 debug/profile 参数 |
| L663–710 `_restore_session_file` | 只有 `Po` / `o path` 两路，无 debug 感知 |
| L959–974 open 复用分支 | 重建 `R2Process()` 无模式参数 |
| L1107–1133 `_resp_r2_dead` | 重建 `R2Process()` 无模式参数 |
| L512–521 `Session` | 无 debug 字段 |
| L1137–1240 `status` / L1244–1264 `list_sessions` | 无调试态展示 |
| L149 `R3_VERSION` | "1.3.1" |
| `_save_state_with_key`（L722–735） | state.json 无 debug 字段 |

### 3.2 v2 实测结论（r2 6.1.9，WSL，ptrace_scope=1；本方案作者已实测复核，直接采信）

1. `r2 -q0 -d <文件>`（不带 `-`）管道模式可用：`db main`/`dc`/`dcr`/`drj`/`dr rax=0x1234`/
   `wx 90 @ rip` 全部正常；启动就绪 NUL 与命令 NUL 分帧与 static 模式一致。
2. `ood` 可在已开会话内切调试态（r2 原生能力；v2 不依赖它，daemon 自己杀 r2 重开）。
3. **调试子进程的 stdout 默认继承 r2 的 stdout，会混进命令输出流、污染 NUL 分帧**
   （实测 `dc` 后目标程序的 printf 直接出现在 r3 会拿到的那条流里）。
4. `-e dbg.profile=<文件>` + 文件内容 `stdio=/dev/null`（**无空格**）→ 子进程 stdio 全静音，
   stdout 只剩干净的 NUL 分帧；`stdio = /dev/null`（带空格）实测不解析、输出照漏。
   写文件重定向：`stdout=/path` 实测可把目标 stdout 写进文件（捕获技术上可行，但 v2 范围
   只静音不捕获）；`stdio=/path` 实测 spawn 失败（cannot handle stdin redirection）；
   `output=/path` 不是合法 rarun2 指令、不生效。
5. **r2 6.1.9 不会自动清理 debuggee**：调试中 `q` 退出或 r2 被 SIGKILL 后，目标进程仍存活
   （无 PTRACE_O_EXITKILL），直到它自己跑完退出。因此 r3 必须主动清理：R2Process 用
   `start_new_session=True` 起 r2，实测 debuggee 与 r2 同进程组，`os.killpg` 可一次全杀。
6. attach 非子进程失败：`ptrace_attach: Operation not permitted`（内核 yama ptrace_scope=1，
   需 sudo 放宽）→ v2 只做拉起式。
7. debug 会话内 `aaa` 分析的是真实文件：`i~file` 仍输出真实路径（→ verify_current_file
   无需改）、`afl~main` 正常且地址带运行时基址（PIE 重定位）。
   配套复核：static 工程 `Po` 进 debug 会话后 `dr rip` 归 0、`db main`/`dc` 跑飞（Po 有害）；
   debug 会话 `Ps` 被 r2 直接拒绝（does not support projects on debugged bins）。
8. gcc 可用 → 验收可现场编译调试目标。

### 3.3 探针复核结论（实现 agent 可快速复跑存档；与 §3.2 一致）

- **P1 Po 恢复语义**：static 工程 `Po` 进 debug 会话后 `dr rip` 归 0、断点跑飞，
  恢复对 debug **有害** → debug 会话一律不 `Po`，现场 `aaa`。
- **P2 Ps 污染**：debug 会话执行 `Ps` 被 r2 6.1.9 直接拒绝（does not support projects
  on debugged bins）→ 不存在 debug 工程污染 static 缓存的路径；决策 #33 不 `Ps` 照做。
- **P3 profile 生命周期**：r2 仅在拉起 debuggee 时读 dbg.profile；**收到就绪 NUL 之后**
  删 tempfile 安全，Popen 后立刻删会 spawn 失败 → 实现必须在就绪 NUL 后再删。
- **P4 内存模式/沙箱下 tempfile 写 profile 的可行性**（不可写时按 #32 降级）。
- **P5 iIj 在 debug 会话下正常**（aaa 前后均返回合法 JSON）；仍保留失败省略逻辑。

---

## 4. 设计

### 4.1 CLI：open 分支加 --debug（#31）

L1732–1755 open 分支：
- 解析 `--debug`（与 `--no-analyze`、`--gitignore` 同级可选、可组合；`--no-analyze` =
  不分析，与调试正交）。
- `req["mode"] = OpenMode.DEBUG.value if debug else OpenMode.STATIC.value`。
- 用法行：`r3 open <文件路径> [--no-analyze] [--gitignore] [--debug]`。

### 4.2 R2Process debug 启动与 profile（#32）

```python
DBG_PROFILE_CONTENT = "stdio=/dev/null\n"   # 不能带空格：实测 "stdio = /dev/null" 不解析

class R2Process:
    def __init__(self, debug=False, path=None):
        args = [R2_BIN, "-q0",
                "-e", "scr.color=0", "-e", "scr.interactive=0",
                "-e", "scr.pager=cat"]
        if debug:
            args += ["-d"]
            profile = self._write_dbg_profile()   # mkstemp；失败 None + log
            if profile:
                args += ["-e", f"dbg.profile={profile}"]
            args += [path]      # -d 必须带文件（实测裸 r2 -q0 -d 报 Missing file）
        else:
            args += ["-"]       # 现状不变
        # Popen 加 start_new_session=True：r2 与 debuggee 同进程组，killpg 才能全清。
        # stderr 排空线程 / 就绪 NUL 等待逻辑不变（实测 debug 启动行为一致）。

    def kill(self):
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)   # r2 + debuggee 全组
        except (ProcessLookupError, PermissionError):
            try:
                self.proc.kill()                       # 组已空等兜底
            except OSError:
                pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            pass
```

- `_write_dbg_profile()`：tempfile.mkstemp 写 DBG_PROFILE_CONTENT；成功返回路径，**收到就绪
  NUL 之后**尝试删除、失败忽略（P3：Popen 后立刻删会 spawn 失败）；失败返回 None 并 log
  （此时子进程 stdio 继承 → 输出可能混入，属降级路径，文档注明）。

### 4.3 open_file debug 分支（#31/#33）

- 删除 L906–908 拒绝。
- 会话汇聚规则扩展：文件已有会话且 `sess.debug != (mode == OpenMode.DEBUG)` → 先
  `sess.debug = (mode == OpenMode.DEBUG)`、`sess.cur_file = path`，杀旧 r2，
  `sess.r2 = R2Process(debug=sess.debug, path=path)`，走 `_restore_session_file(sess)`
  （只恢复现场，不分析），再按本流程第 4 步由 open 的 `analyze` 参数决定 `_debug_aaa`；
  输出注明"会话已切换为调试模式"（static→debug 同理反向）。
- debug 打开流程（新建或切换后统一）：
  1. `sess.debug = True`；`sess.cur_file = path`
  2. `e scr.pager=cat`（保守照发，与 static 同）
  3. `verify_current_file`（debug 会话 `i~file` 输出真实路径，实测无需改）
  4. **不 `Po`、不读静态工程**（P1：Po 会破坏调试态）；`analyze=True` 时调用
     `_debug_aaa(sess)` 现场分析（大文件降级逻辑照用；`--no-analyze` 跳过），
     分析只在会话内存
  5. **不 `Ps`、不写 meta**（#33；`sess.analyzed=True` 只反映现场分析，不落盘）
  6. `_apply_econf(sess)`（econf 与模式无关，直接复用；agent 设过的 `e dbg.*`
     配置同样按名常驻重放——传声筒语义自然成立）
  7. 成功输出头部注明调试会话（拉起式，目标已启动并停在 r2 初始断点）；
     `iIj` 速览行按现状（P5 已实测正常，异常则省略）
- `--gitignore` 动作与调试正交，维持现有调用点。

### 4.4 _restore_session_file debug 感知（#33）

- 按 `sess.debug` 分流：
  - debug=True：**不发 `o path`**（会切走调试 io、破坏 -d 态）；**也不 `Po`**（P1
    实测破坏调试态）。只做 `verify_current_file` + pager 重设 + `_apply_econf`，
    **不在本函数里 `aaa`**——是否分析由调用方用 `_debug_aaa(sess)` 决定
    （open 按 `analyze` 参数；自愈/复用/boot 按 `sess.analyzed`）。
  - static：现状不动。
- `_debug_aaa(sess)`：现场 `aaa`（大文件降级照用），超时固定 `DEFAULT_CMD_TIMEOUT`，
  不落 `Ps`、不写 meta；成功后 `sess.analyzed=True`。
- verify_current_file 无需改（实测 3.2.7）。

### 4.5 自愈/复活/重启保持模式（#35）

- `_resp_r2_dead`（L1116）：`sess.r2 = R2Process(debug=sess.debug, path=sess.cur_file)`；
  `_restore_session_file` 后若 `sess.debug and sess.analyzed` → `_debug_aaa(sess)`。
- open_file 复用分支（L967）：同改，并遵守上一行的重分析规则。
- `_save_state_with_key`（L722–735）：data 加 `"debug": sess.debug`；`_boot_restore`
  （当前代码约 L635–661，以实际为准）读 `debug` 字段以对应模式重建（缺失默认 False，
  兼容旧 state），并把 `st["analyzed"]` 带回 `sess.analyzed`——debug 恢复后据此决定
  是否 `_debug_aaa(sess)`。
- serve() 退出清理、close_session、看门狗杀 r2：统一走 `R2Process.kill()` 的
  `os.killpg` 全组清理；**不能只 kill r2**（实测 r2 死不会带走 debuggee）。
- 超时语义不变：默认 900s；agent 有界等待用 `R3_CMD_TIMEOUT=30 r3 "dcu <addr>"`（文档教招）。
  触发自愈后的 debug 现场 `aaa` 固定用 `DEFAULT_CMD_TIMEOUT`，不继承本次请求小 timeout。
  `dc` 无断点跑到目标退出属 r2 正常行为（后续寄存器查询结果不作保证），文档写明。

### 4.6 状态展示（#34）

- Session 加 `self.debug = False`（L512–521）。
- status() 会话列表项加 `[调试]` 标签（文本）；structured 的 sessions 项加 `"debug": s.debug`。
  当前会话在调试态时，`已分析` 行后追加一行
  `调试模式 : True（拉起式 r2 -d；attach 受内核 yama 限制不可用）`。文案细节实现 agent
  自定，验收断言关键词"调试"。
- list_sessions() 文本与 structured 同步加。

### 4.7 文档五处同步（#38）

1. **AGENTS.md**：命令表加 `r3 open <文件> --debug`；「agent 必知」加调试条（拉起式、
   断点工作流、有界等待、attach 不可用、**目标程序 stdout 被静音看不到 printf**、
   r3 关闭/超时/daemon 退出会主动清理 debuggee（勿假设 r2 自动清理）、
   不要自己动 `e dbg.profile`）；版本号 v2.0.0。
2. **r3 内 USAGE**（L169–204）：open 用法行加 `[--debug]`；说明段加调试段落；版本号。
3. **DESIGN.md**：传声筒原则补"调试命令同样透传"；看门狗节补"r2 死时 debuggee 不会自动清理，r3 以 killpg 主动清理
   （实测）"；新增"v2 动态调试"节简述 #31–#38 理念与边界（拉起式/静音/不落 Ps/attach
   边界/ESIL 排除）。
4. **SKILL.md**（`/home/jin/.dsh/skills/r3/SKILL.md`）：版本 v2.0.0；description 触发词加
   调试、`r3 open --debug`、断点、`db`/`dc`/`dr`、单步、寄存器；命令表加 `--debug`；
   「必知」加调试条；新增"动态调试工作流"段（示例：`r3 open ./crackme --debug` →
   `r3 "db main"` → `r3 "dc"` → `r3 "drj"` → `r3 "wx 90 @ rsp"` →
   `R3_CMD_TIMEOUT=30 r3 "dcu 0x…"`）；attach 边界、"目标程序输出静音"与"r3 主动清理 debuggee"写明。
5. **tests/acceptance.sh**：A2/W2 版本断言 1.3.1 → 2.0.0；F1 交付物清单加 PLAN-v2.md；
   F4 改为 debug 实现标记断言（见 §6）；新增 X 组（§6）。

### 4.8 版本号（#37）

- L149 `R3_VERSION = "2.0.0"`；文件头注释追加 v2 结论存档（profile 无空格、r2 不自动清
  debuggee、Po 有害、debug Ps 被拒、killpg 全组清理 + #31–#38 要点 + 探针结论）。

---

## 5. 代码改动点清单（r3 单文件）

| 位置 | 改动 |
|---|---|
| L149 `R3_VERSION` | → "2.0.0"（#37） |
| L408–412 `OpenMode` | DEBUG 占位转正（#31） |
| 新增常量 | `DBG_PROFILE_CONTENT`（#32） |
| L417–499 `R2Process` | 加 `debug/path`、`start_new_session=True`、`_write_dbg_profile()`、`killpg` 清理（#32/#35） |
| L512–521 `Session` | 加 `debug: bool`（#33/#34） |
| L663–710 `_restore_session_file` | debug 分流：禁 `o`、禁 `Po`，只 verify/pager/econf（#33） |
| 新增 helper | `_debug_aaa(sess)`：现场 aaa/大文件降级，不落 Ps/meta（#33） |
| L722–735 `_save_state_with_key` | state.json 存 debug 字段（#35） |
| L635–661 `_boot_restore` | 按 debug 字段重建模式（#35；行号以实际为准） |
| L897–1105 `open_file` | 删 L906–908 拒绝；模式切换与 debug 打开流程（#31/#33） |
| L959–974 复用分支 | R2Process 带 debug/path（#35） |
| L1107–1133 `_resp_r2_dead` | 同上（#35） |
| L1137–1240 `status` | 调试态展示（#34） |
| L1244–1264 `list_sessions` | 调试态展示（#34） |
| L169–204 `USAGE` | --debug 用法与调试段（#38） |
| L1647–1755 `cli_main` | open 解析 --debug（#31） |
| 文件头注释 | v2 结论存档（3.2 + 探针结论） |

AGENTS.md / DESIGN.md / SKILL.md / acceptance.sh 按 §4.7 同步。

---

## 6. 验收标准

沿用脚本隔离要求（顶部 export R3_CACHE_DIR/R3_SOCK_PATH 到 mktemp -d；先 r3 kill 再清缓存）。
A–W 既有语义保持，**旧验收修订**两处：
- **A2/W2 版本断言**：grep "v1.3.1" → "v2.0.0"（r3 help 与 status 文本、status --json 的 r3_version）。
- **F1**：交付物清单加 PLAN-v2.md；**F4**：改为断言 debug 实现标记齐全（`DBG_PROFILE_CONTENT`、
  `start_new_session`、`os.killpg`、`--debug`、`OpenMode.DEBUG` 均可 grep 到）。

新增 **X 组（调试，v2.0.0）**：
- **X0 环境前置**：先 `r3 kill` + 清空测试缓存 + 确认无 `dbg_target` 残留；
  `command -v gcc` 无 → 整组 SKIP 并提示。
- **目标构造**：`$TEST_TMP/dbg/dbg_target`（gcc -O0 编译；逻辑：`tick()` 循环函数 +
  main 开始处 `printf("DBG_MARKER_1337\n")` + `fflush` + main 中段 `sleep(3)`——保证
  断点可停、无断点输出可验证静音、超时场景可控）。
- **X1 入口与基本态**：`r3 open $DBG --debug` → 退出码 0、输出含"调试"；`r3 status`
  含"调试"；`r3 status --json` 的 sessions 项 `debug==true`；`r3 "i~file"` 输出含 DBG 路径。
- **X2 断点/继续/寄存器**：`r3 "db main"` → `r3 "dc"`（停 main）→ `r3 "dr rax=0x1234"`
  → `r3 "dr rax"` 含 0x1234；`r3 --json "dbj"` 为合法 JSON 且含 main。
- **X3 内存读写**：`r3 "wx 9090 @ rsp"` → `r3 "px 2 @ rsp"` 含 9090（写栈不写 text 段）。
- **X4 child stdio 静音（核心）**：无断点 `r3 "dc"`（目标跑完，期间打印 DBG_MARKER_1337）
  → r3 输出**不含** DBG_MARKER_1337。
- **X5 debuggee 清理与自愈保持**：open --debug → db main → dc → `r3 close` →
  `pgrep -x dbg_target` 为空（close 全组清理）。再 open --debug，记录 `P=$(r3 "dp" |
  awk '{print $2}')` → `R3_CMD_TIMEOUT=1 r3 "dc"`（sleep(3) 触发超时 → 退出码 3）→
  旧 pid `kill -0 $P` 失败、`pgrep -x dbg_target` 恰有 1 个且 pid != 旧值（旧目标被杀、
  自愈已拉起新目标），且 `r3 status` 该会话仍含"调试"。
- **X6 模式切换**：X5 之后 `r3 open $DBG`（不带 --debug）→ status 不含"调试"、
  `r3 "i~file"` 正常（static 恢复）。
- **X7 透传面**：`r3 "dp"` 退出码 0（进程列表可用）；静态断言 AGENTS.md 与 SKILL.md
  均含 yama/attach 边界说明。

---

## 7. 已知风险（本次不修）

- debug 会话分析不落盘：每次新建/切换调试会话现场 `aaa`（P1 实测 Po 有害）——首次较慢，
  属"调试态正确性优先"的代价；文档注明。
- 目标程序 stdout 被静音：agent 看不到 printf 输出；如需捕获让目标程序自己写文件
  （r2 `stdout=` 重定向可写文件，但用户已拍板 v2 只静音不捕获，捕获留后续版本）。
- 若调试目标自行 setsid/daemonize 改进程组，killpg 可能漏杀；v2 按"普通前台调试目标"处理，
  文档注明边界。
- 沙箱下 debuggee 继承 daemon 环境（landlock 等）可能影响目标行为；验收在宿主正常环境跑，
  文档注明边界。
- attach 受 yama 限制不可用（需 sudo 放宽），v2 不写代码；`dp` 列进程可用但 attach 会报
  Operation not permitted（错误文本透出）。
- `dc` 无断点长时间阻塞 → 看门狗兜底（默认 900s），文档教有界等待。

---

## 8. 实现顺序建议

先快速复跑探针 P1–P5 存档（§3.3 已有结论，不一致才停下问）；再搭 X 组骨架（全红）随实现变绿：

1. 复跑/存档探针 P1–P5。
2. **#32 R2Process debug 启动 + profile + killpg** → X4 静音、X5 清理随其自然绿。
3. **#31/#33 open_file debug 分支 + _restore_session_file 分流 + #35 自愈/复活/重启保持**
   → X1/X2/X3/X5/X6 绿。
4. **#34 状态展示** → X1 展示断言绿。
5. **#37 版本号** → A2/W2 修订绿。
6. **#38 文档五处同步 + F 组修订**。
7. 全量回归 A–X 全绿（重点 G 组跨文件污染、S 组 econf 回归不受影响）。

（全文完）
