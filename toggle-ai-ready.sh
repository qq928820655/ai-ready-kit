#!/usr/bin/env bash
# toggle-ai-ready.sh — .ai-ready 规则一键替换 / 一键还原
# version: 20261029.3
#
# 托管：仓库里放两个文件（脚本 + 载荷包），服务器上一条命令安装:
#   curl -fsSL <URL_BASE>/toggle-ai-ready.sh | sh
#   curl -fsSL <URL_BASE>/toggle-ai-ready.sh | sh -s -- replace /workspace/projA
#
# 装好后的本地入口:
#   bash /workspace/.ai-ready-kit/toggle-ai-ready.sh           # 交互菜单
#   ... toggle-ai-ready.sh list | status | replace | restore | diff | update
#
# 环境变量:
#   AIREADY_URL_BASE   仓库原始文件地址（默认见下），脚本与载荷都从这里下载
#   AIREADY_KIT_DIR    安装目录，默认 /workspace/.ai-ready-kit
#   SEARCH_ROOT        目标探测根目录，默认 /workspace

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
NEW_DIR="$KIT_DIR/new"
BACKUP_ROOT="$KIT_DIR/backups"
SEARCH_ROOT="${SEARCH_ROOT:-/workspace}"
MARKER_DIR="$BACKUP_ROOT/.markers"
URL_BASE="${AIREADY_URL_BASE:-https://raw.githubusercontent.com/qq928820655/ai-ready-kit/main}"
SCRIPT_NAME="toggle-ai-ready.sh"
PAYLOAD_NAME="ai-ready-payload.tar.gz"
VERSION="20261029.3"

C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_B='\033[36m'; C_0='\033[0m'
say()  { printf "%b%s%b\n" "$C_B" "$*" "$C_0"; }
ok()   { printf "%b%s%b\n" "$C_G" "$*" "$C_0"; }
warn() { printf "%b%s%b\n" "$C_Y" "$*" "$C_0"; }
err()  { printf "%b%s%b\n" "$C_R" "[错误] $*" "$C_0" >&2; }
die()  { err "$*"; exit 1; }

# ---------- 安装 / 更新（同一动作：拉最新脚本 + 载荷，落到 KIT） ----------

fetch() {  # $1=url $2=dest
    command -v curl >/dev/null || die "缺少 curl，请先安装"
    curl -fsSL "$1" -o "$2" || die "下载失败: $1（检查 AIREADY_URL_BASE=$URL_BASE）"
}

do_install() {
    local kit="${AIREADY_KIT_DIR:-/workspace/.ai-ready-kit}"
    mkdir -p "$kit"
    say "拉取脚本与载荷 ← $URL_BASE"

    fetch "$URL_BASE/$SCRIPT_NAME" "$kit/.toggle.tmp"
    bash -n "$kit/.toggle.tmp" || die "下载的脚本语法异常，已放弃"
    fetch "$URL_BASE/$PAYLOAD_NAME" "$kit/.payload.tmp"
    # 在 kit 目录内用相对名操作 tar，避免 Windows 盘符冒号被 tar 当成远程主机
    ( cd "$kit" && tar tzf .payload.tmp >/dev/null ) || die "载荷包损坏，已放弃"

    mv -f "$kit/.toggle.tmp"  "$kit/$SCRIPT_NAME"
    chmod +x "$kit/$SCRIPT_NAME"
    rm -rf "$kit/new"
    ( cd "$kit" && tar xzf .payload.tmp )
    rm -f "$kit/.payload.tmp"

    ok "已安装/更新 → $kit（version $VERSION，new/ 共 $(find "$kit/new" -type f | wc -l) 个文件）"
    echo
    say "下一步（任选）:"
    say "  bash $kit/$SCRIPT_NAME               # 交互菜单"
    say "  bash $kit/$SCRIPT_NAME list          # 探测目标"
    say "  bash $kit/$SCRIPT_NAME status <目标>  # 查看状态"
    say "  bash $kit/$SCRIPT_NAME replace <目标> # 一键替换"
    echo
    local ts=() t i=1
    mapfile -t ts < <(discover_targets)
    if [ "${#ts[@]}" -gt 0 ]; then
        say "当前探测到的目标:"
        for t in "${ts[@]}"; do printf '  %d) %s\n' "$i" "$t"; i=$((i+1)); done
        say "替换示例: bash $kit/$SCRIPT_NAME replace ${ts[0]}"
    else
        warn "在 $SEARCH_ROOT 下暂未探测到 .ai-ready 目标"
    fi
}

