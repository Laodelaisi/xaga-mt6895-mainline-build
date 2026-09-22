#!/usr/bin/env bash
# build-rootfs.sh —— xaga 本地构建 rootfs 镜像 (Arch Linux ARM / Debian 13 / Ubuntu 26.04 LTS)
#
# 项目根目录 = 本脚本所在目录, 不硬编码任何绝对路径:
#   ./cache/                  下载的 tarball / debootstrap 包缓存 (有就不重复下载)
#   ./build-rootfs/<发行版>/  工作目录 (rootfs 文件树 + 中间镜像)
#   ./rootfs/'Arch Linux'/    最终产物
#   ./rootfs/'Debian 13'/
#   ./rootfs/'Ubuntu 26.04 LTS'/
#   ./logs/                   构建日志
#
# 不带任何参数直接跑 = 交互式问答, 每一项都对应 .github/workflows/build.yml 的
# workflow_dispatch 输入 (下拉选序号 / 打勾输 y/n / 文本框直接回车用默认)。
#
# 只有 root 用户, 不创建普通用户。需要 root 权限 (loop 挂载 + chroot + qemu)。
# SSH 容易断: 加 --tmux, 脚本会把自己丢进后台 tmux 会话, 断开也不中断,
# 跑完调用 .github/bot-offline.py 推送通知。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ===========================================================================
# 宏定义 —— 与 .github/workflows/build.yml 的 workflow_dispatch 输入一一对应
# ===========================================================================

ROOT="${XAGA_ROOT:-$SCRIPT_DIR}"      # 项目根目录 = 脚本所在目录

# build.yml: rootfs_distro (下拉 1/2/3)
DISTRO="${DISTRO:-ubuntu}"
# build.yml: arch_desktop (下拉 1/2/3/4, 仅 distro=arch 时生效)
DESKTOP="${DESKTOP:-kde}"
# build.yml: rootfs_size (文本框)
SIZE="${SIZE:-6}"
# build.yml: rootfs_hostname / rootfs_root_password (文本框)
HOSTNAME="${HOSTNAME:-xaga}"
ROOTPASS="${ROOTPASS:-root}"
# build.yml: rootfs_extra_packages (文本框)
EXTRA_PKGS="${EXTRA_PKGS:-}"
# build.yml: wifi_ssid / wifi_password (文本框, 留空不预置)
SSID="${SSID:-}"
WIFI_PSK="${WIFI_PSK:-}"
# build.yml: send_notification (打勾 y/n)
NOTIFY="${NOTIFY:-1}"

CACHE_DIR="$ROOT/cache"
WORK_BASE="$ROOT/build-rootfs"
OUT_BASE="$ROOT/rootfs"
LOG_DIR="$ROOT/logs"

ALARM_TARBALL="$CACHE_DIR/ArchLinuxARM-aarch64-latest.tar.gz"
ALARM_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"

DEBIAN_SUITE="trixie"            # Debian 13
DEBIAN_MIRROR="http://deb.debian.org/debian"
UBUNTU_SUITE="resolute"          # Ubuntu 26.04 LTS
UBUNTU_MIRROR="http://ports.ubuntu.com/ubuntu-ports"

FORCE=0
USE_TMUX=0
OUT_SET=0        # 1 = 命令行显式给了 --out
INTERACTIVE=0    # 1 = 走交互式问答
SESSION="xaga-rootfs"

TS="$(date +'%Y%m%d-%H%M%S')"
LOG_FILE=""
STATUS_FILE=""

# --------------------------------------------------------------------------- 工具函数

log()  { printf '\033[1;32m[rootfs]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[rootfs][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[rootfs][error]\033[0m %s\n' "$*" >&2; exit 1; }

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
    printf '\033[1;31m[rootfs][error]\033[0m 第 %s 行失败 (exit=%s)\n' "$line" "$rc" >&2
    [ -n "$STATUS_FILE" ] && echo "failure" > "$STATUS_FILE"
    notify failure "rootfs 构建失败: 第 $line 行 (exit=$rc)${LOG_FILE:+  日志: $LOG_FILE}"
    exit "$rc"
}
trap 'on_err $LINENO $?' ERR

