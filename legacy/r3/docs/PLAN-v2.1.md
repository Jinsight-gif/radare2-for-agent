# r3 v2.1.0 开发方案 —— 调试体验修复 + 目标输入注入（goal 模式）

> 本文是 v2.1.0 的定稿开发规格，在 v2.0.0（r3 文件 + AGENTS.md + acceptance X 组）之上增量修订。
> v1/v1.1/v1.2/v1.3/v2 决策（#1–#38）继续有效，本文只追加、修订。
> 实现 agent 按本文档直接实现，无需再做架构决策。
> 文中 r3 行号以当前 2121 行版本（v2.0.0）为基线；实现时若行号因局部调整漂移，以实际代码为准，不按行号硬改。
> 配套：`DESIGN.md`、`PLAN.md`（v1）、`PLAN-v1.1.md`、`PLAN-v1.2.md`、`PLAN-v1.3.md`、`PLAN-v2.md`、`AGENTS.md`、
> SKILL.md（`/home/jin/.dsh/skills/r3/SKILL.md`）。
> 需求已与用户拍板：修复范围 = 报错可读性 + 模式切换失败状态一致性 + 目标 stdin 注入三件事全做；
> 无执行位只预检提示不替 agent 改权限；切换失败回滚为"旧模式 + 待重开"标记、后续命令自动自愈；
> 输入注入形态 = `r3 open <文件> --debug --stdin <输入文件>`，换输入 = 重新 open（拉起时快照，不支持运行中追加）；
> status/sessions 显示输入文件与待重开标记；版本 v2.1.0；交付物按仓库惯例全套（本文 + 文档五处同步 + acceptance Y 组）。

---

## 0. Goal 模式执行须知

**目标**：交付 r3 v2.1.0，修复 v2 调试的报错可读性与状态一致性缺陷，并补齐目标程序 stdin 注入。
完成定义 = `bash tests/acceptance.sh`（仓库根、WSL bash）退出码 0。

**执行环境**（同 v2 §0）：WSL 原生文件系统；r2 6.1.9 `/usr/local/bin/r2`；Python 3.12.3；
gcc（验收编译调试目标用）；`r3` 部署 `~/.local/bin/r3`（`bash install.sh`）。宿主环境每次 bash
调用可能带 `landlock-run: partial enforcement (older Landlock ABI)` stderr 警告——**非 r3 输出，
忽略即可**。

**规则**：
1. 本文档是唯一需求来源，自足。
2. §2 决策表是硬约束，不得重设计、不得扩范围。
3. 事实类出入以实测为准并写进代码注释；架构级分歧停下问用户。
4. 范围护栏：只用 Python 3 标准库；不 fork/不修改 r2；stdin 注入**只走 dbg.profile 的
   rarun2 `stdin=` 指令**，不自研管道/pty/进程间转发；不做 TCP、远程调试（rap://）、ESIL、
   内核调试；attach 仍只文档注明边界不写代码。
5. §3 现状/实测是实测结论，直接采信；§3.3 已附复核结论，实现 agent 动手前可快速复跑
   并写进代码注释/存档（可仿 tests/probe_protocol*.py 惯例）；结论不一致才停下问。

---

## 1. 背景：v2.1 为什么做

v2.0.0 上线后的实战评测（真实 CTF 题 re2.elf 的动态调试）暴露三个问题，全部有代码级根因：

| # | 现场现象 | 根因 | v2.1 解法 |
|---|---|---|---|
| 1 | `r3 open --debug` 失败只报 `r2 启动后未收到就绪 NUL`，真正病因（目标文件无执行权限 → r2 报 `Cannot open 'dbg://…' for writing`）埋在 daemon.log，agent 看不到 | R2Process 启动异常不携带 r2 stderr；r2 6.1.9 对该病因的报错文案本身还误导（"for writing"实际是 execv EACCES） | 报错富化：异常携带 r2 stderr 尾行 + debug 拉起预检（isfile/R_OK/X_OK，缺执行位直接说 `chmod +x`） |
| 2 | 模式切换失败报退出码 1，但 status 仍显示"调试模式: True"、会话带 [调试] 标签——账本与事实不符，agent 拿着假会话继续干活直到命令崩溃 | `open_file` 模式切换失败分支（L1126–1148）不回滚：旧 r2 已杀、`sess.debug` 已改成新值，异常返回后坏会话留在池里 | 失败回滚：模式改回旧值、`r2=None`、置"启动失败待重开"标记；后续命令走自动自愈重建；status 如实展示 |
| 3 | 交互式目标（游戏、密码输入等）在调试时喂不进 stdin，只能硬改内存/寄存器绕过 | 无输入注入通道（v2 只静音不捕获） | `--stdin <文件>`：dbg.profile `stdin=` 注入（实测可行），拉起时快照语义，换输入 = 重新 open |

