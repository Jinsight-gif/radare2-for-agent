# r3 v1.3 开发方案 —— 上下文可信性加固（goal 模式）

> 本文是 v1.3 的定稿开发规格，在 v1.2（`PLAN-v1.2.md`）之上增量修订。
> v1.2 决策（#15–#22）、v1.1 决策（#9–#14）与 v1 决策（#1–#8）继续有效，本文只追加、修订。
> 实现 agent 按本文档直接实现，无需再做架构决策。
> 配套：`DESIGN.md`、`PLAN.md`（v1）、`PLAN-v1.1.md`（v1.1）、`PLAN-v1.2.md`（v1.2）。

---

## 0. Goal 模式执行须知

**目标**：交付 r3 v1.3，解决评测缺陷 ①–⑥（"边界场景下静默拿错上下文"六连）与
易用性/文档建议 ⑦–⑨。完成定义 = `bash tests/acceptance.sh`（仓库根、WSL bash）退出码 0。

**执行环境**（同 v1.2 §0）：WSL 原生文件系统；r2 6.1.9 `/usr/local/bin/r2`；Python 3.12.3；
`r3` 部署 `~/.local/bin/r3`。宿主环境每次 bash 调用可能带 `landlock-run: partial enforcement
(older Landlock ABI)` stderr 警告——**非 r3 输出，忽略即可**（决策 #30 写入文档）。

**规则**：
1. 本文档是唯一需求来源，自足。
2. §2 决策表是硬约束，不得重设计、不得扩范围。
3. 事实类出入以实测为准并写进代码注释；架构级分歧停下问用户。
4. 范围护栏：只用 Python 3 标准库；不 fork/不修改 r2；不做 TCP；不做动态调试。
5. §3 现状/根因是实测结论，直接采信，不重探；矛盾时以实测为准并更新注释。

---

## 1. 背景：v1.2 评测缺陷清单

评测总评 9/10。剩余问题的共性：**不是崩溃，而是边界场景下静默拿错上下文**——正是 agent
最怕的一类错误。优先级 ①→②→③→④→⑤→⑥，⑦⑧⑨ 为低成本易用性/文档项。

| # | 缺陷 | 定性 | 处理 |
|---|---|---|---|
| ① | `--session` 相对路径按 daemon 的 cwd 解析而非调用方 cwd；裸别名被 daemon abspath 成精确路径命中，歧义冲突被静默吞掉；同一命令换发起目录行为不同。`open <相对路径>` 同族（同一根因） | 正确性（静默拿错上下文） | 修（#23） |
| ② | 已关闭会话的完整路径静默回落同 basename 会话：`close /x/conflict_test/re2.elf` 后 `--session /x/conflict_test/re2.elf "afl"` 不报"会话不存在"，而是绑定到另一同名文件会话 | 正确性（静默拿错上下文） | 修（#23） |
| ③ | 缓存键 = SHA-256(内容)+r2 版本，不含路径：同内容不同路径的副本二进制互踩工程缓存，reopen 报"缓存校验失败，已回退为重新打开，未分析"（CTF 拷贝同一道题常见） | 正确性/缓存 | 修（#24） |
| ④ | 看门狗超时杀 r2 自愈后该会话 `e` 配置回默认：配置常驻只跨 open 切换，不跨 r2 重启，与"配置按文件常驻"有落差 | 一致性 | 修（#25） |
| ⑤ | restart 在沙箱下恢复失效：启动时锚点未知 → 回退链只到 XDG → 内存，state.json 读不到，重启后 sessions 为空（skill 未提此沙箱失效）；正常环境也只重建 last_file 一个会话 | 健壮性/沙箱 | 修（#26） |
| ⑥ | close 当前会话后裸命令静默空转：`r3 "afl~main"` 落到无文件 r2，空输出 exit 0，agent 会把"空"误读为"查询无结果" | 正确性（空 ≠ 无结果） | 修（#27） |
| ⑦ | open 缺文件元信息速览：需另跑 `file` 才知道 PIE/stripped/动态链接 | 易用性 | 修（#28） |
| ⑧ | `.r3cache/` 污染目标目录：只会"提醒"加 .gitignore，不会"动手" | 易用性 | 修（#29） |
| ⑨ | AGENTS.md 略重（"必知"7 条 + 命令表 + 缓存章节）；landlock stderr 噪声未记载 | 文档 | 修（#30） |

另记（非 r3 缺陷，不改代码）：r2 的 `~` 过滤对 `izzj` 这类 JSON 输出是"整行匹配、全有或全无"，
文档继续引导"--json 全量 + 本地过滤"的正确姿势即可。

---

## 2. 决策表（硬约束）