usage() {
    cat <<EOF
用法: sudo $0 [选项]

不带任何参数直接运行 = 交互式问答 (对应 build.yml 的 workflow_dispatch 参数)。

  -i, --interactive  强制走交互式问答
  --root DIR         项目根目录 (默认: 脚本所在目录 $ROOT)
  --distro NAME      arch | debian | ubuntu (默认 $DISTRO)
  --desktop NAME     Arch 桌面: kde | none | phosh | sway (默认 $DESKTOP)
  --size N           初始镜像容量 GB, 纯数字 (默认 $SIZE; 刷入后 resize2fs 撑满)
  --hostname NAME    主机名 (默认 $HOSTNAME)
  --password PASS    root 密码 (默认 $ROOTPASS)
  --extra "p1 p2"    额外包, 空格分隔 (Arch 用包名)
  --ssid NAME        预置 WiFi 名称 (留空不预置)
  --wifi-pass PASS   预置 WiFi 密码 (留空不预置)
  --force            忽略缓存, 重新下载 / 重新构建文件树
  --out DIR          产物目录 (默认 $OUT_BASE)
  --tmux             丢进后台 tmux 会话, SSH 断了也不中断
  --session NAME     tmux 会话名 (默认 $SESSION)
  --no-notify        构建完不发通知
  -h, --help         看这个

产物落到 (目录名照本地 ./rootfs 里已有的那三个):
  $OUT_BASE/'Arch Linux'/rootfs-sparse-<ts>.img[.gz]
  $OUT_BASE/'Debian 13'/rootfs-sparse-<ts>.img[.gz]
  $OUT_BASE/'Ubuntu 26.04 LTS'/rootfs-sparse-<ts>.img[.gz]
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

# 下拉选择: 输入序号 (选项写成 "值|显示文本")
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

================ xaga RootFS 构建 (本地) ================
直接回车 = 用默认值; 打勾项输 y/n; 下拉项输序号。
项目根目录: $ROOT
========================================================
EOF
    echo "[1/8] rootfs_distro —— 发行版"
    DISTRO="$(ask_choice "选择发行版" 3 \
        'arch|Arch Linux' \
        'debian|Debian 13' \
        'ubuntu|Ubuntu 26.04 LTS')"

    if [ "$DISTRO" = "arch" ]; then
        echo "[2/8] arch_desktop —— Arch 桌面环境"
        DESKTOP="$(ask_choice "选择桌面环境" 1 \
            'kde|KDE Plasma' \
            'none|不装桌面' \
            'phosh|Phosh' \
            'sway|Sway')"
    else
        echo "[2/8] arch_desktop —— 仅 Arch 生效, 本次跳过 (发行版=$DISTRO)"
    fi

    echo "[3/8] rootfs_size —— 初始镜像容量"
    SIZE="$(ask_str "容量 (GB, 纯数字; 6 够用, 完整桌面 10~16)" "$SIZE")"

    echo "[4/8] rootfs_hostname —— 主机名"
    HOSTNAME="$(ask_str "主机名" "$HOSTNAME")"

    echo "[5/8] rootfs_root_password —— root 密码"
    ROOTPASS="$(ask_str "root 密码 (只有 root 用户, 不建普通用户)" "$ROOTPASS")"

    echo "[6/8] rootfs_extra_packages —— 额外包"
    EXTRA_PKGS="$(ask_str "额外包 (空格分隔)" "$EXTRA_PKGS")"

    echo "[7/8] wifi_ssid / wifi_password —— 预置 WiFi"
    SSID="$(ask_str "WiFi 名称 (留空不预置)" "$SSID")"
    if [ -n "$SSID" ]; then
        WIFI_PSK="$(ask_str "WiFi 密码" "$WIFI_PSK")"
    else
        WIFI_PSK=""
    fi

    echo "[8/8] send_notification —— 构建完推送通知"
    NOTIFY="$(ask_bool "构建完推送通知 (喵提醒/Server酱)?" "$NOTIFY")"

    echo
    echo "  --- 本地附加项 ---"
    USE_TMUX="$(ask_bool "丢进后台 tmux 会话 (SSH 断线也不中断)?" "$USE_TMUX")"
    FORCE="$(ask_bool "忽略缓存, 重新下载并重建文件树?" "$FORCE")"

    echo
    log "汇总: 发行版=$DISTRO 桌面=$DESKTOP 容量=${SIZE}G 主机=$HOSTNAME"
    log "      额外包=${EXTRA_PKGS:-<空>} WiFi=${SSID:-<不预置>} 通知=$NOTIFY tmux=$USE_TMUX force=$FORCE"
}