设计基调与 v1/v2 一致：**调试命令依旧只是透传**，r3 只把"调试态"这个会话属性管对；
v2.1 新增的两样（预检、--stdin）也都落在"会话属性"上，不新增命令翻译层。

---

## 2. 决策表（硬约束）

| # | 决策 |
|---|---|
| 39 | **调试拉起报错富化**。R2Process 在 debug 启动失败（就绪 NUL 超时或进程提前退出）时，异常消息必须携带 r2 的 stderr 尾行（清洗鼠标禁用 CSI 序列后取末 500 字符；空则标"(空)"；进程已退出时附带退出码）。覆盖**所有**拉起路径：新建会话、模式切换、复用重建、看门狗自愈、daemon boot 恢复——这些路径的 `{e}` 插值自然透出，不改各自文案骨架。实现：drain 线程写入带锁 ring buffer（上限 4096 字节），异常构造时快照。 |
| 40 | **debug 拉起预检**。R2Process `__init__` 的 debug 分支在 Popen 之前按序预检：目标文件存在（isfile）→ 可读（R_OK）→ **可执行（X_OK）**；失败抛 RuntimeError，文案明确：目标文件不存在 / 不可读 / `目标文件无执行权限（mode %o）——chmod +x <文件> 后重试`。预检不替 agent 改文件权限。`stdin_file` 非 None 时**同时**预检输入文件（isfile + R_OK，文案 `输入文件不存在或不可读: <路径>`）。预检放在 R2Process 单点：所有拉起路径统一受益（含自愈/boot 重建时目标或输入文件已被删的场景）。open_file 里保留一次对 stdin_file 的提前校验（#42：避免白拉 r2），属 UX 层重复，语义与 R2Process 预检一致。static 分支不受影响。 |
| 41 | **模式切换失败回滚**。`open_file` 模式切换分支（L1126–1148）R2Process 构造抛异常时：`sess.debug` 回滚为旧值、`sess.r2 = None`、置 `sess.startup_failed = True` 并记 `fail_reason`；返回 `{"ok": False, "code": 1, "out": 富化消息 + "会话已回滚为原模式，下次命令/重开会自动重建"}`。该会话**留在池里**（保留 econf/分析痕迹），status/sessions 显示 `[启动失败待重开]`（文本）与 `"startup_failed": true`（JSON）。后续任何普通命令命中该会话（r2 为 None）→ 走现有 `_resp_r2_dead` 自愈路径按**旧模式**重建，重建成功即清 `startup_failed/fail_reason`；`open` 重建成功同样清标记。新建会话失败维持现状（删会话回滚）。`startup_failed` 不持久化进 state.json（daemon 重启后的 boot 恢复按"重建成功与否"自然决定会话去留）。 |
| 42 | **stdin 注入入口 `r3 open <文件> --debug --stdin <输入文件>`**。CLI：`--stdin` 仅可与 `--debug` 组合（否则用法错误 exit 1）；取值 = 其后一个参数，缺失同样用法错误 exit 1；发送 `req["stdin_file"]`（走 `normalize_target`，与 path 同规则：按调用方 cwd 解析）。daemon（open_file，仅 debug 分支）：对 stdin_file 做 realpath 后校验 `isfile + R_OK`，失败返回 code 1、文案 `输入文件不存在或不可读: <路径>`（不白拉 r2）。Session 加 `stdin_file` 字段；R2Process 加 `stdin_file` 参数，profile 内容按有无输入文件二选一：无 = 现状 `stdio=/dev/null\n`；有 = `stdin=<绝对路径>\nstdout=/dev/null\nstderr=/dev/null\n`（实测组合，见 §3.2.2）。state.json 增存 `stdin_file`（`_save_state_with_key`），`_boot_restore` 据此传参重建——自愈/daemon 重启后输入注入保持。open 成功输出注明 `输入文件: <路径>`（无则不注）。 |
| 43 | **同模式换输入 = 重新拉起（respawn）**。dbg.profile 只在拉起 debuggee 时读一次（P3 既有结论），且 stdin 是拉起时快照（§3.2.3：运行中向文件追加无效）。因此复用分支（`sess.debug == want_debug` 且 r2 存活）里，若 `want_debug and sess.stdin_file != 新 stdin_file`：杀旧 r2（killpg 连带 debuggee）→ 用新 stdin_file 重建 R2Process → `_restore_session_file` → 按 `sess.analyzed` 决定 `_debug_aaa`（debug 不落盘，重新拉起后现场分析，与 v2 复活语义一致）→ 输出注明 `已按新输入文件重新拉起目标（输入为拉起时快照）`。不带 `--stdin` 重新 open 已注入会话 = 新 stdin_file 为 None → 同样 respawn，回默认静音三件套（`stdio=/dev/null`）。static 会话忽略 stdin_file。 |
| 44 | **状态可见与交付物**。status/sessions 文本：有 `stdin_file` 的会话加 `[输入文件: <路径>]`；`startup_failed` 的会话加 `[启动失败待重开]`（两标记独立、可同现）。structured JSON sessions 项加 `"stdin_file"`、`"startup_failed"`（无则 null/false）。版本号 v2.1.0（L180 `R3_VERSION`）；help/status 展示同步。文档五处同步见 §4.7；验收见 §6（A2/W2 版本断言更新、F1/F4 修订、新增 Y 组）。 |