| # | 决策 |
|---|---|
| 23 | **`--session`/`open` 路径解释权归调用方**。CLI 发送前把"路径样目标"（绝对路径，或含路径分隔符的相对路径）按**调用方 cwd** 展开为绝对 realpath；纯裸名（不含分隔符）原样发送作 basename 别名。daemon 侧删除对目标的 `abspath`（daemon cwd 不再参与任何解析）；绝对路径精确匹配未命中**直接报错，不回退 basename**；含分隔符的非绝对目标（旧客户端可能发送）报错提示改用绝对路径；仅纯裸名做 basename 模糊匹配（冲突报错列候选，保持 v1.2 语义）。`open <路径>` 同样在 CLI 侧按调用方 cwd 绝对化后发送。 |
| 24 | **缓存键加 realpath 维**：`key = sha256(内容) + sha256(realpath(路径))[:12] + r2 版本`；meta 缓存命中条件追加 `meta.path == realpath` 校验。同内容不同路径各用各的缓存（**放弃跨路径去重**，磁盘占用按副本数增长，属预期代价）。v1.2 旧键缓存自然作废：不匹配新键即未命中重分析，永不误用。 |
| 25 | **e 配置按文件常驻**。透传旁路记录 agent 的 `e <名>=<值>` 命令（只旁路识别、不解析不改写命令与输出，传声筒透明性不变），按名去重存到会话。磁盘缓存模式下落盘 `<cache_dir>/econf/<sid>.json`（含 file 归属字段），会话 r2 每次新建/复活后重放（open 新建、复用前复活、看门狗自愈、boot 恢复、缓存命中 Po 后）；纯内存模式只记会话内存（close 即失，文档注明）。`cache_clean` 连带清理 econf/。 |
| 26 | **`r3 restart` 传递生效缓存目录**。restart 前先 `status --json` 取 `cache.path`（磁盘模式），杀 daemon 后以 `R3_CACHE_DIR=<旧路径>` 拉起新 daemon——锚定 .r3cache 档时 state.json 立即可读、boot 恢复生效（修沙箱失效）。内存模式无路径可传，维持现状。kill 后任意调用仍找不回锚点（锚点只存于旧缓存目录内），文档注明边界：沙箱下会话恢复走 `r3 restart`。 |
| 27 | **无当前会话报错，退出码 5**。pass 无活跃会话（close 当前会话后、冷启动无 state）不再懒建无文件会话空转，返回 `{"ok":false,"code":5,"error":"no_active_session","out":"无当前会话：请先 r3 open <文件> 或 r3 --session <目标> 指定会话"}`；CLI 透传退出码 5；`--json` 时以结构化错误回执输出（error 字段自然携带）。删除 `_active` 懒建无文件会话（`FILELESS_SID` 兼容判断保留）。 |
| 28 | **open 输出追加一行文件信息速览**。daemon 在成功打开后发一条 `iIj` 解析，追加一行摘要（arch、bits、PIE、canary、NX、stripped、静态/动态链接、大小）；`iIj` 失败/超时省略该行，不影响 open 成功与否。 |
| 29 | **`r3 open <文件> --gitignore`**。仅当生效缓存档为 `.r3cache` 时执行：自文件所在目录向上逐级查找 `.git`（目录或文件均可，兼容 worktree）；命中则向**文件所在目录**的 `.gitignore` 幂等追加一行 `.r3cache/`（已含则不追加；文件不存在则创建），输出提示；未检测到仓库或缓存未落在 .r3cache 档时输出说明，不追加、不报错。 |
| 30 | **AGENTS.md 重排与同步**：快速上手提前；「agent 必知」压缩为短句；缓存细节（回退链/写探针/meta/econf）折叠到附录；新增「环境噪声」条目（landlock 警告为宿主 WSL 沙箱层 stderr，非 r3 输出，agent 解析管道时忽略）；同步 v1.3 全部行为变化（--session 路径规则、退出码 5、open 速览行、--gitignore、缓存键含路径维、restart 沙箱边界）。 |

---

## 3. 现状与根因（实测结论，直接采信）

### 3.1 路径解释权在 daemon cwd（问题 ①②）

- CLI 对 `--session <目标>` 不加工：目标串原样放进请求 `sid` 字段（L1520–1521）；
  `close [目标]` 同样原样传（L1497–1499）；`open` 的路径也原样传（L1455）。
