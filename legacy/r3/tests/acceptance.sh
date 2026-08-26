#!/usr/bin/env bash
# r3 v2.1.0 验收脚本 —— PLAN-v1.3 §6（A–V 组）+ W 组修复回归 + PLAN-v2 §6 X 组调试 + PLAN-v2.1 §6 Y 组修复/输入注入验收
#
# 用法:     bash tests/acceptance.sh
# 完成定义: 退出码 0 = 全部 PASS（O2 等允许有理由的 SKIP）；任一 FAIL → 退出码 1。
#
# 旧验收修订（PLAN-v1.2 §6 继续有效，PLAN-v1.3 §6 追加）:
#   - G4「切文件提示配置已重置」删除（§4.1 解除换文件必丢配置）；
#   - I 组 JSON 断言按决策 #19 修订（废除首字符豁免：不加 --json 一律按文本截断，
#     aflj 完整性的保证改由 M 组的 --json 声明承担）。
#   - B2 修订（决策 #27）：懒启动探针从 r3 "?t" 改为 r3 status（无会话时
#     ?t 现在返回退出码 5，由 U2 专门覆盖）。
#
# 隔离设计（PLAN-v1.1 §6 脚本隔离要求）:
#   - 顶部 export R3_CACHE_DIR / R3_SOCK_PATH 到脚本自建临时目录，
#     所有 r3 调用与路径断言都走这两个变量，不依赖 ~/.cache/r3 与 /tmp/r3.sock 的写权限。
#   - 可用环境变量 R3_TEST_TMPDIR 指定临时目录（默认 mktemp -d）。
#   - 从干净状态起跑：先杀掉遗留 daemon、清空缓存目录。

set -u

# ---------------------------------------------------------------- 环境隔离
# 先杀掉外部遗留的"默认路径"daemon（若存在），避免干扰 H1 对 /tmp/r3.sock 的断言
env -u R3_SOCK_PATH -u R3_CACHE_DIR r3 kill >/dev/null 2>&1 || true
rm -f /tmp/r3.sock 2>/dev/null || true

CREATED_TMP=0
if [ -n "${R3_TEST_TMPDIR:-}" ]; then
    TEST_TMP="$R3_TEST_TMPDIR"
    mkdir -p "$TEST_TMP"
else
    if ! TEST_TMP="$(mktemp -d /tmp/r3-acceptance.XXXXXX 2>/dev/null)"; then
        TEST_TMP="$(mktemp -d ./tests/.r3-acceptance.XXXXXX)"
    fi
    CREATED_TMP=1
fi
export R3_CACHE_DIR="$TEST_TMP/cache"
export R3_SOCK_PATH="$TEST_TMP/r3.sock"
export R3_MAX_OUT=20000        # 固定默认截断上限，保证 D4/I 组断言确定性

cleanup() {
    r3 kill >/dev/null 2>&1 || true
    [ "$CREATED_TMP" = 1 ] && rm -rf "$TEST_TMP" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- 结果记录
PASS=0; FAIL=0; SKIP=0; FAILED=""
ok()   { PASS=$((PASS+1)); echo "  PASS  $1  $2"; }
bad()  { FAIL=$((FAIL+1)); FAILED="$FAILED $1"; echo "  FAIL  $1  $2"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP  $1  $2"; }

# 工具: 判断耗时是否小于 $2 秒（$1 = date +%s.%N 起点）
time_lt() { awk -v a="$1" -v b="$(date +%s.%N)" -v lim="$2" 'BEGIN{exit !(b-a<lim)}'; }
# 工具: 判断字符串是否为合法 JSON 且是数组（可再叠加 python 检查）
json_ok() { python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }

echo "=== r3 v2.1.0 acceptance（A–V 组 + W 组修复回归 + X 组调试 + Y 组 v2.1）==="
echo "R3_CACHE_DIR = $R3_CACHE_DIR"
echo "R3_SOCK_PATH = $R3_SOCK_PATH"
echo "r2           = $(r2 -v 2>/dev/null | head -1)"
echo

# ================================================================ A 部署
echo "--- A 部署 ---"
A1_OK=1
[ -f install.sh ] && bash install.sh >/dev/null 2>&1 || A1_OK=0
R3BIN="$(bash -lc 'command -v r3' 2>/dev/null)"
[ -n "$R3BIN" ] && echo "$R3BIN" | grep -q 'bin/r3$' || A1_OK=0
if [ "$A1_OK" -eq 1 ]; then
    ok A1 "install.sh 退出码 0 且 r3 在 PATH（$R3BIN）"
else
    bad A1 "install.sh 失败或 r3 不在 PATH（command -v r3 = '$R3BIN'）"
fi
H_OUT="$(r3 help 2>&1)"; H_RC=$?
H_OK=1
for w in open status restart kill sessions close; do echo "$H_OUT" | grep -q "$w" || H_OK=0; done
echo "$H_OUT" | grep -q -- "--session" || H_OK=0
echo "$H_OUT" | grep -q -- "--json" || H_OK=0
echo "$H_OUT" | grep -q -- "--gitignore" || H_OK=0
echo "$H_OUT" | grep -q -- "无当前会话" || H_OK=0
echo "$H_OUT" | grep -q "v2.1.0" || H_OK=0
echo "$H_OUT" | grep -q "6 会话目标不存在或有歧义" || H_OK=0
# cache-clean 是可选项（决策 #13）：已实现才要求出现在 help
if grep -q "cache-clean" r3; then echo "$H_OUT" | grep -q "cache-clean" || H_OK=0; fi
if [ "$H_RC" -eq 0 ] && [ "$H_OK" -eq 1 ]; then
    ok A2 "r3 help 显示自身版本 v2.1.0，且含保留子命令、--session/--json/--gitignore 与退出码 5/6"
else
    bad A2 "r3 help 缺失版本/保留子命令或退出码非 0"
fi

# ================================================================ B daemon 生命周期
echo "--- B daemon 生命周期 ---"
r3 kill >/dev/null 2>&1 || true
rm -f "$R3_SOCK_PATH"
OUT="$(r3 status 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "radare2"; then
    ok B1 "冷启动 r3 status 自动拉起 daemon 且输出含 r2 版本"
else
    bad B1 "冷启动失败（RC=$RC，输出: ${OUT:0:120}）"
fi
r3 kill >/dev/null 2>&1 || true
sleep 0.3
SOCK_GONE=1; [ -S "$R3_SOCK_PATH" ] && SOCK_GONE=0
# PLAN-v1.3 §6 B2 修订：?t 在无会话时已改为退出码 5（U2 覆盖），
# 懒启动验证本意不变——kill 后 socket 消失、r3 status 自动拉起且输出非空。
OUT="$(r3 status 2>&1)"; RC=$?
if [ "$SOCK_GONE" -eq 1 ] && [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
    ok B2 "kill 后 socket 消失；r3 status 自动重启 daemon 且输出非空"
else
    bad B2 "socket 未消失或 status 未自动重启（RC=$RC）"
fi

# ================================================================ C 打开与分析缓存
echo "--- C 打开与分析缓存 ---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
OUT="$(r3 open /bin/ls 2>&1)"; RC=$?
PROJ_FILE="$(find "$R3_CACHE_DIR/projects" -maxdepth 1 -type f ! -name '*.meta.json' 2>/dev/null | head -1)"
PROJ_META="$(find "$R3_CACHE_DIR/projects" -maxdepth 1 -name '*.meta.json' 2>/dev/null | head -1)"
ST="$(r3 status 2>&1)"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "耗时" \
   && [ -n "$PROJ_FILE" ] && [ -n "$PROJ_META" ] \
   && echo "$ST" | grep -q "bin/ls" && echo "$ST" | grep -q "已分析"; then
    ok C1 "open 落缓存（工程文件+meta）、status 显示当前文件且已分析"
else
    bad C1 "open/缓存/status 有缺失（RC=$RC，工程文件='$PROJ_FILE'，meta='$PROJ_META'）"
fi
r3 kill >/dev/null 2>&1 || true
T0="$(date +%s.%N)"
OUT="$(r3 open /bin/ls 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "缓存命中" && time_lt "$T0" 3; then
    ok C2 "kill 后同文件 open < 3s 且标注缓存命中"
else
    bad C2 "缓存未命中或超时（RC=$RC，输出: ${OUT:0:120}）"
fi
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
T0="$(date +%s.%N)"
OUT="$(r3 open /bin/ls --no-analyze 2>&1)"; RC=$?
PROJ_AGAIN="$(find "$R3_CACHE_DIR/projects" -maxdepth 1 -type f ! -name '*.meta.json' 2>/dev/null | head -1)"
AFLJ="$(r3 "aflj" 2>&1)"
AFLJ_EMPTY=0
echo "$AFLJ" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,list) and len(d)==0 else 1)' 2>/dev/null && AFLJ_EMPTY=1
if [ "$RC" -eq 0 ] && time_lt "$T0" 2 && [ -z "$PROJ_AGAIN" ] && [ "$AFLJ_EMPTY" -eq 1 ]; then
    ok C3 "--no-analyze 快开、无工程落盘、aflj 无函数条目"
else
    bad C3 "--no-analyze 行为不符（RC=$RC，工程文件='$PROJ_AGAIN'，aflj 空=$AFLJ_EMPTY）"
fi
SZ="$(stat -c %s /bin/ls)"
OUT="$(R3_BIGFILE_LIMIT=$((SZ/2)) r3 open /bin/ls 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "轻量分析"; then
    ok C4 "大文件阈值触发轻量分析降级提示"
else
    bad C4 "降级分支未触发（RC=$RC，输出: ${OUT:0:120}）"
fi
META="$(find "$R3_CACHE_DIR/projects" -maxdepth 1 -name '*.meta.json' 2>/dev/null | head -1)"
if [ -n "$META" ]; then
    python3 - "$META" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["sha256"] = "deadbeef" * 16          # 篡改归属，模拟脏缓存
json.dump(d, open(sys.argv[1], "w"))
PYEOF
    r3 kill >/dev/null 2>&1 || true
    OUT="$(r3 open /bin/ls 2>&1)"; RC=$?
    REAL_SHA="$(sha256sum /bin/ls | awk '{print $1}')"
    META2="$(find "$R3_CACHE_DIR/projects" -maxdepth 1 -name '*.meta.json' 2>/dev/null | head -1)"
    META_OK=0
    [ -n "$META2" ] && python3 - "$META2" "$REAL_SHA" <<'PYEOF' && META_OK=1
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("sha256") == sys.argv[2] else 1)
PYEOF
    if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "缓存命中" && [ "$META_OK" -eq 1 ]; then
        ok C5 "meta 被篡改后不命中缓存、重新分析并生成正确 meta"
    else
        bad C5 "meta 归属校验未生效（RC=$RC，输出: ${OUT:0:120}）"
    fi
