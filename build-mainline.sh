#!/usr/bin/env bash
# =============================================================================
#  build-mainline.sh —— xaga (Redmi Note 11T Pro / MT6895 / 天玑8100)
#                      主线内核一键编译 + boot.img 打包
#
#  本脚本按 postmarketOS wiki（Xiaomi Redmi Note 11T Pro (xiaomi-xaga)）的
#  「Building」章节实现，并把 wiki 之外必须知道的东西全部写死在流程里：
#
#    https://wiki.postmarketos.org/wiki/Xiaomi_Redmi_Note_11T_Pro_(%2B)_/_POCO_X4_GT_/_Redmi_K50i_(xiaomi-xaga)
#
#  ---------------------------------------------------------------------------
#  产物（默认放在 $TOP/out/，**文件名一律带「编译完成时间」时间戳**）
#    boot-<戳>.img             —— 直接 fastboot flash boot_a / boot_b 的镜像
#    boot-<戳>.img.gz          —— 上面那个的 gzip 备份（收发/存档用；刷机用 .img）
#    Image-<戳>.gz             —— 压缩后的内核（boot.img 里用的就是它）
#    initramfs-<戳>.cpio.lz4   —— lz4 legacy 格式 ramdisk
#    modules-<戳>.tar.gz       —— 内核模块（BUILD_MODULES=1 时；rootfs 的 /lib/modules）
#    SHA256SUMS-<戳>.txt       —— 校验和
#    build.log                 —— 完整编译日志
#
#    时间戳格式 YYYYmmdd-HHMMSS，在**内核编完、开始打包那一刻**取，
#    所以同一台机器反复构建不会互相覆盖。想固定名字就传 STAMP，例如
#      STAMP=20260920-1046 ./build-mainline.sh
#
#  ---------------------------------------------------------------------------
#  用法
#    chmod +x build-mainline.sh
#    ./build-mainline.sh                      # 全默认：编内核 + 打 boot.img + 编模块
#    USB_GADGET=1 ./build-mainline.sh         # 默认就是 1：内建 USB 串口/RNDIS gadget
#    USB_GADGET=0 ./build-mainline.sh         # 完全等价上游配置（不要 USB 调试）
#    BUILD_MODULES=0 ./build-mainline.sh      # 不编模块（快 ~5-10 分钟）
#    KERNEL_COMMIT=<sha> ./build-mainline.sh  # 固定到某个 commit（默认取分支 HEAD）
#    MEM_LIMIT=6G ./build-mainline.sh         # 给 boot.img 追加 mem=6G（见下面 §cmdline）
#    STAMP=20260920-1046 ./build-mainline.sh  # 指定产物时间戳（默认取编译完成时刻）
#
#  ---------------------------------------------------------------------------
#  构建前置（Debian/Ubuntu/Armbian 系）
#    clang >= 17.0.1 + lld + llvm-objcopy（DTB 是以 objcopy 链进 vmlinux 的，
#    递归 make 里硬编码了 LLVM=1，所以 Clang 是硬性要求）
#    aarch64-linux-gnu-gcc（编 initramfs 的 init.c）
#    缺什么脚本会自己 apt-get（SKIP_APT=1 可跳过）
#
#  ---------------------------------------------------------------------------
#  ★ 硬约束（都是从实测镜像/日志里抠出来的，别改）
#
#  1) BOOT_PARTITION 默认 /dev/sdc86 —— 这是 initramfs 的 init.c 里找 rootfs 用的
#     设备节点，不是 fastboot 分区名。xaga 的 UFS 在主线内核里枚举成 scsi 盘：
#        sd 0:0:0:0 -> sda(4MB)  sd 0:0:0:1 -> sdb(4MB)  sd 0:0:0:2 -> sdc(128GB)
#     userdata 是 sdc 的第 86 号分区，所以是 /dev/sdc86。
#     实测日志可证：`EXT4-fs (sdc86): mounted filesystem ...` 然后
#     `CINIT: switch_root -> /sbin/init`。
#     （网上/旧笔记里写的 /dev/mmcblk0p86 在这台机器这块内核上是错的，会找不到 root。）
#  2) NVDATA_PARTITION 默认 /dev/sdc13 —— WiFi/BT 的 NVRAM 只读 ext4 分区，
#     init.c 默认值就是这个，脚本用 EXTRA_CFLAGS 显式注入一次以防上游改默认值。
#  3) rootfs 文件系统必须是 ext4（init.c 写死按 ext4 挂）。
#  4) DTB 已被 objcopy 链进 vmlinux，mkbootimg **不要**再传 --dtb
#     （`XAGA-DTB: overriding LK FDT with embedded mt6895-xiaomi-xaga.dtb`）。
#  5) MTK v4 boot header 只认 base/kernel_offset/ramdisk_offset/tags_offset 齐全的镜像；
#     而且设备**不支持 `fastboot boot`**，只能 flash 到 boot_a / boot_b。
#  6) 本工程历史上只 `make Image`、从不 `make modules`，defconfig 里任何 `=m`
#     都等于没编（那份镜像里有 1420 个 =m）。所以：
#       - 要用的功能一律写 `=y`（本脚本的 USB gadget 片段就是这么干的）
#       - 或者开 BUILD_MODULES=1 真的把模块编出来并塞进 rootfs
#  7) 首次构建建议 USE_RUST=0：7.2 的 Rust 部分需要 rustc>=1.85 + bindgen>=0.71.1。
#
#  ---------------------------------------------------------------------------
#  §cmdline 说明（重要，实测结论）
#    xaga 的补丁会用内嵌 DTB 覆盖 LK 传进来的 FDT，生效的 `Kernel command line:`
#    来自 DTB 的 /chosen/bootargs，**boot.img 里的 --cmdline 不会进内核**。
#    实测启动日志：
#      XAGA-CMDLINE: 8250.nr_uarts=4 console=tty0 printk.devkmsg=on log_buf_len=2M ...
#      Kernel command line: 8250.nr_uarts=4 console=tty0 ... panic=15
#      Memory: 5417384K/6291456K available     <- 6291456K = 6GiB，已经是 6G
#    所以默认 CMDLINE=""（与当前能正常启动的镜像完全一致）。
#    要是你确认需要（例如换成 8G 机器或 DTB 又改回 8GiB），用 MEM_LIMIT=6G
#    追加一个 mem=6G 即可，加错也不会更糟。
# =============================================================================
set -Eeuo pipefail