- daemon `_resolve_sid`（L511–530）在 L516 用 `os.path.abspath()` 把相对目标按
  **daemon 进程 cwd** 展开（daemon cwd = 首次拉起它的 CLI 的 cwd，之后固定）。
  → 从 /tmp 发裸别名 `re2.elf`，daemon cwd=/home/jin/work 时被 abspath 成
  /home/jin/work/re2.elf **精确命中**该会话，同 basename 冲突被静默吞掉；换 cwd 重启
  daemon 后才报"basename 冲突，候选: ..."。同一命令换发起目录，行为不同。
- 精确路径未命中后**无条件**落 basename 匹配（L521–524）：close 掉
  /x/conflict_test/re2.elf 后 `--session /x/conflict_test/re2.elf "afl"` 精确未中 →
  basename 撞到另一同名会话 → 静默绑定错会话（问题 ②）。
- `open_file` L703 同样用 daemon cwd abspath 相对路径（问题 ① 同族：`r3 open re2.elf`
  打开的是 daemon cwd 下的文件，不是调用方 cwd 下的）。

### 3.2 缓存键无路径维（问题 ③）

- `cache_key`（L284–286）= `file_sha256(path) + "-" + version_slug(version)`，不含路径。
- meta 归属校验只比内容 sha256（缓存命中条件 L781–782 只查 `meta.sha256 == sha`；
  meta 里**已经存了 path 字段**（`_write_meta` L644），但从未用于校验）。
- 同内容副本 A、B 共用 `projects/<key>`：r2 工程内记录了保存时打开的文件，
  B 的 open 走 `Po` 恢复后 `verify_current_file`（L788）对不上 → L798–800 报
  "缓存校验失败，已回退为重新打开，未分析"，且每次 open B 都重复 Po+verify 弯路，
  B 的缓存永远不可用。

### 3.3 e 配置只随 r2 进程存活（问题 ④）

- `Session` 文档注释 L398："e 配置随 r2 进程自然存活（r2 不重启配置就不丢），不单独存"。
- 看门狗自愈 `_resp_r2_dead`（L880–906）：杀 r2 → `R2Process()` 全新出厂配置 →
  `_restore_session_file`（L565–604）只做 `Po`/`o` + `e scr.pager=cat`，**不恢复任何
  agent 设过的 e 配置**。boot 恢复（L537–563）、复用前复活（L743–757）同样不恢复。

### 3.4 restart 锚点丢失（问题 ⑤）

- daemon 启动时 `anchor_dir=None` → `_resolve_cache`（L436、L445–453）只解析两级链
  （R3_CACHE_DIR → XDG）；沙箱下 XDG 不可写 → `cache_dir=None` → 内存模式。
- `_boot_restore`（L544–545）内存模式直接 return → 重启后 sessions 为空。
  .r3cache 档的锚点 = 首次 open 文件的 dirname(realpath)（L713–716），锚点信息只存在于
  旧缓存目录内的 state.json——新 daemon 不知道去哪找。
- 正常环境 `_boot_restore` 也只重建 last_file 一个会话（L537–543 注释写明），其余靠
  下次 open 缓存重建——该语义保留（#26 不扩大）。

### 3.5 无当前会话静默空转（问题 ⑥）

- `dispatch` pass 分支（L1202–1216）：sid 解析落空（active_sid=None，如 close 当前会话
  后 L1056–1057 置 None；或冷启动无 state）→ `self.sessions.get(None)` 为 None →
  `self._active()`（L472–490）懒建一个无文件会话（v1.1"daemon 总有一个 r2 可用"语义）→
  命令发给未开文件的 r2 → 空输出、code 0。
- 现状验收依赖：B2（acceptance.sh L99–104）用"未 open 先跑 `r3 "?t"`"验证懒启动——
  #27 修法会把它变成退出码 5，**旧验收需修订**（见 §6）。

### 3.6 易用性与文档（问题 ⑦⑧⑨）

- `open_file` 所有成功返回只报"已打开/耗时/缓存状态"，无文件元信息（⑦）。
- .r3cache 档只输出提醒（L721–726），不提供任何自动动作（⑧）。
- AGENTS.md 结构：必知 7 条 + 命令表 + 缓存章节全平铺；无 landlock 噪声记载（⑨）。
- `status --json` 已带 `cache.path`/`cache.mode`（L939–959），#26 可直接复用。

---

## 4. 设计

### 4.1 路径解释权归调用方（#23）

**CLI 新增规范化函数**（透传/close/open 共用）：

```python
def normalize_target(t):
    """调用方 cwd 语义：路径样目标绝对化；纯裸名保留作 basename 别名。"""
    t = os.path.expanduser(t)
    if os.path.isabs(t):
        return os.path.realpath(t)
    if "/" in t:                      # 含分隔符 = 路径样，按调用方 cwd 解释
        return os.path.realpath(os.path.abspath(t))
    return t                          # 裸名：原样发送，daemon 当别名
```