else
    bad C5 "未找到 meta 文件（C1 或 C4 未落缓存？）"
fi

# ================================================================ D 传声筒与输出处理
echo "--- D 传声筒与输出处理 ---"
OUT="$(r3 "afl" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -n "$OUT" ] && ! printf '%s' "$OUT" | grep -q $'\x1b'; then
    ok D1 "afl 非空且无 ANSI 转义"
else
    bad D1 "afl 为空或含 ANSI（RC=$RC）"
fi
FN="$(r3 --json "aflj" 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["name"] if d else "")' 2>/dev/null)"
PDF="$(r3 "pdf @ $FN" 2>&1)"
if [ -n "$FN" ] && [ -n "$PDF" ]; then
    ok D2 "aflj 是合法 JSON，pdf @ 首函数 输出非空"
else
    bad D2 "aflj 非法 JSON 或 pdf 为空（FN='$FN'）"
fi
r3 "e asm.bytes=false" >/dev/null 2>&1
OUT="$(r3 "e asm.bytes" 2>&1)"
if echo "$OUT" | grep -q "false"; then
    ok D3 "配置常驻生效（e asm.bytes=false 后读回 false）"
else
    bad D3 "配置未常驻（输出: $OUT）"
fi
LIBC=""
for c in /usr/lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6; do
    [ -e "$c" ] && LIBC="$c" && break
done
if [ -n "$LIBC" ]; then
    r3 open "$LIBC" --no-analyze >/dev/null 2>&1
    OUT="$(r3 "izz" 2>&1)"
    FULL="$(r3 --full "izz" 2>&1)"
    L1="$(printf '%s' "$OUT" | wc -c)"
    L2="$(printf '%s' "$FULL" | wc -c)"
    if echo "$OUT" | grep -q "Output truncated" && [ "$L1" -le 21500 ] && [ "$L2" -gt 20000 ]; then
        ok D4 "默认截断+横幅生效（${L1}B），--full 看全量（${L2}B）"
    else
        bad D4 "截断行为不符（截断长度=${L1}B，full 长度=${L2}B）"
    fi
else
    skip D4 "未找到 libc.so.6"
fi
r3 "?t" >"$TEST_TMP/d5a" 2>&1 & P1=$!
r3 "?t" >"$TEST_TMP/d5b" 2>&1 & P2=$!
wait "$P1"; RC1=$?
wait "$P2"; RC2=$?
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ -s "$TEST_TMP/d5a" ] && [ -s "$TEST_TMP/d5b" ]; then
    ok D5 "两个并发 r3 调用均退出码 0 且输出非空"
else
    bad D5 "并发调用异常（RC=$RC1/$RC2）"
fi

# ================================================================ E 防挂死
echo "--- E 防挂死 ---"
OUT="$(r3 "V" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "拒绝"; then
    E1_REFUSE=1
else
    E1_REFUSE=0
fi
r3 status >/dev/null 2>&1; RC2=$?
if [ "$E1_REFUSE" -eq 1 ] && [ "$RC2" -eq 0 ]; then
    ok E1 "交互命令被拒绝（退出码 2）且 daemon 仍存活"
else
    bad E1 "黑名单拒绝失败或 daemon 挂死（RC=$RC，status RC=$RC2）"
fi
OUT="$(R3_CMD_TIMEOUT=2 r3 "!sleep 5" 2>&1)"; RC=$?
if [ "$RC" -eq 3 ] && echo "$OUT" | grep -q "超时"; then
    E2_TIMEOUT=1
else
    E2_TIMEOUT=0
fi
r3 status >/dev/null 2>&1; RC2=$?
if [ "$E2_TIMEOUT" -eq 1 ] && [ "$RC2" -eq 0 ]; then
    ok E2 "看门狗超时杀 r2 自愈（退出码 3）且 daemon 存活"
else
    bad E2 "看门狗行为不符（RC=$RC，status RC=$RC2）"
fi

# ================================================================ G 跨文件污染回归（核心）
echo "--- G 跨文件污染回归 ---"
r3 kill >/dev/null 2>&1 || true
OUT_LS="$(r3 open /bin/ls 2>&1)"
r3 "aaa" >/dev/null 2>&1
OUT_TRUE="$(r3 open /bin/true 2>&1)"; RC=$?
IFILE="$(r3 "i~file" 2>&1)"
PDF="$(r3 --full "pdf @ main" 2>&1)"
if [ "$RC" -eq 0 ] && echo "$IFILE" | grep -q "bin/true" \
   && ! printf '%s' "$PDF" | grep -qE 'LS_COLORS|src/ls\.c'; then
    ok G1 "切到 /bin/true 后 i~file 正确、pdf @ main 无 ls 残留（不污染）"
else
    bad G1 "跨文件污染复现（i~file: ${IFILE:0:60}；pdf 应不含 LS_COLORS/src/ls.c）"
fi
r3 kill >/dev/null 2>&1 || true
OUT="$(r3 open /bin/true 2>&1)"; RC=$?
PDF="$(r3 --full "pdf @ main" 2>&1)"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "缓存命中" \
   && ! printf '%s' "$PDF" | grep -qE 'LS_COLORS|src/ls\.c'; then
    ok G2 "kill 后缓存命中恢复 /bin/true，分析仍是 true（缓存未被污染）"
else
    bad G2 "缓存被污染或未命中（RC=$RC，输出: ${OUT:0:120}）"
fi
r3 open /bin/ls >/dev/null 2>&1
r3 "aaa" >/dev/null 2>&1
PDF="$(r3 --full "pdf @ main" 2>&1)"
if printf '%s' "$PDF" | grep -q 'LS_COLORS'; then
    ok G3 "切回 /bin/ls 后 pdf @ main 恢复 ls 内容"
else
    bad G3 "切回失败或 ls 反汇编异常"
fi
# G4 已删除（PLAN-v1.2 §6 旧验收修订：§4.1 解除换文件必丢配置，不再提示配置重置）

# ================================================================ H 沙箱友好
echo "--- H 沙箱友好 ---"
if [ -f "$R3_CACHE_DIR/daemon.log" ] && [ -d "$R3_CACHE_DIR/projects" ] \
   && [ -S "$R3_SOCK_PATH" ] && [ ! -S /tmp/r3.sock ]; then
    ok H1 "日志/缓存/socket 全部落在 R3_CACHE_DIR 与 R3_SOCK_PATH，/tmp/r3.sock 未被占用"
else
    bad H1 "路径可配置未生效（cache=$R3_CACHE_DIR，sock=$R3_SOCK_PATH）"
fi
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
OUT="$(R3_NO_CACHE=1 r3 open /bin/ls 2>&1)"; RC=$?
ST="$(R3_NO_CACHE=1 r3 status 2>&1)"
AFL="$(R3_NO_CACHE=1 r3 "afl" 2>&1)"
N_PROJ="$(find "$R3_CACHE_DIR/projects" -type f 2>/dev/null | wc -l)"
if [ "$RC" -eq 0 ] && echo "$ST" | grep -qE '内存|无落盘缓存' \
   && [ "$N_PROJ" -eq 0 ] && [ -n "$AFL" ]; then
    ok H2 "R3_NO_CACHE=1 纯内存模式：status 标注、不落缓存、afl 仍可用"
else
    bad H2 "纯内存模式不符（RC=$RC，工程文件数=$N_PROJ）"
fi
# H3（v1.1.x 回退链：R3_CACHE_DIR 不可写 → 回退 XDG 档）
r3 kill >/dev/null 2>&1 || true
XDG_DIR="$TEST_TMP/xdg-cache"
mkdir -p "$XDG_DIR"
OUT="$(R3_CACHE_DIR=/proc/r3-nonexistent XDG_CACHE_HOME="$XDG_DIR" r3 open /bin/ls 2>&1)"; RC=$?
ST="$(R3_CACHE_DIR=/proc/r3-nonexistent XDG_CACHE_HOME="$XDG_DIR" r3 status 2>&1)"
if [ "$RC" -eq 0 ] && echo "$ST" | grep -q "磁盘缓存" \
   && echo "$ST" | grep -q "$XDG_DIR/r3" && echo "$ST" | grep -q "回退原因"; then
    ok H3 "R3_CACHE_DIR 不可写时回退 XDG 档（status 显示生效路径+磁盘模式+回退原因）"
else
    bad H3 "XDG 回退失败（RC=$RC，输出: ${OUT:0:120}）"
