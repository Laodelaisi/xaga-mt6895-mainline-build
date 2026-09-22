#!/usr/bin/env bash
# build-mainline.sh —— xaga (Redmi Note 11T Pro / MT6895 / 天玑8100) 主线内核本地构建
#
# 项目根目录 = 本脚本所在目录, 不硬编码任何绝对路径:
#   ./linux/      内核源码 (已存在就不重新 clone)
#   ./initramfs/  MT6895-Mainline/initramfs (已存在就不重新 clone)
#   ./mktools/    mkbootimg 打包器 (没有就装到这里)
#   ./out/        产物: boot-<ts>.img / Image-<ts>.gz / initramfs-<ts>.cpio.lz4 / modules-<ts>.tar.gz
#   ./logs/       构建日志
#
# 不带任何参数直接跑 = 交互式问答, 每一项都对应 .github/workflows/build.yml 的
# workflow_dispatch 输入 (下拉选序号 / 打勾输 y/n / 文本框直接回车用默认)。
#
# SSH 容易断的场景: 加 --tmux, 脚本会把自己丢进后台 tmux 会话, 断开也不中断,
# 跑完调用 .github/bot-offline.py 推送通知 (喵提醒 / Server酱)。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ===========================================================================
# 宏定义 —— 与 .github/workflows/build.yml 的 workflow_dispatch 输入一一对应
# 直接运行脚本会按下面的默认值逐条问答; 命令行参数 / 同名环境变量可覆盖
# ===========================================================================

ROOT="${XAGA_ROOT:-$SCRIPT_DIR}"          # 项目根目录 = 脚本所在目录

# build.yml: kernel_branch (下拉 1/2)
KERNEL_BRANCH="${KERNEL_BRANCH:-7.2-mt6895-xiaomi-xaga}"
# build.yml: initramfs_userdata / initramfs_nvdata (文本框, xaga 硬事实, 别乱改)
INITRAMFS_USERDATA="${INITRAMFS_USERDATA:-/dev/sdc86}"
INITRAMFS_NVDATA="${INITRAMFS_NVDATA:-/dev/sdc13}"
# build.yml: build_kernel / build_initramfs / build_modules (打勾 y/n)
BUILD_KERNEL="${BUILD_KERNEL:-1}"
BUILD_INITRAMFS="${BUILD_INITRAMFS:-1}"
BUILD_MODULES="${BUILD_MODULES:-1}"
# build.yml: reuse_run_id (文本框, 留空 = 复用本地 ./out 里最新产物)
REUSE_RUN_ID="${REUSE_RUN_ID:-}"
# build.yml: send_notification (打勾 y/n)
NOTIFY="${NOTIFY:-1}"

KERNEL_REPO="${KERNEL_REPO:-MT6895-Mainline/linux}"
INITRAMFS_REPO="${INITRAMFS_REPO:-MT6895-Mainline/initramfs}"
GH_REPO="${XAGA_GH_REPO:-}"              # 复用 RUNS ID 时的 OWNER/REPO

LINUX_DIR="$ROOT/linux"
INITRAMFS_DIR="$ROOT/initramfs"
MKTOOLS_DIR="$ROOT/mktools"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
LOG_DIR="$ROOT/logs"

# boot 头部参数, 与 postmarketOS wiki 一致
BASE=0x3fff8000
KERNEL_OFFSET=0x8000
PAGESIZE=4096
RAMDISK_OFFSET=0x26f08000
TAGS_OFFSET=0x07c88000
DTB_OFFSET=0x07c88000
HEADER_VERSION=4
OS_VERSION=16.0.0
OS_PATCH_LEVEL=2026-08

UPDATE=0          # 1 = 强制 git fetch 更新已有源码
DO_CLEAN=0        # 1 = 先 make clean
USE_TMUX=0
SESSION="xaga-build"
JOBS="$(nproc 2>/dev/null || echo 4)"
OUT_SET=0                    # 1 = 命令行显式给了 --out
INTERACTIVE=0     # 1 = 走交互式问答
MKBOOTIMG="${MKBOOTIMG:-}"   # 可用环境变量指定打包器
REUSE_DIR=""      # 复用 RUNS ID 时, gh 下载下来的产物目录

TS="$(date +'%Y%m%d-%H%M%S')"
LOG_FILE=""
STATUS_FILE=""

# --------------------------------------------------------------------------- 工具函数