- 应用到：`--session <目标>`（L1520–1521）、`close [目标]`（L1497–1499）、
  `open <路径>`（L1455，用 `realpath(abspath(expanduser(p)))`）。
- `os.path.realpath` 不要求文件存在，daemon 侧的存在性检查（L705）不受影响。

**daemon `_resolve_sid` 改写**（L511–530）：

```python
def _resolve_sid(self, target):
    if target in self.sessions:                     # ① sid 直接命中（保持）
        return target, None
    if os.path.isabs(target):                       # ② 绝对路径：精确匹配，未中即错，不回退
        rp = os.path.realpath(target)
        hits = [s for s in self.sessions.values()
                if s.cur_file and s.cur_file == rp]
        if len(hits) == 1:
            return hits[0].sid, None
        return None, f"会话 '{target}' 不存在（r3 sessions 查看已开会话）"
    if "/" in target:                               # ③ 含分隔符但非绝对（旧客户端）：
        return None, (f"会话目标 '{target}' 请使用绝对路径（v1.3 起相对路径由调用方解析）")  # 安全失败
    base = target                                   # ④ 纯裸名：basename 模糊匹配（保持 v1.2）
    hits = [s for s in self.sessions.values()
            if s.cur_file and os.path.basename(s.cur_file) == base]
    if len(hits) == 1:
        return hits[0].sid, None
    if len(hits) > 1:
        return None, (f"会话目标 '{target}' 有歧义（basename 冲突），"
                      "候选: " + ", ".join(s.cur_file for s in hits))
    return None, f"会话 '{target}' 不存在（r3 sessions 查看已开会话）"
```

**要点**：
- daemon cwd 不再参与任何目标解析（删除原 L516 的 abspath）。
- 路径样目标精确未命中**一律报错**（修问题 ②）；含分隔符的相对目标直接报错提示
  （旧客户端安全失败，绝不按 daemon cwd 猜）。
- basename 匹配只保留给纯裸名；歧义报错列候选保持 v1.2 行为（修问题 ① 的"静默吞歧义"）。
- `open_file` L703 的 daemon 侧 abspath 保留作纵深防御（CLI 已发绝对路径，abspath 无副作用）。
- `close_session` 复用 `_resolve_sid`，自动获得相同语义。

**兼容性**：v1.3 CLI 行为变化 —— 裸名仍是别名（向后兼容）；相对路径带斜杠从
"按 daemon cwd 猜"变为"按调用方 cwd"（正确行为）；旧客户端发送的相对路径带斜杠目标
改为报错（安全方向）。AGENTS.md 同步说明。

### 4.2 缓存键加 realpath 维（#24）

- `cache_key(path, version)`（L284–286）改为：

```python
def cache_key(path, version):
    rp = os.path.realpath(os.path.abspath(os.path.expanduser(path)))
    return (file_sha256(path) + "-" + hashlib.sha256(rp.encode("utf-8")).hexdigest()[:12]
            + "-" + version_slug(version))
```

- 缓存命中条件（open_file L781–782 与 `_restore_session_file` L583–584）追加
  `meta.get("path") == path`（path 为 open 时 realpath 化的值；meta 已存 path 字段，
  `_write_meta` L644 不用改）。
- `_restore_session_file` L576 手算 key 改为直接调 `cache_key(path, self.version)`；
  state.json 里 v1.3 起存新格式 key，旧 state 的 key 不匹配时走 L575–576 重算兜底。
- 语义变化与代价（写进 AGENTS.md 缓存章节）：同内容多副本不再共享缓存，每副本独立
  分析、独立落盘；v1.2 旧格式缓存成为孤儿（不误用；`r3 cache-clean` 可清）。

### 4.3 e 配置按文件常驻与重放（#25）

**记录（旁路，不改写命令与输出）**：`passthrough`（L1103–1123）开头加：

```python
first = command.strip().split()[0] if command.strip() else ""
if first == "e" and "=" in command.split(None, 1)[1] if len(command.split(None, 1)) > 1 else False:
    name = command.split(None, 2)[1].split("=", 1)[0]
    sess.e_cmds[name] = command        # 按名去重，后设覆盖
    self._save_econf(sess)             # 磁盘模式落盘；内存模式 no-op
```

> 只识别「首 token 为 `e` 且其后含 `=`」的命令原样入表；不解析语义、不改输出——透明性不变。

**存储**：`Session.e_cmds: dict[name, cmd]`（L395–411 加字段，初始 `{}`）。
磁盘模式（`self.cache_dir` 非 None 且非 memory_mode）写
`<cache_dir>/econf/<sid>.json`：`{"file": sess.cur_file, "cmds": [按插入序]}`，
tmp+rename 原子写，OSError 静默 log（不打断命令）。