# ---------- 目标探测 ----------

normalize_target() {
    local p="$1"
    p="${p%/}"
    if [ -d "$p/.ai-ready" ]; then p="$p/.ai-ready"; fi
    [ -d "$p" ] || return 1
    [ -d "$p/rules" ] || [ -d "$p/skills" ] || return 1
    printf '%s' "$p"
}

discover_targets() {
    [ -d "$SEARCH_ROOT" ] || return 0
    find "$SEARCH_ROOT" -maxdepth 6 -type d -name .ai-ready \
        -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null |
    while read -r d; do
        if [ -d "$d/rules" ] || [ -d "$d/skills" ]; then printf '%s\n' "$d"; fi
    done
}

slug() { printf '%s' "$1" | sed 's#^/##; s#/#_#g; s#[^A-Za-z0-9_.-]#_#g'; }
marker_file() { printf '%s/%s' "$MARKER_DIR" "$(slug "$1")"; }

# ---------- 核心操作 ----------

snapshot() {
    local t="$1" ts backup
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_ROOT/$(slug "$t")/$ts"
    mkdir -p "$backup"
    # cp -a 保权限保时间戳，还原后与快照时逐字节一致；每次 replace 都新开一层，
    # 所以重复执行安全，历史状态全部可回
    [ -d "$t/rules" ]  && cp -a "$t/rules"  "$backup/rules"
    [ -d "$t/skills" ] && cp -a "$t/skills" "$backup/skills"
    printf '%s' "$backup"
}

do_replace() {
    local t; t="$(normalize_target "$1")" || die "目标无效: $1（没有 rules/skills）"
    [ -d "$NEW_DIR/rules" ] || die "new/ 不存在，先安装: curl -fsSL $URL_BASE/$SCRIPT_NAME | sh"
    local backup; backup="$(snapshot "$t")"
    say "已备份现网 → $backup"
    rm -rf "$t/rules" "$t/skills"
    cp -a "$NEW_DIR/rules"  "$t/rules"
    cp -a "$NEW_DIR/skills" "$t/skills"
    mkdir -p "$MARKER_DIR"
    printf '%s' "$backup" > "$(marker_file "$t")"
    ok "替换完成 → $t"
    say "一键还原: bash ${BASH_SOURCE[0]:-$0} restore $(dirname "$t")"
}

do_restore() {
    local t="$1" rp="${2:-}"
    t="$(normalize_target "$t")" || die "目标无效: $t"
    local mfile; mfile="$(marker_file "$t")"
    if [ -z "$rp" ]; then
        [ -f "$mfile" ] || die "该目标没有还原点记录，请指定备份时间戳"
        rp="$(cat "$mfile")"
    fi
    [ -d "$rp" ] || rp="$BACKUP_ROOT/$(slug "$t")/$rp"
    [ -d "$rp" ] || die "备份不存在: $rp"
    local current; current="$(snapshot "$t")"
    say "当前状态已另存 → $current"
    rm -rf "$t/rules" "$t/skills"
    cp -a "$rp/rules" "$t/rules"
    [ -d "$rp/skills" ] && cp -a "$rp/skills" "$t/skills"
    printf '%s' "$current" > "$mfile"   # 还原后再还原则回到还原前
    ok "已还原: $t ← $rp"
}

do_status() {
    local t; t="$(normalize_target "$1")" || die "目标无效: $1"
    say "目标: $t"
    local n_new=0 n_diff=0 f rel
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
    local bdir="$BACKUP_ROOT/$(slug "$t")"
    if [ -d "$bdir" ] && ls -A "$bdir" 2>/dev/null | grep -q .; then
        say "可用备份:"
        ls -1 "$bdir" | sed 's/^/  /'
    else
        say "暂无备份。"
    fi
}