---

## 3. 现状与实测（直接采信）

### 3.1 代码现状（r3 单文件，2121 行，v2.0.0）

| 位置 | 现状 |
|---|---|
| L180 `R3_VERSION` | "2.0.0" |
| L459–605 `R2Process` | `__init__(debug, path)`；无 stdin_file；无预检；启动失败只抛 `RuntimeError("r2 启动后未收到就绪 NUL")`（L519）；stderr 由 drain 线程只写 daemon.log 不保留（L534–544） |
| L522–532 `_write_dbg_profile` | 固定写 `DBG_PROFILE_CONTENT`（`stdio=/dev/null\n`） |
| L607 `Session` | 无 stdin_file / startup_failed / fail_reason |
| L739–774 `_boot_restore` | `R2Process(debug=sess.debug, path=…)` 无 stdin_file；state.json 无 stdin_file |
| L884–889 `_save_state_with_key` | data 无 stdin_file |
| L1060–1231 `open_file` | L1119–1124 新建失败删会话；L1126–1148 模式切换失败**不回滚**（根因 #41）；L1149–1168 复用分支只按 `r2 is None or not alive()` 重建，无 stdin_file 感知；三处 R2Process 构造均无 stdin_file |
| L1359–1395 `_resp_r2_dead` | 重建 R2Process 无 stdin_file；重建失败消息 `{e}`（v2.1 起自动富化） |
| L1399 `status` / L1511 `list_sessions` | 无输入文件/待重开展示 |
| L2001–2029 CLI open 分支 | 只解析 `--no-analyze`/`--gitignore`/`--debug`，无 `--stdin`；req 无 stdin_file |
| L204–216 `USAGE` | open 用法行无 `--stdin` |

### 3.2 v2.1 实测结论（r2 6.1.9，WSL；本方案作者已实测复核，直接采信）

1. **目标文件无执行位 → r2 -d 必挂，且报错文案误导**。`r2 -q0 -d … <644 文件>` 时 r2 在
   stderr 报 `ERROR: Cannot open 'dbg://…' for writing` 并立即退出、不发就绪 NUL。
   实际病因是 io_debug 插件 `execv` debuggee 时 EACCES（无执行位），与"for writing"无关。
   同一 inode `chmod 755` 后立即正常（发就绪 NUL、目标停在初始断点）。→ 预检（#40）必要性实证。