# --------------------------------------------------------------------------- 参数解析

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--interactive) INTERACTIVE=1; shift ;;
        --root)      ROOT="$2"; shift 2 ;;
        --distro)    DISTRO="$2"; shift 2 ;;
        --desktop)   DESKTOP="$2"; shift 2 ;;
        --size)      SIZE="$2"; shift 2 ;;
        --hostname)  HOSTNAME="$2"; shift 2 ;;
        --password)  ROOTPASS="$2"; shift 2 ;;
        --extra)     EXTRA_PKGS="$2"; shift 2 ;;
        --ssid)      SSID="$2"; shift 2 ;;
        --wifi-pass) WIFI_PSK="$2"; shift 2 ;;
        --force)     FORCE=1; shift ;;
        --out)       OUT_BASE="$2"; OUT_SET=1; shift 2 ;;
        --tmux)      USE_TMUX=1; shift ;;
        --session)   SESSION="$2"; shift 2 ;;
        --no-notify) NOTIFY=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "未知参数: $1 (试试 $0 --help)" ;;
    esac
done

# 布尔量归一化
NOTIFY="$(to_bool "$NOTIFY")"

# 一个参数都没给 且 是终端 -> 走交互式问答
if [ "$INTERACTIVE" = "1" ] || { [ "$ARGC" = "0" ] && [ -t 0 ]; }; then
    interactive_config
fi

# --root 可能改了根目录, 这些路径必须重新算 (没显式给 --out 就跟着 ROOT 走)
CACHE_DIR="$ROOT/cache"
WORK_BASE="$ROOT/build-rootfs"
LOG_DIR="$ROOT/logs"
[ "$OUT_SET" = "1" ] || OUT_BASE="$ROOT/rootfs"
BOT="$(find_bot)"

case "$DISTRO" in
    arch)   DISTRO_DIR_NAME="Arch Linux"        DISTRO_LABEL="Arch Linux ARM" ;;
    debian) DISTRO_DIR_NAME="Debian 13"         DISTRO_LABEL="Debian 13 (trixie)" ;;
    ubuntu) DISTRO_DIR_NAME="Ubuntu 26.04 LTS"  DISTRO_LABEL="Ubuntu 26.04 LTS (resolute)" ;;
    *)      die "--distro 只能是 arch / debian / ubuntu" ;;
esac

case "$SIZE" in
    ''|*[!0-9]*) die "--size 必须是纯数字 (GB): $SIZE" ;;
esac

WORK="$WORK_BASE/$DISTRO"
TREE="$WORK/rootfs"
OUT_DIR="$OUT_BASE/$DISTRO_DIR_NAME"

mkdir -p "$CACHE_DIR" "$WORK" "$OUT_DIR" "$LOG_DIR"

# --------------------------------------------------------------------------- tmux: 断开 SSH 也不中断