fi
# H4（v1.1.x 回退链：前两级只读、文件目录档也不可写 → 纯内存兜底）
# chmod 555 模拟已存在但只读的缓存目录（makedirs 不抛异常，须靠写探针）。
r3 kill >/dev/null 2>&1 || true
RO1="$TEST_TMP/ro1"; mkdir -p "$RO1"; chmod 555 "$RO1"
RO2="$TEST_TMP/ro2"; mkdir -p "$RO2"; chmod 555 "$RO2"
OUT="$(R3_CACHE_DIR="$RO1" XDG_CACHE_HOME="$RO2" r3 open /bin/ls 2>&1)"; RC=$?
AFL="$(R3_CACHE_DIR="$RO1" XDG_CACHE_HOME="$RO2" r3 "afl" 2>&1)"
ST="$(R3_CACHE_DIR="$RO1" XDG_CACHE_HOME="$RO2" r3 status 2>&1)"; RC2=$?
chmod 755 "$RO1" "$RO2"
if [ "$RC" -eq 0 ] && [ -n "$AFL" ] && [ "$RC2" -eq 0 ] \
   && echo "$ST" | grep -qE '内存|无落盘缓存'; then
    ok H4 "全部层级不可写（含 /usr/bin 下文件目录档）→ 纯内存兜底，open/afl/status 正常"
else
    bad H4 "内存兜底失败（RC=$RC/$RC2，输出: ${OUT:0:120}）"
fi
# H5（v1.1.x 回退链：前两级不可写 → 文件目录 .r3cache/ 档落盘 + .gitignore 提示）
r3 kill >/dev/null 2>&1 || true
BIN_DIR="$TEST_TMP/bin"; mkdir -p "$BIN_DIR"
cp /bin/ls "$BIN_DIR/ls"
RO_XDG="$TEST_TMP/ro-xdg"; mkdir -p "$RO_XDG"; chmod 555 "$RO_XDG"
OUT="$(R3_CACHE_DIR= XDG_CACHE_HOME="$RO_XDG" r3 open "$BIN_DIR/ls" 2>&1)"; RC=$?
ST="$(R3_CACHE_DIR= XDG_CACHE_HOME="$RO_XDG" r3 status 2>&1)"
N_PROJ="$(find "$BIN_DIR/.r3cache/projects" -maxdepth 1 -type f ! -name '*.meta.json' 2>/dev/null | wc -l)"
chmod 755 "$RO_XDG"
if [ "$RC" -eq 0 ] && echo "$ST" | grep -q "$BIN_DIR/.r3cache" \
   && [ "$N_PROJ" -ge 1 ] && echo "$OUT" | grep -q '.gitignore'; then
    ok H5 "前两级不可写时回退到文件目录 .r3cache/ 落盘，open 输出含 .gitignore 提示"
else
    bad H5 "文件目录档回退失败（RC=$RC，工程数=$N_PROJ，输出: ${OUT:0:120}）"
fi

# ================================================================ I 截断控制（#19 修订）
echo "--- I 截断控制（决策 #19 修订：废除首字符豁免）---"
r3 kill >/dev/null 2>&1 || true
r3 open /bin/ls >/dev/null 2>&1
OUT="$(R3_MAX_OUT=100 r3 "aflj" 2>&1)"
if echo "$OUT" | grep -q "Output truncated"; then
    ok I1 "R3_MAX_OUT=100 时 aflj 不再因首字符豁免，按文本截断（#19）"
else
    bad I1 "aflj 仍被首字符豁免（应截断；长度=$(printf '%s' "$OUT" | wc -c)B）"
fi
OUT="$(R3_MAX_OUT=100 r3 "afl" 2>&1)"
if echo "$OUT" | grep -q "Output truncated"; then
    ok I2 "R3_MAX_OUT=100 时文本输出仍按上限截断（对照组）"
else
    bad I2 "文本截断失效"
fi

# ================================================================ J cache-clean（可选项）
echo "--- J cache-clean（可选项）---"
if grep -q "cache-clean" r3; then
    r3 kill >/dev/null 2>&1 || true
    rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
    r3 open /bin/ls >/dev/null 2>&1
    OUT="$(r3 cache-clean 2>&1)"; RC=$?
    ST="$(r3 status 2>&1)"
    N_LEFT="$(find "$R3_CACHE_DIR/projects" -mindepth 1 2>/dev/null | wc -l)"
    if [ "$RC" -eq 0 ] && echo "$ST" | grep "缓存工程" | grep -q "0 个" && [ "$N_LEFT" -eq 0 ]; then
        ok J1 "cache-clean 清空工程缓存与 meta，status 缓存计数为 0"
    else
        bad J1 "cache-clean 行为不符（RC=$RC，残留=$N_LEFT）"
    fi
else
    skip J1 "cache-clean 未实现（PLAN-v1.1 决策 #13 可选项，允许跳过）"
fi

# ================================================================ K 多会话（核心，v1.2 #15–#17）
echo "--- K 多会话（核心）---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
r3 open /bin/ls >/dev/null 2>&1
r3 open /bin/true >/dev/null 2>&1
PDF_LS="$(r3 --session /bin/ls --full "pdf @ main" 2>&1)"
PDF_TRUE="$(r3 --session /bin/true --full "pdf @ main" 2>&1)"
if printf '%s' "$PDF_LS" | grep -q 'LS_COLORS' \
   && ! printf '%s' "$PDF_TRUE" | grep -qE 'LS_COLORS|src/ls\.c'; then
    ok K1 "--session 交叉会话不混：ls 的 main 含 LS_COLORS、true 的 main 不含"
else
    bad K1 "交叉会话串扰（ls 含 LS_COLORS，true 含残留）"
fi
r3 --session /bin/ls "e asm.bytes=false" >/dev/null 2>&1
OUT_LS="$(r3 --session /bin/ls "e asm.bytes" 2>&1)"
OUT_TRUE="$(r3 --session /bin/true "e asm.bytes" 2>&1)"
if echo "$OUT_LS" | grep -q "false" && ! echo "$OUT_TRUE" | grep -q "false"; then
    ok K2 "配置按会话留存：切走切回 ls 仍为 false，true 会话不受影响"
else
    bad K2 "会话配置串扰（ls: $OUT_LS / true: $OUT_TRUE）"
fi
SESS="$(r3 sessions 2>&1)"
SJ="$(r3 status --json 2>&1)"
SJ_OK=0
# 注意：会话 file 是 realpath（/bin/ls → /usr/bin/ls），用 endswith 判定
echo "$SJ" | python3 -c '
import json,sys
d=json.load(sys.stdin)
fs=[s["file"] for s in d["sessions"]]
sys.exit(0 if len(fs)>=2
            and any(f.endswith("/ls") for f in fs)
            and any(f.endswith("/true") for f in fs) else 1)' 2>/dev/null && SJ_OK=1
if echo "$SESS" | grep -q "bin/ls" && echo "$SESS" | grep -q "bin/true" && [ "$SJ_OK" -eq 1 ]; then
    ok K3 "sessions 列出两会话及路径；status --json 的 sessions 长度 ≥2"
else
    bad K3 "会话列表或 status --json 缺失（sessions: $SESS / SJ_OK=$SJ_OK）"
fi
r3 close /bin/true >/dev/null 2>&1
SESS="$(r3 sessions 2>&1)"
T0="$(date +%s.%N)"
OUT="$(r3 open /bin/true 2>&1)"
if ! echo "$SESS" | grep -q "bin/true" && echo "$OUT" | grep -q "缓存命中" && time_lt "$T0" 5; then
    ok K4 "close /bin/true 后 sessions 不含 true；重开秒开且缓存命中"
else
    bad K4 "close/重开行为不符（sessions: $SESS / open: ${OUT:0:120}）"
fi

# ================================================================ L 机器可读（v1.2 #18）
echo "--- L 机器可读 ---"
SJ="$(r3 status --json 2>&1)"
L1_OK=0
echo "$SJ" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c=d["cache"]
sys.exit(0 if all(k in c for k in ("mode","path","fallback_reason"))
            and c["mode"] in ("disk","memory")
            and "sessions" in d and "daemon" in d and "active_session" in d else 1)' 2>/dev/null && L1_OK=1
if [ "$L1_OK" -eq 1 ]; then
    ok L1 "status --json 合法 JSON，含 cache.mode/path/fallback_reason、daemon、active_session、sessions"
else
    bad L1 "status --json 结构不符（输出: ${SJ:0:200}）"
fi
r3 open /bin/ls >/dev/null 2>&1
OUT="$(R3_MAX_OUT=100 r3 --json "izz" 2>&1)"
L="$(printf '%s' "$OUT" | wc -c)"
if [ "$L" -gt 100 ] && ! echo "$OUT" | grep -q "Output truncated"; then
    ok L2 "R3_MAX_OUT=100 时 --json izz 不截断（${L}B > 100），无横幅"
else
    bad L2 "--json 未保证不截断（长度=${L}B）"
fi

# ================================================================ M 显式 --json（v1.2 #19）
echo "--- M 显式 --json ---"
OUT="$(R3_MAX_OUT=100 r3 --json "aflj" 2>&1)"; RC=$?
L="$(printf '%s' "$OUT" | wc -c)"
if [ "$RC" -eq 0 ] && [ "$L" -gt 100 ] && echo "$OUT" | json_ok; then
    ok M2 "R3_MAX_OUT=100 时 --json aflj 完整合法 JSON（${L}B > 100，RC=0）"
else
    bad M2 "--json aflj 不符（RC=$RC，长度=${L}B）"