log()  { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build][error]\033[0m %s\n' "$*" >&2; exit 1; }

# 各种"真"的写法统一成 1/0
to_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|y|yes|true|on)  echo 1 ;;
        *)                echo 0 ;;
    esac
}

find_bot() {
    local c
    for c in "$ROOT/.github/bot-offline.py" "$ROOT/bot-offline.py"; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    echo ""
}

BOT="$(find_bot)"

notify() {
    local status="$1"; shift
    local msg="$*"
    [ "$NOTIFY" = "1" ] || { log "(通知已关闭)"; return 0; }
    if [ -z "$BOT" ]; then
        warn "找不到 bot-offline.py, 跳过通知"
        return 0
    fi
    local -a extra=()
    [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && extra=(--log "$LOG_FILE")
    python3 "$BOT" --notify --status "$status" --message "$msg" \
        ${extra[@]+"${extra[@]}"} || warn "通知发送失败 (不影响构建结果)"
}

on_err() {
    local line="$1" rc="$2"
    printf '\033[1;31m[build][error]\033[0m 第 %s 行失败 (exit=%s)\n' "$line" "$rc" >&2
    [ -n "$STATUS_FILE" ] && echo "failure" > "$STATUS_FILE"
    notify failure "构建失败: 第 $line 行 (exit=$rc)${LOG_FILE:+  日志: $LOG_FILE}"
    exit "$rc"
}
trap 'on_err $LINENO $?' ERR

usage() {
    cat <<EOF
用法: $0 [选项]

不带任何参数直接运行 = 交互式问答 (对应 build.yml 的 workflow_dispatch 参数)。

  -i, --interactive  强制走交互式问答
  --root DIR         项目根目录 (默认: 脚本所在目录 $ROOT)
  --branch NAME      内核分支 (默认 $KERNEL_BRANCH)
  --userdata DEV     initramfs 的 userdata 设备 (默认 $INITRAMFS_USERDATA)
  --nvdata DEV       initramfs 的 NVRAM 分区 (默认 $INITRAMFS_NVDATA)
  --no-kernel        不编内核, 复用 Image-*.gz
  --no-initramfs     不编 initramfs, 复用 initramfs-*.cpio.lz4
  --no-modules       不编内核模块, 复用 modules-*.tar.gz
  --reuse-run-id ID  复用 GitHub Actions 某次 Run 的产物 (留空=复用本地 ./out)
  --repo OWNER/REPO  配合 --reuse-run-id, gh 要的仓库 (默认读环境变量 XAGA_GH_REPO)
  --update           强制 fetch 更新已存在的 linux/ 和 initramfs/
  --clean            编译前先 clean
  -j N               并行数 (默认 nproc)
  --out DIR          产物目录 (默认 $OUT_DIR)
  --tmux             丢进后台 tmux 会话, SSH 断了也不中断
  --session NAME     tmux 会话名 (默认 $SESSION)
  --no-notify        构建完不发通知
  -h, --help         看这个

头部参数硬编码为 postmarketOS wiki 的值, 不提供命令行修改 (别乱改)。
EOF
}

# --------------------------------------------------------------------------- 交互式问答

# 打勾选项: y/n, 直接回车用默认
ask_bool() {
    local prompt="$1" def="$2" ans hint
    if [ "$def" = "1" ]; then hint="Y/n"; else hint="y/N"; fi
    read -r -p "  $prompt [$hint]: " ans || true
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    case "$ans" in
        "")                 echo "$def" ;;
        y|Y|yes|YES|1|on)   echo 1 ;;
        n|N|no|NO|0|off)    echo 0 ;;
        *)  echo "$def" ;;
    esac
}

# 文本框: 直接回车用默认
ask_str() {
    local prompt="$1" def="$2" ans
    if [ -z "$def" ]; then
        read -r -p "  $prompt [默认: 空]: " ans || true
    else
        read -r -p "  $prompt [默认: $def]: " ans || true
    fi
    if [ -z "$ans" ]; then printf '%s' "$def"; else printf '%s' "$ans"; fi
}