2. **dbg.profile `stdin=` 指令可行，且可与 stdout/stderr 静音组合**。
   - 单行 `stdin=<文件>`：目标成功从文件读到输入（实测目标 exit 0x700 = 读到 '7'），
     但该单行下目标 stdout 会漏进 NUL 分帧流（v2 静音被绕过）。
   - 三行组合 `stdin=<文件>` + `stdout=/dev/null` + `stderr=/dev/null`：目标读到输入
     （exit 0x700），且 r3 侧分帧干净、目标输出不漏（实测 `dc` 输出为空、`dr rip` 正常分帧）。
   - v2 既有结论 `stdio=/path` spawn 失败不变；`stdio=/dev/null`（无空格）静音三件套不变。
3. **stdin 是拉起时快照，运行中追加无效**。rarun2 在拉起 debuggee 时打开 stdin 文件并
   一次性喂给子进程：实测以空文件拉起后每秒向文件追加一行，目标立即 EOF 退出、追加内容
   一行都没读到（目标零输出、exit 42）。→ "换输入 = 重新 open 重新拉起"（#43）的语义依据。
   附带推论：自愈/boot 重建时 debuggee 重新拉起、重新读同一 stdin 文件——输入天然重放，
   无需额外状态。
4. **富化素材位置**：r2 的真实错误与鼠标禁用 CSI 序列同走 stderr，当前 drain 线程只写
   daemon.log（L534–544）——ring buffer 就加在这个线程里（#39）。

### 3.3 探针复核结论（实现 agent 可快速复跑存档；与 §3.2 一致）

- **P6 执行位**：`cp` 任一 ELF → `chmod 644` → `r2 -q0 -d …` 报 Cannot open for writing；
  `chmod 755` 后同 inode 立即正常。预检 X_OK 能提前拦下。
- **P7 stdin 注入组合**：profile 三行版 `stdin=/tmp/in.txt` + `stdout=/dev/null` +
  `stderr=/dev/null` → `dc` 后目标读到文件内容、stdout 干净分帧（可用 3.2.2 的小目标复现）。
- **P8 快照语义**：空 stdin 文件拉起，spawn 后逐秒追加 → 目标立刻 EOF、追加不可见；
  换输入必须重新拉起。
- **P9 预检不误伤**：`os.access(path, os.X_OK)` 对 755 ELF / 带 shebang 脚本 / 无权限文件
  的判定与 execv 实际行为一致（脚本可执行位语义同 ELF）；预检只做 isfile/R_OK/X_OK 三查，
  不解析 ELF 头。

---

## 4. 设计

### 4.1 R2Process：stderr ring buffer + debug 预检 + 富化异常（#39/#40）

```python
STDERR_BUF_CAP = 4096          # ring buffer 上限（字节）
STDERR_TAIL_LEN = 500          # 异常里带的尾行长度（字符，清洗后）

_CSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")   # 剥鼠标禁用等 ANSI/CSI 序列

class R2Process:
    def __init__(self, debug=False, path=None, stdin_file=None):
        if debug:
            # #40 预检（Popen 之前；所有拉起路径统一受益）
            if not os.path.isfile(path):
                raise RuntimeError(f"目标文件不存在: {path}")
            if not os.access(path, os.R_OK):
                raise RuntimeError(f"目标文件不可读: {path}")
            if not os.access(path, os.X_OK):
                st = os.stat(path)
                raise RuntimeError(
                    f"目标文件无执行权限（mode {oct(st.st_mode & 0o777)}）"
                    f"——chmod +x {path} 后重试")
            if stdin_file and (not os.path.isfile(stdin_file)
                               or not os.access(stdin_file, os.R_OK)):
                raise RuntimeError(f"输入文件不存在或不可读: {stdin_file}")
        ...
        self._stderr_buf = bytearray()
        self._stderr_lock = threading.Lock()
        # drain 线程：除写 daemon.log 外，追加进 ring buffer（超上限丢最旧）
        # 就绪 NUL 超时/进程提前退出时的异常：
        #   tail = _sanitize(bytes(self._stderr_buf))[-STDERR_TAIL_LEN:] or "(空)"
        #   status = self.proc.poll()
        #   msg = f"r2 启动后未收到就绪 NUL（进程已退出，退出码 {status}）"  # 或"超时"
        #   msg += f"；r2 stderr 尾行: {tail}"
```