# ───────────────────────────── 配置区（环境变量可覆盖） ─────────────────────────────
TOP="${TOP:-$HOME/xaga}"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/MT6895-Mainline/linux}"
KERNEL_BRANCH="${KERNEL_BRANCH:-7.2-mt6895-xiaomi-xaga}"
KERNEL_COMMIT="${KERNEL_COMMIT:-}"          # 留空 = 用分支 HEAD

INITRAMFS_REPO="${INITRAMFS_REPO:-https://github.com/MT6895-Mainline/initramfs}"
INITRAMFS_BRANCH="${INITRAMFS_BRANCH:-xaga-mt6895}"
INITRAMFS_COMMIT="${INITRAMFS_COMMIT:-}"    # 留空 = 用分支 HEAD

BOOT_PARTITION="${BOOT_PARTITION:-/dev/sdc86}"     # xaga userdata（见硬约束 §1）
NVDATA_PARTITION="${NVDATA_PARTITION:-/dev/sdc13}" # xaga nvdata（见硬约束 §2）

# ---- boot.img 头部参数（与 postmarketOS wiki / 已验证可启动镜像一致）----
HEADER_VERSION="${HEADER_VERSION:-4}"
PAGE_SIZE="${PAGE_SIZE:-4096}"
BASE="${BASE:-0x3fff8000}"
KERNEL_OFFSET="${KERNEL_OFFSET:-0x8000}"
RAMDISK_OFFSET="${RAMDISK_OFFSET:-0x26f08000}"
TAGS_OFFSET="${TAGS_OFFSET:-0x07c88000}"
DTB_OFFSET="${DTB_OFFSET:-0x07c88000}"
OS_VERSION="${OS_VERSION:-16.0.0}"
OS_PATCH_LEVEL="${OS_PATCH_LEVEL:-2026-08}"
MEM_LIMIT="${MEM_LIMIT:-}"                  # 见 §cmdline；默认空
CMDLINE="${CMDLINE:-}"                      # 直接指定完整 cmdline（覆盖 MEM_LIMIT）
STAMP="${STAMP:-}"                          # 产物时间戳（留空 = 内核编完打包时取当前时间）

# ---- 功能开关 ----
USB_GADGET="${USB_GADGET:-1}"       # 1 = 合并 USB gadget 片段（=y，串口/RNDIS 调试）
BUILD_MODULES="${BUILD_MODULES:-1}" # 1 = 额外编内核模块并打包 modules.tar.gz
USE_RUST="${USE_RUST:-0}"           # 0 = 关 Rust（需要 rustc>=1.85）
SKIP_APT="${SKIP_APT:-0}"           # 1 = 不自动装依赖
JOBS="${JOBS:-$(nproc)}"

# 本仓库根目录（放 usb-debug/kernel-fragments 的那个）
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