# 下拉选择: 输入序号 (选项写成 "值|显示文本", 没有 | 就显示值本身)
ask_choice() {
    local prompt="$1" def="$2"; shift 2
    local -a opts=("$@")
    local i entry val disp ans n="${#opts[@]}"
    # 菜单走 stderr: 调用方是 $(ask_choice ...), 只有最后那个值走 stdout
    printf '  %s\n' "$prompt" >&2
    for i in "${!opts[@]}"; do
        entry="${opts[$i]}"
        val="${entry%%|*}"
        disp="${entry#*|}"
        [ "$disp" != "$entry" ] || disp="$val"
        printf '    %d) %s%s\n' "$((i+1))" "$disp" \
            "$( [ "$((i+1))" = "$def" ] && echo '   <默认>' || true )" >&2
    done
    printf '  请输入序号 [默认 %s]: ' "$def" >&2
    read -r ans || true
    [ -n "$ans" ] || ans="$def"
    case "$ans" in
        ''|*[!0-9]*) warn "'$ans' 不是序号, 用默认 $def"; ans="$def" ;;
    esac
    if [ "$ans" -lt 1 ] || [ "$ans" -gt "$n" ]; then
        warn "序号 $ans 超出范围, 用默认 $def"; ans="$def"
    fi
    printf '%s' "${opts[$((ans-1))]%%|*}"
}

# 对应 build.yml 的 workflow_dispatch 输入, 逐条问答
interactive_config() {
    cat <<EOF

================ xaga 主线内核构建 (本地) ================
直接回车 = 用默认值; 打勾项输 y/n; 下拉项输序号。
项目根目录: $ROOT
==========================================================
EOF
    echo "[1/8] kernel_branch —— 内核分支"
    KERNEL_BRANCH="$(ask_choice "选择内核分支" 1 \
        '7.2-mt6895-xiaomi-xaga|7.2 功能最新' \
        '6.18-mt6895-xiaomi-xaga|6.18 更保守')"

    echo "[2/8] initramfs_userdata —— initramfs 找 rootfs 的设备节点"
    INITRAMFS_USERDATA="$(ask_str "userdata 设备节点 (xaga = /dev/sdc86, 不是 fastboot 分区名)" "$INITRAMFS_USERDATA")"

    echo "[3/8] initramfs_nvdata —— WiFi/BT NVRAM 分区"
    INITRAMFS_NVDATA="$(ask_str "NVRAM 分区 (xaga = /dev/sdc13)" "$INITRAMFS_NVDATA")"

    echo "[4/8] build_kernel —— 是否编译内核"
    BUILD_KERNEL="$(ask_bool "编译内核?" "$BUILD_KERNEL")"

    echo "[5/8] build_initramfs —— 是否编译 initramfs"
    BUILD_INITRAMFS="$(ask_bool "编译 initramfs?" "$BUILD_INITRAMFS")"

    echo "[6/8] build_modules —— 是否编译内核模块"
    BUILD_MODULES="$(ask_bool "编译内核模块?" "$BUILD_MODULES")"

    echo "[7/8] reuse_run_id —— 复用产物来源"
    REUSE_RUN_ID="$(ask_str "GitHub Actions RUNS ID (留空=复用本地 ./out 最新产物)" "$REUSE_RUN_ID")"

    echo "[8/8] send_notification —— 构建完推送通知"
    NOTIFY="$(ask_bool "构建完推送通知 (喵提醒/Server酱)?" "$NOTIFY")"

    echo
    echo "  --- 本地附加项 ---"
    USE_TMUX="$(ask_bool "丢进后台 tmux 会话 (SSH 断线也不中断)?" "$USE_TMUX")"
    JOBS="$(ask_str "并行编译数 -j" "$JOBS")"
    UPDATE="$(ask_bool "强制 git fetch 更新 linux/ 和 initramfs/?" "$UPDATE")"

    echo
    log "汇总: 分支=$KERNEL_BRANCH userdata=$INITRAMFS_USERDATA nvdata=$INITRAMFS_NVDATA"
    log "      内核=$BUILD_KERNEL initramfs=$BUILD_INITRAMFS modules=$BUILD_MODULES"
    log "      复用RUNS ID=${REUSE_RUN_ID:-<留空, 用本地 out/>} 通知=$NOTIFY tmux=$USE_TMUX -j$JOBS"
}