- `_sanitize`：先 `_CSI_RE.sub("", …)` 剥 CSI 序列，再连续空白折叠为单空格、strip。
- 三处 open 调用点与 `_resp_r2_dead` 的 `{e}` 插值不改文案骨架，自动获得富化效果；
  boot 恢复失败走 log（L762–764），log 同样富化。
- `stdin_file` 参数见 4.3；`_write_dbg_profile` 改为按 stdin_file 生成内容：

```python
def _dbg_profile_content(stdin_file):
    if stdin_file:
        return (f"stdin={stdin_file}\n"      # 实测组合（§3.2.2）；不能带空格
                "stdout=/dev/null\n"
                "stderr=/dev/null\n")
    return "stdio=/dev/null\n"              # 现状不变
```

### 4.2 open_file：模式切换失败回滚（#41）

L1126–1148 分支改造（顺序即语义）：

```python
elif sess.debug != want_debug:
    old_debug = sess.debug
    old_stdin = sess.stdin_file
    if sess.r2 is not None:
        try: sess.r2.kill()
        except Exception: pass
    sess.debug = want_debug
    sess.cur_file = path
    try:
        sess.r2 = R2Process(debug=want_debug,
                            path=path if want_debug else None,
                            stdin_file=stdin_file if want_debug else None)
    except (RuntimeError, ValueError) as e:
        # #41 回滚：账本回到旧模式，坏 r2 不留在会话里
        sess.debug = old_debug
        sess.stdin_file = old_stdin
        sess.r2 = None
        sess.startup_failed = True
        sess.fail_reason = str(e)
        return {"ok": False, "code": 1,
                "out": f"r2 模式切换启动失败: {e}\n"
                       "会话已回滚为原模式；下次命令或重新 open 会自动重建"
                       "（status 显示[启动失败待重开]）"}
```

- 新建会话失败分支（L1119–1124）维持删会话；其 R2Process 调用同样传 stdin_file。
- 复用分支重建（L1159–1163）与 `_resp_r2_dead`（L1367–1373）的 R2Process 调用传
  `stdin_file=sess.stdin_file if sess.debug else None`；重建成功处统一清
  `startup_failed/fail_reason`（写一个 `_mark_rebuilt(sess)` helper 或两处就地清，实现自定）。

### 4.3 --stdin 全链路（#42）

- **CLI**（L2001–2029）：解析规则——
  - `rest` 中含 `"--stdin"`：取其**后一个**元素为值；后无元素 → 打印用法行、exit 1。
  - 值拿到但 `--debug` 不在 → `--stdin 仅可与 --debug 一起使用` + 用法行、exit 1。
  - `req["stdin_file"] = normalize_target(值)`（不传时省略该键或 None）。
  - 用法行：`r3 open <文件路径> [--no-analyze] [--gitignore] [--debug [--stdin <输入文件>]]`。
- **daemon open_file**：函数签名加 `stdin_file=None`；仅 `want_debug` 时生效：
  - `stdin_file = os.path.realpath(stdin_file)`；校验 `isfile + R_OK`，失败返回
    `{"ok": False, "code": 1, "out": f"输入文件不存在或不可读: {stdin_file}"}`（在
    R2Process 构造之前，不白拉 r2）。
  - 成功后 `sess.stdin_file = stdin_file`；static 分支一律 `sess.stdin_file = None`。
  - 成功头部注明 `输入文件: <路径>`（有则），复用/切换/新建三条路都适用。
- **Session**：`self.stdin_file = None`、`self.startup_failed = False`、`self.fail_reason = None`。
- **state.json**：`_save_state_with_key` 的 data 加 `"stdin_file": sess.stdin_file`；
  `_boot_restore` 读 `st.get("stdin_file")` → `sess.stdin_file`，R2Process 传参
  `stdin_file=sess.stdin_file if sess.debug else None`（boot 恢复时输入文件已被删 →
  预检失败 → 走 L762–764 富化 log，会话不恢复——行为与目标文件被删一致，属预期）。
- **校验失败/预检失败的会话状态**：新建 → 删会话；切换 → #41 回滚；复用重建 → 会话
  留在池里且 startup_failed 置位（复用分支失败返回 code 1，置标记，与 #41 同文案风格，
  但不回滚模式——模式没变）。