if [ "$USE_TMUX" = "1" ] && [ -z "${TMUX:-}" ] && [ -z "${XAGA_IN_TMUX:-}" ]; then
    if ! command -v tmux >/dev/null 2>&1; then
        warn "没装 tmux, 直接前台构建 (建议 apt-get install tmux)"
    else
        LOG_FILE="$LOG_DIR/build-rootfs-$TS.log"
        STATUS_FILE="$LOG_DIR/build-rootfs-$TS.status"
        : > "$LOG_FILE"
        quoted="$(printf '%q ' --root "$ROOT" --distro "$DISTRO" --desktop "$DESKTOP" \
                  --size "$SIZE" --hostname "$HOSTNAME" --password "$ROOTPASS" \
                  --out "$OUT_BASE" --session "$SESSION")"
        [ -n "$EXTRA_PKGS" ] && quoted="$quoted --extra $(printf '%q' "$EXTRA_PKGS")"
        [ -n "$SSID" ]       && quoted="$quoted --ssid $(printf '%q' "$SSID")"
        [ -n "$WIFI_PSK" ]   && quoted="$quoted --wifi-pass $(printf '%q' "$WIFI_PSK")"
        [ "$FORCE" = "1" ]   && quoted="$quoted --force"
        [ "$NOTIFY" = "1" ]  || quoted="$quoted --no-notify"

        tmux new-session -d -s "$SESSION" \
            "XAGA_IN_TMUX=1 XAGA_LOG_FILE=$(printf '%q' "$LOG_FILE") XAGA_STATUS_FILE=$(printf '%q' "$STATUS_FILE") bash $(printf '%q' "$0") $quoted 2>&1 | tee -a $(printf '%q' "$LOG_FILE")"
        echo
        log "已在后台 tmux 会话 '$SESSION' 开始构建 $DISTRO_LABEL rootfs"
        log "  查看进度: tmux attach -t $SESSION   (Ctrl-b d 安全脱离)"
        log "  日志文件: $LOG_FILE"
        log "  盯完推送: python3 $( [ -n "$BOT" ] && echo "$BOT" || echo "$ROOT/.github/bot-offline.py" ) --watch-tmux $SESSION --log $LOG_FILE"
        exit 0
    fi
fi

LOG_FILE="${XAGA_LOG_FILE:-$LOG_DIR/build-rootfs-$TS.log}"
STATUS_FILE="${XAGA_STATUS_FILE:-$LOG_DIR/build-rootfs-$TS.status}"
mkdir -p "$(dirname "$LOG_FILE")"

# --------------------------------------------------------------------------- 环境检查

check_env() {
    [ "$(id -u)" = "0" ] || die "要 root 权限 (loop 挂载 + chroot): sudo $0 ..."

    local missing=()
    for t in qemu-aarch64-static rsync pigz mkfs.ext4 truncate; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    case "$DISTRO" in
        arch)   command -v bsdtar >/dev/null 2>&1 || missing+=("bsdtar(libarchive-tools)") ;;
        debian|ubuntu) command -v debootstrap >/dev/null 2>&1 || missing+=("debootstrap") ;;
    esac
    command -v img2simg >/dev/null 2>&1 || warn "没装 img2simg (android-sdk-libsparse-utils), 会退化为直接压原始 ext4 镜像"

    if [ "${#missing[@]}" -gt 0 ]; then
        die "缺这些工具: ${missing[*]}
装上再跑:
  sudo apt-get update
  sudo apt-get install -y qemu-user-static debootstrap libarchive-tools \\
       android-sdk-libsparse-utils pigz rsync e2fsprogs"
    fi
    log "环境检查通过 ($DISTRO_LABEL)"
}

# --------------------------------------------------------------------------- 文件树: 有缓存就不重复下载

fetch_alarm() {
    if [ -s "$ALARM_TARBALL" ] && [ "$FORCE" = "0" ]; then
        log "Arch tarball 已缓存, 跳过下载: $ALARM_TARBALL ($(du -h "$ALARM_TARBALL" | cut -f1))"
        return 0
    fi
    log "下载 Arch Linux ARM tarball -> $CACHE_DIR"
    wget -q --show-progress -O "$ALARM_TARBALL.part" "$ALARM_URL"
    mv -f "$ALARM_TARBALL.part" "$ALARM_TARBALL"
}

debootstrap_foreign() {
    local suite mirror comps cachedir
    if [ "$DISTRO" = "ubuntu" ]; then
        suite="$UBUNTU_SUITE"; mirror="$UBUNTU_MIRROR"; comps="main,universe"
    else
        suite="$DEBIAN_SUITE"; mirror="$DEBIAN_MIRROR"; comps="main,universe,non-free-firmware"
    fi
    cachedir="$CACHE_DIR/deb-$suite"
    mkdir -p "$cachedir"
    log "debootstrap --foreign $suite (包缓存: $cachedir, 二次构建不重复下载)"
    if ! debootstrap --arch=arm64 --foreign --components="$comps" \
            --cache-dir="$cachedir" "$suite" "$TREE" "$mirror"; then
        warn "带 --cache-dir 失败了, 退化为不带缓存重试"
        rm -rf "$TREE"; mkdir -p "$TREE"
        debootstrap --arch=arm64 --foreign --components="$comps" "$suite" "$TREE" "$mirror"
    fi
}