# --------------------------------------------------------------------------- 参数解析

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--interactive) INTERACTIVE=1; shift ;;
        --root)         ROOT="$2"; shift 2 ;;
        --branch)       KERNEL_BRANCH="$2"; shift 2 ;;
        --userdata|--boot-part) INITRAMFS_USERDATA="$2"; shift 2 ;;
        --nvdata)       INITRAMFS_NVDATA="$2"; shift 2 ;;
        --no-kernel)    BUILD_KERNEL=0; shift ;;
        --no-initramfs) BUILD_INITRAMFS=0; shift ;;
        --no-modules)   BUILD_MODULES=0; shift ;;
        --reuse-run-id) REUSE_RUN_ID="$2"; shift 2 ;;
        --repo)         GH_REPO="$2"; shift 2 ;;
        --update)       UPDATE=1; shift ;;
        --clean)        DO_CLEAN=1; shift ;;
        -j)             JOBS="$2"; shift 2 ;;
        --out)          OUT_DIR="$2"; OUT_SET=1; shift 2 ;;
        --tmux)         USE_TMUX=1; shift ;;
        --session)      SESSION="$2"; shift 2 ;;
        --no-notify)    NOTIFY=0; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "未知参数: $1 (试试 $0 --help)" ;;
    esac
done

# 布尔量归一化 (环境变量可能给 true / false / yes ...)
BUILD_KERNEL="$(to_bool "$BUILD_KERNEL")"
BUILD_INITRAMFS="$(to_bool "$BUILD_INITRAMFS")"
BUILD_MODULES="$(to_bool "$BUILD_MODULES")"
NOTIFY="$(to_bool "$NOTIFY")"

# 一个参数都没给 且 是终端 -> 走交互式问答
if [ "$INTERACTIVE" = "1" ] || { [ "$ARGC" = "0" ] && [ -t 0 ]; }; then
    interactive_config
fi

# --root 可能改了根目录, 这些路径必须重新算 (没显式给 --out 就跟着 ROOT 走)
LINUX_DIR="$ROOT/linux"
INITRAMFS_DIR="$ROOT/initramfs"
MKTOOLS_DIR="$ROOT/mktools"
LOG_DIR="$ROOT/logs"
[ "$OUT_SET" = "1" ] || OUT_DIR="$ROOT/out"
BOT="$(find_bot)"

# initramfs 的 make 参数名沿用上游 Makefile
BOOT_PARTITION="$INITRAMFS_USERDATA"
NVDATA_PARTITION="$INITRAMFS_NVDATA"

mkdir -p "$OUT_DIR" "$LOG_DIR"

# --------------------------------------------------------------------------- tmux: 断开 SSH 也不中断

if [ "$USE_TMUX" = "1" ] && [ -z "${TMUX:-}" ] && [ -z "${XAGA_IN_TMUX:-}" ]; then
    if ! command -v tmux >/dev/null 2>&1; then
        warn "没装 tmux, 直接前台编译 (建议 apt-get install tmux)"
    else
        LOG_FILE="$LOG_DIR/build-mainline-$TS.log"
        STATUS_FILE="$LOG_DIR/build-mainline-$TS.status"
        : > "$LOG_FILE"
        # 去掉 --tmux 再交给会话里的自己 (并打上 XAGA_IN_TMUX 标记), 避免无限套娃
        quoted="$(printf '%q ' --root "$ROOT" --branch "$KERNEL_BRANCH" \
                  --userdata "$INITRAMFS_USERDATA" --nvdata "$INITRAMFS_NVDATA" \
                  -j "$JOBS" --out "$OUT_DIR" --session "$SESSION")"
        [ "$BUILD_KERNEL"    = 1 ] || quoted="$quoted --no-kernel"
        [ "$BUILD_INITRAMFS" = 1 ] || quoted="$quoted --no-initramfs"
        [ "$BUILD_MODULES"   = 1 ] || quoted="$quoted --no-modules"
        [ -n "$REUSE_RUN_ID" ]    && quoted="$quoted --reuse-run-id $(printf '%q' "$REUSE_RUN_ID")"
        [ -n "$GH_REPO" ]         && quoted="$quoted --repo $(printf '%q' "$GH_REPO")"
        [ "$UPDATE"          = 1 ] &&  quoted="$quoted --update"
        [ "$DO_CLEAN"        = 1 ] &&  quoted="$quoted --clean"
        [ "$NOTIFY"          = 1 ] ||  quoted="$quoted --no-notify"

        tmux new-session -d -s "$SESSION" \
            "XAGA_IN_TMUX=1 XAGA_LOG_FILE=$(printf '%q' "$LOG_FILE") XAGA_STATUS_FILE=$(printf '%q' "$STATUS_FILE") bash $(printf '%q' "$0") $quoted 2>&1 | tee -a $(printf '%q' "$LOG_FILE")"
        echo
        log "已在后台 tmux 会话 '$SESSION' 开始构建, SSH 断开也不会中断"
        log "  查看进度: tmux attach -t $SESSION   (Ctrl-b d 安全脱离)"
        log "  日志文件: $LOG_FILE"
        log "  盯完推送: python3 $( [ -n "$BOT" ] && echo "$BOT" || echo "$ROOT/.github/bot-offline.py" ) --watch-tmux $SESSION --log $LOG_FILE"
        exit 0
    fi