### 4.4 同模式换输入 respawn（#43）

复用分支（L1149–1168）在"r2 存活"时加一个前置判定：

```python
respawn = (sess.r2 is not None and sess.r2.alive() and want_debug
           and sess.stdin_file != stdin_file)
if respawn:
    try: sess.r2.kill()          # killpg：旧 debuggee 一并清
    except Exception: pass
    sess.r2 = None
# 后续复用分支的"r2 is None or not alive()"重建逻辑自然接手：
#   R2Process(debug=want_debug, path=path,
#             stdin_file=stdin_file if want_debug else None)
#   + _restore_session_file + 按 sess.analyzed 决定 _debug_aaa
# notes 追加 "已按新输入文件重新拉起目标（输入为拉起时快照）"
```

- respawn 后 `sess.stdin_file = stdin_file`（由 open_file 统一赋值处落）。
- debug 会话 respawn 不 Po 不 Ps（沿用 #33），现场 aaa 按 `sess.analyzed`（不因 respawn 重置）。
- 无 `--stdin` 重新 open 注入会话 → `stdin_file=None` ≠ 旧值 → respawn 回默认静音；输出
  注明"已重新拉起目标（回默认静音，无输入文件）"或类似文案（实现自定，验收断言关键词"重新拉起"）。

### 4.5 状态展示（#44）

- status() 会话行与 list_sessions() 文本行：`[调试]` 之后按需追加
  `[输入文件: <路径>]`、`[启动失败待重开]`（无则缺省）。
- structured sessions 项加 `"stdin_file": s.stdin_file`、`"startup_failed": bool(s.startup_failed)`。
- status 当前会话块：`startup_failed` 时在"调试模式"行后追加一行
  `启动失败待重开 : True（上次拉起失败；下次命令或重新 open 会自动重建）`。
- 文案关键词"输入文件""待重开"供验收断言，细节实现自定。

### 4.6 版本号（#44）

- L180 `R3_VERSION = "2.1.0"`；文件头注释追加 v2.1 结论存档（§3.2 四条 + 探针 P6–P9 +
  #39–#44 要点）。

### 4.7 文档五处同步（#44）

1. **AGENTS.md**：命令表 `--debug` 行加 `--stdin <输入文件>`；「agent 必知」调试条扩：
   - open --debug 失败时看报错里的 `r2 stderr 尾行`（真实病因）与预检提示
     （目标无执行权限会直接说 `chmod +x`）；
   - 模式切换失败会回滚为原模式并标 `[启动失败待重开]`，**普通命令会自动重建，无需手动处理**；
   - `--stdin` 仅与 `--debug` 组合、输入为拉起时快照（运行中追加无效）、换输入 = 重新
     `r3 open --debug --stdin 新文件`（会重新拉起目标）；
   - status/sessions 显示 `[输入文件]`/`[启动失败待重开]`。
   版本号 v2.1.0。
2. **r3 内 USAGE**（L204–216）：open 用法行加 `[--stdin <输入文件>]`；说明段加调试输入
   注入与排错两句；版本号随 R3_VERSION。
3. **DESIGN.md**：§3.2 传声筒注补"报错富化不违背透传（不改 r2 输出，只把 r2 stderr 尾行
   附在 r3 自己的错误消息里）"；§7 补 v2.1 边界（预检不代改权限、--stdin 快照语义、
   换输入=重新拉起、切换失败回滚+待重开+自动自愈）；新增"v2.1 修复与输入注入"节简述
   #39–#44 理念（大白话风格，保持文档口吻）。
4. **SKILL.md**（`/home/jin/.dsh/skills/r3/SKILL.md`）：版本 v2.1.0；description 触发词加
   `--stdin`、输入文件、待重开、chmod；「动态调试工作流」段加
   `r3 open ./crackme --debug --stdin ./input.txt` 示例与"换输入=重新 open"；「必知」排错加：
   启动失败看报错里 r2 stderr 尾行、无执行权限 `chmod +x`、status 的 `[启动失败待重开]`
   会自动自愈。
5. **tests/acceptance.sh**：A2/W2 版本断言 2.0.0 → 2.1.0；F1 交付物清单加 PLAN-v2.1.md；
   F4 在 v2 标记之外追加 v2.1 实现标记断言（`stdin_file`、`X_OK`、`startup_failed`、
   `_dbg_profile_content`、`STDERR_TAIL_LEN` 均可 grep 到）；新增 Y 组（§6）。

