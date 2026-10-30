#!/usr/bin/env bash
# toggle-ai-ready.sh — .ai-ready 规则一键替换 / 一键还原
# version: 2026103009
#
# 托管：仓库里放脚本 + 载荷包，服务器上一条命令安装（监控随安装自动开启）:
#   curl -fsSL <URL_BASE>/toggle-ai-ready.sh | sh              # 安装 → 进菜单
#   curl -fsSL <URL_BASE>/toggle-ai-ready.sh | sh -s -- replace /workspace/projA
#
# 设计要点:
#   - 安装与替换解耦：装完只落地 kit（脚本 + new/ 载荷），不动任何目标项目
#   - 重复执行安全：已装则比对版本，有新版本先更新再进菜单，无更新直接进菜单
#   - 所有动作都能单独调：menu/list/status/replace/restore/diff/backups/...
#
# 环境变量:
#   AIREADY_URL_BASE    仓库原始文件地址（默认见下），脚本与载荷都从这里下载
#   AIREADY_KIT_DIR     安装目录，默认 /workspace/.ai-ready-kit
#   AIREADY_SKIP_UPDATE 非空则跳过启动时的版本检查（离线环境用）
#   AIREADY_UPDATE_TTL  版本检查结果缓存秒数，默认 600
#   SEARCH_ROOT         目标探测根目录；不设时依次扫 /workspace 与 /root

# ---------- POSIX 引导：服务器上 sh 通常是 dash，不认 bash 语法 ----------
# `curl ... | sh` 时由这段接管：把本脚本下载成临时文件，交给 bash 执行。
# 以文件方式运行（sh toggle-ai-ready.sh ...）则直接换 bash 重入，不做二次下载。
if [ -z "${BASH_VERSION:-}" ]; then
    __sh_die() { printf '[错误] %s\n' "$*" >&2; exit 1; }
    command -v bash >/dev/null 2>&1 || __sh_die "需要 bash，请先安装：apt-get install -y bash"
    if [ -f "$0" ] && [ -r "$0" ] && head -c 64 "$0" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
        exec bash "$0" "$@"
    fi
    __ub="${AIREADY_URL_BASE:-https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main}"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || __sh_die "缺少 curl/wget"
    __tmp="$(mktemp /tmp/aiready-toggle.XXXXXX 2>/dev/null)" || __tmp="/tmp/aiready-toggle.$$"
    __dl() {
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 5 --max-time 30 "$1/toggle-ai-ready.sh" -o "$__tmp"
        else
            wget -qO "$__tmp" "$1/toggle-ai-ready.sh"
        fi
    }
    # raw.githubusercontent 在国内经常连不上，依次回退到 jsDelivr 镜像
    for __b in "$__ub" "https://cdn.jsdelivr.net/gh/qq928820655/ai-ready-kit@main"; do
        __dl "$__b" && break
    done
    [ -s "$__tmp" ] || { rm -f "$__tmp"; __sh_die "下载失败: $__ub"; }
    AIREADY_PIPED=1
    export AIREADY_PIPED
    exec bash "$__tmp" "$@"
fi

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
# 两种情况自己不在磁盘上：POSIX 引导重启到 /tmp（AIREADY_PIPED=1），
# 或 sh 本身就是 bash 直接吃管道（BASH_SOURCE 为空，dirname 会算成当前目录）
if [ -n "${AIREADY_PIPED:-}" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then
    KIT_DIR="${AIREADY_KIT_DIR:-/workspace/.ai-ready-kit}"
fi
# 引导重启产生的临时脚本，进程退出时清掉
case "${BASH_SOURCE[0]:-}" in /tmp/aiready-toggle*) trap 'rm -f "${BASH_SOURCE[0]}"' EXIT ;; esac

NEW_DIR="$KIT_DIR/new"
BACKUP_ROOT="$KIT_DIR/backups"
MARKER_DIR="$BACKUP_ROOT/.markers"
STATE_FILE="$KIT_DIR/.installed"
CHECK_CACHE="$KIT_DIR/.updatecheck"
SEARCH_ROOT="${SEARCH_ROOT:-}"
DEFAULT_BASE="https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main"
# raw 在国内常见超时，按顺序回退；AIREADY_URL_BASE 一旦显式指定就只用它
MIRROR_BASES=(
    "https://cdn.jsdelivr.net/gh/qq928820655/ai-ready-kit@main"
    "https://ghproxy.net/https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main"
)
URL_BASE="${AIREADY_URL_BASE:-$DEFAULT_BASE}"
BASE_CACHE="$KIT_DIR/.base"
SCRIPT_NAME="toggle-ai-ready.sh"
PAYLOAD_NAME="ai-ready-payload.tar.gz"
VERSION="2026103009"
UPDATE_TTL="${AIREADY_UPDATE_TTL:-600}"

C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_B='\033[36m'; C_0='\033[0m'
say()  { printf "%b%s%b\n" "$C_B" "$*" "$C_0"; }
ok()   { printf "%b%s%b\n" "$C_G" "$*" "$C_0"; }
warn() { printf "%b%s%b\n" "$C_Y" "$*" "$C_0"; }
err()  { printf "%b%s%b\n" "$C_R" "[错误] $*" "$C_0" >&2; }
die()  { err "$*"; exit 1; }

# 全局状态：check_update 会写 IV / RV
IV=""; RV=""

# ---------- 版本与安装状态 ----------

# 未安装时返回空串且退出码 0：这些函数在 set -e 下被 $( ) 调用，
# 若返回非零会让调用方整段静默退出（首次安装正是没有状态文件的情况）
installed_version() {
    [ -f "$STATE_FILE" ] || return 0
    sed -n 's/^VERSION=//p' "$STATE_FILE" 2>/dev/null
}
installed_at() {
    [ -f "$STATE_FILE" ] || return 0
    sed -n 's/^INSTALLED_AT=//p' "$STATE_FILE" 2>/dev/null
}

count_new() {
    if [ -d "$NEW_DIR" ]; then find "$NEW_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; else echo 0; fi
}

# 已安装 = 脚本在位 + new/rules 与 new/skills 都有内容
is_installed() {
    [ -f "$KIT_DIR/$SCRIPT_NAME" ] || return 1
    [ -d "$NEW_DIR/rules" ] || return 1
    [ "$(count_new)" -gt 0 ] || return 1
    return 0
}

# $1 > $2 → 0；相等或更小 → 1。日期版本号 YYYYMMDD.N，sort -V 可正确排序
ver_gt() {
    [ "$1" = "$2" ] && return 1
    local m
    m="$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | tail -1)"
    if [ -n "$m" ]; then [ "$m" = "$1" ] && return 0 || return 1; fi
    [ "$1" \> "$2" ]
}

# 取远端脚本头部的 version 行；TTL 内走缓存。失败返回非零（不退出）
remote_version() {
    local now ts ver
    now="$(date +%s)"
    if [ -f "$CHECK_CACHE" ]; then
        ts="$(sed -n 's/^TS=//p'  "$CHECK_CACHE" | head -1)"
        ver="$(sed -n 's/^VER=//p' "$CHECK_CACHE" | head -1)"
        # 缓存未过期直接复用，避免每次进菜单都拉一遍脚本
        if [ -n "${ts:-}" ] && [ -n "${ver:-}" ] && [ $((now - ts)) -lt "$UPDATE_TTL" ] 2>/dev/null; then
            printf '%s' "$ver"; return 0
        fi
    fi
    command -v curl >/dev/null 2>&1 || return 1
    local tmp; tmp="$(mktemp 2>/dev/null)" || return 1
    if ! fetch_file "$SCRIPT_NAME" "$tmp" 10; then
        rm -f "$tmp"; return 1
    fi
    ver="$(sed -n 's/^# version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$tmp" | head -1)"
    rm -f "$tmp"
    [ -n "$ver" ] || return 1

    # 命中源不是主通道时再向主通道核对一次：jsDelivr 的 @main 分支引用最长缓存 12 小时，
    # 只用它的版本号会漏判新版，导致永远停在旧版。主通道更高就采信它并作废源缓存，
    # 让随后的 do_install 从主通道重新试，不会从落后源下载回旧脚本。
    if [ -z "${AIREADY_URL_BASE:-}" ] && [ "${URL_BASE:-}" != "$DEFAULT_BASE" ]; then
        local hv
        hv="$(curl -fsSL --connect-timeout 5 --max-time 10 "$DEFAULT_BASE/$SCRIPT_NAME" 2>/dev/null \
              | sed -n 's/^# version:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"
        if [ -n "${hv:-}" ] && ver_gt "$hv" "$ver"; then
            ver="$hv"
            rm -f "$BASE_CACHE"
        fi
    fi

    printf 'TS=%s\nVER=%s\n' "$now" "$ver" > "$CHECK_CACHE" 2>/dev/null || true
    printf '%s' "$ver"
}

# 0=有新版 1=已最新 2=检查失败（网络/地址问题）。结果写入 IV / RV
check_update() {
    IV="$(installed_version)"; [ -n "$IV" ] || IV="$VERSION"
    if ! RV="$(remote_version)"; then RV=""; return 2; fi
    [ -n "$RV" ] || return 2
    if ver_gt "$RV" "$IV"; then return 0; fi
    return 1
}

# ---------- 安装 / 更新 ----------

# $1=仓库内文件名 $2=落盘路径 $3=超时秒。依次试 raw → jsDelivr → ghproxy，
# 命中的 base 写进 .base 缓存，后续请求直接走它能少等一轮超时。
fetch_file() {
    local name="$1" dest="$2" tmo="${3:-60}" b bases=() seen=" "
    command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装"
    if [ -n "${AIREADY_URL_BASE:-}" ]; then
        bases=("$AIREADY_URL_BASE")
    else
        [ -s "$BASE_CACHE" ] && bases+=("$(head -1 "$BASE_CACHE")")
        bases+=("$DEFAULT_BASE" "${MIRROR_BASES[@]}")
    fi
    for b in "${bases[@]}"; do
        [ -n "$b" ] || continue
        case "$seen" in *" $b "*) continue ;; esac
        seen="$seen$b "
        if curl -fsSL --connect-timeout 5 --max-time "$tmo" "$b/$name" -o "$dest" 2>/dev/null; then
            URL_BASE="$b"
            mkdir -p "$KIT_DIR" 2>/dev/null || true
            printf '%s\n' "$b" > "$BASE_CACHE" 2>/dev/null || true
            return 0
        fi
    done
    return 1
}

# 把 $1 指向的 tar.gz 解到 KIT_DIR，替换 new/
unpack_payload() {
    local pkg="$1" kit="$KIT_DIR" lst
    # 在 kit 目录内用相对名操作 tar，避免 Windows 盘符冒号被 tar 当成远程主机
    lst="$( cd "$kit" && tar tzf "$pkg" 2>/dev/null )" || die "载荷包损坏，已放弃"
    printf '%s\n' "$lst" | grep -q '^new/rules/' || die "载荷不完整（缺 new/rules/），已放弃"
    rm -rf "$kit/new"
    ( cd "$kit" && tar xzf "$pkg" ) || die "解包失败，已放弃"
    rm -f "$pkg"
}

link_entry() {
    local kit="$KIT_DIR" entry="bash $kit/$SCRIPT_NAME"
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ] && ln -sf "$kit/$SCRIPT_NAME" /usr/local/bin/ai-ready 2>/dev/null; then
        ok "快捷命令: ai-ready → $kit/$SCRIPT_NAME"
    else
        say "未建快捷命令（/usr/local/bin 不可写），可自行加别名:"
        say "  echo \"alias ai-ready='bash $kit/$SCRIPT_NAME'\" >> ~/.bashrc && source ~/.bashrc"
    fi
    return 0
}