LINUX_DIR="$TOP/linux"
INITRAMFS_DIR="$TOP/initramfs"
TOOLS_DIR="$TOP/tools"
OUT="$TOP/out"

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
step() { echo -e "\n${C}==>${N} ${G}$*${N}"; }
warn() { echo -e "${Y}[warn]${N} $*"; }
info() { echo -e "    $*"; }
die()  { echo -e "${R}[fatal]${N} $*" >&2; exit 1; }

# ───────────────────────────── 1. 依赖 ─────────────────────────────
if [[ "$SKIP_APT" != "1" ]]; then
  step "安装构建依赖"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends \
      git bc bison flex libssl-dev libelf-dev libncurses-dev \
      cpio lz4 zstd gzip xz-utils kmod rsync python3 python3-pip \
      device-tree-compiler build-essential make \
      gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
  else
    warn "非 apt 系统，跳过自动装依赖（请自行确保 git/make/clang/lld/lz4/cpio 存在）"
  fi
fi

# ───────────────────────────── 2. 定位 Clang (>=17.0.1) ─────────────────────────────
step "检查 Clang / LLVM 工具链（最低 17.0.1）"
clang_ver() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
ver_ge() { [[ "$(printf '%s\n%s' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

CLANG_BIN=""
for c in clang clang-21 clang-20 clang-19 clang-18 clang-17 \
         /usr/lib/llvm-21/bin/clang /usr/lib/llvm-20/bin/clang \
         /usr/lib/llvm-19/bin/clang /usr/lib/llvm-18/bin/clang \
         /usr/lib/llvm-17/bin/clang; do
  if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then
    v="$(clang_ver "$c")"
    if [[ -n "$v" ]] && ver_ge "$v" "17.0.1"; then
      CLANG_BIN="$(command -v "$c" 2>/dev/null || echo "$c")"; break
    fi
  fi
done

if [[ -z "$CLANG_BIN" ]]; then
  if command -v apt-get >/dev/null 2>&1 && [[ "$SKIP_APT" != "1" ]]; then
    warn "未找到 >= 17.0.1 的 clang，用 apt.llvm.org 装 LLVM 18"
    sudo apt-get install -y -qq lsb-release wget software-properties-common gnupg
    wget -q https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh && chmod +x /tmp/llvm.sh
    sudo /tmp/llvm.sh 18 all
    CLANG_BIN="/usr/lib/llvm-18/bin/clang"
  fi
fi
[[ -n "$CLANG_BIN" ]] || die "找不到 clang>=17.0.1，请手动安装 LLVM"

LLVM_BIN_DIR="$(dirname "$CLANG_BIN")"
export PATH="$LLVM_BIN_DIR:$PATH"
info "clang : $CLANG_BIN ($(clang_ver "$CLANG_BIN"))"

# LLVM=1 模式下 make 会去找不带版本后缀的工具名，缺一个就 build 不出来
for tld in ld.lld llvm-objcopy llvm-ar llvm-nm llvm-strip llvm-readelf llvm-objdump; do
  if ! command -v "$tld" >/dev/null 2>&1; then
    # 尝试用带版本后缀的建软链
    for v in 21 20 19 18 17; do
      if [[ -x "$LLVM_BIN_DIR/$tld-$v" ]]; then
        ln -sf "$LLVM_BIN_DIR/$tld-$v" "$LLVM_BIN_DIR/$tld"
        break
      fi
    done
  fi
  command -v "$tld" >/dev/null 2>&1 || die "缺少 $tld（LLVM 工具链不完整，装 llvm / lld 包）"
done
info "LLVM 工具链齐全（ld.lld / llvm-objcopy 等）"

export ARCH=arm64
export LLVM=1
# 注意：不要加 O= 出树构建 —— DTB 的递归 make 只在 srctree 里跑

AARCH64_GCC="$(command -v aarch64-linux-gnu-gcc || true)"
[[ -n "$AARCH64_GCC" ]] || die "缺少 aarch64-linux-gnu-gcc（编 initramfs 的 init.c 必需）"

# ───────────────────────────── 3. 准备 mkbootimg ─────────────────────────────
step "准备 mkbootimg 打包工具"
MKBOOTIMG=""
if command -v mkbootimg >/dev/null 2>&1; then
  MKBOOTIMG="$(command -v mkbootimg)"
  info "使用系统已安装的 mkbootimg: $MKBOOTIMG"
else
  mkdir -p "$TOP"
  if [[ ! -d "$TOOLS_DIR/.git" ]]; then
    info "克隆 osm0sis/mkbootimg（C 实现，支持 --os_version / --header_version）"
    git clone --depth=1 https://github.com/osm0sis/mkbootimg.git "$TOOLS_DIR" || rm -rf "$TOOLS_DIR"
  fi
  if [[ -d "$TOOLS_DIR" ]]; then
    # 新版 GCC 会把若干旧警告升级成错误，去掉 -Werror
    sed -i 's/-Werror//g' "$TOOLS_DIR/Makefile" 2>/dev/null || true
    sed -i 's/-Werror//g' "$TOOLS_DIR/libmincrypt/Makefile" 2>/dev/null || true
    if make -C "$TOOLS_DIR" -j"$JOBS" >/dev/null 2>&1 && [[ -x "$TOOLS_DIR/mkbootimg" ]]; then
      MKBOOTIMG="$TOOLS_DIR/mkbootimg"
      info "自编译 mkbootimg 成功: $MKBOOTIMG"
    fi
  fi
  if [[ -z "$MKBOOTIMG" ]]; then
    warn "C 版 mkbootimg 不可用，退回 AOSP 官方 python 版"
    [[ -d "$TOOLS_DIR/.git" ]] || git clone --depth=1 \
      https://android.googlesource.com/platform/system/tools/mkbootimg "$TOOLS_DIR"
    [[ -f "$TOOLS_DIR/mkbootimg.py" ]] || die "mkbootimg.py 也不可用"
    MKBOOTIMG="python3 $TOOLS_DIR/mkbootimg.py"
    info "使用 $MKBOOTIMG"
  fi
fi

# ───────────────────────────── 4. 拉代码 ─────────────────────────────
step "拉取源码"
mkdir -p "$TOP"

clone_or_update() {  # $1=url $2=branch $3=dir
  local url="$1" br="$2" dir="$3" i
  if [[ -d "$dir/.git" ]]; then
    info "$(basename "$dir") 已存在，fetch 更新"
    git -C "$dir" fetch --depth=1 origin "$br" -q || warn "fetch 失败，用本地已有的"
  else
    for i in 1 2 3; do
      git clone --depth=1 -b "$br" "$url" "$dir" && break
      warn "第 $i 次克隆失败，重试…"; rm -rf "$dir"; sleep 10
    done
  fi
  [[ -d "$dir/.git" ]] || die "拉取失败: $url ($br)"
}

clone_or_update "$KERNEL_REPO"    "$KERNEL_BRANCH"    "$LINUX_DIR"
clone_or_update "$INITRAMFS_REPO" "$INITRAMFS_BRANCH" "$INITRAMFS_DIR"

if [[ -n "$KERNEL_COMMIT" ]]; then
  info "内核固定到 commit: $KERNEL_COMMIT"
  git -C "$LINUX_DIR" fetch --depth=1 origin "$KERNEL_COMMIT" -q || true
  git -C "$LINUX_DIR" checkout -q "$KERNEL_COMMIT" || die "内核 checkout $KERNEL_COMMIT 失败"
fi
if [[ -n "$INITRAMFS_COMMIT" ]]; then
  info "initramfs 固定到 commit: $INITRAMFS_COMMIT"
  git -C "$INITRAMFS_DIR" fetch --depth=1 origin "$INITRAMFS_COMMIT" -q || true
  git -C "$INITRAMFS_DIR" checkout -q "$INITRAMFS_COMMIT" || die "initramfs checkout 失败"
fi

KVER_STR="$(git -C "$LINUX_DIR" rev-parse --short HEAD)"
info "内核      : $KERNEL_BRANCH @ $KVER_STR  ($(git -C "$LINUX_DIR" log -1 --format='%s'))"
info "initramfs : $INITRAMFS_BRANCH @ $(git -C "$INITRAMFS_DIR" rev-parse --short HEAD)"

# ───────────────────────────── 5. 构建 initramfs ─────────────────────────────
# init.c 做三件事：挂 nvdata 取 WiFi/BT NVRAM 与固件 → 镜像进 rootfs 与 initramfs
#                   → pivot_root 到 BOOT_PARTITION 并 exec /sbin/init
step "构建 initramfs (BOOT_PARTITION=$BOOT_PARTITION, NVDATA=$NVDATA_PARTITION)"
make -C "$INITRAMFS_DIR" clean >/dev/null 2>&1 || true

# 上游 Makefile 只注入 BOOT_PARTITION；NVDATA_PARTITION 是 init.c 里的 #ifndef 默认宏。
# 这里给 Makefile 的 CFLAGS 前面挂一个 EXTRA_CFLAGS 钩子（不改上游逻辑），
# 把 nvdata 路径显式传进去，避免上游以后改默认值把 xaga 弄坏。
if grep -q '^CFLAGS := ' "$INITRAMFS_DIR/Makefile" \
   && ! grep -q 'EXTRA_CFLAGS' "$INITRAMFS_DIR/Makefile"; then
  sed -i 's|^CFLAGS := |CFLAGS := $(EXTRA_CFLAGS) |' "$INITRAMFS_DIR/Makefile"
fi

# ⚠️ 不要写 `make initramfs.cpio` —— 该 Makefile 的目标是**绝对路径**
#    TMP_CPIO := $(CURDIR)/initramfs.cpio，make 匹配不到相对名字。
#    直接跑默认目标 all（= initramfs.cpio.lz4），它先生成 cpio 再 lz4。
make -C "$INITRAMFS_DIR" \
     CROSS=aarch64-linux-gnu- \
     BOOT_PARTITION="$BOOT_PARTITION" \
     EXTRA_CFLAGS="-DNVDATA_PARTITION=\\\"$NVDATA_PARTITION\\\""

INITRAMFS_LZ4="$INITRAMFS_DIR/initramfs.cpio.lz4"
[[ -f "$INITRAMFS_LZ4" ]] || die "initramfs.cpio.lz4 未生成"

# lz4 -l 产出 legacy 格式，正好匹配原厂 boot.img 的 RAMDISK_FMT=lz4_legacy
info "initramfs.cpio     : $(du -h "$INITRAMFS_DIR/initramfs.cpio" | cut -f1)"
info "initramfs.cpio.lz4 : $(du -h "$INITRAMFS_LZ4" | cut -f1)"
info "init.c 里写死的分区路径（应含 $BOOT_PARTITION 与 $NVDATA_PARTITION）："
strings "$INITRAMFS_DIR/root/init" 2>/dev/null | grep -E '^/dev/' | sort -u | sed 's/^/      /' || true

# ───────────────────────────── 6. 生成 .config ─────────────────────────────
step "生成 .config（defconfig + xaga.config[ + USB gadget 片段]）"
cd "$LINUX_DIR"
[[ -f arch/arm64/configs/defconfig   ]] || die "缺少 arch/arm64/configs/defconfig"
[[ -f arch/arm64/configs/xaga.config ]] || die "缺少 arch/arm64/configs/xaga.config（分支选错了？）"

MERGE_LIST=(arch/arm64/configs/defconfig arch/arm64/configs/xaga.config)

GADGET_FRAG="$REPO_ROOT/usb-debug/kernel-fragments/xaga-usb-gadget.config"
if [[ "$USB_GADGET" == "1" ]]; then
  [[ -f "$GADGET_FRAG" ]] || die "USB_GADGET=1 但找不到 $GADGET_FRAG"
  # merge_config.sh 后写的覆盖先写的，所以 fragment 放最后，不必去 fork 内核仓库改 xaga.config
  MERGE_LIST+=("$GADGET_FRAG")
  info "追加 gadget 片段: $GADGET_FRAG"
fi

ARCH=arm64 scripts/kconfig/merge_config.sh -m "${MERGE_LIST[@]}"

if [[ "$USE_RUST" != "1" ]]; then
  warn "关闭 Rust（CONFIG_RUST=n；panic 画面改用 kmsg）"
  scripts/config --disable CONFIG_RUST
  scripts/config --disable CONFIG_DRM_PANIC_SCREEN_QR_CODE
  scripts/config --set-str CONFIG_DRM_PANIC_SCREEN "kmsg"
fi

# 避免新版 clang 把驱动警告升级成错误（上游树警告不少）
scripts/config --disable CONFIG_WERROR

# 关掉与 xaga(MT6895) 无关的联发科 ASoC 驱动：
# mt8183-afe-pcm.c 自带的 MTK_AFE_RATE_8K 与 common/mtk-base-afe.h 里的同名枚举
# 取值不同，clang 直接判定 redefinition 编挂。这些 SoC 都是 Chromebook/电视盒，
# xaga 用不到，关掉即可（顺带省编译时间）。
warn "关闭无关联发科 ASoC 驱动（只保留 MT6895）"
scripts/config \
  --disable CONFIG_SND_SOC_MT8183 \
  --disable CONFIG_SND_SOC_MT8183_MT6358_TS3A227E_MAX98357A \
  --disable CONFIG_SND_SOC_MT8183_DA7219_MAX98357A \
  --disable CONFIG_SND_SOC_MT8188 \
  --disable CONFIG_SND_SOC_MT8188_MT6359 \
  --disable CONFIG_SND_SOC_MT8192 \
  --disable CONFIG_SND_SOC_MT8192_MT6359_RT1015_RT5682 \
  --disable CONFIG_SND_SOC_MT8195 \
  --disable CONFIG_SND_SOC_MT8195_MT6359 \
  --disable CONFIG_SND_SOC_MT8365 \
  --disable CONFIG_SND_SOC_MT8365_MT6357 \
  --disable CONFIG_SND_SOC_SOF_MT8186 \
  --disable CONFIG_SND_SOC_SOF_MT8195

make ARCH=arm64 LLVM=1 olddefconfig >/dev/null

# 关于日志里那句 `systemd-modules-load: Failed to find module 'crypto_user'`：
# CONFIG_CRYPTO_USER 本来就已经 =y（已内建），这句报错的真正原因是 rootfs 里有
# modules-load.d 的 drop-in 在开机时 modprobe crypto_user —— 内建的东西没有 .ko 文件，
# modprobe 自然找不到。修法在 rootfs 侧（删掉那条 drop-in），见 build-rootfs.sh。

step "校验关键配置"
grep -q '^CONFIG_OF=y'           .config || die "CONFIG_OF 必须为 y —— DTB 嵌入依赖它"
grep -q '^CONFIG_BLK_DEV_INITRD=y' .config || die "CONFIG_BLK_DEV_INITRD 必须为 y"
for k in CONFIG_OF CONFIG_BLK_DEV_INITRD CONFIG_RD_LZ4 CONFIG_CONFIGFS_FS CONFIG_MODULES CONFIG_IKCONFIG CONFIG_CRYPTO_USER; do
  printf '      %-28s %s\n' "$k" "$(grep -m1 "^${k}=" .config || echo '(unset)')"
done

if [[ "$USB_GADGET" == "1" ]]; then
  # 硬断言：宁可构建失败，也不要再产出一个「插上 PC 没反应」的 boot.img
  for k in CONFIG_USB_GADGET CONFIG_USB_LIBCOMPOSITE CONFIG_USB_CONFIGFS \
           CONFIG_USB_U_SERIAL CONFIG_USB_F_ACM CONFIG_USB_CONFIGFS_ACM \
           CONFIG_CONFIGFS_FS; do
    if ! grep -qx "^${k}=y" .config; then
      die "USB gadget 断言失败：${k} 不是 y（当前: $(grep -m1 "^${k}=" .config || echo unset)）"
    fi
  done
  grep -qx '^# CONFIG_USB_G_SERIAL is not set' .config \
    || warn "legacy CONFIG_USB_G_SERIAL 未被显式关闭（它会在 probe 时抢占 UDC，configfs 就绑不上）"
  info "USB gadget 配置断言通过（全部 =y，走 configfs）"
fi

# ───────────────────────────── 7. 编译内核 ─────────────────────────────
step "编译内核 Image（-j$JOBS，全 LLVM）"
LOG="$TOP/build.log"
make -j"$JOBS" ARCH=arm64 LLVM=1 Image 2>&1 | tee "$LOG"

IMAGE="$LINUX_DIR/arch/arm64/boot/Image"
DTB="$LINUX_DIR/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-xaga.dtb"
[[ -f "$IMAGE" ]] || die "Image 未生成，检查 $LOG"

# dtb 规则可能因为已被链入 vmlinux 而跳过，这里补一次构建（失败不致命）
if [[ ! -f "$DTB" ]]; then
  make -j"$JOBS" ARCH=arm64 LLVM=1 \
    arch/arm64/boot/dts/mediatek/mt6895-xiaomi-xaga.dtb >>"$LOG" 2>&1 || true
fi

step "校验 DTB 已嵌入 vmlinux（开机能不能挂全看这个）"
if nm "$LINUX_DIR/vmlinux" 2>/dev/null | grep -q mt6895_xiaomi_xaga_dtb_start; then
  info "${G}OK${N}: 找到 _binary_arch_arm64_boot_dts_mediatek_mt6895_xiaomi_xaga_dtb_start"
else
  die "DTB 未链入 vmlinux —— 刷上去必挂。检查 clang 是否在 PATH 且 >= 17.0.1"
fi
info "Image : $(du -h "$IMAGE" | cut -f1)"
[[ -f "$DTB" ]] && info "DTB   : $(du -h "$DTB" | cut -f1)（已内嵌，打包时不要再传 --dtb）"

# ───────────────────────────── 8. 打包 boot.img ─────────────────────────────
# 走到这里内核已经编完 —— 就用此刻作为「编译完成时间」给所有产物命名。
# 同一台机器反复构建不再互相覆盖；想固定名字传 STAMP=YYYYmmdd-HHMMSS。
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
BOOT_IMG="$OUT/boot-${STAMP}.img"
BOOT_IMG_GZ="${BOOT_IMG}.gz"
IMAGE_OUT="$OUT/Image-${STAMP}"
IMAGE_OUT_GZ="${IMAGE_OUT}.gz"
INITRAMFS_OUT="$OUT/initramfs-${STAMP}.cpio.lz4"
INITRAMFS_CPIO_OUT="$OUT/initramfs-${STAMP}.cpio"
MODULES_OUT="$OUT/modules-${STAMP}.tar.gz"
SUMS_OUT="$OUT/SHA256SUMS-${STAMP}.txt"

step "打包 boot.img（时间戳 $STAMP）"
mkdir -p "$OUT"
cp -f "$IMAGE" "$IMAGE_OUT"
gzip -n -9 -c "$IMAGE" > "$IMAGE_OUT_GZ"     # -n 不写时间戳，保证可复现
cp -f "$INITRAMFS_LZ4"          "$INITRAMFS_OUT"
cp -f "$INITRAMFS_DIR/initramfs.cpio" "$INITRAMFS_CPIO_OUT"  # 给 magiskboot repack 用

FINAL_CMDLINE="$CMDLINE"
if [[ -z "$FINAL_CMDLINE" && -n "$MEM_LIMIT" ]]; then
  FINAL_CMDLINE="mem=$MEM_LIMIT"
fi

MK_ARGS=(
  --kernel          "$IMAGE_OUT_GZ"
  --ramdisk         "$INITRAMFS_OUT"
  --base             "$BASE"
  --kernel_offset    "$KERNEL_OFFSET"
  --pagesize         "$PAGE_SIZE"
  --ramdisk_offset   "$RAMDISK_OFFSET"
  --tags_offset      "$TAGS_OFFSET"
  --dtb_offset       "$DTB_OFFSET"
  --header_version   "$HEADER_VERSION"
  --os_version       "$OS_VERSION"
  --os_patch_level   "$OS_PATCH_LEVEL"
  -o                 "$BOOT_IMG"
)
[[ -n "$FINAL_CMDLINE" ]] && MK_ARGS=(--cmdline "$FINAL_CMDLINE" "${MK_ARGS[@]}")

info "mkbootimg ${MK_ARGS[*]}"
# shellcheck disable=SC2086
$MKBOOTIMG "${MK_ARGS[@]}"
[[ -f "$BOOT_IMG" ]] || die "boot.img 未生成"

step "校验 boot.img 头部（v4 必须 header_size=1584）"
python3 - "$BOOT_IMG" <<'PY'
import struct, sys
p = sys.argv[1]
d = open(p, 'rb').read(4096)
magic = d[0x00:0x08]
if magic != b'ANDROID!':
    print('!! magic 异常:', magic); sys.exit(1)
ksize = struct.unpack_from('<I', d, 0x08)[0]
rsize = struct.unpack_from('<I', d, 0x0c)[0]
osver = struct.unpack_from('<I', d, 0x10)[0]
hsize = struct.unpack_from('<I', d, 0x14)[0]
hver  = struct.unpack_from('<I', d, 0x28)[0]
print(f'    magic          : {magic.decode()}')
print(f'    kernel_size    : {ksize} ({ksize/1024/1024:.2f} MB)')
print(f'    ramdisk_size   : {rsize} ({rsize/1024:.1f} KB)')
print(f'    header_size    : {hsize}  (v4 应为 1584)')
print(f'    header_version : {hver}')
if hver != 4:  print(f'!! header_version 应为 4，实际 {hver}'); sys.exit(1)
if hsize != 1584: print(f'!! header_size 应为 1584，实际 {hsize}'); sys.exit(1)
if ksize == 0: print('!! kernel 段为空'); sys.exit(1)
if rsize == 0: print('!! ramdisk 段为空'); sys.exit(1)
print('    OK: boot.img 校验通过')
PY

# boot.img -> .gz：存档 / 发网盘 / 走 CI artifact 时省流量。刷机仍然用 .img 本体。
step "压缩 boot.img -> $(basename "$BOOT_IMG_GZ")"
gzip -n -9 -c "$BOOT_IMG" > "$BOOT_IMG_GZ"   # -n 不写时间戳；-c 保留原 .img 不动
gzip -t "$BOOT_IMG_GZ" || die "boot.img.gz 回读校验失败（压缩写坏了）"
info "$(basename "$BOOT_IMG")     : $(du -h "$BOOT_IMG" | cut -f1)"
info "$(basename "$BOOT_IMG_GZ")  : $(du -h "$BOOT_IMG_GZ" | cut -f1)  （已过 gzip -t 回读校验）"

# 从产物本身再抠一次内嵌 .config 复核，防止「改了 config 但编的不是那份」
step "复核产物内嵌 config（IKCFG_ST…IKCFG_ED）"
python3 - "$IMAGE_OUT" <<'PY' || warn "内嵌 config 复核失败（不影响刷机，只是少一道保险）"
import gzip, io, re, sys
raw = open(sys.argv[1], 'rb').read()
s = raw.find(b'IKCFG_ST')
e = raw.find(b'IKCFG_ED')
if s < 0 or e < 0:
    print('    IKCFG 标记不存在（CONFIG_IKCONFIG 未开？）'); sys.exit(0)
blob = raw[s+8:e]
cfg = None
for off in range(0, 16):
    try:
        cfg = gzip.decompress(blob[off:]).decode('utf-8', 'replace'); break
    except Exception:
        continue
if cfg is None:
    print('    gzip 解压失败'); sys.exit(0)
m = re.search(r'^Linux version .*$', raw.decode('utf-8', 'replace'), re.M)
ver = m.group(0) if m else '(未找到版本串)'
print('    ' + ver)
for k in ('CONFIG_USB_CONFIGFS', 'CONFIG_USB_F_ACM', 'CONFIG_USB_U_SERIAL',
          'CONFIG_USB_LIBCOMPOSITE', 'CONFIG_CRYPTO_USER'):
    hit = re.search(rf'^{k}=.*$', cfg, re.M)
    print(f'    {k:26s} {hit.group(0) if hit else "(unset)"}')
PY

step "计算校验和 -> $(basename "$SUMS_OUT")"
(
  cd "$OUT"
  sha256sum \
    "$(basename "$BOOT_IMG")" \
    "$(basename "$BOOT_IMG_GZ")" \
    "$(basename "$IMAGE_OUT_GZ")" \
    "$(basename "$INITRAMFS_OUT")" > "$(basename "$SUMS_OUT")"
  cat "$(basename "$SUMS_OUT")"
)

# ───────────────────────────── 9. 内核模块（可选但推荐） ─────────────────────────────
# 放在 boot.img 之后：即使模块编不过，也不会毁掉已经产出的 boot.img。
if [[ "$BUILD_MODULES" == "1" ]]; then
  step "编译内核模块并打包 modules.tar.gz"
  warn "本工程历史上从不编模块，defconfig 里 1420 个 =m 全是死的；这一步把它们真正编出来"
  if make -j"$JOBS" ARCH=arm64 LLVM=1 modules >>"$LOG" 2>&1; then
    rm -rf "$OUT/mods"
    if make -j"$JOBS" ARCH=arm64 LLVM=1 \
         modules_install INSTALL_MOD_PATH="$OUT/mods" INSTALL_MOD_STRIP=1 >>"$LOG" 2>&1; then
      tar -czf "$MODULES_OUT" -C "$OUT/mods" lib
      info "$(basename "$MODULES_OUT") : $(du -h "$MODULES_OUT" | cut -f1)"
      info "模块数         : $(find "$OUT/mods/lib/modules" -name '*.ko*' | wc -l)"
      info "内核版本目录   : $(ls "$OUT/mods/lib/modules")"
      rm -rf "$OUT/mods"
    else
      warn "modules_install 失败，详见 $LOG"
    fi
  else
    warn "make modules 失败（不影响 boot.img）。详见 $LOG"
  fi
fi

# ───────────────────────────── 10. 完成 ─────────────────────────────
step "完成"
ls -lh "$OUT"

cat <<EOF

${Y}产物（本次时间戳 $STAMP）${N}
  $BOOT_IMG                 刷机用的镜像 ← 用这个
  $BOOT_IMG_GZ              boot.img 的 gz（存档/传输；刷机前先 gunzip -k）
  $IMAGE_OUT_GZ             内核（boot.img 里就是它）
  $INITRAMFS_OUT            ramdisk
  $MODULES_OUT              内核模块（BUILD_MODULES=1 时）
  $SUMS_OUT                 校验和
  $LOG                      完整编译日志

${Y}刷机（注意：MTK v4 头不支持 fastboot boot，只能写槽位）${N}
  adb reboot bootloader
  fastboot flash boot_a "$BOOT_IMG"          # 当前槽位；另一槽是 boot_b
  fastboot flash userdata rootfs-*-sparse.img   # ⚠ 会清空手机内置存储
  fastboot reboot
  回滚: fastboot flash boot_a stock_boot.img

${Y}产物只留最新一份${N}
  ls -t $OUT/boot-*.img | head -1
  find $OUT -name 'boot-*.img' -o -name 'Image-*' -o -name 'initramfs-*' -o -name 'modules-*' | sort   # 想清理时先看

${Y}开机后${N}
  zcat /proc/config.gz | grep -E 'USB_CONFIGFS|USB_F_ACM'   # 复核 gadget 是否真的内建
  xaga-usb-gadget --once                                    # 插上线后手工绑一次 UDC
  systemctl status xaga-usb-gadget                          # 或用常驻服务（rootfs 里已铺）

${Y}排查${N}
  echo 1 > /sys/devices/platform/soc@0/11201000.usb0/device_recover   # 上游给的 USB 复位开关
  dmesg | grep -iE 'udc|gadget|mtu3'                                  # DRD 角色切换是否发生
EOF