fi
OUT="$(R3_MAX_OUT=100 r3 "aflj" 2>&1)"
if echo "$OUT" | grep -q "Output truncated"; then
    ok M2b "对照组：同上限不加 --json 的 aflj 被截断"
else
    bad M2b "不加 --json 的 aflj 未被截断（#19 失效）"
fi
LIBC=""
for c in /usr/lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6; do
    [ -e "$c" ] && LIBC="$c" && break
done
if [ -n "$LIBC" ]; then
    r3 open "$LIBC" --no-analyze >/dev/null 2>&1
    OUT="$(R3_MAX_OUT=100 r3 "izzj~password" 2>&1)"
    if echo "$OUT" | grep -q "Output truncated"; then
        ok M1 "过滤后的 izzj~password 按文本截断（首字符豁免已废除）"
    else
        bad M1 "izzj~password 未截断（长度=$(printf '%s' "$OUT" | wc -c)B）"
    fi
else
    skip M1 "未找到 libc.so.6"
fi

# ================================================================ N 截断退出码（v1.2 #21）
echo "--- N 截断退出码 ---"
r3 open /bin/ls >/dev/null 2>&1
R3_MAX_OUT=100 r3 "afl" >/dev/null 2>&1; RC_AFL=$?
# 事实类出入（以实测为准）：PLAN 的 "afl~main" 在 /bin/ls 上匹配 3 行
# （textdomain/bindtextdomain 以 "main" 结尾，共 220 字符）会触发截断退出码 4。
# 改用空格锚定 " main$" 精确匹配 1 个函数（<100 字符），保持 N1 原意「过滤后短输出退出码 0」。
R3_MAX_OUT=100 r3 "afl~ main$" >/dev/null 2>&1; RC_FILT=$?
R3_MAX_OUT=100 r3 --json "aflj" >/dev/null 2>&1; RC_JSON=$?
if [ "$RC_AFL" -eq 4 ] && [ "$RC_FILT" -eq 0 ] && [ "$RC_JSON" -eq 0 ]; then
    ok N1+N2 "截断退出码 4；afl~main 退出码 0；--json aflj 退出码 0"
else
    bad N1+N2 "退出码不符（afl=$RC_AFL，afl~main=$RC_FILT，--json aflj=$RC_JSON）"
fi

# ================================================================ O 故障报错细化（v1.2 #22）
echo "--- O 故障报错细化 ---"
r3 kill >/dev/null 2>&1 || true
NODIR="$TEST_TMP/no-such-dir"
OUT="$(R3_SOCK_PATH="$NODIR/r3.sock" r3 status --json 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "daemon_not_running"; then
    ok O1 "daemon 拉不起来时 --json 报错含 daemon_not_running，退出码 1"
else
    bad O1 "故障分类不符（RC=$RC，输出: ${OUT:0:200}）"
fi
skip O2 "daemon_timeout 需人为挂起 socket（读超时 65s+），按 PLAN-v1.2 §6 允许 SKIP"

# ================================================================ P --session/open 路径解释权（#23）
echo "--- P --session/open 路径解释权（#23）---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
A="$TEST_TMP/projA"; B="$TEST_TMP/projB"
mkdir -p "$A" "$B"
cp /bin/true "$A/re2.elf"; cp /bin/true "$B/re2.elf"
OUT="$(cd "$A" && r3 open ./re2.elf 2>&1)"; RC=$?
ST="$(r3 status 2>&1)"
if [ "$RC" -eq 0 ] && echo "$ST" | grep -q "$A/re2.elf"; then
    ok P1a "open ./re2.elf 按调用方 cwd 打开 A 副本（status 当前文件 == realpath(A/re2.elf)）"
else
    bad P1a "open 相对路径未按调用方 cwd 解释（RC=$RC，status: ${ST:0:120}）"
fi
r3 open "$B/re2.elf" >/dev/null 2>&1
IFILE="$(cd "$A" && r3 --session ./re2.elf "i~file" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$IFILE" | grep -q "$A/re2.elf"; then
    ok P1b "--session ./re2.elf 在 A cwd 下命中 A 会话（与 daemon cwd 无关）"
else
    bad P1b "--session 相对路径未按调用方 cwd 解析（RC=$RC，输出: ${IFILE:0:120}）"
fi
OUT="$(r3 --session re2.elf "afl" 2>&1)"; RC=$?
if [ "$RC" -eq 6 ] && echo "$OUT" | grep -q "歧义" \
   && echo "$OUT" | grep -q "$A/re2.elf" && echo "$OUT" | grep -q "$B/re2.elf"; then
    ok P2 "裸名 basename 歧义退出码 6 并列两个候选路径"
else
    bad P2 "裸名歧义未按 6 安全报错（RC=$RC，输出: ${OUT:0:200}）"
fi
r3 close "$A/re2.elf" >/dev/null 2>&1
OUT="$(r3 --session "$A/re2.elf" "afl" 2>&1)"; RC=$?
if [ "$RC" -eq 6 ] && echo "$OUT" | grep -q "不存在" \
   && ! echo "$OUT" | grep -q "$B/re2.elf"; then
    ok P3 "已关闭会话的绝对路径精确未命中退出码 6，不回退同名 basename 会话"
else
    bad P3 "绝对路径未命中未按 6 报错或静默回落 basename（RC=$RC，输出: ${OUT:0:200}）"
fi

# ================================================================ Q --gitignore（#29）
echo "--- Q --gitignore（#29）---"
r3 kill >/dev/null 2>&1 || true
D="$TEST_TMP/qgit"; mkdir -p "$D"; (cd "$D" && git init -q)
cp /bin/true "$D/foo"
RO_Q1="$TEST_TMP/ro-q1"; RO_Q2="$TEST_TMP/ro-q2"
mkdir -p "$RO_Q1" "$RO_Q2"; chmod 555 "$RO_Q1" "$RO_Q2"
OUT="$(R3_CACHE_DIR="$RO_Q1" XDG_CACHE_HOME="$RO_Q2" r3 open "$D/foo" --gitignore 2>&1)"; RC=$?
COUNT1=0; [ -f "$D/.gitignore" ] && COUNT1="$(grep -c '\.r3cache/' "$D/.gitignore" || true)"
OUT2="$(R3_CACHE_DIR="$RO_Q1" XDG_CACHE_HOME="$RO_Q2" r3 open "$D/foo" --gitignore 2>&1)"; RC2=$?
COUNT2=0; [ -f "$D/.gitignore" ] && COUNT2="$(grep -c '\.r3cache/' "$D/.gitignore" || true)"
chmod 755 "$RO_Q1" "$RO_Q2"
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && echo "$OUT" | grep -q "已追加" \
   && [ "$COUNT1" -eq 1 ] && [ "$COUNT2" -eq 1 ]; then
    ok Q1 "--gitignore 在 .r3cache 档且 git 仓库内幂等追加 .r3cache/（两次均 1 行）"
else
    bad Q1 "--gitignore 追加/幂等失败（RC=$RC/$RC2，count=$COUNT1/$COUNT2，输出: ${OUT:0:200}）"
fi
r3 kill >/dev/null 2>&1 || true
D2="$TEST_TMP/qnogit"; mkdir -p "$D2"; cp /bin/true "$D2/foo"
RO_Q3="$TEST_TMP/ro-q3"; RO_Q4="$TEST_TMP/ro-q4"
mkdir -p "$RO_Q3" "$RO_Q4"; chmod 555 "$RO_Q3" "$RO_Q4"
OUT="$(R3_CACHE_DIR="$RO_Q3" XDG_CACHE_HOME="$RO_Q4" r3 open "$D2/foo" --gitignore 2>&1)"; RC=$?
chmod 755 "$RO_Q3" "$RO_Q4"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "未检测到 git 仓库" \
   && [ ! -f "$D2/.gitignore" ]; then
    ok Q2 "非 git 目录只说明不追加 .gitignore"
else
    bad Q2 "非 git 目录行为不符（RC=$RC，输出: ${OUT:0:200}）"
fi

# ================================================================ R 缓存键路径维（#24）
echo "--- R 缓存键路径维（#24）---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
A="$TEST_TMP/ra"; B="$TEST_TMP/rb"; mkdir -p "$A" "$B"
cp /bin/true "$A/true"; cp /bin/true "$B/true"
r3 open "$A/true" >/dev/null 2>&1
r3 open "$B/true" >/dev/null 2>&1
NPROJ="$(find "$R3_CACHE_DIR/projects" -maxdepth 1 -type f ! -name '*.meta.json' 2>/dev/null | wc -l)"
r3 kill >/dev/null 2>&1 || true
OUT="$(r3 open "$B/true" 2>&1)"; RC=$?
if [ "$NPROJ" -ge 2 ] && [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "缓存命中" \
   && ! echo "$OUT" | grep -q "缓存校验失败"; then
    ok R1 "同内容副本各落独立缓存；kill 后 open B 命中自身缓存且无校验失败"
else
    bad R1 "副本缓存互踩或重开失败（工程数=$NPROJ，RC=$RC，输出: ${OUT:0:200}）"
fi
META_B="$(python3 - "$B/true" <<'PYEOF'
import glob, json, os, sys
want = sys.argv[1]
for p in glob.glob(os.environ['R3_CACHE_DIR'] + '/projects/*.meta.json'):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if d.get('path') == want:
        print(p)
        break
PYEOF
)"
if [ -n "$META_B" ]; then
    python3 - "$META_B" "$A/true" <<'PYEOF'