do_install() {
    local kit="$KIT_DIR" stmp="$KIT_DIR/.toggle.tmp" ptmp="$KIT_DIR/.payload.tmp" newv cur

    # 下载脚本 + 载荷；被 AIREADY_URL_BASE 覆盖时只走指定源
    dl_pair() {
        fetch_file "$SCRIPT_NAME" "$stmp" 30 || { rm -f "$stmp"; die "下载脚本失败（已试 raw 与镜像）: $SCRIPT_NAME"; }
        bash -n "$stmp" || { rm -f "$stmp"; die "下载的脚本语法异常，已放弃"; }
        say "脚本与载荷来源 ← $URL_BASE"
        fetch_file "$PAYLOAD_NAME" "$ptmp" 180 || { rm -f "$stmp" "$ptmp"; die "下载载荷失败（已试 raw 与镜像）: $PAYLOAD_NAME"; }
    }
    script_ver() { sed -n 's/^# version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$stmp" | head -1; }

    mkdir -p "$kit"
    rm -f "$stmp" "$ptmp"
    dl_pair

    # 命中的源是镜像（.base 缓存）时，下到的可能比当前还旧 —— CDN 分支引用缓存最长 12 小时。
    # 这种情况作废源缓存、强制回主通道重下一次，避免"更新"把版本往回带。
    newv="$(script_ver)"
    cur="$(installed_version)"; [ -n "$cur" ] || cur="$VERSION"
    if [ -n "${newv:-}" ] && [ -z "${AIREADY_URL_BASE:-}" ] \
       && [ "${URL_BASE:-}" != "$DEFAULT_BASE" ] && ! ver_gt "$newv" "$cur"; then
        say "命中的源只给到 v$newv（当前 v$cur），回主通道重取"
        rm -f "$BASE_CACHE" "$stmp" "$ptmp"
        AIREADY_URL_BASE="$DEFAULT_BASE" dl_pair
        newv="$(script_ver)"
    fi

    mv -f "$stmp" "$kit/$SCRIPT_NAME"
    chmod +x "$kit/$SCRIPT_NAME"
    unpack_payload "$ptmp"

    # 版本以落盘脚本为准：本进程可能是旧版，正在自我更新
    [ -n "${newv:-}" ] || newv="$VERSION"
    printf 'VERSION=%s\nINSTALLED_AT=%s\nURL_BASE=%s\n' \
        "$newv" "$(date +%Y%m%d-%H%M%S)" "$URL_BASE" > "$STATE_FILE"
    rm -f "$CHECK_CACHE"

    ok "安装/更新完成: v$newv → $kit（new/ 共 $(count_new) 个文件）"
    link_entry
    # 监控默认开启：装完即守，不再要求用户额外执行一次。
    # AIREADY_NO_WATCH=1 可跳过（CI / 只装不跑的场景）。
    if [ -z "${AIREADY_NO_WATCH:-}" ]; then
        ensure_watcher || true
        if watch_alive; then
            do_guard_once >/dev/null 2>&1 || true   # 载荷可能换了，重烤基准
        else
            do_guard_start quiet || true
        fi
    fi
    return 0
}

do_repair() {
    local ptmp="$KIT_DIR/.payload.tmp"
    mkdir -p "$KIT_DIR"
    say "重新下载载荷 ← $PAYLOAD_NAME"
    fetch_file "$PAYLOAD_NAME" "$ptmp" 180 || { rm -f "$ptmp"; die "下载载荷失败（已试 raw 与镜像）"; }
    unpack_payload "$ptmp"
    ok "new/ 已重建，共 $(count_new) 个文件（脚本版本不变: v$(installed_version || echo "$VERSION")）"
    if [ -z "${AIREADY_NO_WATCH:-}" ]; then
        ensure_watcher >/dev/null 2>&1 || true
        if watch_alive; then
            do_guard_once >/dev/null 2>&1 || true
        else
            do_guard_start quiet || true
        fi
    fi
}

do_uninstall() {
    local yn
    printf '%b卸载只删除 %s 下的 kit 组件，目标项目的 .ai-ready 不受影响。确认?[Y/n，输入 n 取消]: %b' "$C_Y" "$KIT_DIR" "$C_0"
    read -r yn || yn=""
    case "$yn" in n|N) say "已取消"; return 0 ;; esac
    if [ -L /usr/local/bin/ai-ready ]; then rm -f /usr/local/bin/ai-ready; fi
    do_guard_stop >/dev/null 2>&1 || true
    rm -rf "$NEW_DIR" "$BACKUP_ROOT" "$STATE_FILE" "$CHECK_CACHE" "$BASE_CACHE" \
           "$KIT_DIR/bin" "$GOLD_DIR" "$WATCH_PID" "$GUARD_LOG" \
           "$KIT_DIR/.toggle.tmp" "$KIT_DIR/.payload.tmp"
    ok "已卸载组件（/usr/local/bin/ai-ready 符号链接一并移除）"
    say "彻底删除目录: rm -rf $KIT_DIR"
    exit 0
}

# ---------- 实时守护 ----------
# 平台每次切模型 / 重开项目，会把 project-tpl 里的 .ai-ready 重铺一遍
# （create .xxx.tmp.<rand> → rename），本地改写被覆盖。
# 这里直接监听那个目录本身，发生写 / 替换 / 删除就按基准副本写回。
#
# 三层结构，从快到慢：
#   1. inotify 事件（CLOSE_WRITE / MOVED_TO / CREATE / DELETE）  毫秒级
#   2. 60ms 静默合并，同批事件只比对一次
#   3. 每秒全量兜底比对，覆盖丢事件 / 队列溢出 / 目录被整棵换掉
# 另加 opencode 进程启动检测：新 pid 出现立刻比对一次，堵住"重铺→重启"的窗口。

GUARD_LOG="$KIT_DIR/watch.log"
WATCH_PY="$KIT_DIR/bin/aiready-watch.py"
WATCH_PID="$KIT_DIR/.watch.pid"
GOLD_DIR="$KIT_DIR/.gold"