do_diff() {
    local t; t="$(normalize_target "$1")" || die "目标无效: $1"
    local tmp; tmp="$(mktemp)"
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

# ---------- 菜单 ----------

pick_target() {  # 提示走 stderr，仅最终路径走 stdout
    local targets=()
    mapfile -t targets < <(discover_targets)
    if [ "${#targets[@]}" -eq 0 ]; then
        warn "在 $SEARCH_ROOT 下没探测到 .ai-ready（需含 rules/ 或 skills/）"
        printf '输入 .ai-ready 或其项目目录路径: ' >&2
        local p; read -r p
        [ -n "$p" ] || return 1
        normalize_target "$p"
        return
    fi
    echo >&2
    say "探测到 ${#targets[@]} 个目标:" >&2
    local i=1 t
    for t in "${targets[@]}"; do printf '  %d) %s\n' "$i" "$t" >&2; i=$((i+1)); done
    printf '  m) 手动输入路径\n' >&2
    printf '选择 [1-%d/m]: ' "${#targets[@]}" >&2
    local c; read -r c
    case "$c" in
        m|M)
            printf '路径: ' >&2; local p; read -r p
            [ -n "$p" ] || return 1
            normalize_target "$p" ;;
        *[!0-9]*|'') return 1 ;;
        *)
            [ "$c" -ge 1 ] && [ "$c" -le "${#targets[@]}" ] || return 1
            printf '%s' "${targets[$((c-1))]}" ;;
    esac
}

menu() {
    local t yn op
    while true; do
        echo
        printf '%b======== .ai-ready 替换/还原 (v%s) ========\n' "$C_B" "$C_0" "$VERSION"
        printf '  1) 探测目标列表 (list)\n'
        printf '  2) 查看状态 (status)\n'
        printf '  3) 一键替换 (replace)\n'
        printf '  4) 一键还原 (restore)\n'
        printf '  5) 查看差异 (diff)\n'
        printf '  6) 更新脚本与 new/ (update)\n'
        printf '  0) 退出\n'
        printf '选择: '
        read -r op
        case "$op" in
            0) exit 0 ;;
            1)
                local ts=()
                mapfile -t ts < <(discover_targets)
                if [ "${#ts[@]}" -eq 0 ]; then
                    warn "未探测到目标"
                else
                    local i=1; for t in "${ts[@]}"; do printf '  %d) %s\n' "$i" "$t"; i=$((i+1)); done
                fi ;;
            2|3|4|5)
                t="$(pick_target)" || { warn "未选定目标"; continue; }
                case "$op" in
                    2) do_status "$t" ;;
                    3)
                        printf '%b确认替换 %s ?[y/N]: %b' "$C_Y" "$t" "$C_0"; read -r yn
                        if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then do_replace "$t"; else say "已取消"; fi ;;
                    4) do_restore "$t" "" ;;
                    5) do_diff "$t" ;;
                esac ;;
            6) do_install ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ---------- 入口 ----------

CMD="${1:-}"

# curl | sh 管道执行（stdin 非终端且脚本不在磁盘上）：
#   无参数 → 安装；带参数 → 先确保已安装，再交给 kit 里的完整脚本执行
if [ -z "${BASH_SOURCE[0]:-}" ] && [ ! -t 0 ]; then
    local_kit="${AIREADY_KIT_DIR:-/workspace/.ai-ready-kit}"
    if [ -n "$CMD" ]; then
        if [ ! -x "$local_kit/$SCRIPT_NAME" ]; then
            say "首次管道执行，先安装..."
            do_install > /dev/null
            echo
        fi
        exec bash "$local_kit/$SCRIPT_NAME" "$@"
    fi
    do_install
    exit 0
fi

[ -n "$CMD" ] || CMD=menu

case "$CMD" in
    menu)    menu ;;
    list)    discover_targets ;;
    install|update) do_install ;;
    status)  shift; do_status "${1:?用法: status <目标路径>}" ;;
    replace) shift; do_replace "${1:?用法: replace <目标路径>}" ;;
    diff)    shift; do_diff "${1:?用法: diff <目标路径>}" ;;
    restore) t="${2:?用法: restore <目标路径> [备份时间戳]}"; do_restore "$t" "${3:-}" ;;
    *)       sed -n '2,20p' "${BASH_SOURCE[0]:-$0}" ;;
esac
exit 0