fi

LOG_FILE="${XAGA_LOG_FILE:-$LOG_DIR/build-mainline-$TS.log}"
STATUS_FILE="${XAGA_STATUS_FILE:-$LOG_DIR/build-mainline-$TS.status}"
mkdir -p "$(dirname "$LOG_FILE")"

# --------------------------------------------------------------------------- 工具链检查

check_toolchain() {
    command -v clang >/dev/null 2>&1 \
        || die "缺 clang (主线内核要求 clang>=17, LLVM=1 全链路)"
    local v
    v="$(clang --version | head -1 | grep -oE '[0-9]+' | head -1 || echo 0)"
    [ "${v:-0}" -ge 17 ] || die "clang 版本太低: $v (要 >=17; README: Clang 18 全链路)"
    command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 \
        || die "缺 aarch64-linux-gnu-gcc (编 initramfs 的 init.c 要用)"
    command -v ld.lld >/dev/null 2>&1 || warn "没找到 ld.lld, LLVM=1 链接可能失败"
    command -v lz4 >/dev/null 2>&1 || warn "没找到 lz4 (initramfs 打包要用)"
    log "工具链: clang $v / $(aarch64-linux-gnu-gcc --version | head -1)"
}

# --------------------------------------------------------------------------- 源码: 有就不重复下载

ensure_kernel_src() {
    if [ -d "$LINUX_DIR/.git" ]; then
        log "内核源码已存在: $LINUX_DIR (不重复 clone)"
        local cur
        cur="$(git -C "$LINUX_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        if [ "$cur" != "$KERNEL_BRANCH" ]; then
            log "当前分支 '$cur' != 目标 '$KERNEL_BRANCH', 拉取目标分支"
            git -C "$LINUX_DIR" fetch --depth 1 origin "$KERNEL_BRANCH"
            git -C "$LINUX_DIR" checkout -f "$KERNEL_BRANCH"
        elif [ "$UPDATE" = "1" ]; then
            if [ -n "$(git -C "$LINUX_DIR" status --porcelain)" ]; then
                warn "linux/ 有未提交改动, 跳过 fetch (要强制更新自己先处理)"
            else
                log "更新内核源码 ($KERNEL_BRANCH)"
                git -C "$LINUX_DIR" fetch --depth 1 origin "$KERNEL_BRANCH"
                git -C "$LINUX_DIR" reset --hard FETCH_HEAD
            fi
        fi
    else
        log "首次拉取内核源码: $KERNEL_REPO@$KERNEL_BRANCH"
        git clone --depth 1 -b "$KERNEL_BRANCH" \
            "https://github.com/$KERNEL_REPO.git" "$LINUX_DIR"
    fi
    log "内核 HEAD: $(git -C "$LINUX_DIR" log -1 --format='%h %s')"
}

ensure_initramfs_src() {
    if [ -d "$INITRAMFS_DIR/.git" ]; then
        log "initramfs 源码已存在: $INITRAMFS_DIR (不重复 clone)"
        if [ "$UPDATE" = "1" ]; then
            if [ -n "$(git -C "$INITRAMFS_DIR" status --porcelain)" ]; then
                warn "initramfs/ 有未提交改动, 跳过 pull"
            else
                git -C "$INITRAMFS_DIR" pull --ff-only
            fi
        fi
    else
        log "首次拉取 initramfs: $INITRAMFS_REPO"
        local br ok=0
        for br in main master; do
            if git clone --depth 1 -b "$br" \
                 "https://github.com/$INITRAMFS_REPO.git" "$INITRAMFS_DIR" 2>/dev/null; then
                ok=1; break
            fi
        done
        [ "$ok" = "1" ] || die "initramfs clone 失败 (main/master 都试过了)"
    fi
    log "initramfs HEAD: $(git -C "$INITRAMFS_DIR" log -1 --format='%h %s')"
}