# 守护脚本以 base64 内嵌：curl 单文件完成全部安装，不额外拉第二个文件，
# 也不会因为 raw.githubusercontent 限流而装一半。
watcher_b64() {
    cat <<'AIREADY_WATCHER_B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIC0qLSBjb2Rpbmc6IHV0Zi04IC0qLQoiIiJhaXJlYWR5
LXdhdGNoLnB5IOKAlCAuYWktcmVhZHkg5qih5p2/55uu5b2V5a6e5pe25a6I5oqkCgrlubPlj7Dm
r4/mrKHliIfmjaLmqKHlnosgLyDph43lvIDpobnnm67vvIzkvJrmioogcHJvamVjdC10cGwg6YeM
55qEIC5haS1yZWFkeSDph43pk7rkuIDpgY0K77yIY3JlYXRlIC54eHgudG1wLjxyYW5kPiDihpIg
cmVuYW1l77yJ77yM5pys5Zyw5pS55YaZ6KKr6KaG55uW44CCCuacrOi/m+eoi+ebkeWQrOmCo+S4
quebruW9le+8jOS4gOaXpuWPkeeUn+WGmS/mm7/mjaIv5Yig6Zmk77yM56uL5Y2z5oyJ5Z+65YeG
5Ymv5pys5YWo6YeP5YaZ5Zue44CCCgrlt6XkvZzlsYLmrKHvvIjkuInlsYLvvIzku47lv6vliLDm
haLvvInvvJoKICAxLiBpbm90aWZ5IOS6i+S7tiAgIENMT1NFX1dSSVRFIC8gTU9WRURfVE8gLyBD
UkVBVEUgLyBERUxFVEUgLi4uIOavq+enkue6pwogIDIuIOmdmem7mOWQiOW5tiAgICAgICDlkIzm
ibnkuovku7blgZwgNTBtcyDmlLbpvZDvvIzkuIDmrKHmr5Tlr7nvvIzpgb/lhY0gMjAg5qyh6YeN
5aSN5omr5o+PCiAgMy4g6L2u6K+i5YWc5bqVICAgICAgIOaXoOS6i+S7tuaXtuavj+enkuWFqOmH
j+avlOWvueS4gOasoe+8iDI2IOaWh+S7tu+8jOW+ruenkue6p++8ie+8jAogICAgICAgICAgICAg
ICAgICAgIOimhuebliBpbm90aWZ5IOS4ouS6i+S7tiAvIOmYn+WIl+a6ouWHuiAvIOebruW9leii
q+aVtOajteaNouaOieeahOaDheWGtQogIOWPpuaciSBvcGVuY29kZSDov5vnqIvlkK/liqjmo4Dm
tYvvvJrmlrAgcGlkIOWHuueOsOeri+WIu+avlOWvueS4gOasoe+8jOWgteS9jyLph43pk7og4oaS
IOmHjeWQryLkuYvpl7TnmoTnqpflj6PjgIIKCuWtkOWRveS7pO+8mgogIGRhZW1vbiAgIOW4uOmp
u++8iOm7mOiupO+8iQogIG9uY2UgICAgIOWNleasoeW3oeajgOW5tuWGmeWbngogIHN0YXR1cyAg
IOaJk+WNsOeKtuaAge+8iFBJRCAvIOWtmOa0uyAvIOW9k+WJjeW3ruW8guaVsCAvIGlub3RpZnkg
5Y+v55So77yJCiAgc3RvcCAgICAg5YGc5o6J5bi46am76L+b56iLCgrlj4LmlbDlhajpg6jlpJbn
va7vvIznvLrnnIHlgLzmjIkgTW9ua2V5Q29kZSDlrrnlmajluIPlsYDmjqjlr7zjgIIKIiIiCgpp
bXBvcnQgYXJncGFyc2UKaW1wb3J0IGN0eXBlcwppbXBvcnQgb3MKaW1wb3J0IHNlbGVjdAppbXBv
cnQgc2lnbmFsCmltcG9ydCBzdHJ1Y3QKaW1wb3J0IHN5cwppbXBvcnQgdGltZQoKIyAtLS0tLS0t
LS0tLS0tLS0tIGlub3RpZnkg5bi46YePIC0tLS0tLS0tLS0tLS0tLS0KSU5fQVRUUklCID0gMHgw
MDAwMDAwNApJTl9DTE9TRV9XUklURSA9IDB4MDAwMDAwMDgKSU5fTU9WRURfRlJPTSA9IDB4MDAw
MDAwNDAKSU5fTU9WRURfVE8gPSAweDAwMDAwMDgwCklOX0NSRUFURSA9IDB4MDAwMDAxMDAKSU5f
REVMRVRFID0gMHgwMDAwMDIwMApJTl9ERUxFVEVfU0VMRiA9IDB4MDAwMDA0MDAKSU5fTU9WRV9T
RUxGID0gMHgwMDAwMDgwMApJTl9RX09WRVJGTE9XID0gMHgwMDAwNDAwMApJTl9JU0RJUiA9IDB4
NDAwMDAwMDAKCldBVENIX01BU0sgPSAoCiAgICBJTl9BVFRSSUIgfCBJTl9DTE9TRV9XUklURSB8
IElOX01PVkVEX0ZST00gfCBJTl9NT1ZFRF9UTwogICAgfCBJTl9DUkVBVEUgfCBJTl9ERUxFVEUg
fCBJTl9ERUxFVEVfU0VMRiB8IElOX01PVkVfU0VMRgopCgpFVkVOVF9IRFIgPSBzdHJ1Y3QuY2Fs
Y3NpemUoImlJSUkiKQoKIyDlj6rplZzlg4/ov5nkuKTkuKrlrZDnm67lvZXov5vln7rlh4blia/m
nKzvvIzpgb/lhY3mioogYmFja3Vwcy/jgIFiaW4vIOS5i+exu+W4pui/m+WOuwpTVUJESVJTID0g
KCJydWxlcyIsICJza2lsbHMiKQoKUVVJRVQgPSAwLjA1ICAgICAgIyDkuovku7blkIjlubbnqpfl
j6PvvIjnp5LvvIkKVElDSyA9IDAuMiAgICAgICAgIyBzZWxlY3Qg6LaF5pe2Ck9QQ0hFQ0sgPSAx
LjUgICAgICMgb3BlbmNvZGUg6L+b56iL5omr5o+P6Ze06ZqUCgoKZGVmIG5vdygpOgogICAgcmV0
dXJuIHRpbWUuc3RyZnRpbWUoIiVZLSVtLSVkVCVIOiVNOiVTWiIsIHRpbWUuZ210aW1lKCkpCgoK
IyAtLS0tLS0tLS0tLS0tLS0tIOmFjee9riAtLS0tLS0tLS0tLS0tLS0tCgpjbGFzcyBDZmcob2Jq
ZWN0KToKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBhKToKICAgICAgICBoZXJlID0gb3MucGF0aC5k
aXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpCiAgICAgICAga2l0ID0gb3MucGF0aC5k
aXJuYW1lKGhlcmUpICAgICAgICAgICAgICAgICAgICAgICMgPGtpdD4vYmluL3gucHkg4oaSIDxr
aXQ+CiAgICAgICAgc2VsZi50cGwgPSBhLnRwbCBvciBmaW5kX3RwbCgpCiAgICAgICAgc2VsZi5z
cmMgPSBhLnNyYyBvciBvcy5wYXRoLmpvaW4oa2l0LCAibmV3IikKICAgICAgICBzZWxmLmdvbGQg
PSBhLmdvbGQgb3Igb3MucGF0aC5qb2luKGtpdCwgIi5nb2xkIikKICAgICAgICBzZWxmLnBpZGZp
bGUgPSBhLnBpZCBvciBvcy5wYXRoLmpvaW4oa2l0LCAiLndhdGNoLnBpZCIpCiAgICAgICAgc2Vs
Zi5sb2dmaWxlID0gYS5sb2cgb3Igb3MucGF0aC5qb2luKGtpdCwgIndhdGNoLmxvZyIpCiAgICAg
ICAgc2VsZi5pbnRlcnZhbCA9IGEuaW50ZXJ2YWwKICAgICAgICBzZWxmLmtpdCA9IGtpdAoKICAg
IGRlZiBvayhzZWxmKToKICAgICAgICByZXR1cm4gYm9vbChzZWxmLnRwbCkgYW5kIG9zLnBhdGgu
aXNkaXIoc2VsZi50cGwpCgoKZGVmIGZpbmRfdHBsKCk6CiAgICAiIiLmjInlt7Lnn6XluIPlsYDm
ib7ooqvph43pk7rnmoTmqKHmnb/nm67lvZXvvJvpg73kuI3lnKjlsLHmiasgcHJvamVjdC10cGzj
gIIiIiIKICAgIGZpeGVkID0gKAogICAgICAgICIvcm9vdC8uY29kaW5nbWF0cml4L3Byb2plY3Qt
dHBsLy5haS1yZWFkeSIsCiAgICAgICAgIi93b3Jrc3BhY2UvLmNvZGluZ21hdHJpeC9wcm9qZWN0
LXRwbC8uYWktcmVhZHkiLAogICAgICAgICIvd29ya3NwYWNlL3Byb2plY3QtdHBsLy5haS1yZWFk
eSIsCiAgICApCiAgICBmb3IgcCBpbiBmaXhlZDoKICAgICAgICBpZiBvcy5wYXRoLmlzZGlyKG9z
LnBhdGguam9pbihwLCAicnVsZXMiKSk6CiAgICAgICAgICAgIHJldHVybiBwCiAgICBmb3Igcm9v
dCBpbiAoIi9yb290IiwgIi93b3Jrc3BhY2UiKToKICAgICAgICBpZiBub3Qgb3MucGF0aC5pc2Rp
cihyb290KToKICAgICAgICAgICAgY29udGludWUKICAgICAgICBiYXNlX2RlcHRoID0gcm9vdC5y
c3RyaXAoIi8iKS5jb3VudCgiLyIpCiAgICAgICAgZm9yIGRpcnBhdGgsIGRpcm5hbWVzLCBfIGlu
IG9zLndhbGsocm9vdCk6CiAgICAgICAgICAgIGlmIGRpcnBhdGguY291bnQoIi8iKSAtIGJhc2Vf
ZGVwdGggPiA1OgogICAgICAgICAgICAgICAgZGlybmFtZXNbOl0gPSBbXQogICAgICAgICAgICAg
ICAgY29udGludWUKICAgICAgICAgICAgZGlybmFtZXNbOl0gPSBbZCBmb3IgZCBpbiBkaXJuYW1l
cwogICAgICAgICAgICAgICAgICAgICAgICAgICBpZiBkIG5vdCBpbiAoIm5vZGVfbW9kdWxlcyIs
ICIuZ2l0IiwgIl9fcHljYWNoZV9fIildCiAgICAgICAgICAgIGlmIG5vdCBkaXJwYXRoLmVuZHN3
aXRoKCJwcm9qZWN0LXRwbCIpOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAg
Y2FuZCA9IG9zLnBhdGguam9pbihkaXJwYXRoLCAiLmFpLXJlYWR5IikKICAgICAgICAgICAgZm9y
IGMgaW4gKGNhbmQsIGRpcnBhdGgpOgogICAgICAgICAgICAgICAgaWYgb3MucGF0aC5pc2Rpcihv
cy5wYXRoLmpvaW4oYywgInJ1bGVzIikpOgogICAgICAgICAgICAgICAgICAgIHJldHVybiBjCiAg
ICByZXR1cm4gIiIKCgojIC0tLS0tLS0tLS0tLS0tLS0g5pel5b+XIC0tLS0tLS0tLS0tLS0tLS0K
CmRlZiBzYXkoY2ZnLCBtc2cpOgogICAgbGluZSA9ICIlcyAlc1xuIiAlIChub3coKSwgbXNnKQog
ICAgdHJ5OgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUobGluZSkKICAgICAgICBzeXMuc3Rkb3V0
LmZsdXNoKCkKICAgIGV4Y2VwdCAoQnJva2VuUGlwZUVycm9yLCBWYWx1ZUVycm9yKToKICAgICAg
ICBwYXNzCiAgICB0cnk6CiAgICAgICAgaWYgb3MucGF0aC5leGlzdHMoY2ZnLmxvZ2ZpbGUpIGFu
ZCBvcy5wYXRoLmdldHNpemUoY2ZnLmxvZ2ZpbGUpID4gNTI0Mjg4OgogICAgICAgICAgICB3aXRo
IG9wZW4oY2ZnLmxvZ2ZpbGUsICJyYiIpIGFzIGY6CiAgICAgICAgICAgICAgICBmLnNlZWsoLTQw
OTYwLCBvcy5TRUVLX0VORCkKICAgICAgICAgICAgICAgIHRhaWwgPSBmLnJlYWQoKS5zcGxpdChi
IlxuIiwgMSlbLTFdCiAgICAgICAgICAgIHdpdGggb3BlbihjZmcubG9nZmlsZSwgIndiIikgYXMg
ZjoKICAgICAgICAgICAgICAgIGYud3JpdGUodGFpbCkKICAgICAgICB3aXRoIG9wZW4oY2ZnLmxv
Z2ZpbGUsICJhIikgYXMgZjoKICAgICAgICAgICAgZi53cml0ZShsaW5lKQogICAgZXhjZXB0IE9T
RXJyb3I6CiAgICAgICAgcGFzcwoKCiMgLS0tLS0tLS0tLS0tLS0tLSDln7rlh4blia/mnKwgLS0t
LS0tLS0tLS0tLS0tLQoKZGVmIHdhbGtfZmlsZXMocm9vdCk6CiAgICBvdXQgPSBbXQogICAgZm9y
IHN1YiBpbiBTVUJESVJTOgogICAgICAgIGQgPSBvcy5wYXRoLmpvaW4ocm9vdCwgc3ViKQogICAg
ICAgIGlmIG5vdCBvcy5wYXRoLmlzZGlyKGQpOgogICAgICAgICAgICBjb250aW51ZQogICAgICAg
IGZvciBkaXJwYXRoLCBkaXJuYW1lcywgZmlsZW5hbWVzIGluIG9zLndhbGsoZCk6CiAgICAgICAg
ICAgIGRpcm5hbWVzWzpdID0gW3ggZm9yIHggaW4gZGlybmFtZXMgaWYgeCAhPSAiX19weWNhY2hl
X18iXQogICAgICAgICAgICBmb3IgZm4gaW4gZmlsZW5hbWVzOgogICAgICAgICAgICAgICAgaWYg
Zm4uZW5kc3dpdGgoIi5weWMiKToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAg
ICAgICAgICAgb3V0LmFwcGVuZChvcy5wYXRoLmpvaW4oZGlycGF0aCwgZm4pKQogICAgcmV0dXJu
IG91dAoKCmRlZiBiYWtlKGNmZyk6CiAgICAiIiLmiormlLnlhpnniYjovb3ojbfvvIhraXQvbmV3
77yJ6ZWc5YOP5oiQIGdvbGQg5Z+65YeG77yM5bm25riF5o6JIGdvbGQg6YeM5bey5LiN5a2Y5Zyo
55qE5paH5Lu244CCIiIiCiAgICBpZiBub3Qgb3MucGF0aC5pc2RpcihjZmcuc3JjKToKICAgICAg
ICByYWlzZSBTeXN0ZW1FeGl0KCLovb3ojbfnm67lvZXkuI3lrZjlnKg6ICVz77yI5YWIIGluc3Rh
bGwgLyByZXBhaXLvvIkiICUgY2ZnLnNyYykKICAgIG4gPSAwCiAgICBrZWVwID0gc2V0KCkKICAg
IGZvciBzcmMgaW4gd2Fsa19maWxlcyhjZmcuc3JjKToKICAgICAgICByZWwgPSBvcy5wYXRoLnJl
bHBhdGgoc3JjLCBjZmcuc3JjKQogICAgICAgIGtlZXAuYWRkKHJlbCkKICAgICAgICBkc3QgPSBv
cy5wYXRoLmpvaW4oY2ZnLmdvbGQsIHJlbCkKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGgg
b3BlbihzcmMsICJyYiIpIGFzIGY6CiAgICAgICAgICAgICAgICBkYXRhID0gZi5yZWFkKCkKICAg
ICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBzYW1lID0g
RmFsc2UKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggb3Blbihkc3QsICJyYiIpIGFzIGY6
CiAgICAgICAgICAgICAgICBzYW1lID0gZi5yZWFkKCkgPT0gZGF0YQogICAgICAgIGV4Y2VwdCBP
U0Vycm9yOgogICAgICAgICAgICBwYXNzCiAgICAgICAgaWYgbm90IHNhbWU6CiAgICAgICAgICAg
IGQgPSBvcy5wYXRoLmRpcm5hbWUoZHN0KQogICAgICAgICAgICBpZiBkOgogICAgICAgICAgICAg
ICAgb3MubWFrZWRpcnMoZCwgZXhpc3Rfb2s9VHJ1ZSkKICAgICAgICAgICAgd2l0aCBvcGVuKGRz
dCwgIndiIikgYXMgZjoKICAgICAgICAgICAgICAgIGYud3JpdGUoZGF0YSkKICAgICAgICBuICs9
IDEKICAgICMg5riF5o6JIGdvbGQg6YeM5bey6KKr6L296I235Yig6Zmk55qE5pen5paH5Lu277yM
5ZCm5YiZ5Lya5LiA55u05b6A5qih5p2/6YeM5oGi5aSN5bm954G15paH5Lu2CiAgICBmb3IgZGly
cGF0aCwgXywgZmlsZW5hbWVzIGluIG9zLndhbGsoY2ZnLmdvbGQpOgogICAgICAgIGZvciBmbiBp
biBmaWxlbmFtZXM6CiAgICAgICAgICAgIHAgPSBvcy5wYXRoLmpvaW4oZGlycGF0aCwgZm4pCiAg
ICAgICAgICAgIGlmIG9zLnBhdGgucmVscGF0aChwLCBjZmcuZ29sZCkgbm90IGluIGtlZXA6CiAg
ICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgb3MudW5saW5rKHApCiAgICAg
ICAgICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgICAgICAgICBwYXNzCiAgICBy
ZXR1cm4gbgoKCmRlZiBnb2xkX2l0ZW1zKGNmZyk6CiAgICAiIiLkuqflh7ogKOWfuuWHhuaWh+S7
tiwg55uu5qCH5paH5Lu2KSDlr7nvvIzlubbkv53mjIEgcnVsZXMg5ZyoIHNraWxscyDkuYvliY3j
gIIiIiIKICAgIG91dCA9IFtdCiAgICBmb3Igc3ViIGluIFNVQkRJUlM6CiAgICAgICAgZCA9IG9z
LnBhdGguam9pbihjZmcuZ29sZCwgc3ViKQogICAgICAgIGlmIG5vdCBvcy5wYXRoLmlzZGlyKGQp
OgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGZvciBkaXJwYXRoLCBkaXJuYW1lcywgZmls
ZW5hbWVzIGluIG9zLndhbGsoZCk6CiAgICAgICAgICAgIGRpcm5hbWVzLnNvcnQoKQogICAgICAg
ICAgICBmb3IgZm4gaW4gc29ydGVkKGZpbGVuYW1lcyk6CiAgICAgICAgICAgICAgICBzcmMgPSBv
cy5wYXRoLmpvaW4oZGlycGF0aCwgZm4pCiAgICAgICAgICAgICAgICBvdXQuYXBwZW5kKChzcmMs
IG9zLnBhdGguam9pbihjZmcudHBsLCBvcy5wYXRoLnJlbHBhdGgoc3JjLCBjZmcuZ29sZCkpKSkK
ICAgIHJldHVybiBvdXQKCgpkZWYgZGlmZl9jb3VudChjZmcpOgogICAgbiA9IDAKICAgIGZvciBz
cmMsIGRzdCBpbiBnb2xkX2l0ZW1zKGNmZyk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBpZiBv
cy5wYXRoLmdldHNpemUoc3JjKSAhPSBvcy5wYXRoLmdldHNpemUoZHN0KToKICAgICAgICAgICAg
ICAgIG4gKz0gMQogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgd2l0aCBvcGVu
KHNyYywgInJiIikgYXMgYSwgb3Blbihkc3QsICJyYiIpIGFzIGI6CiAgICAgICAgICAgICAgICBp
ZiBhLnJlYWQoKSAhPSBiLnJlYWQoKToKICAgICAgICAgICAgICAgICAgICBuICs9IDEKICAgICAg
ICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgbiArPSAxCiAgICByZXR1cm4gbgoKCmRlZiBy
ZXN0b3JlKGNmZywgcmVhc29uKToKICAgICIiIuWFqOmHj+avlOWvueWQjuWGmeWbnuOAgui/lOWb
niAo5YaZ5Zue5pWwLCDlpLHotKXmlbAsIOaWh+S7tuWQjeWIl+ihqCnjgIIiIiIKICAgIHQwID0g
dGltZS50aW1lKCkKICAgIG4gPSBmYWlsID0gMAogICAgbmFtZXMgPSBbXQogICAgZm9yIHNyYywg
ZHN0IGluIGdvbGRfaXRlbXMoY2ZnKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggb3Bl
bihzcmMsICJyYiIpIGFzIGY6CiAgICAgICAgICAgICAgICBkYXRhID0gZi5yZWFkKCkKICAgICAg
ICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgZmFpbCArPSAxCiAgICAgICAgICAgIGNvbnRp
bnVlCiAgICAgICAgY3VyID0gTm9uZQogICAgICAgIHRyeToKICAgICAgICAgICAgd2l0aCBvcGVu
KGRzdCwgInJiIikgYXMgZjoKICAgICAgICAgICAgICAgIGN1ciA9IGYucmVhZCgpCiAgICAgICAg
ZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIGN1ciA9IE5vbmUKICAgICAgICBpZiBjdXIgPT0g
ZGF0YToKICAgICAgICAgICAgY29udGludWUKICAgICAgICB0cnk6CiAgICAgICAgICAgIGQgPSBv
cy5wYXRoLmRpcm5hbWUoZHN0KQogICAgICAgICAgICBpZiBkOgogICAgICAgICAgICAgICAgb3Mu
bWFrZWRpcnMoZCwgZXhpc3Rfb2s9VHJ1ZSkKICAgICAgICAgICAgIyDnm7TmjqXopoblhpnogIzp
nZ4gcmVuYW1l77yacmVuYW1lIOS8muaNoiBpbm9kZe+8jOmDqOWIhiB3YXRjaGVyIOS8muWboOat
pAogICAgICAgICAgICAjIOinpuWPkeS6jOasoeS6i+S7tu+8jOW9ouaIkOiHqua/gOW+queOrwog
ICAgICAgICAgICB3aXRoIG9wZW4oZHN0LCAid2IiKSBhcyBmOgogICAgICAgICAgICAgICAgZi53
cml0ZShkYXRhKQogICAgICAgICAgICBuICs9IDEKICAgICAgICAgICAgbmFtZXMuYXBwZW5kKG9z
LnBhdGguYmFzZW5hbWUoZHN0KSkKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAg
ZmFpbCArPSAxCiAgICBpZiBuIG9yIGZhaWw6CiAgICAgICAgc2F5KGNmZywgIlJFU1RPUkVEIG49
JWQgZmFpbD0lZCByZWFzb249JXMgZWxhcHNlZD0lLjNmcyIgJQogICAgICAgICAgICAobiwgZmFp
bCwgcmVhc29uLCB0aW1lLnRpbWUoKSAtIHQwKSkKICAgIHJldHVybiBuLCBmYWlsLCBuYW1lcwoK
CiMgLS0tLS0tLS0tLS0tLS0tLSBpbm90aWZ5IC0tLS0tLS0tLS0tLS0tLS0KCmNsYXNzIFdhdGNo
ZXIob2JqZWN0KToKICAgIGRlZiBfX2luaXRfXyhzZWxmKToKICAgICAgICB0cnk6CiAgICAgICAg
ICAgIGxpYmMgPSBjdHlwZXMuQ0RMTCgibGliYy5zby42IiwgdXNlX2Vycm5vPVRydWUpCiAgICAg
ICAgICAgIHNlbGYuX2FkZCA9IGxpYmMuaW5vdGlmeV9hZGRfd2F0Y2gKICAgICAgICAgICAgc2Vs
Zi5fYWRkLmFyZ3R5cGVzID0gW2N0eXBlcy5jX2ludCwgY3R5cGVzLmNfY2hhcl9wLCBjdHlwZXMu
Y191aW50MzJdCiAgICAgICAgICAgIHNlbGYuX2FkZC5yZXN0eXBlID0gY3R5cGVzLmNfaW50CiAg
ICAgICAgICAgIHNlbGYuZmQgPSBsaWJjLmlub3RpZnlfaW5pdDEob3MuT19OT05CTE9DSykKICAg
ICAgICBleGNlcHQgKE9TRXJyb3IsIEF0dHJpYnV0ZUVycm9yKToKICAgICAgICAgICAgc2VsZi5m
ZCA9IC0xCiAgICAgICAgaWYgc2VsZi5mZCA8IDA6CiAgICAgICAgICAgIHJhaXNlIE9TRXJyb3Io
Imlub3RpZnkg5LiN5Y+v55SoIikKICAgICAgICBzZWxmLndkcyA9IHt9CgogICAgZGVmIGFkZChz
ZWxmLCBwYXRoKToKICAgICAgICB3ZCA9IHNlbGYuX2FkZChzZWxmLmZkLCBwYXRoLmVuY29kZSgp
LCBXQVRDSF9NQVNLKQogICAgICAgIGlmIHdkIDwgMDoKICAgICAgICAgICAgcmV0dXJuIC0xCiAg
ICAgICAgc2VsZi53ZHNbd2RdID0gcGF0aAogICAgICAgIHJldHVybiB3ZAoKICAgIGRlZiBhZGRf
dHJlZShzZWxmLCByb290KToKICAgICAgICBjbnQgPSAwCiAgICAgICAgaWYgc2VsZi5hZGQocm9v
dCkgPj0gMDoKICAgICAgICAgICAgY250ICs9IDEKICAgICAgICBmb3Igc3ViIGluIFNVQkRJUlM6
CiAgICAgICAgICAgIGQgPSBvcy5wYXRoLmpvaW4ocm9vdCwgc3ViKQogICAgICAgICAgICBpZiBv
cy5wYXRoLmlzZGlyKGQpIGFuZCBzZWxmLmFkZChkKSA+PSAwOgogICAgICAgICAgICAgICAgY250
ICs9IDEKICAgICAgICByZXR1cm4gY250CgogICAgZGVmIHJlYWQoc2VsZik6CiAgICAgICAgb3V0
ID0gW10KICAgICAgICB3aGlsZSBUcnVlOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAg
ICBidWYgPSBvcy5yZWFkKHNlbGYuZmQsIDY1NTM2KQogICAgICAgICAgICBleGNlcHQgKEJsb2Nr
aW5nSU9FcnJvciwgSW50ZXJydXB0ZWRFcnJvcik6CiAgICAgICAgICAgICAgICBicmVhawogICAg
ICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgICAgIGJyZWFrCiAgICAgICAgICAg
IGlmIG5vdCBidWY6CiAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICBpID0gMAogICAg
ICAgICAgICB3aGlsZSBpICsgRVZFTlRfSERSIDw9IGxlbihidWYpOgogICAgICAgICAgICAgICAg
d2QsIG1hc2ssIF9jb29raWUsIGxuID0gc3RydWN0LnVucGFja19mcm9tKCJpSUlJIiwgYnVmLCBp
KQogICAgICAgICAgICAgICAgaSArPSBFVkVOVF9IRFIKICAgICAgICAgICAgICAgIG5hbWUgPSBi
dWZbaTppICsgbG5dLnNwbGl0KGIiXDAiKVswXS5kZWNvZGUoInV0Zi04IiwgInJlcGxhY2UiKQog
ICAgICAgICAgICAgICAgaSArPSBsbgogICAgICAgICAgICAgICAgb3V0LmFwcGVuZCgod2QsIG1h
c2ssIG5hbWUpKQogICAgICAgIHJldHVybiBvdXQKCgpkZWYgc2Nhbl9vcGVuY29kZSgpOgogICAg
cGlkcyA9IHNldCgpCiAgICB0cnk6CiAgICAgICAgZm9yIGUgaW4gb3MubGlzdGRpcigiL3Byb2Mi
KToKICAgICAgICAgICAgaWYgbm90IGUuaXNkaWdpdCgpOgogICAgICAgICAgICAgICAgY29udGlu
dWUKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgd2l0aCBvcGVuKCIvcHJvYy8lcy9j
b21tIiAlIGUpIGFzIGY6CiAgICAgICAgICAgICAgICAgICAgaWYgZi5yZWFkKCkuc3RyaXAoKSA9
PSAib3BlbmNvZGUiOgogICAgICAgICAgICAgICAgICAgICAgICBwaWRzLmFkZChpbnQoZSkpCiAg
ICAgICAgICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgICAgICAgICAgY29udGludWUKICAgIGV4
Y2VwdCBPU0Vycm9yOgogICAgICAgIHBhc3MKICAgIHJldHVybiBwaWRzCgoKIyAtLS0tLS0tLS0t
LS0tLS0tIOWtkOWRveS7pCAtLS0tLS0tLS0tLS0tLS0tCgpkZWYgcmVhZF9waWQoY2ZnKToKICAg
IHRyeToKICAgICAgICB3aXRoIG9wZW4oY2ZnLnBpZGZpbGUpIGFzIGY6CiAgICAgICAgICAgIHJl
dHVybiBpbnQoZi5yZWFkKCkuc3RyaXAoKSBvciAwKQogICAgZXhjZXB0IChPU0Vycm9yLCBWYWx1
ZUVycm9yKToKICAgICAgICByZXR1cm4gMAoKCmRlZiBhbGl2ZShwaWQpOgogICAgcmV0dXJuIGJv
b2wocGlkKSBhbmQgb3MucGF0aC5pc2RpcigiL3Byb2MvJWQiICUgcGlkKQoKCmRlZiBjbWRfc3Rh
dHVzKGNmZyk6CiAgICBmaWxlcyA9IGxlbihnb2xkX2l0ZW1zKGNmZykpIGlmIG9zLnBhdGguaXNk
aXIoY2ZnLmdvbGQpIGVsc2UgMAogICAgcGlkID0gcmVhZF9waWQoY2ZnKQogICAgcHJpbnQoIlRQ
TD0lcyIgJSAoY2ZnLnRwbCBvciAiKOacquaJvuWIsCkiKSkKICAgIHByaW50KCJHT0xEPSVzIGZp
bGVzPSVkIiAlIChjZmcuZ29sZCwgZmlsZXMpKQogICAgcHJpbnQoIlNSQz0lcyIgJSBjZmcuc3Jj
KQogICAgcHJpbnQoIlBJRD0lcyBBTElWRT0lcyIgJSAocGlkIG9yICItIiwgInllcyIgaWYgYWxp
dmUocGlkKSBlbHNlICJubyIpKQogICAgcHJpbnQoIkRJRkZfTk9XPSVkIiAlIChkaWZmX2NvdW50
KGNmZykgaWYgY2ZnLm9rKCkgYW5kIGZpbGVzIGVsc2UgLTEpKQogICAgdHJ5OgogICAgICAgIHcg
PSBXYXRjaGVyKCkKICAgICAgICBvcy5jbG9zZSh3LmZkKQogICAgICAgIHByaW50KCJJTk9USUZZ
PXllcyIpCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICBwcmludCgiSU5PVElGWT1ubyIpCiAg
ICBpZiBvcy5wYXRoLmlzZmlsZShjZmcubG9nZmlsZSk6CiAgICAgICAgcHJpbnQoIi0tLSBsYXN0
IDQgLS0tIikKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggb3BlbihjZmcubG9nZmlsZSwg
InIiLCBlcnJvcnM9InJlcGxhY2UiKSBhcyBmOgogICAgICAgICAgICAgICAgZm9yIGxpbmUgaW4g
Zi5yZWFkKCkuc3RyaXAoKS5zcGxpdGxpbmVzKClbLTQ6XToKICAgICAgICAgICAgICAgICAgICBw
cmludChsaW5lKQogICAgICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgICAgICBwYXNzCiAgICBy
ZXR1cm4gMAoKCmRlZiBjbWRfc3RvcChjZmcpOgogICAgcGlkID0gcmVhZF9waWQoY2ZnKQogICAg
aWYgbm90IGFsaXZlKHBpZCk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBvcy51bmxpbmsoY2Zn
LnBpZGZpbGUpCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHBhc3MKICAgICAg
ICBwcmludCgi5pyq5Zyo6L+Q6KGMIikKICAgICAgICByZXR1cm4gMAogICAgdHJ5OgogICAgICAg
IG9zLmtpbGwocGlkLCBzaWduYWwuU0lHVEVSTSkKICAgIGV4Y2VwdCBPU0Vycm9yIGFzIGU6CiAg
ICAgICAgcHJpbnQoIuWPkemAgeS/oeWPt+Wksei0pTogJXMiICUgZSkKICAgICAgICByZXR1cm4g
MQogICAgZm9yIF8gaW4gcmFuZ2UoNTApOgogICAgICAgIGlmIG5vdCBhbGl2ZShwaWQpOgogICAg
ICAgICAgICBicmVhawogICAgICAgIHRpbWUuc2xlZXAoMC4wNSkKICAgIGlmIGFsaXZlKHBpZCk6
CiAgICAgICAgdHJ5OgogICAgICAgICAgICBvcy5raWxsKHBpZCwgc2lnbmFsLlNJR0tJTEwpCiAg
ICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHBhc3MKICAgIHRyeToKICAgICAgICBv
cy51bmxpbmsoY2ZnLnBpZGZpbGUpCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICBwYXNzCiAg
ICBwcmludCgiU1RPUFBFRCBwaWQ9JWQiICUgcGlkKQogICAgcmV0dXJuIDAKCgpkZWYgY21kX29u
Y2UoY2ZnKToKICAgIGlmIG5vdCBjZmcub2soKToKICAgICAgICBwcmludCgi5qih5p2/55uu5b2V
5LiN5a2Y5ZyoOiAlcyIgJSBjZmcudHBsKQogICAgICAgIHJldHVybiAxCiAgICBuID0gYmFrZShj
ZmcpCiAgICBnb3QsIGZhaWwsIF8gPSByZXN0b3JlKGNmZywgIm9uY2UiKQogICAgcHJpbnQoIkJB
S0VEIGZpbGVzPSVkIFJFU1RPUkVEIG49JWQgZmFpbD0lZCIgJSAobiwgZ290LCBmYWlsKSkKICAg
IHJldHVybiAwCgoKZGVmIGNtZF9kYWVtb24oY2ZnKToKICAgIGlmIG5vdCBjZmcub2soKToKICAg
ICAgICBwcmludCgi5qih5p2/55uu5b2V5LiN5a2Y5ZyoOiAlcyIgJSBjZmcudHBsKQogICAgICAg
IHJldHVybiAxCiAgICBmaWxlcyA9IGJha2UoY2ZnKQogICAgZCA9IG9zLnBhdGguZGlybmFtZShj
ZmcucGlkZmlsZSkKICAgIGlmIGQ6CiAgICAgICAgb3MubWFrZWRpcnMoZCwgZXhpc3Rfb2s9VHJ1
ZSkKICAgIHdpdGggb3BlbihjZmcucGlkZmlsZSwgInciKSBhcyBmOgogICAgICAgIGYud3JpdGUo
c3RyKG9zLmdldHBpZCgpKSkKICAgIHNheShjZmcsICJXQVRDSF9TVEFSVCBwaWQ9JWQgdHBsPSVz
IGdvbGQ9JXMgZmlsZXM9JWQiICUKICAgICAgICAob3MuZ2V0cGlkKCksIGNmZy50cGwsIGNmZy5n
b2xkLCBmaWxlcykpCgogICAgdHJ5OgogICAgICAgIHcgPSBXYXRjaGVyKCkKICAgIGV4Y2VwdCBP
U0Vycm9yIGFzIGU6CiAgICAgICAgc2F5KGNmZywgIldBVENIX0ZBSUwgaW5vdGlmeTogJXPvvIjp
mY3nuqfkuLrnuq/ova7or6LvvIkiICUgZSkKICAgICAgICB3ID0gTm9uZQogICAgaWYgdyBpcyBu
b3QgTm9uZToKICAgICAgICBuID0gdy5hZGRfdHJlZShjZmcudHBsKQogICAgICAgIHNheShjZmcs
ICJJTk9USUZZX09LIGRpcnM9JWQiICUgbikKCiAgICBzdG9wID0geyJvbiI6IEZhbHNlfQoKICAg
IGRlZiBfc2lnKF9zLCBfZik6CiAgICAgICAgc3RvcFsib24iXSA9IFRydWUKCiAgICBzaWduYWwu
c2lnbmFsKHNpZ25hbC5TSUdURVJNLCBfc2lnKQogICAgc2lnbmFsLnNpZ25hbChzaWduYWwuU0lH
SU5ULCBfc2lnKQoKICAgIHNlZW5fb2MgPSBzY2FuX29wZW5jb2RlKCkKICAgIHNheShjZmcsICJP
UEVOQ09ERV9UUkFDSyBpbml0PSVzIiAlIHNvcnRlZChzZWVuX29jKSkKCiAgICBsYXN0X3RpY2sg
PSB0aW1lLnRpbWUoKQogICAgbGFzdF9vYyA9IHRpbWUudGltZSgpCiAgICB0cnk6CiAgICAgICAg
d2hpbGUgbm90IHN0b3BbIm9uIl06CiAgICAgICAgICAgIGZkcyA9IFt3LmZkXSBpZiB3IGlzIG5v
dCBOb25lIGVsc2UgW10KICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgciwgXywgXyA9
IHNlbGVjdC5zZWxlY3QoZmRzLCBbXSwgW10sIFRJQ0spCiAgICAgICAgICAgIGV4Y2VwdCAoT1NF
cnJvciwgSW50ZXJydXB0ZWRFcnJvcik6CiAgICAgICAgICAgICAgICByID0gW10KICAgICAgICAg
ICAgaWYgcjoKICAgICAgICAgICAgICAgIHRfZXYgPSB0aW1lLnRpbWUoKQogICAgICAgICAgICAg
ICAgZXZzID0gdy5yZWFkKCkKICAgICAgICAgICAgICAgIGRlYWRsaW5lID0gdGltZS50aW1lKCkg
KyBRVUlFVAogICAgICAgICAgICAgICAgd2hpbGUgdGltZS50aW1lKCkgPCBkZWFkbGluZToKICAg
ICAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgICAgIHIyLCBfLCBfID0g
c2VsZWN0LnNlbGVjdChbdy5mZF0sIFtdLCBbXSwgUVVJRVQpCiAgICAgICAgICAgICAgICAgICAg
ZXhjZXB0IChPU0Vycm9yLCBJbnRlcnJ1cHRlZEVycm9yKToKICAgICAgICAgICAgICAgICAgICAg
ICAgYnJlYWsKICAgICAgICAgICAgICAgICAgICBpZiBub3QgcjI6CiAgICAgICAgICAgICAgICAg
ICAgICAgIGJyZWFrCiAgICAgICAgICAgICAgICAgICAgZXZzICs9IHcucmVhZCgpCiAgICAgICAg
ICAgICAgICAjIOebruW9leacrOi6q+iiq+WIoCAvIOiiq+aVtOajteaNouaOiSAvIOmYn+WIl+a6
ouWHuiDihpIg5penIHdkIOWFqOWkseaViO+8jOmHjeW7uuebkeWQrAogICAgICAgICAgICAgICAg
cmVidWlsZCA9IEZhbHNlCiAgICAgICAgICAgICAgICBmb3IgX3dkLCBtLCBfbiBpbiBldnM6CiAg
ICAgICAgICAgICAgICAgICAgaWYgbSAmIChJTl9ERUxFVEVfU0VMRiB8IElOX01PVkVfU0VMRiB8
IElOX1FfT1ZFUkZMT1cpOgogICAgICAgICAgICAgICAgICAgICAgICByZWJ1aWxkID0gVHJ1ZQog
ICAgICAgICAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICAgICAgaWYgcmVidWlsZDoK
ICAgICAgICAgICAgICAgICAgICB0aW1lLnNsZWVwKDAuMDIpCiAgICAgICAgICAgICAgICAgICAg
dHJ5OgogICAgICAgICAgICAgICAgICAgICAgICBvcy5jbG9zZSh3LmZkKQogICAgICAgICAgICAg
ICAgICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgICAgICAgICAgICAgICAgICBwYXNzCiAgICAg
ICAgICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgICAgICAgICB3ID0gV2F0Y2hlcigp
CiAgICAgICAgICAgICAgICAgICAgICAgIHcuYWRkX3RyZWUoY2ZnLnRwbCkKICAgICAgICAgICAg
ICAgICAgICAgICAgc2F5KGNmZywgIkRJUl9HT05FIHJlYnVpbGRfd2F0Y2giKQogICAgICAgICAg
ICAgICAgICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgICAgICAgICAgICAgICAgICB3ID0gTm9u
ZQogICAgICAgICAgICAgICAgbmFtZXMgPSBbbiBmb3IgX3dkLCBfbSwgbiBpbiBldnMgaWYgbl0K
ICAgICAgICAgICAgICAgIHJlYXNvbiA9ICJldmVudDoiICsgKCIsIi5qb2luKG5hbWVzWzo2XSkg
aWYgbmFtZXMgZWxzZSAiZGlyIikKICAgICAgICAgICAgICAgIHJlc3RvcmUoY2ZnLCByZWFzb24p
CiAgICAgICAgICAgICAgICBzYXkoY2ZnLCAiRVZFTlRfSEFORExFRCBmaWxlcz0lZCBlbGFwc2Vk
PSUuM2ZzIiAlIChsZW4oZXZzKSwgdGltZS50aW1lKCkgLSB0X2V2KSkKICAgICAgICAgICAgICAg
IGxhc3RfdGljayA9IHRpbWUudGltZSgpCiAgICAgICAgICAgIGVsaWYgdGltZS50aW1lKCkgLSBs
YXN0X3RpY2sgPj0gY2ZnLmludGVydmFsOgogICAgICAgICAgICAgICAgcmVzdG9yZShjZmcsICJ0
aWNrIikKICAgICAgICAgICAgICAgIGxhc3RfdGljayA9IHRpbWUudGltZSgpCgogICAgICAgICAg
ICBpZiB0aW1lLnRpbWUoKSAtIGxhc3Rfb2MgPj0gT1BDSEVDSzoKICAgICAgICAgICAgICAgIGN1
ciA9IHNjYW5fb3BlbmNvZGUoKQogICAgICAgICAgICAgICAgZnJlc2ggPSBjdXIgLSBzZWVuX29j
CiAgICAgICAgICAgICAgICBpZiBmcmVzaDoKICAgICAgICAgICAgICAgICAgICBnb3QsIF9mYWls
LCBfbjMgPSByZXN0b3JlKGNmZywgIm9wZW5jb2RlX3N0YXJ0IikKICAgICAgICAgICAgICAgICAg
ICBzYXkoY2ZnLCAiT1BFTkNPREVfTkVXIHBpZHM9JXMgcmVzdG9yZWQ9JWQiICUgKHNvcnRlZChm
cmVzaCksIGdvdCkpCiAgICAgICAgICAgICAgICBzZWVuX29jID0gY3VyCiAgICAgICAgICAgICAg
ICBsYXN0X29jID0gdGltZS50aW1lKCkKICAgIGZpbmFsbHk6CiAgICAgICAgaWYgdyBpcyBub3Qg
Tm9uZToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgb3MuY2xvc2Uody5mZCkKICAg
ICAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgICAgICBwYXNzCiAgICAgICAgdHJ5
OgogICAgICAgICAgICBpZiByZWFkX3BpZChjZmcpID09IG9zLmdldHBpZCgpOgogICAgICAgICAg
ICAgICAgb3MudW5saW5rKGNmZy5waWRmaWxlKQogICAgICAgIGV4Y2VwdCBPU0Vycm9yOgogICAg
ICAgICAgICBwYXNzCiAgICAgICAgc2F5KGNmZywgIldBVENIX1NUT1AgcGlkPSVkIiAlIG9zLmdl
dHBpZCgpKQogICAgcmV0dXJuIDAKCgpkZWYgbWFpbigpOgogICAgYXAgPSBhcmdwYXJzZS5Bcmd1
bWVudFBhcnNlcihwcm9nPSJhaXJlYWR5LXdhdGNoLnB5IiwgYWRkX2hlbHA9VHJ1ZSkKICAgIGFw
LmFkZF9hcmd1bWVudCgiY21kIiwgbmFyZ3M9Ij8iLCBkZWZhdWx0PSJkYWVtb24iLAogICAgICAg
ICAgICAgICAgICAgIGNob2ljZXM9WyJkYWVtb24iLCAib25jZSIsICJzdGF0dXMiLCAic3RvcCIs
ICJ0cGwiXSkKICAgIGFwLmFkZF9hcmd1bWVudCgiLS10cGwiLCBkZWZhdWx0PSIiKQogICAgYXAu
YWRkX2FyZ3VtZW50KCItLXNyYyIsIGRlZmF1bHQ9IiIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0t
Z29sZCIsIGRlZmF1bHQ9IiIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tcGlkIiwgZGVmYXVsdD0i
IikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1sb2ciLCBkZWZhdWx0PSIiKQogICAgYXAuYWRkX2Fy
Z3VtZW50KCItLWludGVydmFsIiwgdHlwZT1mbG9hdCwgZGVmYXVsdD0xLjApCiAgICBhID0gYXAu
cGFyc2VfYXJncygpCiAgICBjZmcgPSBDZmcoYSkKICAgIGlmIGEuY21kID09ICJ0cGwiOgogICAg
ICAgIHByaW50KGNmZy50cGwgb3IgIiIpCiAgICAgICAgcmV0dXJuIDAKICAgIGlmIGEuY21kID09
ICJzdGF0dXMiOgogICAgICAgIHJldHVybiBjbWRfc3RhdHVzKGNmZykKICAgIGlmIGEuY21kID09
ICJzdG9wIjoKICAgICAgICByZXR1cm4gY21kX3N0b3AoY2ZnKQogICAgaWYgYS5jbWQgPT0gIm9u
Y2UiOgogICAgICAgIHJldHVybiBjbWRfb25jZShjZmcpCiAgICByZXR1cm4gY21kX2RhZW1vbihj
ZmcpCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
AIREADY_WATCHER_B64
}