import json, sys
p, bad = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d['path'] = bad          # 篡改 path 归属，模拟同内容另一副本的缓存
json.dump(d, open(p, 'w'))
PYEOF
    r3 kill >/dev/null 2>&1 || true
    OUT="$(r3 open "$B/true" 2>&1)"; RC=$?
    if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "缓存命中"; then
        ok R2 "meta.path 被篡改后 open B 不命中缓存（重新分析）"
    else
        bad R2 "meta.path 校验未生效（RC=$RC，输出: ${OUT:0:200}）"
    fi
else
    bad R2 "未找到 B 副本的 meta 文件"
fi

# ================================================================ S e 配置常驻与重放（#25）
echo "--- S e 配置常驻与重放（#25）---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
r3 open /bin/ls >/dev/null 2>&1
r3 "e asm.bytes=false" >/dev/null 2>&1
OUT="$(R3_CMD_TIMEOUT=1 r3 "!sleep 3" 2>&1)"; RC=$?
OUT_E="$(r3 "e asm.bytes" 2>&1)"
if [ "$RC" -eq 3 ] && echo "$OUT_E" | grep -q "false"; then
    ok S1 "看门狗自愈后 e 配置重放（e asm.bytes 仍为 false）"
else
    bad S1 "自愈后 e 配置丢失（RC=$RC，e asm.bytes: $OUT_E）"
fi
r3 close >/dev/null 2>&1
r3 open /bin/ls >/dev/null 2>&1
OUT_E="$(r3 "e asm.bytes" 2>&1)"
if echo "$OUT_E" | grep -q "false"; then
    ok S2 "close 后重开（缓存命中）e 配置按文件常驻恢复"
else
    bad S2 "close 后 e 配置未恢复（e asm.bytes: $OUT_E）"
fi
r3 kill >/dev/null 2>&1 || true
r3 open /bin/ls >/dev/null 2>&1
OUT_E="$(r3 "e asm.bytes" 2>&1)"
if echo "$OUT_E" | grep -q "false"; then
    ok S3 "daemon 重启 + boot 恢复后 e 配置重放"
else
    bad S3 "daemon 重启后 e 配置未恢复（e asm.bytes: $OUT_E）"
fi
r3 kill >/dev/null 2>&1 || true
R3_NO_CACHE=1 r3 open /bin/ls >/dev/null 2>&1
R3_NO_CACHE=1 r3 "e asm.bytes=false" >/dev/null 2>&1
OUT="$(R3_NO_CACHE=1 R3_CMD_TIMEOUT=1 r3 "!sleep 3" 2>&1)"; RC=$?
OUT_E="$(R3_NO_CACHE=1 r3 "e asm.bytes" 2>&1)"
if [ "$RC" -eq 3 ] && echo "$OUT_E" | grep -q "false"; then
    ok S4 "纯内存模式看门狗自愈后 e 配置由会话内存重放"
else
    bad S4 "纯内存模式 econf 重放失败（RC=$RC，e asm.bytes: $OUT_E）"
fi
r3 kill >/dev/null 2>&1 || true

# ================================================================ T restart 沙箱恢复（#26）
echo "--- T restart 沙箱恢复（#26）---"
r3 kill >/dev/null 2>&1 || true
D="$TEST_TMP/twork"; mkdir -p "$D"; cp /bin/ls "$D/foo"; chmod +x "$D/foo"
RO1="$TEST_TMP/t-ro1"; RO2="$TEST_TMP/t-ro2"; mkdir -p "$RO1" "$RO2"; chmod 555 "$RO1" "$RO2"
OUT="$(R3_CACHE_DIR="$RO1" XDG_CACHE_HOME="$RO2" r3 open "$D/foo" 2>&1)"; RC=$?
OUT="$(R3_CACHE_DIR= XDG_CACHE_HOME="$RO2" r3 restart 2>&1)"; RC2=$?
ST="$(R3_CACHE_DIR= XDG_CACHE_HOME="$RO2" r3 status 2>&1)"
SJ="$(R3_CACHE_DIR= XDG_CACHE_HOME="$RO2" r3 status --json 2>&1)"
IFILE="$(R3_CACHE_DIR= XDG_CACHE_HOME="$RO2" r3 "i~file" 2>&1)"; RC3=$?
T1J_OK=0
echo "$SJ" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "restart 沿用" in (d.get("cache",{}).get("fallback_reason") or "") else 1)' 2>/dev/null && T1J_OK=1
chmod 755 "$RO1" "$RO2"
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 0 ] \
   && echo "$ST" | grep -q "$D/foo" && echo "$ST" | grep -q '.r3cache' \
   && echo "$ST" | grep -q "磁盘缓存" && echo "$IFILE" | grep -q "$D/foo" \
   && echo "$ST" | grep -q "restart 沿用上次生效缓存目录" \
   && ! echo "$ST" | grep -q "首选层级：R3_CACHE_DIR" && [ "$T1J_OK" -eq 1 ]; then
    ok T1 "restart 传递旧 .r3cache 缓存目录且文本/JSON 原因标签正确"
else
    bad T1 "restart 沙箱恢复/原因标签失败（RC=$RC/$RC2/$RC3，JSON_OK=$T1J_OK，status: ${ST:0:200}）"
fi
r3 kill >/dev/null 2>&1 || true
OUT="$(R3_NO_CACHE=1 r3 restart 2>&1)"; RC=$?
ST="$(R3_NO_CACHE=1 r3 status 2>&1)"
if [ "$RC" -eq 0 ] && echo "$ST" | grep -q "0 个"; then
    ok T2 "纯内存模式 restart 正常完成且会话为空（文档化边界）"
else
    bad T2 "纯内存模式 restart 行为不符（RC=$RC，status: ${ST:0:200}）"
fi
r3 kill >/dev/null 2>&1 || true

# ================================================================ U 无当前会话退出码 5（#27）
echo "--- U 无当前会话退出码 5（#27）---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
r3 open /bin/ls >/dev/null 2>&1
r3 close >/dev/null 2>&1
OUT="$(r3 "afl~main" 2>&1)"; RC=$?
if [ "$RC" -eq 5 ] && echo "$OUT" | grep -q "无当前会话"; then
    ok U1a "close 当前会话后裸命令退出码 5 并提示无当前会话"
else
    bad U1a "无会话裸命令未按 5 报错（RC=$RC，输出: ${OUT:0:120}）"
fi
OUT="$(r3 --json "afl" 2>&1)"; RC=$?
U1B_OK=0
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is False and d.get("error") == "no_active_session" else 1)' 2>/dev/null && U1B_OK=1
if [ "$RC" -eq 5 ] && [ "$U1B_OK" -eq 1 ]; then
    ok U1b "--json 无会话错误回执为合法 JSON 且 error == no_active_session，退出码 5"
else
    bad U1b "--json 无会话回执不符（RC=$RC，JSON_OK=$U1B_OK，输出: ${OUT:0:200}）"
fi
r3 kill >/dev/null 2>&1 || true
rm -f "$R3_CACHE_DIR/state.json" 2>/dev/null || true
OUT="$(r3 "?t" 2>&1)"; RC=$?
if [ "$RC" -eq 5 ] && echo "$OUT" | grep -q "无当前会话"; then
    ok U2 "冷启动无 state.json 时裸命令退出码 5（不再懒建无文件会话空转）"
else
    bad U2 "冷启动无会话行为不符（RC=$RC，输出: ${OUT:0:120}）"
fi

# ================================================================ V open 信息速览（#28）
echo "--- V open 信息速览（#28）---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
OUT="$(r3 open /bin/ls 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "文件信息" \
   && echo "$OUT" | grep -q "arch=" && echo "$OUT" | grep -q "动态链接"; then
    ok V1 "open 输出追加文件信息速览行（arch 与动态链接）"
else
    bad V1 "open 速览行缺失（RC=$RC，输出: ${OUT:0:240}）"
fi
r3 close >/dev/null 2>&1
OUT="$(r3 open /bin/ls --no-analyze 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "文件信息"; then
    ok V2 "--no-analyze 打开同样含文件信息速览行"
else
    bad V2 "--no-analyze 速览行缺失（RC=$RC，输出: ${OUT:0:240}）"
fi

# ================================================================ W v1.3.1 修复回归（实测新问题）
echo "--- W v1.3.1 修复回归 ---"
# W1 --gitignore 追加到缓存锚点目录，而不是本次打开文件所在目录
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
WROOT="$TEST_TMP/wrepo"; WANCHOR="$WROOT/moe-tea"; WREPO="$WROOT/gitrepo"
mkdir -p "$WANCHOR" "$WREPO"; (cd "$WROOT" && git init -q)
cp /bin/true "$WANCHOR/seed"; cp /bin/true "$WREPO/target"
WRO1="$TEST_TMP/w-ro1"; WRO2="$TEST_TMP/w-ro2"; mkdir -p "$WRO1" "$WRO2"; chmod 555 "$WRO1" "$WRO2"
R3_CACHE_DIR="$WRO1" XDG_CACHE_HOME="$WRO2" r3 open "$WANCHOR/seed" >/dev/null 2>&1
OUT="$(R3_CACHE_DIR="$WRO1" XDG_CACHE_HOME="$WRO2" r3 open "$WREPO/target" --gitignore 2>&1)"; RC=$?
chmod 755 "$WRO1" "$WRO2"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "已追加" \
   && [ -f "$WANCHOR/.gitignore" ] && grep -q '\.r3cache/' "$WANCHOR/.gitignore" \
   && [ ! -f "$WREPO/.gitignore" ]; then
    ok W1 "--gitignore 追加到锚点目录 .gitignore；打开文件目录不产生 .gitignore"
else
    bad W1 "--gitignore 落点仍错（RC=$RC，anchor_gi=$([ -f "$WANCHOR/.gitignore" ] && echo yes || echo no)，repo_gi=$([ -f "$WREPO/.gitignore" ] && echo yes || echo no)）"