# 打包器一律装在 ./mktools 下; 每个候选都先"真打一个最小包"验头部, 不是 1584 就换下一个
MKTOOLS_AOSP_URL="https://android.googlesource.com/platform/system/tools/mkbootimg"
MKTOOLS_OSM0SIS_URL="https://github.com/osm0sis/mkbootimg.git"

# 冒烟: 打包器能不能产出合法 v4 头 (header_version=4 / header_size=1584)
mkbootimg_smoke() {
    local cmd="$1" tmpd out
    tmpd="$(mktemp -d)"
    : > "$tmpd/k"; : > "$tmpd/r"
    out="$tmpd/boot.img"
    if ! $cmd --kernel "$tmpd/k" --ramdisk "$tmpd/r" --pagesize 4096 \
         --header_version 4 -o "$out" >"$tmpd/pack.log" 2>&1; then
        warn "  打包器跑不通: $cmd ($(head -2 "$tmpd/pack.log" | tr '\n' ' '))"
        rm -rf "$tmpd"; return 1
    fi
    if ! python3 - "$out" <<'PY'
import struct, sys

with open(sys.argv[1], "rb") as f:
    h = f.read(1584)
ok = (h[:8] == b"ANDROID!"
      and struct.unpack_from("<I", h, 40)[0] == 4
      and struct.unpack_from("<I", h, 20)[0] == 1584)
sys.exit(0 if ok else 1)
PY
    then
        warn "  产出的头不合法 (要 header_version=4 且 header_size=1584): $cmd"
        rm -rf "$tmpd"; return 1
    fi
    rm -rf "$tmpd"
    return 0
}

ensure_mktools() {
    local -a cands=()
    local cmd

    # 1) 已经有的: 环境变量 / ./mktools/bin/mkbootimg / ./mktools/**/mkbootimg.py
    [ -n "$MKBOOTIMG" ] && [ -x "$MKBOOTIMG" ] && cands+=("$MKBOOTIMG")
    [ -x "$MKTOOLS_DIR/bin/mkbootimg" ] && cands+=("$MKTOOLS_DIR/bin/mkbootimg")
    for cmd in "$MKTOOLS_DIR/mkbootimg.py" "$MKTOOLS_DIR/aosp/mkbootimg.py"; do
        [ -f "$cmd" ] && cands+=("python3 $cmd")
    done

    # 2) ./mktools 里有 C 源码但没产物 -> 先 make (大概率是 v3, 1580, 冒烟会拦下)
    if [ "${#cands[@]}" = "0" ] && [ -f "$MKTOOLS_DIR/Makefile" ]; then
        log "./mktools 有源码没产物, 先 make"
        make -C "$MKTOOLS_DIR" || warn "make 失败, 继续找别的打包器"
        [ -x "$MKTOOLS_DIR/bin/mkbootimg" ] && cands+=("$MKTOOLS_DIR/bin/mkbootimg")
    fi

    # 3) 都没有 -> 拉 AOSP 官方 mkbootimg 装到 ./mktools/aosp
    if [ "${#cands[@]}" = "0" ]; then
        log "没有 mkbootimg, 安装 AOSP 官方版到 $MKTOOLS_DIR/aosp"
        mkdir -p "$MKTOOLS_DIR"
        git clone --depth 1 "$MKTOOLS_AOSP_URL" "$MKTOOLS_DIR/aosp" \
            || die "AOSP mkbootimg 拉取失败 (网络?): $MKTOOLS_AOSP_URL"
        # deb/源码里没打 gki 模块, 补个 stub 免得 import 炸
        if [ ! -f "$MKTOOLS_DIR/aosp/gki.py" ]; then
            cat > "$MKTOOLS_DIR/aosp/gki.py" <<'PY'
def GenerateGkiCertificate(*args, **kwargs):
    raise NotImplementedError("GKI 签名未实现 (xaga 用不到)")
PY
        fi
        cands+=("python3 $MKTOOLS_DIR/aosp/mkbootimg.py")
    fi

    # 4) 逐个冒烟, 取第一个能产出合法 v4 头的
    for cmd in "${cands[@]}"; do
        log "校验打包器: $cmd"
        if mkbootimg_smoke "$cmd"; then
            MKBOOTIMG_CMD="$cmd"
            log "打包器可用 (header_size=1584): $MKBOOTIMG_CMD"
            return 0
        fi
    done

    die "所有打包器都产不出合法的 v4 头 (header_size=1584)。
  osm0sis 的 C 版 mkbootimg 只实现到 boot_img_hdr_v3 (恒 1580), MTK LK 会拒载。
  手动装 AOSP 官方版:
    git clone --depth 1 $MKTOOLS_AOSP_URL $MKTOOLS_DIR/aosp
  或者 osm0sis 版 (仅作兜底): git clone $MKTOOLS_OSM0SIS_URL $MKTOOLS_DIR/osm0sis"
}