---

## 5. 代码改动点清单（r3 单文件）

| 位置 | 改动 |
|---|---|
| L180 `R3_VERSION` | → "2.1.0"（#44） |
| 新增常量 | `STDERR_BUF_CAP` / `STDERR_TAIL_LEN` / `_CSI_RE`（#39） |
| L459–605 `R2Process` | `__init__` 加 stdin_file；debug 预检（#40）；stderr ring buffer + drain 线程写入；就绪失败富化异常（#39）；`_write_dbg_profile` → `_dbg_profile_content(stdin_file)`（#42） |
| L607 `Session` | 加 `stdin_file` / `startup_failed` / `fail_reason`（#41/#42） |
| L739–774 `_boot_restore` | 读/传 stdin_file（#42）；失败 log 自动富化 |
| L884–889 `_save_state_with_key` | data 加 stdin_file（#42） |
| L1060–1231 `open_file` | 签名加 stdin_file；debug 分支输入文件校验（#42）；三处 R2Process 传 stdin_file；模式切换失败回滚（#41）；复用分支 respawn 判定（#43）；成功输出注明输入文件/重新拉起 |
| L1359–1395 `_resp_r2_dead` | R2Process 传 stdin_file（#42）；重建成功清 startup_failed/fail_reason（#41） |
| L1399 `status` / L1511 `list_sessions` | `[输入文件]`/`[启动失败待重开]` 文本 + JSON 字段（#44） |
| L2001–2029 CLI open 分支 | 解析 `--stdin`、组合校验、req["stdin_file"]、用法行（#42） |
| L204–216 `USAGE` | open 用法行与排错说明（#44） |
| 文件头注释 | v2.1 结论存档（§3.2 + P6–P9 + #39–#44） |

AGENTS.md / DESIGN.md / SKILL.md / acceptance.sh 按 §4.7 同步。

---

## 6. 验收标准

沿用脚本隔离要求（顶部 export R3_CACHE_DIR/R3_SOCK_PATH 到 mktemp -d；先 r3 kill 再清缓存）。
A–X 既有语义保持，**旧验收修订**三处：
- **A2/W2 版本断言**：grep "v2.0.0" → "v2.1.0"（r3 help 与 status 文本、status --json 的 r3_version）。
- **F1**：交付物清单加 PLAN-v2.1.md。
- **F4**：v2 标记（`DBG_PROFILE_CONTENT`、`start_new_session`、`os.killpg`、`--debug`、
  `OpenMode.DEBUG`）之外追加 v2.1 标记（`stdin_file`、`X_OK`、`startup_failed`、
  `_dbg_profile_content`、`STDERR_TAIL_LEN`）。

新增 **Y 组（v2.1.0：报错富化/回滚/输入注入）**：

- **Y0 环境前置**：同 X0 隔离与清理；gcc 缺失 → 整组 SKIP。目标 `$TEST_TMP/dbg/dbg_in`
  （`gcc -O0 -no-pie`，-no-pie 保证 `sym.buf`/`sym.mark_after_input` 地址稳定）：

```c
#include <stdio.h>
#include <unistd.h>
char buf[64];
void mark_after_input(void) {}
int main(void) {
    printf("STDIN_MARKER\n"); fflush(stdout);
    if (!fgets(buf, sizeof buf, stdin)) return 99;
    mark_after_input();
    sleep(3);
    return 42;
}
```

- **Y1 预检 + 报错富化**：`chmod 644 $DBG` → `r3 open $DBG --debug` 退出码 1、输出含
  `执行权限` 与 `chmod`；`r3 status --json` 该文件不在 sessions（新建失败即删）。
  `chmod 755 $DBG` 恢复。
- **Y2 切换失败回滚 + 待重开 + 自动自愈**：`r3 open $DBG`（static，成功）→ `chmod 644`
  → `r3 open $DBG --debug` 退出码 1 → `r3 status` **不含**"调试"、会话行含 `待重开`；
  → `r3 "i~file"` 退出码 0（普通命令触发自愈按旧模式重建）→ `r3 status` 待重开标记消失、
  仍不含"调试"；→ `chmod 755` → `r3 open $DBG --debug` 退出码 0、status 含"调试"。