fi
# W2 status/help 展示 r3 自身版本
ST="$(r3 status 2>&1)"
SJ="$(r3 status --json 2>&1)"
W2_OK=0
echo "$SJ" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("daemon",{}).get("r3_version")=="2.1.0" else 1)' 2>/dev/null && W2_OK=1
if echo "$ST" | grep -q "r3 版本        : 2.1.0" && [ "$W2_OK" -eq 1 ]; then
    ok W2 "r3 status 文本与 --json 均含自身版本 2.1.0"
else
    bad W2 "r3 自身版本未展示（JSON_OK=$W2_OK，status: ${ST:0:160}）"
fi
# W3 会话目标解析失败退出码 6，连接故障仍为 1 语义
r3 open /bin/ls >/dev/null 2>&1
OUT="$(r3 --session /no/such/session "afl" 2>&1)"; RC=$?
W3_OK=0
echo "$OUT" | grep -q "不存在" && W3_OK=1
OUT_JSON="$(r3 --json --session /no/such/session "afl" 2>&1)"; RCJ=$?
W3J_OK=0
echo "$OUT_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is False and d.get("error")=="session_not_found" else 1)' 2>/dev/null && W3J_OK=1
if [ "$RC" -eq 6 ] && [ "$RCJ" -eq 6 ] && [ "$W3_OK" -eq 1 ] && [ "$W3J_OK" -eq 1 ]; then
    ok W3 "会话不存在退出码 6（文本/--json 均不再占用连接故障码 1）"
else
    bad W3 "会话不存在退出码不符（RC=$RC/$RCJ，JSON_OK=$W3_OK/$W3J_OK）"
fi

# ================================================================ X 调试（v2.0.0）
echo "--- X 调试（v2.0.0）---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
pkill -x dbg_target >/dev/null 2>&1 || true
sleep 0.2
DBG_DIR="$TEST_TMP/dbg"
DBG="$DBG_DIR/dbg_target"
X_SKIP=0
if command -v gcc >/dev/null 2>&1; then
    mkdir -p "$DBG_DIR"
    cat > "$DBG_DIR/dbg_target.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

static void tick(void) {
    for (volatile int i = 0; i < 3; i++) {
        /* 保证有函数可断、代码不会被完全优化掉 */
    }
}

int main(void) {
    printf("DBG_MARKER_1337\n");
    fflush(stdout);
    tick();
    sleep(3);
    return 0;
}
CEOF
    if gcc -O0 -o "$DBG" "$DBG_DIR/dbg_target.c" 2>"$DBG_DIR/gcc.err"; then
        RESIDUAL="$(pgrep -x dbg_target 2>/dev/null | wc -l)"
        if [ "$RESIDUAL" -eq 0 ]; then
            ok X0 "环境前置：r3 kill/清缓存/无 dbg_target 残留，gcc 已编译 $DBG"
        else
            bad X0 "环境前置失败：仍有 $RESIDUAL 个 dbg_target 残留"
            X_SKIP=1
        fi
    else
        skip X0 "gcc 编译失败（$(head -1 "$DBG_DIR/gcc.err" 2>/dev/null)），X 组 SKIP"
        X_SKIP=1
    fi
else
    skip X0 "gcc 缺失，X 组整体 SKIP（PLAN-v2 §6 X0）"
    X_SKIP=1
fi

if [ "$X_SKIP" -eq 1 ]; then
    skip X1 "gcc/环境不可用，X 组 SKIP"
else
    OUT="$(r3 open "$DBG" --debug 2>/dev/null)"; RC=$?
    ST="$(r3 status 2>/dev/null)"
    SJ="$(r3 status --json 2>/dev/null)"
    IFILE="$(r3 "i~file" 2>/dev/null)"; RC_IFILE=$?
    X1J_OK=0
    echo "$SJ" | python3 -c '
import json,sys
d=json.load(sys.stdin)
want=sys.argv[1]
fs=d.get("sessions",[])
sys.exit(0 if any(s.get("debug") is True and s.get("file") == want for s in fs) else 1)' "$DBG" 2>/dev/null && X1J_OK=1
    if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "调试" \
       && echo "$ST" | grep -q "调试" && [ "$X1J_OK" -eq 1 ] \
       && [ "$RC_IFILE" -eq 0 ] && echo "$IFILE" | grep -q "$DBG"; then
        ok X1 "--debug 入口：open/status 文本含调试，status --json debug==true，i~file 指向目标"
    else
        bad X1 "debug 入口/状态不符（RC=$RC/$RC_IFILE，JSON_OK=$X1J_OK，输出: ${OUT:0:160}）"
    fi
fi

if [ "$X_SKIP" -eq 1 ]; then
    skip X2 "gcc/环境不可用，X 组 SKIP"
else
    r3 "db main" >/dev/null 2>&1; RC1=$?
    r3 "dc" >/dev/null 2>&1; RC2=$?
    r3 "dr rax=0x1234" >/dev/null 2>&1; RC3=$?
    RAX="$(r3 "dr rax" 2>/dev/null)"; RC4=$?
    DBJ="$(r3 --json "dbj" 2>/dev/null)"; RC5=$?
    DBJ_OK=0
    echo "$DBJ" | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if isinstance(d, list) and any(x.get("name") == "main" for x in d if isinstance(x, dict)) else 1)' 2>/dev/null && DBJ_OK=1
    if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 0 ] \
       && [ "$RC4" -eq 0 ] && echo "$RAX" | grep -Eq "0x0*1234" \
       && [ "$RC5" -eq 0 ] && [ "$DBJ_OK" -eq 1 ]; then
        ok X2 "db main/dc/dr rax=0x1234/dr rax 生效（r2 实测回读 0x00001234），--json dbj 合法且含 main 断点"
    else
        bad X2 "断点/继续/寄存器不符（RC=$RC1/$RC2/$RC3/$RC4/$RC5，dbj_ok=$DBJ_OK）"
    fi
fi

if [ "$X_SKIP" -eq 1 ]; then
    skip X3 "gcc/环境不可用，X 组 SKIP"
else
    r3 "wx 9090 @ rsp" >/dev/null 2>&1; RC_WX=$?
    PX="$(r3 "px 2 @ rsp" 2>/dev/null)"; RC_PX=$?
    if [ "$RC_WX" -eq 0 ] && [ "$RC_PX" -eq 0 ] && echo "$PX" | grep -q "9090"; then
        ok X3 "wx 9090 @ rsp / px 2 @ rsp 内存写读生效"
    else
        bad X3 "内存写读不符（RC=$RC_WX/$RC_PX，输出: ${PX:0:120}）"
    fi
fi

if [ "$X_SKIP" -eq 1 ]; then
    skip X4 "gcc/环境不可用，X 组 SKIP"
else
    OUT="$(r3 "dc" 2>/dev/null)"; RC=$?
    if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q "DBG_MARKER_1337"; then
        ok X4 "child stdio 静音：无断点 dc 跑完目标，r3 stdout 不含 DBG_MARKER_1337"
    else
        bad X4 "目标 stdout 污染 r3 输出或 dc 失败（RC=$RC，输出: ${OUT:0:200}）"
    fi
fi

if [ "$X_SKIP" -eq 1 ]; then
    skip X5 "gcc/环境不可用，X 组 SKIP"
else
    r3 close >/dev/null 2>&1
    sleep 0.3
    N_AFTER_CLOSE="$(pgrep -x dbg_target 2>/dev/null | wc -l)"
    r3 open "$DBG" --debug >/dev/null 2>&1; RC_OPEN=$?
    P="$(r3 "dp" 2>/dev/null | awk '{print $2}')"
    R3_CMD_TIMEOUT=1 r3 "dc" >/dev/null 2>&1; RC_DC=$?
    sleep 0.3
    OLD_ALIVE=0; kill -0 "$P" 2>/dev/null && OLD_ALIVE=1
    N_NEW=0; NEW_PID=""
    for q in $(pgrep -x dbg_target 2>/dev/null); do
        N_NEW=$((N_NEW+1)); NEW_PID="$q"
    done
    ST="$(r3 status 2>/dev/null)"
    if [ "$N_AFTER_CLOSE" -eq 0 ] && [ "$RC_OPEN" -eq 0 ] && [ -n "$P" ] \
       && [ "$RC_DC" -eq 3 ] && [ "$OLD_ALIVE" -eq 0 ] \
       && [ "$N_NEW" -eq 1 ] && [ "$NEW_PID" != "$P" ] \
       && echo "$ST" | grep -q "调试"; then
        ok X5 "close 全组清理 debuggee；R3_CMD_TIMEOUT=1 dc 超时自愈并保持调试态"
    else
        bad X5 "debuggee 清理/自愈保持不符（close后=$N_AFTER_CLOSE，openRC=$RC_OPEN，P=$P，dcRC=$RC_DC，old_alive=$OLD_ALIVE，new_n=$N_NEW，new_pid=$NEW_PID）"
    fi
fi

if [ "$X_SKIP" -eq 1 ]; then
    skip X6 "gcc/环境不可用，X 组 SKIP"
else
    OUT="$(r3 open "$DBG" 2>/dev/null)"; RC=$?
    ST="$(r3 status 2>/dev/null)"
    IFILE="$(r3 "i~file" 2>/dev/null)"; RC_IFILE=$?
    if [ "$RC" -eq 0 ] && ! echo "$ST" | grep -q "调试" \
       && [ "$RC_IFILE" -eq 0 ] && echo "$IFILE" | grep -q "$DBG"; then
        ok X6 "同文件不带 --debug 打开切换回 static（status 无调试标签，i~file 正常）"
    else
        bad X6 "static/debug 模式切换不符（RC=$RC/$RC_IFILE，status: ${ST:0:160}）"
    fi