# --------------------------------------------------------------------------- 构建步骤

build_initramfs() {
    log "编译 initramfs (BOOT_PARTITION=$BOOT_PARTITION NVDATA_PARTITION=$NVDATA_PARTITION)"
    cd "$INITRAMFS_DIR"
    [ "$DO_CLEAN" = "1" ] && make clean
    CROSS_COMPILE=aarch64-linux-gnu- \
        make BOOT_PARTITION="$BOOT_PARTITION" NVDATA_PARTITION="$NVDATA_PARTITION"
    cp -f "$INITRAMFS_DIR/initramfs.cpio.lz4" "$OUT_DIR/initramfs-$TS.cpio.lz4"
    log "initramfs: $OUT_DIR/initramfs-$TS.cpio.lz4"
    cd "$ROOT"
}

build_kernel() {
    log "编译内核 (LLVM=1, -j$JOBS)"
    cd "$LINUX_DIR"
    if [ ! -f .config ] || [ "$DO_CLEAN" = "1" ]; then
        ARCH=arm64 scripts/kconfig/merge_config.sh \
            arch/arm64/configs/defconfig arch/arm64/configs/xaga.config
        make ARCH=arm64 LLVM=1 olddefconfig
    else
        log "复用已有 .config (要重新 merge 就删掉 linux/.config 或加 --clean)"
        make ARCH=arm64 LLVM=1 olddefconfig
    fi
    make ARCH=arm64 LLVM=1 -j"$JOBS" Image
    gzip -n -9 -c arch/arm64/boot/Image > "$OUT_DIR/Image-$TS.gz"
    log "内核 Image: $OUT_DIR/Image-$TS.gz"
    cd "$ROOT"
}

build_modules() {
    log "编译内核模块"
    cd "$LINUX_DIR"
    make ARCH=arm64 LLVM=1 -j"$JOBS" modules
    rm -rf modout
    make ARCH=arm64 LLVM=1 INSTALL_MOD_PATH="$PWD/modout" INSTALL_MOD_STRIP=1 modules_install
    rm -f modout/lib/modules/*/build modout/lib/modules/*/source
    tar -C modout -czf "$OUT_DIR/modules-$TS.tar.gz" lib
    rm -rf modout
    log "内核模块: $OUT_DIR/modules-$TS.tar.gz"
    cd "$ROOT"
}

# build.yml: reuse_run_id —— 从 GitHub Actions 某次 Run 里把产物下下来再复用
ensure_reuse_run() {
    [ -n "$REUSE_RUN_ID" ] || return 0
    command -v gh >/dev/null 2>&1 \
        || die "填了 RUNS ID 但没装 gh (sudo apt-get install gh, 或留空复用本地 ./out)"
    REUSE_DIR="$OUT_DIR/reuse-$REUSE_RUN_ID"
    if [ -d "$REUSE_DIR" ] && [ -n "$(ls -A "$REUSE_DIR" 2>/dev/null)" ]; then
        log "复用目录已存在, 不重复下载: $REUSE_DIR"
        return 0
    fi
    mkdir -p "$REUSE_DIR"
    log "从 GitHub Actions Run $REUSE_RUN_ID 下载产物 -> $REUSE_DIR"
    local -a repoarg=()
    [ -n "$GH_REPO" ] && repoarg=(-R "$GH_REPO")
    gh run download "$REUSE_RUN_ID" -D "$REUSE_DIR" ${repoarg[@]+"${repoarg[@]}"} \
        || die "gh run download $REUSE_RUN_ID 失败 (仓库不对? 用 --repo OWNER/REPO)"
}