**重放**：新 helper `_apply_econf(sess)`——`sess.cur_file` 为 None 跳过；磁盘模式读
econf 文件（缺失/损坏 → 跳过），校验 `file` 字段 == `sess.cur_file` 才重放（防脏）；
内存模式用 `sess.e_cmds`。逐条 `sess.r2.cmd(cmd, 10)`，失败仅 log（重放失败不致命）。

**调用点**（会话 r2 每次新建/复活后，且在文件打开 + `e scr.pager=cat` 之后，保证
`o`/`Po` 重置 pager 的行为不会覆盖用户配置）：
1. `_restore_session_file` 末尾（L604 前）——覆盖 boot 恢复、看门狗自愈、复用前复活；
2. open_file 全新会话 `o` + verify 成功后（L825 后，分析前）——覆盖首次 open 后
   （首次通常无配置，读磁盘 econf 兜底 close 后重开的场景）；
3. open_file 缓存命中 `Po` + verify 成功后（L801 前）；
4. open_file 校验失败回退重开后（L794 前）。

**清理**：`cache_clean`（L1064–1099）加删 `econf/` 目录（连同 state.json 语义
"清除全部会话状态"）。close 不删 econf（配置按文件常驻，重开恢复）。

**边界（文档注明）**：纯内存模式 econf 不落盘，close/daemon 重启即失（会话内存仍覆盖
看门狗自愈）；LRU 淘汰会话后配置仍在磁盘，重开恢复。

### 4.4 restart 传递生效缓存目录（#26）

CLI `restart` 分支（L1429–1443）改写：

```python
old_path = None
try:
    r = talk({"action": "status", "json": True}, allow_spawn=False)
    if r.get("ok") and r.get("cache", {}).get("mode") == "disk":
        old_path = r["cache"].get("path")
except R3ConnError:
    pass                            # daemon 未在运行，无旧路径可问
try:
    talk({"action": "die"}, allow_spawn=False)
except R3ConnError:
    print("daemon 原本未在运行")
# 等 socket 消失（现有轮询保留）
if old_path:
    os.environ["R3_CACHE_DIR"] = old_path   # 仅影响本 CLI 进程与其 spawn 的子 daemon
talk({"action": "status"})          # 触发懒启动
```

- `spawn_daemon`（L1323–1356）的 `Popen` 继承 CLI 进程环境（L1345–1348），daemon 在
  import 时读 `R3_CACHE_DIR`（L111）→ 新 daemon 第一级回退链即命中旧路径（含 .r3cache 档），
  写探针通过（该目录此前已被探针验证过可写）→ state.json 可读 → `_boot_restore` 恢复
  last_file 会话。restart 输出追加一行"已沿用缓存目录 <path> 重启"。
- 内存模式：`old_path` 为 None，维持现状（重启后会话空是纯内存固有语义）。
- **边界（文档注明，不修）**：`r3 kill` 后任意调用（非 restart）无法得知旧缓存目录
  （锚点只存于旧缓存目录内的 state.json，无全局 locator）；沙箱下恢复会话走 `r3 restart`。
  `_boot_restore` 仍只重建 last_file 一个会话（语义不变，其余下次 open 缓存重建）。

### 4.5 无当前会话报错与退出码 5（#27）

`dispatch` pass 分支（L1202–1216）改写：

```python
sid = req.get("sid")
if sid and sid != FILELESS_SID:
    sid, err = self._resolve_sid(sid)
    if err:
        return {"ok": False, "code": 1, "out": err, "error": "session_not_found"}
else:
    sid = self.active_sid
sess = self.sessions.get(sid) if sid else None
if sess is None:
    return {"ok": False, "code": 5, "error": "no_active_session",
            "out": "无当前会话：请先 r3 open <文件> 或 r3 --session <目标> 指定会话"
                   "（r3 sessions 查看已开会话）"}
```

- 删除 `_active()`（L472–490）及其唯一调用点；`FILELESS_SID` 常量保留（旧客户端
  硬编码 sid="default" 的落回判断，L1203）。
- CLI 透传分支 `return resp.get("code", 1)`（L1551）自然透传 5；`--json` 错误回执
  （L1536–1546）走 `resp.get("error")` → 输出 `{"ok":false,"error":"no_active_session",...}`。
- 退出码表更新：0 成功 / 1 连接或 daemon 故障 / 2 黑名单拒绝 / 3 超时 / 4 截断 /
  **5 无当前会话**。USAGE（L155）与 AGENTS.md 同步。