fi

if [ "$X_SKIP" -eq 1 ]; then
    skip X7 "gcc/环境不可用，X 组 SKIP"
else
    r3 "dp" >/dev/null 2>&1; RC_DP=$?
    AG_DOC=0; SK_DOC=0
    grep -q "yama" AGENTS.md 2>/dev/null && AG_DOC=1
    SKILL_FILE="/home/jin/.dsh/skills/r3/SKILL.md"
    [ -f "$SKILL_FILE" ] && grep -q "yama" "$SKILL_FILE" 2>/dev/null && SK_DOC=1
    if [ "$RC_DP" -eq 0 ] && [ "$AG_DOC" -eq 1 ] && [ "$SK_DOC" -eq 1 ]; then
        ok X7 "dp 透传退出码 0；AGENTS.md 与 SKILL.md 均含 yama/attach 边界说明"
    else
        bad X7 "透传面/文档边界不符（dp RC=$RC_DP，AGENTS_yama=$AG_DOC，SKILL_yama=$SK_DOC）"
    fi
fi

# ================================================================ Y v2.1.0（报错富化/回滚/输入注入）
echo "--- Y v2.1.0（报错富化/回滚/输入注入）---"
r3 kill >/dev/null 2>&1 || true
rm -rf "$R3_CACHE_DIR" 2>/dev/null || true
pkill -x dbg_in >/dev/null 2>&1 || true
sleep 0.2
Y_DBG_DIR="$TEST_TMP/dbg"
Y_DBG="$Y_DBG_DIR/dbg_in"
Y_IN="$TEST_TMP/dbg_in.txt"
Y_IN1="$TEST_TMP/dbg_in1.txt"
Y_IN2="$TEST_TMP/dbg_in2.txt"
Y_SKIP=0
if command -v gcc >/dev/null 2>&1; then
    mkdir -p "$Y_DBG_DIR"
    cat > "$Y_DBG_DIR/dbg_in.c" <<'CEOF'
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
CEOF
    if gcc -O0 -no-pie -o "$Y_DBG" "$Y_DBG_DIR/dbg_in.c" 2>"$Y_DBG_DIR/gcc.err"; then
        RESIDUAL="$(pgrep -x dbg_in 2>/dev/null | wc -l)"
        if [ "$RESIDUAL" -eq 0 ]; then
            ok Y0 "环境前置：r3 kill/清缓存/无 dbg_in 残留，gcc 已编译 $Y_DBG"
        else
            bad Y0 "环境前置失败：仍有 $RESIDUAL 个 dbg_in 残留"
            Y_SKIP=1
        fi
    else
        skip Y0 "gcc 编译失败（$(head -1 "$Y_DBG_DIR/gcc.err" 2>/dev/null)），Y 组 SKIP"
        Y_SKIP=1
    fi
else
    skip Y0 "gcc 缺失，Y 组整体 SKIP（PLAN-v2.1 §6 Y0）"
    Y_SKIP=1
fi

if [ "$Y_SKIP" -eq 1 ]; then
    skip Y1 "gcc/环境不可用，Y 组 SKIP"
else
    chmod 644 "$Y_DBG"
    OUT="$(r3 open "$Y_DBG" --debug 2>/dev/null)"; RC=$?
    SJ="$(r3 status --json 2>/dev/null)"
    Y1J_OK=0
    echo "$SJ" | python3 -c '
import json,sys
d=json.load(sys.stdin)
want=sys.argv[1]
fs=d.get("sessions",[])
sys.exit(0 if all(s.get("file") != want for s in fs) else 1)' "$Y_DBG" 2>/dev/null && Y1J_OK=1
    chmod 755 "$Y_DBG"
    if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "执行权限" \
       && echo "$OUT" | grep -q "chmod" && [ "$Y1J_OK" -eq 1 ]; then
        ok Y1 "debug 预检：644 目标被 X_OK 拦下，报错含执行权限/chmod；新建失败未留会话"
    else
        bad Y1 "debug 预检/会话清理不符（RC=$RC，JSON_OK=$Y1J_OK，输出: ${OUT:0:200}）"
    fi
fi

if [ "$Y_SKIP" -eq 1 ]; then
    skip Y2 "gcc/环境不可用，Y 组 SKIP"
else
    r3 close >/dev/null 2>&1 || true
    OUT="$(r3 open "$Y_DBG" 2>/dev/null)"; RC1=$?
    chmod 644 "$Y_DBG"
    OUT="$(r3 open "$Y_DBG" --debug 2>/dev/null)"; RC2=$?
    ST="$(r3 status 2>/dev/null)"
    OUT_CMD="$(r3 "i~file" 2>/dev/null)"; RC3=$?
    ST2="$(r3 status 2>/dev/null)"
    chmod 755 "$Y_DBG"
    OUT="$(r3 open "$Y_DBG" --debug 2>/dev/null)"; RC4=$?
    ST3="$(r3 status 2>/dev/null)"
    if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 1 ] \
       && ! echo "$ST" | grep -q "调试" && echo "$ST" | grep -q "待重开" \
       && [ "$RC3" -eq 0 ] && echo "$ST2" | grep -q "i~file" \
       && ! echo "$ST2" | grep -q "待重开" && ! echo "$ST2" | grep -q "调试" \
       && [ "$RC4" -eq 0 ] && echo "$ST3" | grep -q "调试"; then
        ok Y2 "static→debug 切换失败回滚为 static+待重开；普通命令自愈后标记消失；chmod 后重开成功"
    else
        bad Y2 "切换失败回滚/自愈不符（RC=$RC1/$RC2/$RC3/$RC4，ST: ${ST:0:160}，ST2: ${ST2:0:160}）"
    fi
fi

if [ "$Y_SKIP" -eq 1 ]; then
    skip Y3 "gcc/环境不可用，Y 组 SKIP"
else
    printf 'HELLO123\n' > "$Y_IN"
    OUT="$(r3 open "$Y_DBG" --debug --stdin "$Y_IN" 2>/dev/null)"; RC=$?
    r3 "db sym.mark_after_input" >/dev/null 2>&1; RC_DB=$?
    OUT_DC="$(r3 "dc" 2>/dev/null)"; RC_DC=$?
    # 实测 r2 6.1.9 全局变量 flag 为 obj.buf（PLAN 文本写 sym.buf，以实测为准）
    PS="$(r3 "ps @ obj.buf" 2>/dev/null)"; RC_PS=$?
    ST="$(r3 status 2>/dev/null)"
    if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "输入文件" \
       && [ "$RC_DB" -eq 0 ] && [ "$RC_DC" -eq 0 ] \
       && ! printf '%s' "$OUT_DC" | grep -q "STDIN_MARKER" \
       && [ "$RC_PS" -eq 0 ] && echo "$PS" | grep -q "HELLO123" \
       && echo "$ST" | grep -q "\[输入文件: $Y_IN\]"; then
        ok Y3 "--stdin 喂入 HELLO123 且保持 stdout 静音；status 会话显示输入文件"
    else
        bad Y3 "--stdin 喂入/静音/状态不符（RC=$RC/$RC_DB/$RC_DC/$RC_PS，OUT: ${OUT:0:160}，PS: ${PS:0:120}）"
    fi
fi

if [ "$Y_SKIP" -eq 1 ]; then
    skip Y4 "gcc/环境不可用，Y 组 SKIP"
else
    OUT1="$(r3 open "$Y_DBG" --stdin "$Y_IN" 2>/dev/null)"; RC1=$?
    OUT2="$(r3 open "$Y_DBG" --debug --stdin 2>/dev/null)"; RC2=$?
    if [ "$RC1" -eq 1 ] && echo "$OUT1" | grep -q "用法" \
       && [ "$RC2" -eq 1 ] && echo "$OUT2" | grep -q "用法"; then
        ok Y4 "用法校验：--stdin 无 --debug / --stdin 缺值均退出码 1 且提示用法"
    else
        bad Y4 "--stdin 用法校验不符（RC=$RC1/$RC2，OUT1: ${OUT1:0:120}，OUT2: ${OUT2:0:120}）"
    fi
fi

if [ "$Y_SKIP" -eq 1 ]; then
    skip Y5 "gcc/环境不可用，Y 组 SKIP"
else
    r3 close >/dev/null 2>&1 || true
    OUT="$(r3 open "$Y_DBG" --debug --stdin "$TEST_TMP/nonexistent-in" 2>/dev/null)"; RC=$?
    ST="$(r3 status 2>/dev/null)"
    if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "输入文件" \
       && ! echo "$ST" | grep -q "输入文件"; then
        ok Y5 "输入文件不存在/不可读：open 失败且不留带输入文件标记的会话"
    else
        bad Y5 "输入文件校验不符（RC=$RC，OUT: ${OUT:0:160}，ST: ${ST:0:160}）"
    fi
fi

if [ "$Y_SKIP" -eq 1 ]; then
    skip Y6 "gcc/环境不可用，Y 组 SKIP"