ensure_watcher() {
    local dst="$WATCH_PY" tmp sz
    if [ -s "$dst" ]; then
        sz="$(wc -c < "$dst" 2>/dev/null || echo 0)"
        if [ "${sz:-0}" -gt 2000 ]; then return 0; fi
    fi
    mkdir -p "$KIT_DIR/bin" 2>/dev/null || die "无法创建 $KIT_DIR/bin"
    tmp="$dst.tmp.$$"
    watcher_b64 | tr -d ' \t\r\n' | base64 -d > "$tmp" 2>/dev/null || true
    if [ ! -s "$tmp" ] && command -v openssl >/dev/null 2>&1; then
        watcher_b64 | tr -d ' \t\r\n' | openssl base64 -d -A > "$tmp" 2>/dev/null || true
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; die "内嵌守护解码失败（缺 base64 与 openssl）"; }
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ast,sys;ast.parse(open(sys.argv[1],encoding="utf-8").read())' "$tmp" 2>/dev/null \
            || { rm -f "$tmp"; die "内嵌守护语法校验失败"; }
    fi
    chmod +x "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dst"
    return 0
}

watch_pid() {
    local p=""
    if [ -f "$WATCH_PID" ]; then p="$(cat "$WATCH_PID" 2>/dev/null || true)"; fi
    printf '%s' "$p"
}