reuse_latest() {
    # $1 = 文件名通配, $2 = 目标文件名; 找不到就返回 1, 由调用方决定是报错还是跳过
    local pattern="$1" dest="$2" f
    # 优先复用 RUNS ID 下下来的, 再退到本地 out/
    f="$( { [ -n "$REUSE_DIR" ] && [ -d "$REUSE_DIR" ] \
                && find "$REUSE_DIR" -type f -name "$pattern" -printf '%T@\t%p\n' 2>/dev/null
            find "$OUT_DIR" -maxdepth 1 -type f -name "$pattern" -printf '%T@\t%p\n' 2>/dev/null
          } | sort -rn | head -1 | cut -f2- )"
    if [ -z "$f" ]; then
        warn "要复用但没有匹配 $pattern 的产物 (找过: ${REUSE_DIR:-<无复用目录>} 和 $OUT_DIR)"
        return 1
    fi
    cp -f "$f" "$OUT_DIR/$dest"
    log "复用已有产物: $f -> $dest"
    return 0
}

pack_boot() {
    local kernel="$OUT_DIR/Image-$TS.gz" ramdisk="$OUT_DIR/initramfs-$TS.cpio.lz4"
    [ -f "$kernel" ]  || die "缺内核 $kernel"
    [ -f "$ramdisk" ] || die "缺 initramfs $ramdisk"
    log "打包 boot.img (header_version=$HEADER_VERSION, 参数照 postmarketOS wiki)"
    # DTB 已 objcopy 链进 vmlinux, 所以不传 --dtb, 也不要拼 Image+dtb
    $MKBOOTIMG_CMD \
        --kernel "$kernel" \
        --ramdisk "$ramdisk" \
        --base $BASE --kernel_offset $KERNEL_OFFSET --pagesize $PAGESIZE \
        --ramdisk_offset $RAMDISK_OFFSET --tags_offset $TAGS_OFFSET --dtb_offset $DTB_OFFSET \
        --header_version $HEADER_VERSION --os_version $OS_VERSION --os_patch_level $OS_PATCH_LEVEL \
        -o "$OUT_DIR/boot-$TS.img"
    log "boot 镜像: $OUT_DIR/boot-$TS.img"
}

verify_boot() {
    if [ -z "$BOT" ]; then
        warn "找不到 bot-offline.py, 跳过 boot 头部校验"
        return 0
    fi
    python3 "$BOT" --verify-bootimg "$OUT_DIR/boot-$TS.img" \
        || die "boot.img 头部校验没过, 别刷它"
}

# --------------------------------------------------------------------------- 主流程

main() {
    log "项目根目录: $ROOT"
    log "时间戳: $TS"
    [ -n "$BOT" ] && log "通知脚本: $BOT" || warn "没找到 bot-offline.py, 构建完不会推送通知"

    check_toolchain
    ensure_mktools
    ensure_reuse_run
    # 不复用的才去拉源码 (已存在就不重复 clone)
    [ "$BUILD_KERNEL" = "1" ] && ensure_kernel_src
    [ "$BUILD_INITRAMFS" = "1" ] && ensure_initramfs_src

    if [ "$BUILD_INITRAMFS" = "1" ]; then
        build_initramfs
    else
        reuse_latest "initramfs-*.cpio.lz4" "initramfs-$TS.cpio.lz4" \
            || die "--no-initramfs 但没东西可复用"
    fi

    if [ "$BUILD_KERNEL" = "1" ]; then
        build_kernel
    else
        reuse_latest "Image-*.gz" "Image-$TS.gz" \
            || die "--no-kernel 但没东西可复用"
    fi

    if [ "$BUILD_KERNEL" = "1" ] && [ "$BUILD_MODULES" = "1" ]; then
        build_modules
    else
        # 复用内核时没法现编模块 (模块必须跟内核同一棵树编译出来)
        reuse_latest "modules-*.tar.gz" "modules-$TS.tar.gz" \
            || warn "没有可复用的 modules-*.tar.gz, 本次不产出模块包"
    fi

    pack_boot
    verify_boot

    echo "success" > "$STATUS_FILE"
    {
        echo "==== 构建产物 ($(date +'%F %T')) ===="
        ls -lh "$OUT_DIR"/boot-$TS.img "$OUT_DIR"/Image-$TS.gz \
               "$OUT_DIR"/initramfs-$TS.cpio.lz4 2>/dev/null || true
    } | tee -a "$LOG_FILE"

    notify success "xaga 主线内核构建完成
产物: $OUT_DIR
- boot-$TS.img
- Image-$TS.gz
- initramfs-$TS.cpio.lz4
- modules-$TS.tar.gz
刷写: fastboot flash boot_a $OUT_DIR/boot-$TS.img (MTK v4 不支持 fastboot boot)"

    log "完成。刷写: fastboot flash boot_a $OUT_DIR/boot-$TS.img"
}

main "$@"