else
    printf 'INPUT_ONE\n' > "$Y_IN1"
    printf 'INPUT_TWO\n' > "$Y_IN2"
    OUT1="$(r3 open "$Y_DBG" --debug --stdin "$Y_IN1" 2>/dev/null)"; RC1=$?
    P1="$(r3 "dp" 2>/dev/null | awk '{print $2}')"
    OUT2="$(r3 open "$Y_DBG" --debug --stdin "$Y_IN2" 2>/dev/null)"; RC2=$?
    P2="$(r3 "dp" 2>/dev/null | awk '{print $2}')"
    r3 "db sym.mark_after_input" >/dev/null 2>&1; RC_DB=$?
    r3 "dc" >/dev/null 2>&1; RC_DC=$?
    # 实测 r2 6.1.9 全局变量 flag 为 obj.buf（PLAN 文本写 sym.buf，以实测为准）
    PS2="$(r3 "ps @ obj.buf" 2>/dev/null)"; RC_PS=$?
    OUT3="$(r3 open "$Y_DBG" --debug 2>/dev/null)"; RC3=$?
    P3="$(r3 "dp" 2>/dev/null | awk '{print $2}')"
    ST3="$(r3 status 2>/dev/null)"
    if [ "$RC1" -eq 0 ] && [ -n "$P1" ] \
       && [ "$RC2" -eq 0 ] && echo "$OUT2" | grep -q "重新拉起" \
       && [ -n "$P2" ] && [ "$P2" != "$P1" ] \
       && [ "$RC_DB" -eq 0 ] && [ "$RC_DC" -eq 0 ] \
       && [ "$RC_PS" -eq 0 ] && echo "$PS2" | grep -q "INPUT_TWO" \
       && [ "$RC3" -eq 0 ] && echo "$OUT3" | grep -q "重新拉起" \
       && [ -n "$P3" ] && [ "$P3" != "$P2" ] \
       && ! echo "$ST3" | grep -q "\[输入文件"; then
        ok Y6 "换输入重新拉起（PID 变化/IN2 生效）；不带 --stdin 重开回默认静音且无输入文件标记"
    else
        bad Y6 "换输入 respawn 不符（RC=$RC1/$RC2/$RC3，P1=$P1，P2=$P2，P3=$P3，PS: ${PS2:0:120}）"
    fi
fi

if [ "$Y_SKIP" -eq 1 ]; then
    skip Y7 "gcc/环境不可用，Y 组 SKIP"
else
    OUT="$(r3 open "$Y_DBG" --debug --stdin "$Y_IN" 2>/dev/null)"; RC_OPEN=$?
    R3_CMD_TIMEOUT=1 r3 "dc" >/dev/null 2>&1; RC_DC=$?
    ST="$(r3 status 2>/dev/null)"
    r3 "db sym.mark_after_input" >/dev/null 2>&1; RC_DB=$?
    r3 "dc" >/dev/null 2>&1; RC_DC2=$?
    # 实测 r2 6.1.9 全局变量 flag 为 obj.buf（PLAN 文本写 sym.buf，以实测为准）
    PS="$(r3 "ps @ obj.buf" 2>/dev/null)"; RC_PS=$?
    if [ "$RC_OPEN" -eq 0 ] && [ "$RC_DC" -eq 3 ] \
       && echo "$ST" | grep -q "调试" && echo "$ST" | grep -q "\[输入文件: $Y_IN\]" \
       && [ "$RC_DB" -eq 0 ] && [ "$RC_DC2" -eq 0 ] \
       && [ "$RC_PS" -eq 0 ] && echo "$PS" | grep -q "HELLO123"; then
        ok Y7 "自愈重建保持 --stdin 注入（超时后重新拉起、重读同一输入文件）"
    else
        bad Y7 "自愈保持输入注入不符（RC=$RC_OPEN/$RC_DC/$RC_DB/$RC_DC2/$RC_PS，ST: ${ST:0:160}，PS: ${PS:0:120}）"
    fi
fi

if [ "$Y_SKIP" -eq 1 ]; then
    skip Y8 "gcc/环境不可用，Y 组 SKIP"
else
    AG_DOC=0; SK_DOC=0
    grep -q -- "--stdin" AGENTS.md && grep -q "chmod" AGENTS.md && grep -q "待重开" AGENTS.md && AG_DOC=1
    SKILL_FILE="/home/jin/.dsh/skills/r3/SKILL.md"
    if [ -f "$SKILL_FILE" ] && grep -q -- "--stdin" "$SKILL_FILE" \
       && grep -q "chmod" "$SKILL_FILE" && grep -q "待重开" "$SKILL_FILE"; then SK_DOC=1; fi
    HELP="$(r3 help 2>/dev/null)"
    if [ "$AG_DOC" -eq 1 ] && [ "$SK_DOC" -eq 1 ] && echo "$HELP" | grep -q -- "--stdin"; then
        ok Y8 "文档同步：AGENTS/SKILL 含 --stdin/chmod/待重开；r3 help 用法行含 --stdin"
    else
        bad Y8 "文档同步缺失（AGENTS=$AG_DOC，SKILL=$SK_DOC，HELP_stdin=$(echo "$HELP" | grep -c -- --stdin)）"
    fi
fi

# ================================================================ F 交付物与约束（静态检查）
echo "--- F 交付物与约束（静态检查）---"
F1_OK=1
for f in PLAN.md PLAN-v1.1.md PLAN-v1.2.md PLAN-v1.3.md PLAN-v2.md PLAN-v2.1.md DESIGN.md r3 install.sh AGENTS.md tests/acceptance.sh; do
    [ -f "$f" ] || F1_OK=0
done
[ "$F1_OK" -eq 1 ] && ok F1 "交付物齐全" || bad F1 "缺少交付文件（PLAN.md/PLAN-v1.1.md/PLAN-v1.2.md/PLAN-v1.3.md/PLAN-v2.md/PLAN-v2.1.md/DESIGN.md/r3/install.sh/AGENTS.md/tests/acceptance.sh）"

F2_OK=1
IMPORTS="$(grep -oE '^\s*(import|from)\s+[a-zA-Z0-9_]+' r3 | awk '{print $2}' | sort -u)"
for m in $IMPORTS; do
    python3 -c "import sys; sys.exit(0 if '$m' in sys.stdlib_module_names else 1)" 2>/dev/null || F2_OK=0
done
[ "$F2_OK" -eq 1 ] && ok F2 "r3 单文件且 import 全属 Python 标准库" || bad F2 "存在非标准库 import（$IMPORTS）"

if r2 -v 2>/dev/null | grep -q "6.1.9" && [ -z "$(find . -name '*.c' -o -name '*.h' 2>/dev/null)" ]; then
    ok F3 "r2 仍为 6.1.9，仓库无 r2 源码"
else
    bad F3 "r2 版本被改或仓库混入 C 源码"
fi
F4_OK=1
for pat in DBG_PROFILE_CONTENT start_new_session os.killpg --debug OpenMode.DEBUG; do
    grep -q -- "$pat" r3 || F4_OK=0
done
# v2.1 标记（PLAN-v2.1 §6 F4 修订）
for pat in stdin_file X_OK startup_failed _dbg_profile_content STDERR_TAIL_LEN; do
    grep -q -- "$pat" r3 || F4_OK=0
done
if [ "$F4_OK" -eq 1 ]; then
    ok F4 "v2 debug 实现标记齐全（DBG_PROFILE_CONTENT/start_new_session/os.killpg/--debug/OpenMode.DEBUG + v2.1: stdin_file/X_OK/startup_failed/_dbg_profile_content/STDERR_TAIL_LEN）"
else
    bad F4 "v2 debug / v2.1 实现标记缺失"
fi
if grep -q 'exit 0' "$0" && grep -q 'exit 1' "$0"; then
    ok F5 "汇总逻辑：全绿退出码 0、有 FAIL 退出码 1"
else
    bad F5 "汇总逻辑缺失"
fi
F6_OK=1
for pat in R3_CACHE_DIR R3_SOCK_PATH R3_NO_CACHE verify_current_file meta; do
    grep -q "$pat" r3 || F6_OK=0
done
for pat in MAX_SESSIONS session_id active_sid sessions close; do
    grep -q "$pat" r3 || F6_OK=0
done
grep -q -- '--json' r3 || F6_OK=0
# 决策 #19：首字符豁免启发式必须废除
grep -qE 'startswith\(.*[{\[]' r3 && F6_OK=0
[ "$F6_OK" -eq 1 ] && ok F6 "v1.2 特性静态检查通过（路径可配置/校验+meta/会话池/显式 --json/首字符豁免废除）" \
                   || bad F6 "v1.2 特性缺失（检查 R3_CACHE_DIR/R3_SOCK_PATH/R3_NO_CACHE/verify_current_file/meta/MAX_SESSIONS/session_id/active_sid/sessions/close/--json/首字符豁免废除）"
if grep -q "cache-clean" r3; then
    grep -q 'cache_clean' r3 && ok F7 "cache-clean 保留字与 daemon action 存在" || bad F7 "cache-clean 实现不完整"
else
    skip F7 "随 J1 跳过（cache-clean 可选项未实现）"
fi
F8_OK=1
for pat in R3_VERSION R3_CACHE_REASON_OVERRIDE session_ambiguous; do
    grep -q "$pat" r3 || F8_OK=0
done
grep -q 'os.path.join(self.anchor_dir, ".gitignore")' r3 || F8_OK=0
[ "$F8_OK" -eq 1 ] && ok F8 "v1.3.1 修复静态检查通过（版本展示/restart 原因标签/退出码 6/锚点 .gitignore）"                    || bad F8 "v1.3.1 修复缺失（R3_VERSION/R3_CACHE_REASON_OVERRIDE/session_ambiguous/锚点 .gitignore）"

# ================================================================ 汇总
echo
echo "================ 汇总 ================"
echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
    echo "结论: 全部通过（SKIP=$SKIP）→ 退出码 0"
    exit 0
else
    echo "结论: 存在 FAIL 项:$FAILED → 退出码 1"
    exit 1
fi