watch_alive() {
    local p
    p="$(watch_pid)"
    [ -n "$p" ] && [ -d "/proc/$p" ] || return 1
    # pid 会被复用，再核一次 cmdline，避免把陌生进程当成自家守护
    [ -r "/proc/$p/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'aiready-watch'
}

# 被重铺的模板目录：优先用环境变量，其次让守护脚本自己探
tpl_dir() {
    local t="${AIREADY_TPL:-}"
    if [ -n "$t" ] && [ -d "$t" ]; then printf '%s' "$t"; return 0; fi
    [ -f "$WATCH_PY" ] || { printf ''; return 0; }
    command -v python3 >/dev/null 2>&1 || { printf ''; return 0; }
    python3 "$WATCH_PY" tpl 2>/dev/null || true
}

# 退回到手工装的旧版守护（/workspace/.aiready-guard 那套，pid 存在别处），
# 不先停掉会和新进程同时往模板目录写，互相覆盖成网络风暴
legacy_stop() {
    local f p
    for f in /workspace/.aiready-guard/watch.pid /workspace/.aiready-guard/guard.pid \
             /workspace/.ai-ready-kit/watch.pid; do
        [ -f "$f" ] || continue
        p="$(cat "$f" 2>/dev/null || true)"
        if [ -n "$p" ] && [ -r "/proc/$p/cmdline" ] \
           && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'aiready-watch'; then
            kill -TERM "$p" 2>/dev/null || true
            say "已停掉旧版守护 pid $p（$f）"
        fi
        rm -f "$f" 2>/dev/null || true
    done
    return 0
}

do_guard_start() {   # $1=quiet 时不打印
    local quiet="${1:-}" tpl i=0
    ensure_watcher
    command -v python3 >/dev/null 2>&1 || die "需要 python3 才能跑实时守护"
    [ -d "$NEW_DIR" ] || die "载荷缺失（$NEW_DIR 不存在），先执行 repair"
    legacy_stop
    tpl="$(tpl_dir)"
    if [ -z "$tpl" ]; then
        if [ -z "$quiet" ]; then
            warn "没找到被重铺的模板目录（*project-tpl/.ai-ready），监控未启动"
            say " 可手工指定: AIREADY_TPL=/路径 $SCRIPT_NAME guard start"
        fi
        return 1
    fi
    if watch_alive; then
        [ -n "$quiet" ] || ok "实时监控已在运行（pid $(watch_pid)，监听 $tpl）"
        return 0
    fi
    rm -f "$WATCH_PID" 2>/dev/null || true
    # setsid 脱离当前会话；没有就退回 nohup，总之不能挂在终端进程组下
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup python3 "$WATCH_PY" daemon \
            --tpl "$tpl" --src "$NEW_DIR" --gold "$GOLD_DIR" \
            --pid "$WATCH_PID" --log "$GUARD_LOG" \
            --interval "${AIREADY_WATCH_INTERVAL:-1.0}" \
            </dev/null >/dev/null 2>&1 &
    else
        nohup python3 "$WATCH_PY" daemon \
            --tpl "$tpl" --src "$NEW_DIR" --gold "$GOLD_DIR" \
            --pid "$WATCH_PID" --log "$GUARD_LOG" \
            --interval "${AIREADY_WATCH_INTERVAL:-1.0}" \
            </dev/null >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    while [ "$i" -lt 40 ]; do
        watch_alive && break
        sleep 0.05
        i=$((i + 1))
    done
    if watch_alive; then
        if [ -z "$quiet" ]; then
            ok "实时监控已启动：pid $(watch_pid)"
            say " 监听 $tpl（事件秒回 + 每秒兜底，日志 $GUARD_LOG）"
        fi
        return 0
    fi
    [ -n "$quiet" ] || warn "守护进程未起来，看日志: $GUARD_LOG"
    return 1
}

do_guard_stop() {
    local p i=0
    p="$(watch_pid)"
    if [ -z "$p" ] || [ ! -d "/proc/$p" ]; then
        rm -f "$WATCH_PID" 2>/dev/null || true
        say "实时监控未在运行"
        return 0
    fi
    kill -TERM "$p" 2>/dev/null || true
    while [ "$i" -lt 40 ] && [ -d "/proc/$p" ]; do
        sleep 0.05
        i=$((i + 1))
    done
    if [ -d "/proc/$p" ]; then kill -KILL "$p" 2>/dev/null || true; fi
    rm -f "$WATCH_PID" 2>/dev/null || true
    ok "实时监控已停止（pid $p）"
    return 0
}

do_guard_once() {
    local tpl
    ensure_watcher
    tpl="$(tpl_dir)"
    if [ -z "$tpl" ]; then warn "没找到模板目录"; return 1; fi
    [ -d "$NEW_DIR" ] || die "载荷缺失，先执行 repair"
    command -v python3 >/dev/null 2>&1 || die "需要 python3"
    python3 "$WATCH_PY" once --tpl "$tpl" --src "$NEW_DIR" --gold "$GOLD_DIR"
}

do_guard_status() {
    if [ ! -f "$WATCH_PY" ]; then warn "守护脚本尚未落地（先 install）"; return 0; fi
    command -v python3 >/dev/null 2>&1 || { warn "缺 python3"; return 0; }
    python3 "$WATCH_PY" status --src "$NEW_DIR" --gold "$GOLD_DIR" \
        --pid "$WATCH_PID" --log "$GUARD_LOG" 2>&1 || true
    return 0
}

do_guard_menu() {
    local op
    while true; do
        echo
        say "实时监控"
        do_guard_status
        echo
        printf '  1) 启动（已在跑则重启，重烤基准）\n'
        printf '  2) 停止\n'
        printf '  3) 立即巡检并回写\n'
        printf '  4) 把模板目录本身改成改写版\n'
        printf '  5) 看日志尾部\n'
        printf '  0) 返回\n'
        printf '选择 [1-5，回车=1]: '
        read -r op || return 0
        op="${op:-1}"
        case "$op" in
            0) return 0 ;;
            1) do_guard_stop >/dev/null 2>&1 || true
               do_guard_start "" ;;
            2) do_guard_stop ;;
            3) do_guard_once ;;
            4) cli_template apply ;;
            5) if [ -f "$GUARD_LOG" ]; then tail -n 40 "$GUARD_LOG"; else warn "暂无日志"; fi ;;
            *) warn "无效选择" ;;
        esac
    done
}