- v1.1"daemon 总有一个 r2 可用"语义废除：无会话时查 r2 版本等信息用 `r3 status`
  （文档注明）。

### 4.6 open 文件信息速览行（#28）

新 helper：

```python
def info_summary_line(sess):
    """iIj 摘要一行；失败/超时返回 None（不报错）。"""
    out, timed_out = sess.r2.cmd("iIj", 10)
    if timed_out or out is None:
        return None
    try:
        d = json.loads(out.decode("utf-8", "replace"))
        if not isinstance(d, dict):
            return None
    except ValueError:
        return None
    parts = [f"arch={d.get('arch') or '?'}",
             f"{d.get('bits')}-bit" if d.get("bits") else ""]
    if d.get("pic"): parts.append("PIE")
    if d.get("canary"): parts.append("canary")
    if d.get("nx"): parts.append("NX")
    parts.append("stripped" if d.get("stripped") else "未stripped")
    parts.append("静态链接" if d.get("static") else "动态链接")
    if d.get("binsz"):
        parts.append(f"{d['binsz']/1024:.1f} KB")
    return "文件信息: " + ", ".join(p for p in parts if p)
```

- 调用点：`open_file` **每个成功返回路径**（复用秒开 L764、缓存命中 L805、校验失败
  回退重开 L798、全新分析完成 L878、--no-analyze L867 分支）输出末尾追加该行；
  None 则省略。复用秒开路径多一条 iIj（~数十 ms，秒开承诺不受实质影响）。
- 注意 `iIj` 在 `o` 打开后即可用，不依赖 `aaa`；`--no-analyze` 同样出该行。

### 4.7 `r3 open <文件> --gitignore`（#29）

- CLI open 分支（L1445–1463）：`--gitignore` 与 `--no-analyze` 同为可选项，
  `req["gitignore"] = True`。
- daemon 新 helper `_maybe_gitignore(path, notes)`，在 open_file 成功返回前调用：

```python
def _maybe_gitignore(self, path, notes):
    if not (self.cache_dir and self.anchor_dir
            and self.cache_dir == os.path.join(self.anchor_dir, ".r3cache")):
        notes.append("--gitignore：缓存未落在 .r3cache 档，无操作")
        return
    d = os.path.dirname(path)
    repo = None
    while True:                                  # 向上找 .git（目录或 worktree 文件）
        if os.path.exists(os.path.join(d, ".git")):
            repo = d
            break
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    if repo is None:
        notes.append("--gitignore：未检测到 git 仓库（向上未找到 .git），未追加")
        return
    gi = os.path.join(os.path.dirname(path), ".gitignore")   # 追加到文件所在目录
    try:
        if os.path.exists(gi):
            with open(gi, "r", encoding="utf-8") as f:
                if any("r3cache" in ln for ln in f):
                    notes.append(f"--gitignore：{gi} 已含 r3cache 条目，未重复追加")
                    return
        with open(gi, "a", encoding="utf-8") as f:
            if os.path.exists(gi) and os.path.getsize(gi) > 0:
                f.write("\n")                   # 简化：不强行补末行换行校验
            f.write(".r3cache/\n")
        notes.append(f"--gitignore：已在 {gi} 追加 .r3cache/")
    except OSError as e:
        notes.append(f"--gitignore：追加失败（{e}），请手动添加")
```

> 追加时若既有文件末行无换行，`\n` 与既有末行粘连风险：实现时先读末字节判断，
> 无换行则补一个 `\n`（文档给意图，细节按此处理）。幂等判断 = "行内含 r3cache 字样"。

### 4.8 AGENTS.md 重排与同步（#30）

文档任务（不碰 r3 代码）：
1. 保留"快速上手"在文首；命令表不动。
2. 「agent 必知的几件事」压缩为 6 条短句（open 先行、多会话配置常驻、截断与 `--json`
   声明、禁交互命令、看门狗、退出码 0–5 一览）。
3. 「缓存与文件」细节（回退链四档、写探针机制、meta 结构、econf）折叠为
   「附录：缓存与文件细节」短段；正文只留"缓存在哪、cache-clean、R3_NO_CACHE"三句。
4. 新增「环境噪声」条目：`landlock-run: partial enforcement (older Landlock ABI)`
   是宿主 WSL 沙箱层 stderr 警告，非 r3 输出；agent 解析管道输出时忽略 stderr。
5. 同步 v1.3 行为：`--session`/`open` 相对路径按调用方 cwd；裸名才当别名；路径样目标
   未命中直接报错不回退；缓存键含路径维（副本不共享缓存）；看门狗/close/重启后 e 配置
   恢复；`r3 open --gitignore`；open 速览行；退出码 5 = 无当前会话；沙箱下会话恢复走
   `r3 restart`；`izzj~过滤` 全有或全无 → `--json` 全量 + 本地过滤。