- **Y3 --stdin 喂入 + 静音保持**：`printf 'HELLO123\n' > $IN` → `r3 open $DBG --debug
  --stdin $IN` 退出码 0、输出含 `输入文件`；`r3 "db sym.mark_after_input"` → `r3 "dc"`
  输出**不含** STDIN_MARKER；`r3 "ps @ sym.buf"` 含 HELLO123；`r3 status` 会话行含
  `[输入文件: $IN]`。
- **Y4 用法校验**：`r3 open $DBG --stdin $IN`（无 --debug）退出码 1、输出含"用法"；
  `r3 open $DBG --debug --stdin`（无值）退出码 1、输出含"用法"。
- **Y5 输入文件校验**：`r3 open $DBG --debug --stdin $TEST_TMP/nonexistent` 退出码 1、
  输出含 `输入文件`；status 会话不带输入文件标记。
- **Y6 换输入 respawn**：`r3 open $DBG --debug --stdin $IN1` → `P1=$(r3 "dp" | awk '{print $2}')`
  → `r3 open $DBG --debug --stdin $IN2`（输出含 `重新拉起`）→ `P2` 有值且 != P1 →
  `r3 "db sym.mark_after_input"` → `r3 "dc"` → `r3 "ps @ sym.buf"` 含 IN2 内容；
  → `r3 open $DBG --debug`（不带 --stdin）→ `P3` != P2、status 无 `[输入文件`。
- **Y7 自愈保持输入注入**：`r3 open $DBG --debug --stdin $IN` → `R3_CMD_TIMEOUT=1 r3 "dc"`
  退出码 3 → `r3 status` 含"调试"与 `[输入文件: $IN]` → `r3 "db sym.mark_after_input"`
  → `r3 "dc"` → `r3 "ps @ sym.buf"` 含 IN 内容（自愈重建后重新拉起、重读同一输入文件）。
- **Y8 文档断言**：AGENTS.md 与 SKILL.md 均含 `--stdin`、`chmod`、`待重开`；
  静态断言 r3 help 用法行含 `--stdin`。

---

## 7. 已知风险（本次不修）

- **stdin 快照语义**：运行中向输入文件追加内容无效（§3.2.3），"边跑边喂"需多次
  `r3 open --debug --stdin 新文件`（每次重新拉起目标、现场 aaa）——文档写明，不实现
  运行中追加（rarun2 层不支持，绕过需自研管道，超出范围护栏）。
- **自愈/boot 重建时输入文件已删**：预检失败 → 重建失败 → 富化报错 + 待重开标记；
  agent 重新 open 指定新输入文件即恢复。属预期行为，文档写明。
- 富化尾行只带 r2 stderr 末 500 字符：极端长噪音可能截掉真实病因行（mouse CSI 已清洗，
  剩余多为 WARN/ERROR，500 字符足够覆盖），不回滚整段日志。
- 预检只查 isfile/R_OK/X_OK：不解析 ELF 头，"可执行但不是 ELF/是损坏文件"仍由 r2 原话
  兜底（富化报错会带上）。
- 既有风险不变：目标自行 setsid 改进程组 killpg 可能漏杀；沙箱 landlock 继承给 debuggee；
  attach 受 yama 限制；socket 无鉴权（低危）；debug 会话分析不落盘。

---

## 8. 实现顺序建议

先快速复跑探针 P6–P9 存档（§3.3 已有结论，不一致才停下问）；再搭 Y 组骨架（全红）随实现变绿：

1. 复跑/存档探针 P6–P9。
2. **#39/#40 R2Process 富化 + 预检** → Y1 随其自然绿。
3. **#41 切换失败回滚 + 待重开展示 + 自愈清标记** → Y2 绿。
4. **#42/#43 --stdin 全链路 + respawn** → Y3/Y4/Y5/Y6/Y7 绿。
5. **#44 展示/版本/文档五处同步** → Y8、A2/W2/F1/F4 修订绿。
6. 全量回归 A–Y 全绿（重点：X 组 v2 调试语义不回归，尤其 X4 静音与 X5 清理）。

（全文完）