cli_guard() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        start|on|install)  do_guard_start "" ;;
        stop|off|remove)   do_guard_stop ;;
        restart)           do_guard_stop >/dev/null 2>&1 || true
                           do_guard_start "" ;;
        once|reapply)      do_guard_once ;;
        status)            do_guard_status ;;
        watch)             do_guard_start "" ;;
        *) die "用法: guard [start|stop|restart|once|status]" ;;
    esac
}

# ---------- 模板层 ----------
# 若重置来自本机模板目录（平台每次铺 .ai-ready 的源），把模板本身也换掉，
# 重置就天然是改写版，守护只剩兜底。

find_template_dirs() {
    local r roots
    [ -n "${AIREADY_TEMPLATE:-}" ] && [ -d "$AIREADY_TEMPLATE" ] && printf '%s\n' "$AIREADY_TEMPLATE"
    roots="${SEARCH_ROOT:-/workspace /root}"
    for r in $roots; do
        [ -d "$r" ] || continue
        find "$r" -maxdepth 5 -type d -name '*project-tpl*' -not -path '*/node_modules/*' 2>/dev/null
    done | while IFS= read -r d; do
        if [ -d "$d/.ai-ready/rules" ] || [ -d "$d/.ai-ready/skills" ]; then printf '%s\n' "$d/.ai-ready"
        elif [ -d "$d/rules" ] || [ -d "$d/skills" ]; then printf '%s\n' "$d"; fi
    done | awk '!seen[$0]++'
}

cli_template() {
    local sub="${1:-list}" d n=0
    shift || true
    case "$sub" in
        list)
            say "模板候选（重置来源）:"
            while IFS= read -r d; do printf '  %s\n' "$d"; n=$((n+1)); done < <(find_template_dirs)
            if [ "$n" -eq 0 ]; then warn "没找到 *project-tpl* 目录；用 AIREADY_TEMPLATE=/路径 指定"; fi
            return 0
            ;;
        apply)
            if [ "$#" -gt 0 ]; then
                do_replace "$1" all
                return 0
            fi
            while IFS= read -r d; do
                say "模板 → $d"
                do_replace "$d" all || warn "跳过 $d"
                n=$((n+1))
            done < <(find_template_dirs)
            [ "$n" -gt 0 ] || die "没找到模板目录；用 template apply /路径 指定"
            ;;
        *) die "用法: template [list|apply [路径]]" ;;
    esac
}