build_tree() {
    if [ -f "$TREE/.xaga-ready" ] && [ "$FORCE" = "0" ]; then
        log "已存在构建好的文件树, 不重复下载/构建: $TREE (要重建加 --force)"
    else
        rm -rf "$TREE"; mkdir -p "$TREE"
        case "$DISTRO" in
            arch)
                fetch_alarm
                log "解压 Arch tarball -> $TREE"
                bsdtar -xpf "$ALARM_TARBALL" -C "$TREE"
                ;;
            debian|ubuntu)
                debootstrap_foreign
                log "debootstrap 第二阶段 (qemu-aarch64)"
                chroot "$TREE" /debootstrap/debootstrap --second-stage
                ;;
        esac
        date +'%F %T' > "$TREE/.xaga-ready"
    fi
    # qemu + DNS: chroot 里跑 aarch64 二进制和联网都要用
    cp -f /usr/bin/qemu-aarch64-static "$TREE/usr/bin/" 2>/dev/null || true
    cp -f /etc/resolv.conf "$TREE/etc/resolv.conf"
    log "文件树大小: $(du -sh "$TREE" | cut -f1)"
}

# --------------------------------------------------------------------------- chroot 配置: 只有 root 用户

config_chroot() {
    log "配置 rootfs (主机名/密码/WiFi/固件/额外包)"
    cat > "$TREE/tmp/xaga-setup.sh" <<'SETUP'
#!/bin/bash
# xaga rootfs 配置: 只有 root 用户, 不创建普通用户
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
HOSTNAME="$1"; ROOT_PASS="$2"; WIFI_SSID="$3"; WIFI_PASS="$4"; EXTRA="$5"; DESKTOP="$6"

printf '%s\n' "$HOSTNAME" > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME" > /etc/hosts

echo "root:${ROOT_PASS}" | chpasswd

if [ -f /etc/pacman.conf ]; then
  FAMILY=arch
else
  FAMILY=debian
fi

if [ "$FAMILY" = "arch" ]; then
  pacman-key --init || true
  pacman-key --populate archlinuxarm || true
  pacman -Syu --noconfirm systemd sudo networkmanager openssh \
    nano vim less htop iproute2 iw wireless_tools wpa_supplicant dialog || true
  case "$DESKTOP" in
    kde)   pacman -S --noconfirm plasma-meta sddm konsole dolphin || true ;;
    phosh) pacman -S --noconfirm phosh || true ;;
    sway)  pacman -S --noconfirm sway || true ;;
    none|*) : ;;
  esac
  # MediaTek 固件: 没有的话 WiFi/蓝牙/声卡/触控全废
  pacman -S --noconfirm linux-firmware || true
  [ -n "$EXTRA" ] && pacman -S --noconfirm $EXTRA || true
else
  apt-get update || true
  apt-get install -y --no-install-recommends systemd systemd-sysv sudo \
    openssh-server network-manager wpa-supplicant iproute2 iw wireless-tools \
    less nano vim htop dialog ca-certificates || true
  apt-get install -y --no-install-recommends firmware-mediatek \
    || echo "warn: firmware-mediatek 装不上, 开机后自己补" >&2
  [ -n "$EXTRA" ] && apt-get install -y --no-install-recommends $EXTRA || true
  apt-get clean || true
fi

# 预置 WiFi (留空不预置)
if [ -n "$WIFI_SSID" ]; then
  mkdir -p /etc/wpa_supplicant
  printf 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry=CN\n\nnetwork={\n\tssid="%s"\n\tpsk="%s"\n}\n' \
    "$WIFI_SSID" "$WIFI_PASS" > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
  mkdir -p /etc/NetworkManager/system-connections
  printf '[connection]\nid=xaga-wifi\ntype=wifi\nautoconnect=true\n\n[wifi]\nssid=%s\nmode=infrastructure\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' \
    "$WIFI_SSID" "$WIFI_PASS" > /etc/NetworkManager/system-connections/xaga-wifi.nmconnection
  chmod 600 /etc/NetworkManager/system-connections/xaga-wifi.nmconnection
  systemctl enable NetworkManager.service || true
  systemctl enable wpa_supplicant@wlan0.service || true