---

## 5. 代码改动点清单（r3 单文件，~1555 行）

| 位置 | 改动 |
|---|---|
| L284–286 `cache_key` | 加 realpath 维（#24） |
| L511–530 `_resolve_sid` | 删除 daemon 侧 abspath；绝对路径精确未中即错、不回退；含分隔符非绝对目标报错；仅裸名 basename 匹配（#23） |
| L395–411 `Session` | 加 `e_cmds: dict` 字段（#25） |
| L472–490 `_active` | 删除（#27） |
| L537–563 `_boot_restore` | 经 `_restore_session_file` 自动获得 econf 重放（#25） |
| L565–604 `_restore_session_file` | key 改调 `cache_key`；meta 校验加 path；末尾 `_apply_econf`（#24/#25） |
| L692–878 `open_file` | 缓存命中条件加 meta.path 校验（#24）；4 处成功路径 `_apply_econf`（#25）；速览行（#28）；`_maybe_gitignore`（#29） |
| L880–906 `_resp_r2_dead` | 经 `_restore_session_file` 自动获得 econf 重放（#25） |
| L1035–1060 `close_session` | 复用新 `_resolve_sid`（自动） |
| L1064–1099 `cache_clean` | 加清 `econf/`（#25） |
| L1103–1123 `passthrough` | 旁路记录 `e 名=值` 命令 + `_save_econf`（#25） |
| L1177–1225 `dispatch` | pass 无会话 → code 5 `no_active_session`；删 `_active` 调用（#27） |
| L1377–1551 `cli_main` | 新 `normalize_target` 用于 `--session`/`close`/`open`（#23）；restart 传 `R3_CACHE_DIR`（#26）；open 解析 `--gitignore`（#29）；退出码 5 透传（#27） |
| 新增 helper | `normalize_target`、`_apply_econf`、`_save_econf`、`econf_path_for`、`info_summary_line`、`_maybe_gitignore` |
| USAGE（L132–163） | 补 `--gitignore`、退出码 5、`--session` 新路径规则（#30） |
| 文件头注释（L1–90） | 追加 v1.3 结论存档（#23–#30 要点） |

AGENTS.md 按 §4.8 重排同步（#30）；tests/acceptance.sh 加 P–V 组与 B2 修订（§6）。

---

## 6. 验收标准

沿用脚本隔离要求（顶部 export `R3_CACHE_DIR`/`R3_SOCK_PATH` 到 `mktemp -d`；先 `r3 kill`
再清缓存）。A–O（v1/v1.1/v1.2）既有语义保持，**[旧验收修订]** 一处：

- **B2 修订**：探针命令 `r3 "?t"` 改 `r3 status`（懒启动验证本意不变——kill 后 socket
  消失、自动拉起、输出非空）；"未 open 先跑裸命令"场景由 U2 覆盖（断言退出码 5）。
  其余旧断言均为 grep 包含式，open 速览行不破坏（C 组已核实）。

新增 P–V 组（副本构造用 `cp /bin/true`，小文件快）：

**P --session/open 路径解释权（#23）**
- P1 调用方 cwd 语义：`A=$(mktemp -d)/projA`、`B=$(mktemp -d)/projB`，各放一份
  `/bin/true` 副本 `re2.elf`；`cd "$A"` 后 `r3 open ./re2.elf` → status 当前文件 ==
  realpath(A/re2.elf)；再 open B 副本；`cd "$A"` 下 `r3 --session ./re2.elf "i~file"`
  输出含 A 路径（daemon cwd 无关）。
- P2 裸名歧义报错：`r3 --session re2.elf "afl"` → 退出码 1，输出含"歧义"与两个候选路径。
- P3 精确未命中不回退（问题 ②）：`r3 close "$A/re2.elf"` → `r3 --session "$A/re2.elf" "afl"`
  → 退出码 1，输出含"不存在"，且不含 B 路径（无静默回落）。

**Q --gitignore（#29）**
- Q1 追加与幂等：临时目录 `git init -q`；`R3_CACHE_DIR`/`XDG_CACHE_HOME` 指向只读目录
  （chmod 555，参照 H5）触发 .r3cache 档 → `r3 open "$D/foo" --gitignore` → 输出含"已追加"、
  `$D/.gitignore` 含 `.r3cache/`；再执行一次 → 行数不变（grep -c == 1）。
- Q2 非 git 目录：同上触发 .r3cache 档但无 .git → 输出含"未检测到 git 仓库"，目录无 .gitignore。