# ---------- 目标探测 ----------

normalize_target() {
    local p="$1"
    p="${p%/}"
    if [ -d "$p/.ai-ready" ]; then p="$p/.ai-ready"; fi
    [ -d "$p" ] || return 1
    [ -d "$p/rules" ] || [ -d "$p/skills" ] || return 1
    # 统一成绝对路径：相对/绝对混用会把同一目标写进两个备份目录
    ( cd "$p" && pwd )
}

discover_targets() {
    local r roots
    roots="${SEARCH_ROOT:-/workspace /root}"
    for r in $roots; do
        [ -d "$r" ] || continue
        find "$r" -maxdepth 6 -type d -name .ai-ready \
            -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null
    done | while read -r d; do
        if [ -d "$d/rules" ] || [ -d "$d/skills" ]; then printf '%s\n' "$d"; fi
    done | awk '!seen[$0]++'
}

slug() { printf '%s' "$1" | sed 's#^/##; s#/#_#g; s#[^A-Za-z0-9_.-]#_#g'; }
marker_file() { printf '%s/%s' "$MARKER_DIR" "$(slug "$1")"; }

# ---------- 核心操作 ----------

snapshot() {
    local t="$1" ts backup
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_ROOT/$(slug "$t")/$ts"
    # 同秒内连续操作时补序号，避免两次快照写同一目录互相覆盖
    [ -d "$backup" ] && backup="${backup}-$RANDOM"
    mkdir -p "$backup"
    # cp -a 保权限保时间戳，还原后与快照时逐字节一致；每次 replace 都新开一层，
    # 所以重复执行安全，历史状态全部可回
    [ -d "$t/rules" ]  && cp -a "$t/rules"  "$backup/rules"
    [ -d "$t/skills" ] && cp -a "$t/skills" "$backup/skills"
    printf '%s' "$backup"
}

# $1=目标 $2=范围 all|rules|skills（默认 all）
do_replace() {
    local t scope="${2:-all}" backup
    t="$(normalize_target "$1")" || die "目标无效: $1（没有 rules/ 或 skills/）"
    [ -d "$NEW_DIR/rules" ] || die "new/ 不存在，先安装: curl -fsSL $URL_BASE/$SCRIPT_NAME | sh"
    case "$scope" in
        all|rules|skills) ;;
        *) die "范围只能是 all|rules|skills，收到: $scope" ;;
    esac
    if [ "$scope" != "rules" ] && [ ! -d "$NEW_DIR/skills" ]; then
        die "载荷里没有 new/skills/，无法替换 skills"
    fi

    backup="$(snapshot "$t")"
    say "已备份现网 → $backup"

    case "$scope" in
        all)
            rm -rf "$t/rules" "$t/skills"
            cp -a "$NEW_DIR/rules"  "$t/rules"
            cp -a "$NEW_DIR/skills" "$t/skills" ;;
        rules)
            rm -rf "$t/rules"
            cp -a "$NEW_DIR/rules" "$t/rules" ;;
        skills)
            rm -rf "$t/skills"
            cp -a "$NEW_DIR/skills" "$t/skills" ;;
    esac

    mkdir -p "$MARKER_DIR"
    printf '%s' "$backup" > "$(marker_file "$t")"
    ok "替换完成（$scope）→ $t"
    say "一键还原: bash ${BASH_SOURCE[0]:-$0} restore $(dirname "$t")"
}

do_restore() {
    local t rp="${2:-}" mfile current
    t="$(normalize_target "$1")" || die "目标无效: $1"
    mfile="$(marker_file "$t")"
    if [ -z "$rp" ]; then
        [ -f "$mfile" ] || die "该目标没有还原点记录，请用 backups 查看并指定时间戳"
        rp="$(cat "$mfile")"
    fi
    [ -d "$rp" ] || rp="$BACKUP_ROOT/$(slug "$t")/$rp"
    [ -d "$rp" ] || die "备份不存在: $rp"
    current="$(snapshot "$t")"
    say "当前状态已另存 → $current"
    rm -rf "$t/rules" "$t/skills"
    # 快照里只会存在替换前真实拥有的目录，缺哪个就跳过，别因 cp 失败中断还原
    [ -d "$rp/rules" ]  && cp -a "$rp/rules"  "$t/rules"
    [ -d "$rp/skills" ] && cp -a "$rp/skills" "$t/skills"
    mkdir -p "$MARKER_DIR"
    printf '%s' "$current" > "$mfile"   # 还原后再还原则回到还原前
    ok "已还原: $t ← $rp"
}

do_status() {
    local t n_new=0 n_diff=0 f rel bdir
    t="$(normalize_target "$1")" || die "目标无效: $1"
    say "目标: $t"
    [ -d "$NEW_DIR" ] || die "new/ 不存在，先安装"
    while IFS= read -r f; do
        rel="${f#"$NEW_DIR/"}"
        if [ -f "$t/$rel" ] && cmp -s "$f" "$t/$rel"; then
            n_new=$((n_new+1))
        else
            n_diff=$((n_diff+1)); warn "  与 new/ 不同: $rel"
        fi
    done < <(find "$NEW_DIR" -type f | sort)
    if [ "$n_diff" -eq 0 ]; then
        ok "现网 == new/（去限制词版，$n_new 个文件一致）"
    else
        warn "现网 $n_diff 个文件与 new/ 不同（$n_new 个一致）→ 可能是原始版或被改过"
    fi
    bdir="$BACKUP_ROOT/$(slug "$t")"
    if [ -d "$bdir" ] && ls -A "$bdir" 2>/dev/null | grep -q .; then
        say "可用备份:"
        ls -1 "$bdir" | sed 's/^/  /'
    else
        say "暂无备份。"
    fi
}

do_diff() {
    local t tmp f rel
    t="$(normalize_target "$1")" || die "目标无效: $1"
    tmp="$(mktemp)"
    while IFS= read -r f; do
        rel="${f#"$NEW_DIR/"}"
        if [ -f "$t/$rel" ]; then
            diff -u "$t/$rel" "$f" >> "$tmp" || true
        else
            printf -- '--- 现网缺失: %s ---\n' "$rel" >> "$tmp"
        fi
    done < <(find "$NEW_DIR" -type f | sort)
    cat "$tmp"; rm -f "$tmp"
}

do_backups() {
    local t bdir cur d p
    t="$(normalize_target "$1")" || die "目标无效: $1"
    bdir="$BACKUP_ROOT/$(slug "$t")"
    if [ ! -d "$bdir" ] || ! ls -A "$bdir" 2>/dev/null | grep -q .; then
        warn "该目标暂无备份: $t"
        return 0
    fi
    cur=""
    [ -f "$(marker_file "$t")" ] && cur="$(cat "$(marker_file "$t")")"
    say "备份列表: $bdir"
    for d in $(ls -1 "$bdir" | sort); do
        p="$bdir/$d"
        if [ "$p" = "$cur" ]; then printf '  * %s  ← 还原点指向这里\n' "$d"
        else printf '    %s\n' "$d"; fi
    done
}

do_info() {  # $1=no-check 时跳过版本检查行，由调用方自行查
    local ntg st=0
    say "KIT 目录 : $KIT_DIR"
    say "脚本版本 : v$VERSION"
    if is_installed; then
        ok  "安装状态 : 已安装 v$(installed_version)（$(installed_at)）"
    else
        warn "安装状态 : 未安装或载荷缺失"
    fi
    say "载荷文件 : $(count_new) 个（$NEW_DIR）"
    say "远端地址 : $URL_BASE"
    ntg="$(discover_targets | wc -l | tr -d ' ')"
    say "探测目标 : $ntg 个（${SEARCH_ROOT:-/workspace 与 /root}）"
    [ "${1:-}" = "no-check" ] && return 0
    if [ -z "${AIREADY_SKIP_UPDATE:-}" ]; then
        check_update || st=$?
        case "$st" in
            0) warn "版本检查 : 远端有新版 v$RV（本地 v$IV）→ 选 4 更新" ;;
            1) ok   "版本检查 : 已是最新 v$IV" ;;
            *) warn "版本检查 : 连不上远端（$URL_BASE），沿用本地 v$IV" ;;
        esac
    else
        say "版本检查 : 已跳过（AIREADY_SKIP_UPDATE=1）"
    fi
}

# ---------- 菜单 ----------

TARGETS=()
scan_targets() { mapfile -t TARGETS < <(discover_targets); }

pick_target() {  # 提示走 stderr，仅最终路径走 stdout
    [ "${#TARGETS[@]}" -gt 0 ] || scan_targets
    if [ "${#TARGETS[@]}" -eq 0 ]; then
        warn "在 ${SEARCH_ROOT:-/workspace 与 /root} 下没探测到 .ai-ready（需含 rules/ 或 skills/）" >&2
        printf '输入 .ai-ready 或其项目目录路径: ' >&2
        local p; read -r p || return 1
        [ -n "$p" ] || return 1
        normalize_target "$p"
        return
    fi
    echo >&2
    say "探测到 ${#TARGETS[@]} 个目标:" >&2
    local i=1 t
    for t in "${TARGETS[@]}"; do printf '  %d) %s\n' "$i" "$t" >&2; i=$((i+1)); done
    printf '  m) 手动输入路径\n' >&2
    printf '选择 [1-%d/m，回车=1]: ' "${#TARGETS[@]}" >&2
    local c; read -r c || return 1
    c="${c:-1}"          # 回车 = 第一个目标
    case "$c" in
        m|M)
            printf '路径: ' >&2; local p; read -r p || return 1
            [ -n "$p" ] || return 1
            normalize_target "$p" ;;
        *[!0-9]*|'') return 1 ;;
        *)
            [ "$c" -ge 1 ] && [ "$c" -le "${#TARGETS[@]}" ] || return 1
            printf '%s' "${TARGETS[$((c-1))]}" ;;
    esac
}

pick_backup() {  # 列备份；输出空串 = 用还原点指向的那次（最近一次）
    local t="$1" bdir d i=2 arr=() cur=""
    bdir="$BACKUP_ROOT/$(slug "$t")"
    mapfile -t arr < <(ls -1 "$bdir" 2>/dev/null | sort -r)
    [ "${#arr[@]}" -gt 0 ] || { warn "该目标暂无备份" >&2; return 1; }
    [ -f "$(marker_file "$t")" ] && cur="$(cat "$(marker_file "$t")")"
    echo >&2
    if [ -n "$cur" ]; then
        printf '  1) 最近一次（%s）\n' "$(basename "$cur")" >&2
    else
        printf '  1) 最近一次\n' >&2
    fi
    for d in "${arr[@]}"; do
        if [ "$bdir/$d" = "$cur" ]; then printf '  %d) %s  ← 还原点\n' "$i" "$d" >&2
        else printf '  %d) %s\n' "$i" "$d" >&2; fi
        i=$((i+1))
    done
    printf '选择 [1-%d，回车=最近一次]: ' "$((i-1))" >&2
    local c; read -r c || c=""
    [ -z "$c" ] && return 0
    case "$c" in *[!0-9]*) return 1 ;; esac
    [ "$c" -ge 1 ] && [ "$c" -le "$((i-1))" ] || return 1
    [ "$c" -eq 1 ] && return 0
    printf '%s' "${arr[$((c-2))]}"
}

pick_scope() {  # 替换范围，走 stdout
    echo >&2
    printf '  1) 全部（rules + skills）\n  2) 仅 rules\n  3) 仅 skills\n' >&2
    printf '范围 [1-3，回车=1]: ' >&2
    local c; read -r c || c=""
    case "$c" in ''|1) printf 'all' ;; 2) printf 'rules' ;; 3) printf 'skills' ;; *) return 1 ;; esac
}