fi

systemctl enable sshd.service 2>/dev/null || systemctl enable ssh.service || true
echo "xaga-setup done: $(head -1 /etc/os-release 2>/dev/null || echo unknown)"
SETUP
    chmod +x "$TREE/tmp/xaga-setup.sh"

    mount -t proc /proc "$TREE/proc"
    mount --rbind /sys "$TREE/sys"
    mount --rbind /dev "$TREE/dev"
    chroot "$TREE" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/bash /tmp/xaga-setup.sh \
        "$HOSTNAME" "$ROOTPASS" "$SSID" "$WIFI_PSK" "$EXTRA_PKGS" "$DESKTOP"
    rm -f "$TREE/tmp/xaga-setup.sh"
    umount -R "$TREE/dev" || true
    umount -R "$TREE/sys" || true
    umount -R "$TREE/proc" || true
}

# --------------------------------------------------------------------------- 镜像 / 压缩 / 落盘

IMG=""
make_image() {
    IMG="$WORK/rootfs-$TS.img"
    log "生成 ext4 镜像 ${SIZE}G -> $IMG"
    rm -f "$IMG"
    truncate -s "${SIZE}G" "$IMG"
    mkfs.ext4 -F -L xaga-rootfs "$IMG" >/dev/null
    mkdir -p "$WORK/mnt"
    mount -o loop "$IMG" "$WORK/mnt"
    rsync -aHAX --numeric-ids "$TREE"/ "$WORK/mnt"/
    # 刷入后首次开机: resize2fs /dev/sdc86 撑满 userdata
    umount "$WORK/mnt"
    log "镜像填充完成: $(du -h "$IMG" | cut -f1)"
}

compress_and_move() {
    local sparse="$WORK/rootfs-sparse-$TS.img"
    if command -v img2simg >/dev/null 2>&1; then
        log "转 Android sparse 镜像"
        img2simg "$IMG" "$sparse"
        rm -f "$IMG"
    else
        warn "没有 img2simg, 直接压原始 ext4 镜像 (fastboot 可能不接受)"
        mv -f "$IMG" "$sparse"
    fi

    local gz="$sparse.gz"
    log "pigz 压缩"
    pigz -9 -k -p "$(nproc)" "$sparse"

    if [ "$(stat -c%s "$gz")" -gt 2000000000 ]; then
        log "gz 超过 2GB, 自动分卷"
        split -b 1900M -d -a 2 "$gz" "$gz.part-"
        rm -f "$gz"
        log "合并方法: cat $(basename "$gz").part-* > $(basename "$gz")"
    fi

    local f
    for f in "$sparse" "$gz" "$gz".part-*; do
        [ -e "$f" ] && mv -f "$f" "$OUT_DIR/"
    done
    sync
    log "产物目录: $OUT_DIR"
    ls -lh "$OUT_DIR" | tail -n 10
}

# --------------------------------------------------------------------------- 主流程

main() {
    log "项目根目录: $ROOT"
    log "发行版: $DISTRO_LABEL / 桌面: $DESKTOP / 容量: ${SIZE}G / 主机: $HOSTNAME"
    [ -n "$BOT" ] && log "通知脚本: $BOT" || warn "没找到 bot-offline.py, 构建完不会推送通知"

    check_env
    build_tree
    config_chroot
    make_image
    compress_and_move

    echo "success" > "$STATUS_FILE"
    notify success "xaga rootfs 构建完成 ($DISTRO_LABEL)
产物: $OUT_DIR/rootfs-sparse-$TS.img(.gz)
刷写: fastboot flash rootfs ...
首次开机: resize2fs /dev/sdc86"

    log "完成。刷写: fastboot flash rootfs $OUT_DIR/rootfs-sparse-$TS.img"
}

main "$@"