**R 缓存键路径维（#24）**
- R1 副本互不踩：两份同内容副本 open A（分析）→ open B（分析）→ projects 下存在 ≥2 个
  不同 key 的工程文件 → `r3 kill` → open B → 输出含"缓存命中"且不含"缓存校验失败"。
- R2 meta.path 校验：篡改 B 的 meta `path` 字段为 A → `r3 kill` → open B → 不含"缓存命中"
  （未命中重分析）。

**S e 配置常驻与重放（#25）**
- S1 看门狗自愈恢复：open /bin/ls → `r3 "e asm.bytes=false"` →
  `R3_CMD_TIMEOUT=1 r3 "!sleep 3"`（退出码 3，自愈）→ `r3 "e asm.bytes"` 输出含 `false`。
- S2 跨 close 常驻：`r3 close` → `r3 open /bin/ls`（缓存命中）→ `e asm.bytes` 仍 `false`。
- S3 跨 daemon 重启：`r3 kill` → `r3 open /bin/ls`（boot 恢复 + econf 重放）→ `e asm.bytes`
  仍 `false`。
- S4（可选，可 SKIP）内存模式：`R3_NO_CACHE=1` 下 open → 设 e → `!sleep` 超时自愈 →
  `e asm.bytes` 仍 `false`（会话内存重放）。

**T restart 沙箱恢复（#26）**
- T1 前两级只读（chmod 555）→ open `$D/foo`（.r3cache 档落盘）→ `r3 restart` →
  status 显示当前文件 == foo、缓存模式磁盘、路径含 `.r3cache`；`r3 "i~file"` 输出含 foo 路径。
- T2（可选，可 SKIP）内存模式 `r3 restart` → 正常完成，sessions 空（文档化边界）。

**U 无当前会话退出码 5（#27）**
- U1 close 当前会话后：open /bin/ls → `r3 close` → `r3 "afl~main"` → 退出码 5、输出含
  "无当前会话"；`r3 --json "afl"` → 退出码 5、stdout 为合法 JSON 且
  `error == "no_active_session"`。
- U2 冷启动无 state：`r3 kill` + 删 `$R3_CACHE_DIR/state.json` → `r3 "?t"` → 退出码 5
  （B2 修订后旧组仍绿）。

**V open 信息速览（#28）**
- V1 open /bin/ls → 输出含"文件信息"行且含 `arch=` 与"动态链接"；`--no-analyze` 打开
  同样含"文件信息"行。

---

## 7. 已知风险（本次不修）

- **④ socket 安全（#20）**：`/tmp/r3.sock` 可预测；0700 挡跨用户，同 uid 可注入 r2 命令。
  低危，本地单用户可接受。缓解：`R3_SOCK_PATH` 指向用户专属目录。
- 纯内存模式固有边界：econf 不落盘（close/daemon 重启即失）、restart 无锚点可传
  （重启后会话空）——文档注明，属"不落盘"语义的自然结果。
- `r3 kill` 后任意调用（非 restart）无法找回 .r3cache 锚点（锚点只存于旧缓存目录内）：
  沙箱下会话恢复走 `r3 restart`；文档注明。
- #24 代价：同内容多副本不共享缓存，磁盘占用按副本数线性增长。
- v1.2 旧格式缓存（无路径维 key）成为孤儿文件：不误用、不自动清；`r3 cache-clean` 可清，
  孤儿回收留后续版本。
- `_boot_restore` 仍只重建 last_file 一个会话（其余下次 open 缓存重建）——#26 不扩大该语义。
- `--gitignore` 只追加不删除；幂等判断按"行内含 r3cache 字样"（`.r3cache`/`.r3cache/` 均可）。

---

## 8. 实现顺序建议

先搭 `tests/acceptance.sh` v1.3 骨架（P–V 全红 + B2 修订），随实现逐项变绿：

1. **#23 路径解释权**（normalize_target + _resolve_sid 改写）→ P 组绿，回归 A–O。
2. **#27 无会话退出码 5**（dispatch + 删 _active + B2 修订）→ U 组绿。
3. **#24 缓存键路径维**（cache_key + meta.path 校验）→ R 组绿。
4. **#25 e 配置常驻**（Session.e_cmds + passthrough 旁路 + econf 落盘/重放 + cache_clean）→ S 组绿。
5. **#26 restart 传缓存路径** → T 组绿。
6. **#28 速览行**（info_summary_line）→ V 组绿。
7. **#29 --gitignore**（CLI 解析 + _maybe_gitignore）→ Q 组绿。
8. **#30 文档配套**：AGENTS.md 重排同步、USAGE/文件头注释存档 v1.3 结论 → 全量回归（A–V 全绿）。

（全文完）