# 一览：每个目标一行摘要，输入编号再看详情与差异
do_overview() {
    local t i=1 f rel same diff miss total
    local -a files=()
    scan_targets
    if [ "${#TARGETS[@]}" -eq 0 ]; then
        warn "未探测到 .ai-ready 目标（${SEARCH_ROOT:-/workspace 与 /root}）"
        return 0
    fi
    [ -d "$NEW_DIR" ] || { warn "new/ 不存在，先到「维护」里修复"; return 0; }
    mapfile -t files < <(find "$NEW_DIR" -type f 2>/dev/null | sort)
    total="${#files[@]}"
    say "目标 ${#TARGETS[@]} 个（载荷 $total 个文件）:"
    for t in "${TARGETS[@]}"; do
        same=0; diff=0; miss=0
        for f in "${files[@]}"; do
            rel="${f#"$NEW_DIR/"}"
            if [ ! -f "$t/$rel" ]; then miss=$((miss+1))
            elif cmp -s "$f" "$t/$rel"; then same=$((same+1))
            else diff=$((diff+1)); fi
        done
        if [ "$same" -eq "$total" ]; then
            printf '  %d) %s\n     %b一致 %d/%d%b\n' "$i" "$t" "$C_G" "$same" "$total" "$C_0"
        elif [ "$same" -eq 0 ] && [ "$diff" -eq 0 ]; then
            printf '  %d) %s\n     未部署（缺 %d 个）\n' "$i" "$t" "$miss"
        else
            printf '  %d) %s\n     部分一致（同 %d / 异 %d / 缺 %d）\n' "$i" "$t" "$same" "$diff" "$miss"
        fi
        i=$((i+1))
    done
    printf '输入编号看详情 [1-%d，回车=1]: ' "${#TARGETS[@]}"
    local c; read -r c || return 0
    c="${c:-1}"                 # 回车 = 第一个目标
    case "$c" in *[!0-9]*) return 0 ;; esac
    [ "$c" -ge 1 ] && [ "$c" -le "${#TARGETS[@]}" ] || return 0
    t="${TARGETS[$((c-1))]}"
    do_status "$t"
    printf '看逐文件差异? [Y/n]: '
    local yn; read -r yn || return 0
    case "$yn" in n|N) ;; *) do_diff "$t" ;; esac
}

# 版本与更新：先显示状态，远端有新版就问一句
do_version_menu() {
    local st=0 yn
    do_info no-check
    echo
    check_update || st=$?
    case "$st" in
        0)
            printf '%b远端 v%s（本地 v%s），现在更新? [Y/n]: %b' "$C_Y" "$RV" "$IV" "$C_0"
            read -r yn || yn=""
            case "$yn" in
                n|N) say "已跳过" ;;
                *)
                    do_install
                    # 更新后 exec 新脚本，让新版本功能立即生效
                    ensure_interactive || return 0
                    export AIREADY_SKIP_UPDATE=1
                    unset AIREADY_PIPED
                    exec bash "$KIT_DIR/$SCRIPT_NAME" menu ;;
            esac ;;
        1) ok "已是最新 v$IV" ;;
        *) warn "连不上远端，无法检查（$URL_BASE）" ;;
    esac
}

do_maintenance() {
    local op
    while true; do
        echo
        say "维护"
        printf '  1) 修复 new/（只重下载荷）\n'
        printf '  2) 强制重装（脚本 + 载荷）\n'
        printf '  3) 实时监控（inotify 秒级回写 + 轮询兜底）\n'
        printf '  4) 卸载\n'
        printf '  0) 返回\n'
        printf '选择 [1-4，回车=1]: '
        read -r op || return 0
        op="${op:-1}"
        case "$op" in
            0) return 0 ;;
            1) do_repair ;;
            2) do_install ;;
            3) do_guard_menu ;;
            4) do_uninstall ;;
            *) warn "无效选择" ;;
        esac
    done
}

menu() {
    local t yn op scope bk
    scan_targets
    while true; do
        echo
        printf '%b===== .ai-ready 工具包 v%s =====%b\n' "$C_B" "$VERSION" "$C_0"
        printf '已装 %s   目标 %s 个\n' \
            "$(if is_installed; then echo "v$(installed_version)"; else echo 未安装; fi)" "${#TARGETS[@]}"
        echo
        printf '  1) 目标与状态   列目标 + 一致性，可展开差异\n'
        printf '  2) 替换         选目标 → 全部 / 仅 rules / 仅 skills\n'
        printf '  3) 还原         选目标 → 选备份（回车=最近一次）\n'
        printf '  4) 版本与更新   版本信息，有新版时询问\n'
        printf '  5) 维护         修复 / 重装 / 卸载\n'
        printf '  6) 实时监控     %s\n' "$(if watch_alive; then echo "运行中 pid $(watch_pid)"; else echo "已停止"; fi)"
        printf '  0) 退出\n'
        printf '选择 [1-6，0=退出，回车=取消]: '
        read -r op || { echo; say "输入结束，退出"; return 0; }
        [ -z "$op" ] && continue     # 主菜单回车=取消，不执行任何动作
        case "$op" in
            0) return 0 ;;
            1) do_overview ;;
            2)
                t="$(pick_target)" || { warn "未选定目标"; continue; }
                scope="$(pick_scope)" || { warn "未选定范围"; continue; }
                [ -d "$NEW_DIR/rules" ] || { warn "new/ 不存在，先到「维护 → 修复」"; continue; }
                printf '%b替换 %s（范围: %s）?[Y/n]: %b' "$C_Y" "$t" "$scope" "$C_0"
                read -r yn || yn=""
                case "$yn" in
                    n|N) say "已取消" ;;
                    *)   do_replace "$t" "$scope" ;;
                esac ;;
            3)
                t="$(pick_target)" || { warn "未选定目标"; continue; }
                bk="$(pick_backup "$t")" || { warn "未选定备份"; continue; }
                do_restore "$t" "$bk" ;;
            4) do_version_menu ;;
            5) do_maintenance ;;
            6) do_guard_menu ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ---------- 交互与自更新 ----------

# 管道执行时 stdin 是管道，读不到输入；能打开 /dev/tty 就换过去
# AIREADY_NO_TTY=1 强制按无终端处理（cron / CI 里跑，避免卡在 /dev/tty）
ensure_interactive() {
    [ -n "${AIREADY_NO_TTY:-}" ] && return 1
    [ -t 0 ] && return 0
    if { : </dev/tty; } 2>/dev/null; then exec </dev/tty; return 0; fi
    return 1
}

# 安装/更新后重启到落盘的新脚本，再进菜单
reexec_menu() {
    ensure_interactive || true
    export AIREADY_SKIP_UPDATE=1
    unset AIREADY_PIPED
    exec bash "$KIT_DIR/$SCRIPT_NAME" menu
}

# 菜单入口流程：未装→装；已装→比版本，有新版先更新；最后进菜单
run_menu_flow() {
    local st=0
    if ! is_installed; then
        say "未检测到已安装的 kit，开始安装..."
        do_install
        echo
        reexec_menu
    fi
    if [ -z "${AIREADY_SKIP_UPDATE:-}" ]; then
        check_update || st=$?
        case "$st" in
            0) say "发现新版本 v$IV → v$RV，先更新..."
               do_install
               echo
               reexec_menu ;;
            1) ok "已是最新 v$IV" ;;
            *) warn "版本检查失败（$URL_BASE），沿用本地 v$IV" ;;
        esac
    fi
    if ensure_interactive; then
        menu
    else
        warn "当前没有可用终端，未进入菜单。可用子命令直接调用，例如: ai-ready list"
    fi
}

usage() {
    cat <<'EOF'
用法: ai-ready [命令] [参数]

交互菜单 6 项: 目标与状态 / 替换 / 还原 / 版本与更新 / 维护 / 实时监控
（下面每个动作也都能直接当子命令调）

  menu                              交互菜单（默认）
  info                              安装状态 / 版本 / 目标数量
  check                             只检查远端版本（0=有新版 1=已最新 2=连不上）
  install | update                  安装或更新到远端最新版（不动任何目标项目）
  repair                            只重下载荷并重建 new/（脚本版本不变）
  reapply [目标...]                  巡检并回写漂移（不给目标=扫全部），切模型后手动救一次用这个
  guard start                       启动实时监控（inotify 事件秒级回写 + 每秒兜底）
  guard stop | restart              停止 / 重启监控
  guard once                        立即巡检模板目录并写回
  guard status                      监控状态：pid / 存活 / 当前差异数 / 最近日志
  （install 完成后自动启动，AIREADY_NO_WATCH=1 可关掉这个默认行为）
  template list                     列出可能的模板目录（平台重置 .ai-ready 的来源）
  template apply [路径]             把模板目录本身也换成改写版，重置后即天然生效
  list                              列出探测到的 .ai-ready 目标
  status  <目标>                     对比现网与 new/
  diff    <目标>                     输出逐文件差异
  replace <目标> [all|rules|skills]   替换，默认 all
  backups <目标>                     列出该目标的备份
  restore <目标> [时间戳]             还原，省略时间戳=还原点指向的那次
  uninstall                         卸载 kit（目标项目不受影响）

环境变量:
  AIREADY_URL_BASE     远端地址，默认 https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main
  AIREADY_KIT_DIR      安装目录，默认 /workspace/.ai-ready-kit
  AIREADY_SKIP_UPDATE=1 跳过启动时的版本检查
  AIREADY_UPDATE_TTL   版本检查缓存秒数，默认 600
  AIREADY_WATCH_INTERVAL 无事件时的兜底比对间隔秒数，默认 1.0
  AIREADY_NO_WATCH=1   安装后不自动启动监控
  AIREADY_TPL          手工指定被重铺的模板目录（默认自动探测）
  AIREADY_TEMPLATE     手工指定模板目录（template 命令用）
  SEARCH_ROOT          目标探测根，默认 /workspace 与 /root
EOF
}

cli_replace() {  # 解析 replace 的位置参数与范围开关
    local scope=all path="" a
    for a in "$@"; do
        case "$a" in
            --rules|rules)   scope=rules ;;
            --skills|skills) scope=skills ;;
            --all|all)       scope=all ;;
            *)               path="$a" ;;
        esac
    done
    [ -n "$path" ] || die "用法: replace <目标路径> [all|rules|skills]"
    do_replace "$path" "$scope"
}

# ---------- 入口 ----------

CMD="${1:-}"
[ $# -gt 0 ] && shift || true

# curl | sh 管道执行（脚本不在磁盘上）：stdin 非终端且没有可执行路径
if [ -n "${AIREADY_PIPED:-}" ] || { [ -z "${BASH_SOURCE[0]:-}" ] && [ ! -t 0 ]; }; then
    if [ -n "$CMD" ]; then
        # 带参数：先确保已安装且为最新，再交给 kit 里的完整脚本
        if ! is_installed; then
            say "首次管道执行，先安装..."
            do_install > /dev/null
            echo
        elif [ -z "${AIREADY_SKIP_UPDATE:-}" ]; then
            st=0; check_update || st=$?
            if [ "$st" -eq 0 ]; then
                say "发现新版本 v$IV → v$RV，先更新..."
                do_install > /dev/null
            fi
        fi
        # AIREADY_PIPED 是 export 的，不 unset 会被 exec 的 kit 脚本继承，
        # kit 脚本再次进入本分支 exec 自己 → 无限循环
        unset AIREADY_PIPED
        # CMD 已经 shift 掉了，必须显式带上，否则参数丢空会掉进菜单流程
        exec bash "$KIT_DIR/$SCRIPT_NAME" "$CMD" "$@"
    fi
    # 无参数：安装（管道拿到的一定是最新版）→ 换到落盘脚本进菜单
    do_install
    echo
    reexec_menu
fi

case "$CMD" in
    ''|menu)  run_menu_flow ;;
    info)     do_info ;;
    check)
        st=0; check_update || st=$?
        case "$st" in
            0) warn "有新版: v$IV → v$RV" ;;
            1) ok   "已是最新: v$IV" ;;
            *) warn "检查失败，连不上 $URL_BASE" ;;
        esac
        exit "$st" ;;
    install|update) do_install ;;
    repair)   do_repair ;;
    reapply)  do_reapply "$@" ;;
    guard)    cli_guard "$@" ;;
    template) cli_template "$@" ;;
    uninstall) do_uninstall ;;
    list)     discover_targets ;;
    status)   do_status "${1:?用法: status <目标路径>}" ;;
    diff)     do_diff "${1:?用法: diff <目标路径>}" ;;
    replace)  cli_replace "$@" ;;
    backups)  do_backups "${1:?用法: backups <目标路径>}" ;;
    restore)
        [ -n "${1:-}" ] || die "用法: restore <目标路径> [备份时间戳]"
        do_restore "$1" "${2:-}" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
exit 0
