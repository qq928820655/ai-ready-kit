#!/usr/bin/env bash
# toggle-ai-ready.sh — .ai-ready 规则一键替换 / 一键还原
# version: 2026103007
#
# 托管：仓库里放两个文件（脚本 + 载荷包），服务器上一条命令安装:
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
VERSION="2026103007"
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
    return 0
}

do_repair() {
    local ptmp="$KIT_DIR/.payload.tmp"
    mkdir -p "$KIT_DIR"
    say "重新下载载荷 ← $PAYLOAD_NAME"
    fetch_file "$PAYLOAD_NAME" "$ptmp" 180 || { rm -f "$ptmp"; die "下载载荷失败（已试 raw 与镜像）"; }
    unpack_payload "$ptmp"
    ok "new/ 已重建，共 $(count_new) 个文件（脚本版本不变: v$(installed_version || echo "$VERSION")）"
}

do_uninstall() {
    local yn
    printf '%b卸载只删除 %s 下的 kit 组件，目标项目的 .ai-ready 不受影响。确认?[Y/n，输入 n 取消]: %b' "$C_Y" "$KIT_DIR" "$C_0"
    read -r yn || yn=""
    case "$yn" in n|N) say "已取消"; return 0 ;; esac
    if [ -L /usr/local/bin/ai-ready ]; then rm -f /usr/local/bin/ai-ready; fi
    rm -rf "$NEW_DIR" "$BACKUP_ROOT" "$STATE_FILE" "$CHECK_CACHE" "$BASE_CACHE" \
           "$KIT_DIR/.toggle.tmp" "$KIT_DIR/.payload.tmp"
    ok "已卸载组件（/usr/local/bin/ai-ready 符号链接一并移除）"
    say "彻底删除目录: rm -rf $KIT_DIR"
    exit 0
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
        printf '  3) 卸载\n'
        printf '  0) 返回\n'
        printf '选择 [1-3，回车=1]: '
        read -r op || return 0
        op="${op:-1}"
        case "$op" in
            0) return 0 ;;
            1) do_repair ;;
            2) do_install ;;
            3) do_uninstall ;;
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
        printf '  0) 退出\n'
        printf '选择 [1-5，0=退出，回车=取消]: '
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

交互菜单 5 项: 目标与状态 / 替换 / 还原 / 版本与更新 / 维护
（下面每个动作也都能直接当子命令调）

  menu                              交互菜单（默认）
  info                              安装状态 / 版本 / 目标数量
  check                             只检查远端版本（0=有新版 1=已最新 2=连不上）
  install | update                  安装或更新到远端最新版（不动任何目标项目）
  repair                            只重下载荷并重建 new/（脚本版本不变）
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
