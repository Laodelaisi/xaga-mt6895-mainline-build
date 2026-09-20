# xaga-mt6895-mainline-build

**Redmi Note 11T Pro / 11T Pro+ / POCO X4 GT / Redmi K50i**(xaga / MT6895 / 天玑8100)
的 **Linux 7.2 主线内核 + 可刷 rootfs** 全套构建工程:本地一键脚本 + 一份 GitHub Actions 工作流。

|           |                                                                                                                                                                  |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 内核源码  | [`MT6895-Mainline/linux`](https://github.com/MT6895-Mainline/linux/tree/7.2-mt6895-xiaomi-xaga) 分支 `7.2-mt6895-xiaomi-xaga`(也有 `6.18-mt6895-xiaomi-xaga`) |
| initramfs | [`MT6895-Mainline/initramfs`](https://github.com/MT6895-Mainline/initramfs) 分支 `xaga-mt6895`                                                                  |
| 上游 wiki | [postmarketOS: Xiaomi Redmi Note 11T Pro (xiaomi-xaga)](https://wiki.postmarketos.org/wiki/Xiaomi_Redmi_Note_11T_Pro_(%2B)_/_POCO_X4_GT_/_Redmi_K50i_(xiaomi-xaga)) |
| 工具链    | Clang 全链路 `LLVM=1`(硬性要求,≥ 17.0.1)                                                                                                                      |

> 本 README 是仓库唯一的说明文档,已合并原先散落的
> `xaga-mainline-build-guide.md` / `补充说明.md` / `usb-debug/README.md`。

---

## 快速索引

| 我想…                                   | 看                                              |
| ---------------------------------------- | ----------------------------------------------- |
| 直接编出 boot.img                        | [§3 本地构建](#3-本地一键构建)                    |
| 用 CI 编                                 | [§4 GitHub Actions](#4-github-actions-工作流)     |
| 刷进手机                                 | [§5 刷机](#5-刷进手机)                            |
| 开 USB 串口调试                          | [§6 USB 串口调试](#6-usb-串口调试)                |
| 内置存储连不上 / WiFi 挂了时的第二条通路 | [§6](#6-usb-串口调试)                             |
| 查已刷镜像到底是什么版本                 | [§7 镜像校验](#7-校验刷进去的到底是什么)          |
| 遇到报错                                 | [§8 排错](#8-排错)                                |
| 看作者做到哪一步了                       | [§1.3 上游功能进度](#13-上游功能进度作者更新日志) |

---

## 1. 先弄清这棵树怎么工作(别跳过)

### 1.1 硬事实

| 事实       | 值                                                                                          | 影响                                                              |
| ---------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| 内核版本   | **Linux 7.2.0**(`NAME = Baby Opossum Posse`)                                        | 很新的树,老工具链编不动                                           |
| 默认分支   | `7.2-mt6895-xiaomi-xaga`                                                                  | 直接 clone 即可                                                   |
| defconfig  | `arch/arm64/configs/defconfig` **+** `xaga.config`(后者是 **fragment**)     | 必须 `merge_config.sh` 合并,**不能** `make xaga.config` |
| DTB        | `mt6895-xiaomi-xaga.dtb` 由 `arch/arm64/kernel/Makefile` **objcopy 链进 vmlinux** | 不是 `cat` 拼接,打包时**不要** `--dtb`                  |
| 最低 LLVM  | **17.0.1**(`scripts/min-tool-version.sh`)                                           | Debian 12 的 clang 14 不够                                        |
| 最低 rustc | 1.85,作者实际 pin **1.88**                                                            | 第一版建议直接关掉                                                |
| 默认产物   | `arch/arm64/boot/Image.gz`(`KBUILD_IMAGE`)                                              | 裸 `make` 就出 Image.gz                                         |

**为什么必须 Clang 全链路(不是玄学)。** `arch/arm64/kernel/Makefile` 里构建 DTB 的递归 make 硬编码了 `LLVM=1`:

```make
$(srctree)/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-xaga.dtb: FORCE
	$(Q)$(MAKE) -C $(srctree) ARCH=arm64 LLVM=1 mediatek/mt6895-xiaomi-xaga.dtb
$(obj)/xaga-dtb.o: $(srctree)/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-xaga.dtb FORCE
	$(call if_changed,objcopy)
```

就算外层用 GCC,这一步照样调 clang。clang < 17 → DTB 编不出来 → objcopy 失败 → 报
`undefined reference to _binary_..._xaga_dtb_start` → 整个构建挂掉。

**为什么 appended DTB 在这棵树上完全无效。** 主线 **arm64 没有 appended-DTB 支持**:
`arch/arm64/kernel/head.S` 里 FDT 唯一来源是 `preserve_boot_args` 的 `mov x21, x0`
(bootloader 从 x0 传进来),全文没有扫描 kernel 尾部找 `d00dfeed` 的代码
(`CONFIG_ARM_APPENDED_DTB` 是 arm32 专属)。所以 `cat Image.gz xxx.dtb` 拼出来的尾部 DTB
内核根本不看。本树靠 objcopy 链进 vmlinux + `setup.c` 覆盖(`XAGA-DTB: overriding LK FDT with embedded mt6895-xiaomi-xaga.dtb`),已经把这事做完了。另:原厂 boot.img 的
`KERNEL_FMT` 是 gzip,MTK LK 能解压 Image.gz,直接喂 Image.gz 即可。

**为什么建议纯 in-tree 构建。** 递归 make 用 `-C $(srctree)`,**没有传 `O=`**;
用 `O=` 出树构建会让 DTB 污染源码树并可能和 `always-y` 规则打架。

### 1.2 分区与 cmdline(全部有实测日志支撑)

| 项              | 值                            | 说明                                                                          |
| --------------- | ----------------------------- | ----------------------------------------------------------------------------- |
| rootfs 分区     | **`/dev/sdc86`**      | initramfs 的 `init.c` 找 rootfs 用的设备节点,**不是** fastboot 分区名 |
| nvdata          | `/dev/sdc13`                | 只读 ext4,放 WiFi/BT NVRAM                                                    |
| rootfs 文件系统 | **ext4**(硬编码)        | f2fs / btrfs 都不行                                                           |
| init            | `/sbin/init` 必须存在可执行 | 缺了 = 黑屏死循环                                                             |

xaga 的 UFS 在主线内核里枚举成 **scsi 盘**:

```
sd 0:0:0:0 -> sda (4MB)    sd 0:0:0:1 -> sdb (4MB)    sd 0:0:0:2 -> sdc (128GB)
```

userdata 是 `sdc` 的第 86 号分区 → `/dev/sdc86`。实测日志:

```
CINIT: mounting /dev/sdc86 → EXT4-fs (sdc86): mounted → CINIT: switch_root -> /sbin/init
```

> ⚠️ **旧笔记里的「主线内核下 root 是 `/dev/mmcblk0p86`」是错的**,会找不到 root。
> pmOS wiki 的默认值也是 `/dev/sdc86`。

**cmdline 来自内嵌 DTB,不是 boot.img。** xaga 的补丁会用内嵌 DTB 覆盖 LK 传进来的 FDT,
所以生效的 `Kernel command line:` 来自 DTB 的 `/chosen/bootargs`
(`8250.nr_uarts=4 clk_ignore_unused console=tty0 printk.devkmsg=on log_buf_len=2M`

+ 补丁加的 `panic=15`),**boot.img 的 `--cmdline` 不会进内核**。

**内存不用管。** 实测 `Memory: 5417384K/6291456K`(6291456K = 6GiB),说明 DTB/fixup
已经处理好了 6+128 机型。所以**默认不加 `mem=6G`**(和当前能正常启动的镜像一致),
需要时 `MEM_LIMIT=6G` 一键加上。

### 1.3 上游功能进度(作者更新日志)

按时间从新到旧。这是**作者原帖**,也是判断「某个功能到底有没有」的唯一依据。

**1) 自动亮度 / 自动旋转** — 传感器挂在 SCP 上(参考 furruka 给 1+ACE 竞速版主线的 SCP 实现),
暴露了加速度计和环境光,可开 KDE Plasma 的屏幕自动旋转 / 自动亮度。
`dd659b700e9c3686ea4c1787370a4347b7a0fcfa`

**2) PPS 协议快充** — 2:1 电荷泵(xaga)/ 4:1(xaga pro)。实测 xaga 00:34→27:38 从 23%→78%,
峰值约 43W;xaga pro 峰值约 42W。压差太大会触发硬件保护,所以没调更激进。
PD 只有 mt6375 内置 9V 档位(实际限制到 10W),只有 PPS 能调用另外两个电荷泵。
xaga `a211f7281d77cd3f8e8ffb1d8af45a5b3c6c3ec0` / xaga pro `0ad66a0ff11f99b44ee1159653d9de93c29b96ad`

**4) 相机 RAW** — 能用 camsv 拿到主摄 4.6K 30fps 的 `bayer_bggr8` 码流。
camsv 绕过 ISP,没有自动曝光/白平衡/对焦,所以是「清朝画质」。
**⚠ 相机/ISP 改动还在作者本地,没上传** —— 任何从上游构建的镜像都不会有这部分。

**5) 蓝牙** — 移植了下游安卓内核的 MTK 蓝牙驱动并针对 BlueZ 修复,不需要任何 userspace trick。
`d00468298df83555d5157f37a39d84e242dbd5ee`(内核) + `126b0c137338c1ec6a2cbc434bd67239ce2e38c7`(initramfs)

**6) 华星 / 天马屏同时支持** — 面板驱动通用,但触控固件不同。通过 DDIC lockdown 读屏幕供应商
(42/36),在设备树里填两套触摸屏配置按值选择,和安卓内核行为一致。
`a1c4294f72a3d64cd1e8f83b02dcb1ed57cb9720`

**7) Panthor/PanVK 内存压力卡顿** — Linux 7.2 的 panthor 引入了 GEM Shrinker,内存压力过大时
回收开销很大 → 雷霆大卡顿。这是 shrinker 的第一版,有回归正常,遇到了先关掉。
`4fadce8d6bbce016a8965ad93a5285c565401c1d`

**8) 144Hz 高刷** — GNU/Linux 切刷新率走标准 CRTC 模式,不会像安卓专有 HAL 那样写
`CRTC_PROP_DISP_MODE_IDX`,导致面板 `ext_param dynamic_fps` 属性没变而花屏。
让 mtk dsi 根据 CRTC 模式刷新率改面板 `ext_param` 即可。

**9) 3.5mm 耳机** / **10) 扬声器** — 已驱动。
(声音相关的 quirk 见 `MT6895-Mainline/quirks`:拷 UCM 到 `/usr/share/alsa/ucm2/conf.d/`,
并装 `xaga-mic-switch` 守护进程 —— 内置麦和耳机共用一条通路,不能同时录。)

**11) KDE Plasma 全 GPU 加速** — GPU 和 DRM 已修好;`logind` 仍报
`Operation not permitted`,作者 patch 了 `kwin_wayland` 手动开 DRM 设备绕过,能跑。

---

## 2. 项目结构

```
xaga-mainline/
├── build-mainline.sh                 # 一键:拉代码 → .config → 编内核 → initramfs → boot.img
├── build-rootfs.sh                   # 一键:可刷 userdata 的 ext4 rootfs(arch/debian/ubuntu)
├── README.md                         # 本文档(唯一)
├── .github/
│   ├── workflows/
│   │   └── build-mainline.yml        # 唯一工作流(内核 + rootfs + 发布 + 通知)
│   ├── bot.py                        # 上游检测 / 触发构建 / 通知 / 镜像校验(纯标准库)
│   ├── build-state.json              # 上次构建用的 upstream commit(去重靠它)
│   └── scripts/validate-workflow.py  # YAML 解析 + 每个 run 块 bash -n
├── usb-debug/                        # USB 串口调试(gadget 配置片段 + rootfs 侧文件)
│   ├── kernel-fragments/xaga-usb-gadget.config
│   ├── usb-gadget/                   # 铺进 rootfs 的 configfs 脚本 / systemd / udev / NM
│   ├── reference/boot-img-007893e66767.config   # 基线 config(12214 行),用来 diff
│   └── xaga-verify.py                # 校验「刷进去的到底是什么」
├── img/                              # 实测镜像(参照物)
└── log/                              # 实测启动日志(full / kernel / system)
```

---

## 3. 本地一键构建

### 3.1 环境准备

```bash
sudo apt update
sudo apt install -y git bc bison flex libssl-dev libelf-dev libncurses-dev \
  cpio lz4 zstd gzip xz-utils kmod rsync python3 device-tree-compiler \
  build-essential gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
```

> `gcc-aarch64-linux-gnu` 是给 **initramfs 的 init.c** 用的(它的 Makefile 写死
> `CROSS ?= aarch64-linux-gnu-`),**不是**编内核用的。

**Clang ≥ 17(最容易踩的坑):**

```bash
clang --version | head -1        # ≥ 17.0.1 就跳过本段
```

```bash
# 方案 A:apt.llvm.org(推荐)
wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
sudo ./llvm.sh 18 all
export PATH=/usr/lib/llvm-18/bin:$PATH

# 方案 B:AOSP 预编译 clang(和 Android 内核最贴合)
mkdir -p ~/toolchain && cd ~/toolchain
curl -L -o clang.tar.gz https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r547379.tar.gz
mkdir clang && tar -xzf clang.tar.gz -C clang
export PATH=$HOME/toolchain/clang/bin:$PATH
```

验证(三个都必须有,`llvm-objcopy` 缺了 DTB 就嵌不进去):

```bash
clang --version && ld.lld --version && llvm-objcopy --version
```

**磁盘至少 40GB 空闲,别在 exFAT/NTFS 上编译。**

### 3.2 `build-mainline.sh`

```bash
chmod +x build-mainline.sh
./build-mainline.sh                      # 默认:编内核 + 打 boot.img + 编模块(含 USB gadget)
```

常用开关(都是环境变量,放命令前):

| 变量                 | 默认           | 作用                                                             |
| -------------------- | -------------- | ---------------------------------------------------------------- |
| `USB_GADGET`       | `1`          | 内建 USB 串口/RNDIS gadget(**修「插上 PC 没反应」的关键**) |
| `BUILD_MODULES`    | `1`          | 真正编出内核模块并打包(快省 5~10 分钟就设 0)                     |
| `USE_RUST`         | `0`          | 关 Rust(开了需要 rustc ≥ 1.85 + bindgen ≥ 0.71.1)              |
| `KERNEL_COMMIT`    | 空             | 固定到某个 commit(默认取分支 HEAD)                               |
| `INITRAMFS_COMMIT` | 空             | 同上,针对 initramfs                                              |
| `BOOT_PARTITION`   | `/dev/sdc86` | initramfs 找 rootfs 的节点                                       |
| `MEM_LIMIT`        | 空             | 给 boot.img 追加 `mem=6G`(一般不用)                            |
| `STAMP`            | 空             | 固定产物时间戳,如 `20260920-1046`                              |
| `TOP`              | `~/xaga`     | 工作根目录                                                       |
| `JOBS`             | `nproc`      | 并行度                                                           |
| `SKIP_APT`         | `0`          | 设为 1 不自动装依赖                                              |

脚本内部流程:检查 clang ≥ 17 → clone `--depth=1` → `merge_config.sh defconfig xaga.config`
→ 关 Rust → **关掉无关联发科 ASoC**(见下)→ 追加 USB gadget 片段并**硬断言 `=y`**
→ `make Image` + 可选 `make modules` → 编 initramfs(`BOOT_PARTITION=/dev/sdc86`)
→ mkbootimg → **校验 boot.img 头 / DTB 已链进 vmlinux / 从产物 IKCFG 再抠一次 config**。

**为什么要关掉无关联发科 ASoC。** 不关的话编到 `sound/soc/mediatek` 必挂:

```
sound/soc/mediatek/mt8183/mt8183-afe-pcm.c:26:2: error: redefinition of enumerator 'MTK_AFE_RATE_8K'
```

这棵树的 defconfig 默认开了 MT8183 / MT8188 / MT8192 / MT8195 / MT8365 以及 SOF 的
MT8186 / MT8195,而 `mt8183-afe-pcm.c` 自己定义了一份 `MTK_AFE_RATE_*` 枚举,和
`common/mtk-base-afe.h` 撞车。而且两份取值并不一致(mt8183 的 `MTK_AFE_RATE_130K = 7`,
common 头的 `MTK_AFE_RATE_352K = 7`),所以不能简单删掉 mt8183 那份 —— 会静默改变驱动行为。
这些都是 Chromebook / 电视盒方案,xaga 用不到,关掉最干净。脚本已经替你关了,
手动版:

```bash
scripts/config \
  --disable CONFIG_SND_SOC_MT8183 --disable CONFIG_SND_SOC_MT8183_MT6358_TS3A227E_MAX98357A \
  --disable CONFIG_SND_SOC_MT8183_DA7219_MAX98357A --disable CONFIG_SND_SOC_MT8188 \
  --disable CONFIG_SND_SOC_MT8188_MT6359 --disable CONFIG_SND_SOC_MT8192 \
  --disable CONFIG_SND_SOC_MT8192_MT6359_RT1015_RT5682 --disable CONFIG_SND_SOC_MT8195 \
  --disable CONFIG_SND_SOC_MT8195_MT6359 --disable CONFIG_SND_SOC_MT8365 \
  --disable CONFIG_SND_SOC_MT8365_MT6357 \
  --disable CONFIG_SND_SOC_SOF_MT8186 --disable CONFIG_SND_SOC_SOF_MT8195
make LLVM=1 ARCH=arm64 olddefconfig
grep -E 'CONFIG_SND_SOC_MT(6895|8183|8188|8192|8195|8365)' .config   # 6895 那两个必须还在
```

**boot.img 打包参数**(postmarketOS wiki 同款,已实测可启动):

```
--base 0x3fff8000 --kernel_offset 0x8000 --pagesize 4096
--ramdisk_offset 0x26f08000 --tags_offset 0x07c88000 --dtb_offset 0x07c88000
--header_version 4 --os_version 16.0.0 --os_patch_level 2026-08
```

不传 `--dtb`(DTB 已链进 vmlinux)。想自己摸原机参数:

```bash
adb shell 'dd if=/dev/block/by-name/boot_a of=/sdcard/stock_boot.img'   # 先把原厂 boot.img 备份出来,救砖全靠它
adb pull /sdcard/stock_boot.img ~/xaga/stock_boot.img
python3 tools/unpack_bootimg.py --boot_img ~/xaga/stock_boot.img --out ~/xaga/stock_unpack
cat ~/xaga/stock_unpack/boot.img-args
```

**产物**(`~/xaga/out/`,文件名一律带**编译完成时间戳**):

```
boot-<戳>.img             刷机用这个
boot-<戳>.img.gz          自动 gzip 出来的备份(传输/存档;刷机前 gunzip -k)
Image-<戳> / Image-<戳>.gz
initramfs-<戳>.cpio / .cpio.lz4
modules-<戳>.tar.gz       BUILD_MODULES=1 时(默认开)
SHA256SUMS-<戳>.txt
build.log                 完整编译日志
```

时间戳格式 `YYYYmmdd-HHMMSS`,在**内核编完、开始打包那一刻**取,反复构建不互相覆盖。

### 3.3 `build-rootfs.sh`

**必须 root。** 支持 `arch`(作者同款,推荐) / `debian` / `ubuntu`。

```bash
sudo ./build-rootfs.sh -d arch                              # Arch Linux ARM
sudo ./build-rootfs.sh -d debian -r bookworm                # Debian 12
sudo ./build-rootfs.sh -d ubuntu -r resolute                # Ubuntu 26.04 LTS
sudo ./build-rootfs.sh -d arch -k ~/xaga/linux -m ~/xaga/out/modules-20260920-1046.tar.gz
sudo ./build-rootfs.sh -d arch --ssid "MyAP" --psk password
sudo ./build-rootfs.sh --help
```

| 参数                   | 说明                                                                                 | 默认                                |
| ---------------------- | ------------------------------------------------------------------------------------ | ----------------------------------- |
| `-d, --distro`       | `arch` / `debian` / `ubuntu`                                                   | arch                                |
| `-r, --release`      | arch→latest,debian→bookworm(也可 trixie/sid),ubuntu→resolute(也可 noble/questing) | 按发行版                            |
| `-s, --size`         | 镜像大小                                                                             | 6G                                  |
| `-o, --out`          | 输出路径                                                                             | `~/xaga/rootfs-<distro>-<戳>.img` |
| `-w, --work`         | 工作目录                                                                             | `~/xaga/rootfs-dir`               |
| `-k, --kernel`       | 内核源码目录(装了就能编模块注入)                                                     | `~/xaga/linux`                    |
| `-m, --modules`      | 直接指定 `modules-<戳>.tar.gz`                                                     | 空                                  |
| `--no-modules`       | 跳过模块注入(rootfs 会没有 `/lib/modules`)                                         | —                                  |
| `--no-usb-gadget`    | 不铺 USB 串口调试那套文件                                                            | —                                  |
| `--ssid` / `--psk` | 预置 WiFi(NetworkManager,开机自动连)                                                 | 空                                  |
| `-e, --rootdev`      | rootfs 所在分区设备节点                                                              | `/dev/sdc86`                      |
| `-p, --password`     | root 密码                                                                            | root                                |
| `-n, --hostname`     | 主机名                                                                               | xaga                                |
| `-t, --tool`         | `debootstrap` / `mmdebstrap`(仅 deb 系)                                          | auto                                |
| `--mirror`           | 镜像站                                                                               | 国内源                              |
| `--no-sparse`        | 不生成 sparse 镜像                                                                   | —                                  |

产物:`~/xaga/rootfs-<distro>-<戳>.img` + `-sparse.img`(fastboot 刷 sparse)。
固定名字:`STAMP=20260920-1046 sudo -E ./build-rootfs.sh -d arch`。

**rootfs 必须满足的硬条件**(来自 `init.c`,写死的):

```c
mount_(BOOT_PARTITION, "/newroot", "ext4", 0, 0);       // 必须 ext4
mount_(NVDATA_PARTITION, "/nvdata", "ext4", MS_RDONLY, 0);
execve_("/sbin/init", argv, envp);                      // 必须有 systemd
```

| 条件             | 值                                     | 不满足的后果                                |
| ---------------- | -------------------------------------- | ------------------------------------------- |
| 文件系统         | **ext4**(f2fs/btrfs 不行)        | `CINIT: mount failed` → 无限 sleep       |
| init             | `/sbin/init` 可执行                  | `CINIT: exec /sbin/init failed` → 死循环 |
| `/dev` 节点    | **不需要**                       | initramfs 自己挂 devtmpfs                   |
| proc/sys/run/tmp | **不需要**                       | initramfs 全部提前挂好                      |
| cmdline          | **不需要** `root=` / `init=` | argv[0] 写死 `/sbin/init`                 |

**三种发行版的构建方式**(Arch 反而最省事):

| 发行版         | 方式                                           | 特点                                                                       |
| -------------- | ---------------------------------------------- | -------------------------------------------------------------------------- |
| **arch** | 下 `ArchLinuxARM-aarch64-latest.tar.gz` 解压 | 没有 second-stage,最快最稳;自动 `pacman -Rdd linux-aarch64` 去掉自带内核 |
| debian         | `debootstrap --foreign` + second-stage       | second-stage 在 qemu 下很慢                                                |
| ubuntu         | 同上,或 `-t mmdebstrap`                      | 见下面 resolute 的坑                                                       |

> **Ubuntu 26.04 (resolute) 的坑**:debootstrap 不认它(主机是 24.04,`scripts/` 里没
> `resolute`),直接跑报 `E: No such script`。脚本里的 `ensure_suite_script()` 会自动拿一个
> 已有脚本顶替。手动版:
>
> ```bash
> sudo ln -sf /usr/share/debootstrap/scripts/questing /usr/share/debootstrap/scripts/resolute
> ```
>
> 或用 `-t mmdebstrap`(不依赖 suite 脚本,也更快;但它走 binfmt,容器里没注册会失败,
> 这时退回 `-t debootstrap`)。

**第一版建议别装桌面。** 6GB 内存 + 尚未完全验证的 GPU 加速,先跑纯命令行 + SSH 把硬件摸清。
等 `DRM_PANTHOR`(Mali-G610)确认能用,再装 Phosh / KDE 不迟。

**镜像只做 6G 就够。** 刷进去第一次开机执行 `resize2fs /dev/sdc86` 撑满整个 userdata,
比直接刷一个百 G 的镜像快得多。

> 云主机/容器里 `mount -o loop` 经常直接失败。脚本走的是
> **bootstrap 到普通目录 → `mkfs.ext4 -d <dir>` 直接出镜像**,全程不需要 loop。

**内核模块注入:**

```bash
KVER=$(make -s -C ~/xaga/linux ARCH=arm64 kernelrelease)
sudo make -C ~/xaga/linux ARCH=arm64 LLVM=1 modules_install \
     INSTALL_MOD_PATH=$WORK INSTALL_MOD_STRIP=1 DEPMOD=true
sudo chroot $WORK depmod -a $KVER      # 必须在 arm64 下生成 modules.dep
```

> Arch 是 `/usr` 合并布局,`/lib` 必须是 `usr/lib` 的**软链接**。若解压后 `/lib` 成了真目录,
> glibc 加载器只在 `/usr/lib`,`/lib/ld-linux-aarch64.so.1` 就找不到 →
> 报 `Could not open '/lib/ld-linux-aarch64.so.1'`。所以**内核模块 tar 要解到 `rootfs/usr`**,
> 不是 `rootfs/` 根。

### 3.4 rootfs 侧顺手修掉的问题

| 现象                                                          | 根因                                                                                                                   | 修法(脚本已带)                                                                                       |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `shadow.service: Failed`                                    | `userdel -r alarm` 清了 `/etc/passwd`、`/etc/group`,但 `/etc/gshadow` 里 wheel 的 alarm 成员还留着             | 删用户**之前** `gpasswd -d alarm wheel`,删完再 `sed -i 's/\balarm\b//g' /etc/gshadow` 兜底 |
| `cfg80211: failed to load regulatory.db`                    | 缺 `wireless-regdb`(提供 `/lib/firmware/regulatory.db`),影响 5GHz 信道与发射功率                                   | 装 `wireless-regdb`,装不上从宿主拷一份                                                             |
| `systemd-modules-load: Failed to find module 'crypto_user'` | **不是**模块没编 —— `CONFIG_CRYPTO_USER=y` 已内建,没有 `.ko`;是 modules-load.d 的 drop-in 开机 modprobe 它 | 把那个 drop-in 里的 `crypto_user` 删掉                                                             |
| 插上 PC 没反应                                                | 见 [§6](#6-usb-串口调试)                                                                                                 | 铺 USB gadget 文件 + 内核侧改 `=y`                                                                 |

---

## 4. GitHub Actions 工作流

仓库里**只有** `.github/workflows/build-mainline.yml` 一份工作流。五个 job:

```
meta(参数归一化 + 上游 commit 检测) → kernel(编内核/模块/boot.img)
                                   → rootfs(postmarketOS / Arch / Ubuntu)
                                   → release(压缩 / 分卷 / README / Release)
                                   → notify(喵提醒 / Server酱 / 钉钉 + 回写 build-state)
```

**触发器:** `workflow_dispatch`(手动)、`schedule`(每天 `02:00` / `14:00` UTC 查上游)、
`push tag all-v*` / `v*`、`repository_dispatch`(`xaga-build`)。

### 4.1 主要 inputs

| 输入                                      | 说明                                                                   | 默认         |
| ----------------------------------------- | ---------------------------------------------------------------------- | ------------ |
| `TASK`                                  | `全部(内核+RootFS)` / `仅编译内核` / `仅构建RootFS`              | 全部         |
| `KERNEL_BRANCH`                         | `7.2-mt6895-xiaomi-xaga`(最新) / `6.18-mt6895-xiaomi-xaga`(更保守) | 7.2          |
| `KERNEL_COMMIT` / `INITRAMFS_COMMIT`  | 固定 commit,留空取 HEAD                                                | 空           |
| `BOOT_PARTITION` / `NVDATA_PARTITION` | `/dev/sdc86` / `/dev/sdc13`                                        | 同左         |
| `MEM_LIMIT`                             | 追加 `mem=6G`,一般留空                                               | 空           |
| `USB_GADGET`                            | 内建 USB gadget(默认开)                                                | true         |
| `BUILD_MODULES`                         | 真编内核模块                                                           | true         |
| `CLANG_VERSION`                         | LLVM 版本(≥17)                                                        | 18           |
| `REUSE_BOOT_FROM_RUN`                   | 复用某历史 run 的 boot.img(跳过 ~30 分钟编译),填 Run ID                | 空           |
| `ROOTFS_TYPE`                           | `postmarketOS` / `Arch Linux ARM` / `Ubuntu`                     | postmarketOS |
| `PMOS_UI`                               | `phosh` / `none` / `plasma-mobile`(仅 pmOS)                      | phosh        |
| `UBUNTU_VERSION`                        | `26.04 LTS` / `25.10` / `24.04 LTS`                              | 26.04 LTS    |
| `ROOTFS_DESKTOP`                        | `none` / `kde` / `phosh` / `sway`(仅 Arch)                     | none         |
| `IMAGE_SIZE_GB`                         | 初始镜像容量                                                           | 6            |
| `HOSTNAME` / `ROOT_PASSWORD`          | 主机名 / root 密码                                                     | xaga / root  |
| `EXTRA_PACKAGES`                        | 额外安装的包,空格分隔                                                  | 空           |
| `WIFI_SSID` / `WIFI_PASSWORD`         | 预置 WiFi(xaga 建议 2.4GHz 热点)                                       | 空           |
| `COMPRESS_ARTIFACTS`                    | `.img` → `.img.gz`(超 2GB 自动分卷 `.part-00`…)                | true         |
| `CREATE_RELEASE`                        | 发布到 GitHub Release                                                  | true         |
| `ENABLE_NOTIFY`                         | 构建完成推送通知                                                       | true         |
| `RUNNER`                                | 见 [§4.5](#45-已知坑chroot-里-exit-255)                                  | ubuntu-24.04 |

### 4.2 三种构建模式

内核编一次要 30 分钟左右,rootfs 又经常要反复调包,所以支持拆开跑:

| `TASK`         | 做什么                                                                           |
| ---------------- | -------------------------------------------------------------------------------- |
| `全部`         | kernel + rootfs(默认)                                                            |
| `仅编译内核`   | 只出 `boot-<戳>.img[.gz]` / `Image-<戳>.gz` / initramfs / `kernel-modules` |
| `仅构建RootFS` | 只做 rootfs,模块自动从**最近一次成功构建**拉                               |

单独跑 rootfs:直接选 `仅RootFS` 触发即可 —— rootfs job 自己用 `gh run list` 找最近一次成功
构建的 `kernel-modules` artifact 拉下来(找不到就 warning,rootfs 会没有 `/lib/modules`)。
内核版本不是从 kernel job 的 output 拿的,而是**从 modules tar 的 `lib/modules/<ver>/` 目录名
反推**,所以拉历史 artifact 也能对上正确的 `depmod`。

省时间复用已编好的 boot:填 `REUSE_BOOT_FROM_RUN=<run id>`
(在 `https://github.com/<owner>/<repo>/actions/runs/<run id>` 里取),kernel job 会直接下载
那次 run 的 `boot-*.img` 跳过编译,并照常跑全部校验。

> **为什么 job 都不用 job-level `if`:** GitHub Actions 里 `needs` 的 job 一旦被 skip,
> 下游 job 会无条件跟着 skip,`if: always()` 也救不回来(notify 也会一起没)。
> 所以统一用 **step-level `if`**:kernel 在 `仅RootFS` 模式下几秒跑完并返回 success,needs 链不断。

### 4.3 上游自动检测与 `bot.py`

`.github/bot.py` 纯标准库,六个子命令:

| 子命令             | 作用                                                                                                                                                                                                             |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `check-upstream` | 比对上游 linux / initramfs 分支 HEAD 与 `.github/build-state.json`,有变化就置 `SHOULD_BUILD=true`;`--force` 无条件构建,`--trigger-build` 检测到更新直接触发,`--json <path>` 另存结果给工作流同 step 读 |
| `save-state`     | 回写本次构建用的 commit(`--no-push` 只写本地)                                                                                                                                                                  |
| `trigger`        | 调 workflow_dispatch 触发构建(`--task` / `--rootfs-type` / `--kernel-commit` / `--usb-gadget`)                                                                                                           |
| `notify`         | 推送构建结果(喵提醒 / Server酱 / 钉钉;`--markdown` 给 Server酱用)                                                                                                                                              |
| `verify-bootimg` | 校验 boot.img 头(v4 / page size / 段大小)                                                                                                                                                                        |
| `inspect-image`  | 读裸 Image 的版本串 + 从 `IKCFG_ST…IKCFG_ED` 抠出内嵌完整 `.config`;`--keys` 打印指定项,`--assert-y` 断言必须 `=y`(不满足返回非零),`--dump` 落盘                                                    |

`.github/build-state.json` 存「上一次构建用的 kernel/initramfs commit」。
初始基线是当前刷在设备上、已实测能正常启动的那份:

```json
{ "kernel_commit": "007893e66767a99495ac11c51b442b425606a70e",
  "initramfs_commit": "126b0c137338c1ec6a2cbc434bd67239ce2e38c7",
  "kernel_branch": "7.2-mt6895-xiaomi-xaga", "initramfs_branch": "xaga-mt6895" }
```

`schedule` 每天两次拿它跟上游 HEAD 比,**只有上游有新 commit 才自动构建**,成功后自动回写。

本机用法:

```bash
python3 .github/bot.py check-upstream                      # 打印 + 写 $GITHUB_OUTPUT
python3 .github/bot.py check-upstream --trigger-build      # 有更新就触发
python3 .github/bot.py verify-bootimg ~/xaga/out/boot-20260920-104630.img
python3 .github/bot.py inspect-image ~/xaga/out/Image-20260920-104630 \
        --assert-y CONFIG_USB_GADGET CONFIG_USB_CONFIGFS CONFIG_USB_F_ACM
```

### 4.4 Secrets 配置

仓库 → Settings → Secrets and variables → Actions → New repository secret:

| Secret               | 说明                                             | 必需                               |
| -------------------- | ------------------------------------------------ | ---------------------------------- |
| `MIAO_ID`          | [喵提醒](https://miaotixing.com) 的提醒码           | 可选                               |
| `SERVERCHAN_KEY`   | [Server酱](https://sct.ftqq.com) SendKey(推微信/QQ) | 可选                               |
| `DINGTALK_WEBHOOK` | 钉钉机器人 Webhook 完整地址                      | 可选                               |
| `DINGTALK_SECRET`  | 钉钉机器人加签密钥                               | 可选(GITHUB_TOKEN 自动注入,无需配) |

**钉钉配置:** 钉钉群 → 智能群助手 → 添加机器人 → 自定义 → 安全设置选**加签** → 密钥填
`DINGTALK_SECRET`,Webhook 地址填 `DINGTALK_WEBHOOK`。

### 4.5 已知坑:chroot 里 exit 255

```
aarch64-binfmt-P: Could not open '/lib/ld-linux-aarch64.so.1': No such file or directory
##[error]Process completed with exit code 255.
```

在 `ubuntu-24.04`(x86_64)上调 `chroot 配置系统` 这步挂掉。两层原因都可能触发同一句报错,
工作流两个都处理了:

1. **binfmt 注册方式** —— Ubuntu 24.04 的 `qemu-aarch64` binfmt 以 preserve-argv0(`-P`)+
   credentials 注册,chroot 下解析目标动态加载器会失败。
   → **不再依赖 binfmt**,把 `qemu-aarch64-static` 显式作为 chroot 的第一个程序执行:
   ```bash
   sudo chroot rootfs /usr/bin/qemu-aarch64-static /bin/bash -c '...'
   ```
2. **`/lib` 布局** —— Arch 是 `/usr` 合并布局,`/lib` 必须是 `usr/lib` 的软链接。
   若解压后 `/lib` 成了真目录,glibc 加载器只在 `/usr/lib`,`/lib/ld-linux-aarch64.so.1` 就找不到。
   → 工作流在注入模块**之前**体检,发现异常就把 `/lib` 内容并入 `/usr/lib` 再重建软链接
   (放前面是因为模块有几百 MB,晚了要多搬一趟)。

想彻底躲开 qemu:`RUNNER` 选 `ubuntu-24.04-arm`(公开仓库免费)。ARM64 原生 runner 不需要
binfmt,工作流会自动跳过注册步骤直接 `chroot /bin/bash`。

### 4.6 产物与发布

- Artifacts:`kernel-output`、`kernel-modules`、`rootfs-output`;Release 里合并成 `xaga-all-in-one`
- `COMPRESS_ARTIFACTS=true` 时 `.img` → `.img.gz`(pigz),超 2GB 自动分卷 `.part-00` / `.part-01`…;
  每个 `.gz` 旁有 `.gz.sha256`,分卷另有 `.gz.whole-sha256`(合并后整体的哈希)
- Release 附 `README.txt`(构建参数、刷机步骤、USB 用法、排查命令)和 `kernel-<戳>.config`
  (从镜像 IKCFG 抠出来的完整 config,和 `usb-debug/reference/` 里的基线 diff 就知道配置动了什么)

```bash
# 合并分卷(Linux/macOS)
cat rootfs.img.gz.part-* > rootfs.img.gz && gunzip rootfs.img.gz
# Windows
copy /b rootfs.img.gz.part-00+rootfs.img.gz.part-01 rootfs.img.gz
```

---

## 5. 刷进手机

**⚠ 前置:bootloader 已解锁。** 另外 **MTK v4 boot header 不支持 `fastboot boot`**,
只能 flash 到槽位。

```bash
adb reboot bootloader
fastboot devices

# 0) 确认槽位 —— 决定后面写 boot 还是 boot_a
fastboot getvar current-slot 2>&1 | head -3
fastboot getvar all 2>&1 | grep -i 'partition-size.*boot'
```

- `current-slot:` **有值**(a/b) → 用 `boot_a` / `boot_b`
- **为空 / 报错** → A-only,直接用 `boot`

```bash
# 1) 先存回滚镜像,别偷懒
adb shell 'dd if=/dev/block/by-name/boot_a of=/sdcard/stock_boot.img' && adb pull /sdcard/stock_boot.img

# 2) 刷 rootfs 到 userdata   ⚠ 会清空手机内置存储,先备份!
fastboot flash userdata ~/xaga/rootfs-arch-20260920-104630-sparse.img
fastboot erase metadata
fastboot erase misc

# 3) 刷内核(VBMETA 校验失败时先执行 fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img)
fastboot flash boot_a ~/xaga/out/boot-20260920-104630.img
fastboot reboot
```

开机后第一件事,把 6G 的镜像撑满整个 userdata:

```bash
resize2fs /dev/sdc86
```

**卡在开机画面 / 提示系统损坏:** v4 镜像带 VBMETA,解锁后的 BL 一般会跳过校验,
个别机器仍会拦。补一刀:

```bash
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
# 没有 vbmeta.img:用 avbtool 造一个(全 0 的 4KB 不行);部分 MTK 机型认 fastboot erase vbmeta
```

> 追加 `/etc/fstab` 里指向 userdata(`/dev/sdc86 / ext4 defaults,noatime,errors=remount-ro 0 1`),
> 否则 systemd 会认为 rootfs 不匹配。原厂 CMDLINE 为空,console 走 DT 的 `stdout-path`(多半是串口),
> 所以**屏幕上不会有登录提示符** —— 建议 `systemctl enable getty@tty1`。

---

## 6. USB 串口调试

### 6.1 为什么之前插上没反应(根因)

从镜像内嵌 config 里读出的真实状态:

```
CONFIG_USB_GADGET=y              ← 控制器侧是好的
CONFIG_USB_MTU3_DUAL_ROLE=y      ← DRD 双角色,TCPM 切角色正常
CONFIG_TYPEC_TCPCI_MT6375=y      ← Type-C 协商正常
CONFIG_USB_LIBCOMPOSITE=m        ← 模块,没编
CONFIG_USB_CONFIGFS=m            ← 模块,没编
CONFIG_USB_F_ACM=m
CONFIG_USB_U_SERIAL=m
# CONFIG_USB_G_SERIAL is not set  ← xaga.config 里显式关掉了 legacy g_serial
```

上游 `defconfig` 里 USB gadget 那坨全是 `=m`,而本构建流程历史上只跑 `make Image`、
**从不 `make modules`、rootfs 里也没有 `/lib/modules`**,所以所有 `=m` 项等于没编。

> **更大的坑:整份 `.config` 里有 1420 个 `=m` 项**,全部处于「配了但用不了」的状态。
> 要用必须改成 `=y`(本目录的做法)或真的 `make modules` + `modules_install` + `depmod`。

### 6.2 现在的做法

内核侧:`usb-debug/kernel-fragments/xaga-usb-gadget.config` 强制那几个
`CONFIG_USB_*` 为 `=y`,并在合并列表最后追加(merge_config.sh 后写覆盖先写,不用 fork 内核仓库改
`xaga.config`)。合并后**硬断言**,不是 `=y` 就 `exit 1`;打完包还从 boot.img 产物里
(IKCFG)**再断言一遍**。本地脚本默认 `USB_GADGET=1`,做的是同一件事。

rootfs 侧:`usb-debug/usb-gadget/` 下四个文件铺进去,并建
`multi-user.target.wants/xaga-usb-gadget.service` 软链接完成自启(不进 chroot,快):

```
usb-gadget/usr/local/sbin/xaga-usb-gadget                        configfs 绑定脚本(轮询等 UDC)
usb-gadget/etc/systemd/system/xaga-usb-gadget.service            常驻服务
usb-gadget/etc/udev/rules.d/91-xaga-usb-serial.rules             ttyGS0 出现就拉 getty
usb-gadget/etc/NetworkManager/system-connections/xaga-usb0.nmconnection
```

**刻意不 enable `serial-getty@ttyGS0`:** ttyGS0 要等 gadget 绑定后才存在,
开机无条件拉起会报 device not found,交给 udev 规则按需启动。

### 6.3 用法

选 `TASK=仅编译内核` 跑一次,刷 `boot_a`,插数据线到 PC:

- **Windows**:设备管理器出现 COM 口(Win10+ 免驱 usbser),PuTTY / Tera Term 打开,
  115200 8N1(ACM 下波特率无意义),回车就是 root 登录提示符
- **Linux**:`screen /dev/ttyACM0 115200`
- 手机侧对应 `/dev/ttyGS0`,由 udev 规则自动开 getty

**顺带要 USB 网卡(不靠 WiFi 也能 ssh):** 把 `/etc/systemd/system/xaga-usb-gadget.service`
里的 `ENABLE_RNDIS=0` 改成 `1`,`systemctl restart xaga-usb-gadget`,手机侧出现 `usb0`
(固定 `10.9.0.1/24`),PC 侧网卡手动填 `10.9.0.2/24`,然后 `ssh root@10.9.0.1`。

### 6.4 排查与已知限制

```bash
systemctl status xaga-usb-gadget        # 服务状态
ls /sys/class/udc                       # 插线后 TCPM 切 device 角色才出现
echo 1 > /sys/devices/platform/soc@0/11201000.usb0/device_recover   # 上游给的恢复开关
```

- 上游 `mtu3_dr.c` 里 xaga 的 `allow_userspace_control=false`,**userspace 不能强制切 device
  角色**,只能等 TCPM → 所以脚本用轮询,不能开机 oneshot 绑一次
- 本方案给的是 **rootfs 起来之后**的串口登录(几秒内),不是早期 kernel console。
  要看更早的日志走已经开着的 `ramoops` + `drm_panic`(上游调试路线)
- **不要开 legacy `g_serial`**:它会在 probe 时抢占 UDC,configfs 就绑不上了
- ULPI/USB3 用不到;`mtu3` 日志里 `max_speed: high-speed`,串口 + 网卡 USB2 足够
- Windows 11 新版对 RNDIS 有弃用趋势,认不出来就把功能换成 NCM/EEM(Linux/macOS 友好)

---

## 7. 校验「刷进去的到底是什么」

`usb-debug/xaga-verify.py` 一条命令出功能覆盖 + 上游覆盖报告:

```bash
python usb-debug/xaga-verify.py                                   # 默认读 img/boot/boot.img
python usb-debug/xaga-verify.py --boot-img img/boot/boot.img
python usb-debug/xaga-verify.py --log log/kernel_boot_log.txt     # 从启动日志取版本串
python usb-debug/xaga-verify.py --version 7.2.0-g007893e66767 --no-network
GITHUB_TOKEN=xxx python usb-debug/xaga-verify.py                  # 提高 GitHub API 限额
```

它做三件事:

1. 解 `boot.img` 头(v4 / 1584 / kernel_size / ramdisk_size),kernel 段 gunzip 成裸 `Image`,
   扫 `Linux version ...` 拿到构建时的 commit;
2. 扫 `IKCFG_ST ... IKCFG_ED` 抠出**内核编译时内嵌的完整 `.config`**
   (defconfig 有 `CONFIG_IKCONFIG_PROC=y`,设备上 `zcat /proc/config.gz` 是同一份),
   逐条对照 [§1.3](#13-上游功能进度作者更新日志) 报 `[OK]` / `[MISS]`,并单列所有「`=m` 但用不了」的项;
3. 拿 commit 去 GitHub 比分支 HEAD,落后就把缺的 commit 列出来,再逐个确认更新日志里那几个
   commit 是否在镜像里(**祖先关系,不是看提交时间**)。

**在实测镜像上的结论:** `Linux version 7.2.0-g007893e66767` == 上游 HEAD
`007893e66767a99495ac11c51b442b425606a70e`(2026-09-16),更新日志里 6 个已推送 commit 全在镜像里,
initramfs HEAD `126b0c13` 也在。**唯一例外是相机/ISP**(作者本地未上传,任何上游构建都不会有)。
功能 11 项全过,唯一 `[MISS]` 是 USB gadget —— 与实机现象一致。

> 基线留在 `usb-debug/reference/boot-img-007893e66767.config`(就是从设备上刷着的那份 boot.img
> 里抠出来的完整 `.config`,12214 行)。以后重编新镜像 diff 一下就知道配置动了什么:
>
> ```bash
> diff usb-debug/reference/boot-img-007893e66767.config 新config | grep -E '^[<>]' | head -50
> ```

---

## 8. 排错

| 现象                                                              | 排查                                                                                                                                                   |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `undefined reference to _binary_..._xaga_dtb_start`             | DTB 没编出来。99% 是 clang 不在 PATH 或 < 17                                                                                                           |
| `error: redefinition of enumerator 'MTK_AFE_RATE_8K'`           | 关掉无关联发科 ASoC,见 [§3.2](#32-build-mainlinesh)                                                                                                      |
| `unable to rename temporary 'xxx.o.tmp' to output file 'xxx.o'` | clang 写完临时文件 rename 失败(ENOENT),多为磁盘/inode 瞬时故障。`df -h` `df -i` `df -T`(**别在 exFAT/NTFS 上编译**),单进程确认无并发后重编 |
| `CINIT: mount failed` 后黑屏                                    | userdata 不是 ext4,或 rootfs 没刷进去。init.c 硬编码按 ext4 挂                                                                                         |
| `CINIT: exec /sbin/init failed`                                 | rootfs 里没有可执行的 `/sbin/init`。debootstrap 没装 `systemd-sysv`,或 second-stage 没跑完                                                         |
| 开机卡住但屏幕上啥也没有                                          | 原厂 CMDLINE 为空,console 走 DT 的 `stdout-path`(串口)。rootfs 里 `systemctl enable getty@tty1`                                                    |
| 进了系统但 WiFi / 触摸不工作                                      | 检查 `/lib/firmware/mediatek/mt6895/` 下有没有 WIFI 和那 9 个固件;再 `lsmod` 看模块装上没                                                          |
| WiFi 起不来                                                       | 确认 nvdata 挂载成功、`/lib/firmware/mediatek/mt6895/WIFI` 存在。看 `dmesg \| grep CINIT`                                                           |
| ramdisk 解不开                                                    | 用了 lz4 但 `.config` 只有 `RD_GZIP`。用 lz4 legacy(`lz4 -l -9`),原厂 `RAMDISK_FMT` 就是 `lz4_legacy`,内核 `CONFIG_RD_LZ4=y` 默认已开      |
| `fastboot flash` 报 image too large                             | boot 分区比镜像小。先 `fastboot getvar partition-size:boot` 确认,别猜                                                                                |
| 卡在开机第一屏、无日志                                            | 没有串口。开 `CONFIG_DRM_PANIC`(默认已开),panic 会画在屏幕上;或接 USB gadget 串口                                                                    |
| `pstore` 抓不到上一把日志                                       | 已知:WDT/硬复位路径下 ramoops 没刷 cache,靠 expdb 的 XAGR ring                                                                                         |
| 触摸不灵(CSOT 屏)                                                 | 树里已有按 DDIC lockdown 自动选固件的逻辑;另确认包含 "Lower spi max frequency" 的修复                                                                  |
| 12GB 内存版崩溃                                                   | 早期树把 8GB 版的 reserved-memory 硬编码了,必须有 `reserve top-of-DRAM bootloader window` 那个 commit                                                |
| 声音没声                                                          | 拷 UCM 到 `/usr/share/alsa/ucm2/conf.d/`,并装 `xaga-mic-switch` 守护进程                                                                           |
| 变砖 / 起不来                                                     | `fastboot flash boot_a stock_boot.img` 回滚;进 fastboot 通常还能救                                                                                   |
| userdata 已覆盖且进不去 fastboot                                  | 只能 MiFlash 线刷整机                                                                                                                                  |

---

## 9. 注意事项

1. **必须解锁 Bootloader** 才能刷自定义 boot.img
2. `fastboot flash userdata` 会彻底清除安卓用户数据,**操作前务必备份**
3. `init.c` 里 rootfs 和 nvdata 都硬编码 ext4,不支持 f2fs
4. 首次进系统后自行 `apk add linux-firmware-mediatek` / `apt install linux-firmware` 补固件
   (initramfs 已经会从 nvdata 拷 WiFi/BT 那一套)
5. 七个 `=m` 的坑:**这个工程的历史版本从不 `make modules`**,需要什么功能就写 `=y`
   (或用 `BUILD_MODULES=1`)
6. 本仓库不是 git 仓库,删改前建议先整目录打包备份

## 10. 技术栈

- **编译:** Clang ≥ 17 / LLVM / LLD 全链路(`LLVM=1`)
- **打包:** osm0sis mkbootimg(C 版,兼容 MTK 原厂 LK)
- **rootfs:** postmarketOS edge / Arch Linux ARM / Debian 12 / Ubuntu 24.04·25.10·26.04
- **通知:** 喵提醒 / Server酱 / 钉钉 Webhook(加签)
- **缓存:** actions/cache(内核 obj)+ ccache
