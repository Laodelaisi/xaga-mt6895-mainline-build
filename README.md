# xaga-mt6895-mainline-build

基于 GitHub Actions 的 **Redmi Note 11T Pro (xaga / MT6895 / 天玑8100)** 主线内核自动化构建项目。

内核源码: [MT6895-Mainline/linux (7.2-mt6895-xiaomi-xaga)](https://github.com/MT6895-Mainline/linux/tree/7.2-mt6895-xiaomi-xaga)
Initramfs: [MT6895-Mainline/initramfs](https://github.com/MT6895-Mainline/initramfs)
wiki: [postmarketos](https://wiki.postmarketos.org/wiki/Xiaomi_Redmi_Note_11T_Pro_(%2B)_/_POCO_X4_GT_/_Redmi_K50i_(xiaomi-xaga))

根据postmarketos的wiki中构建boot镜像的方法，创建一个利用GitHub工作流，完成boot镜像的构建

根据选择构建RootFS系统，有以下几种：

- Arch Linux
- Debian 13
- Ubuntu 26.04 LTS

根文件系统只有root用户，没有普通用户

## 项目结构

```
xaga-mt6895-mainline-build/
├── .github/
│   └── workflows/
│       ├── build.yml    # 主编译工作流 (内核编译 + 完成通知)
│       └── clean.yml    # 缓存清理工作流
├── bot.py               # 自动化助手 (喵提醒/Server酱通知 + 上游更新检测 + 自动触发构建)
├── build-mainline.sh    # 本地构建 boot 镜像（内核 + initramfs + 打包）脚本
├── build-rootfs.sh      # 本地构建 rootfs（要 root：loop 挂载 + chroot）脚本
└── README.md		 # 项目说明
```

## 功能特性

| 功能                | 说明                                           |
| ------------------- | ---------------------------------------------- |
| Clang 18 全链路编译 | LLVM=1 LLVM_IAS=1, 作者强制规范, 禁用 GCC      |
| 项目专用 initramfs  | 使用 MT6895-Mainline/initramfs                 |
| 喵提醒/Server酱通知 | 构建完成自动推送 (喵提醒 / Server酱)           |
| 上游更新监控        | bot.py 自动检测上游内核 commit, 可自动触发构建 |

## 构建参数

| 功能                      | 说明                                                                                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 构建任务                  | 构建任务选择，有：仅构建Boot镜像（默认）；仅构建RootFS镜像；构建Boot镜像和RootFS镜像 通过下拉选择                                                        |
| 内核分支                  | 7.2 功能最新；6.18 更保守 通过下拉选择                                                                                                                   |
| initramfs userdata        | 默认是/dev/sdc86 initramfs 找 rootfs 用的设备节点 xaga 上是 /dev/sdc86（= userdata）。这不是 fastboot 分区名。 除非改过分区表，否则别动                  |
| initramfs NVRAM           | 默认是/dev/sdc13 initramfs 取 WiFi/BT NVRAM 用的分区，xaga 是 /dev/sdc13                                                                                 |
| kernel                    | 需要编译就打勾，默认打勾，否则跳过内核编译，复用  RUNS ID 中的内核产物 没填 RUNS ID 就按默认进行                                                         |
| initramfs                 | 需要编译就打勾，默认打勾，否则跳过initramfs编译，复用  RUNS ID 中的initramfs产物 没填 RUNS ID 就按默认进行                                               |
| RUNS ID                   | 留空 : 正常编译内核和initramfs，填 Run ID: 例如 35342958852 根据kernel和initramfs编译选择进行复用Image-<时间戳>.gz和initramfs-<时间戳>.cpio.lz4          |
| modules                   | 需要编译就打勾，（BUILD_MODULES 开着时）默认打勾，否则跳过内核模块编译，复用  RUNS ID 中的内核模块产物 没填 RUNS ID 就按默认进行                         |
| rootfs 发行版             | 选择构建的RootFS系统，默认ubuntu 26.04 LTS 下拉选择                                                                                                      |
| Arch Linux ARM 的桌面环境 | 选择安装的桌面环境，默认KED；none；phosh；sway 下拉选择                                                                                                  |
| rootfs 初始镜像容量       | （GB，纯数字） 6 够用；完整桌面 10~16。刷入后首次开机 resize2fs 即可撑满 userdata。                                                                      |
| rootfs 主机名             | 默认xaga                                                                                                                                                 |
| rootfs root 密码          | 默认root                                                                                                                                                 |
| rootfs 额外包             | 默认空 空格分隔（Arch 用包名）                                                                                                                           |
| rootfs 预置 WiFi 名称     | 默认空（留空不预置）                                                                                                                                     |
| rootfs 预置 WiFi 密码     | 默认空（留空不预置）                                                                                                                                     |
| 汇总产物                  | 默认打勾 汇总产物并做 Release 前的收尾  rootfs-sparse 在 rootfs job 里已 pigz 压缩（1.7G -> ~730M）单文件超 2GB 自动分卷成 .gz.part-00 / .gz.part-01 ... |
| 发布 Release              | 默认打勾，发布到 GitHub Release（永久资源，不过期）                                                                                                      |
| 构建完成推送通知          | 默认打勾，推送构建完成通知                                                                                                                               |

## 产物说明

| 产物                        | 说明                |
| --------------------------- | ------------------- |
| boot-<时间戳>.img           | 内核 boot 镜像      |
| Image-<时间戳>.gz           | kernel image        |
| initramfs-<时间戳>.cpio.lz4 | initramfs image     |
| modules-<时间戳>.tar.gz     | modules image       |
| rootfs-sparse-<时间戳>.img  | rootfs-sparse image |

## postmarketos wiki 上的构建命令

### Build custom initramfs

```bash
git clone https://github.com/MT6895-Mainline/initramfs
cd initramfs
make clean
make # BOOT_PARTITION=\"/dev/sdc86\" NVDATA_PARTITION=\"/dev/sdc13\"
# Default BOOT_PARTITION is /dev/sdc86. On xaga it's userdata.
# Default NVDATA_PARTITION is /dev/sdc13. On xaga it's nvdata. Init will mount and copy WIFI/Bluetooth configuration from nvdata.
ls -l initramfs.cpio.lz4
```

### Build kernel

```bash
# Merge config
ARCH=arm64 scripts/kconfig/merge_config.sh arch/arm64/configs/defconfig arch/arm64/configs/xaga.config
make ARCH=arm64 LLVM=1 olddefconfig

# Build kernel image and dtb
make ARCH=arm64 LLVM=1 -j"$(nproc --all)" Image

# Pack boot image
gzip -n -9 -c arch/arm64/boot/Image > "tmp/Image.gz"
mkbootimage --kernel "tmp/Image.gz" --ramdisk initramfs/initramfs.coio.lz4 \
    --base 0x3fff8000 --kernel_offset 0x8000 --pagesize 4096 \
    --ramdisk_offset 0x26f08000 --tags_offset 0x07c88000 --dtb_offset 0x07c88000 \
    --header_version 4 --os_version 16.0.0 --os_patch_level 2026-08 \
    -o "tmp/boot.img"

```

### Install userspace hacks

```bash
# On device
git clone https://github.com/MT6895-Mainline/quirks
cd quirks

# Sound configuration
cp -r ucm/mt6895-mt6368 /usr/share/alsa/ucm2/conf.d/

# Microphone built-in/headset auto switch
# On xaga, built in mic and 3.5mm headset are connected to the same pipe, they can't record stereo stream at same time. Instead of patching UCM, leave one "Built-in Microphone" device and switch routing in a daemon.
gcc -O2 -Wall -o xaga-mic-switch mic/xaga-mic-switch.c -lasound
mv xaga-mic-switch /usr/local/sbin/xaga-mic-switch
cp -r mic/xaga-mic-switch.service /etc/systemd/system/xaga-mic-switch.service
systemctl daemon-reload
systemctl enable --now xaga-mic-switch.servic
```

### Boot镜像头部参数

必须与 postmarketOS wiki中Pack boot image中的一致，别乱改

```bash
KERNEL_BASE: '0x3fff8000'
KERNEL_OFFSET: '0x8000'
PAGESIZE: '4096'
RAMDISK_OFFSET: '0x26f08000'
TAGS_OFFSET: '0x07c88000'
DTB_OFFSET: '0x07c88000'
HEADER_VERSION: '4'
OS_VERSION: '16.0.0'
OS_PATCH_LEVEL: '2026-08'
```

## 使用方法

### 1. 触发构建

仓库页面 → **Actions** → 选择 **Build Boot** → 点击 **Run workflow**→填写参数，开始构建

### 2. 下载产物

构建成功后, 在Release下载需要的构建产物

### 3. 刷写

```bash
# 检查设备连接状态
fastboot devices

# 刷内核 (boot 分区)
fastboot flash boot boot-physical.img

# 刷 rootfs-sparse (rootfs 分区)
fastboot flash rootfs rootfs-sparse-physical.img

# 重启设备
fastboot reboot
```

### 4. 清理缓存

当编译异常或缓存冲突时, Actions → **Clean Cache** → Run workflow, 一键清空全部缓存

## 通知功能配置

仓库 → Settings → Secrets and variables → Actions → New repository secret:

| Secret 名称        | 说明                                  | 是否必需 |
| ------------------ | ------------------------------------- | -------- |
| `MEOW_WEBHOOK`   | 喵提醒机器人 Webhook 完整地址         | 可选     |
| `MEOW_SECRET`    | 喵提醒机器人加签密钥                  | 可选     |
| `SERVERCHAN_KEY` | Server酱 SendKey (sct开头, 推微信/QQ) | 可选     |

> `GITHUB_TOKEN` 由 Actions 自动注入, 无需手动配置。

### 喵提醒配置

1. 喵提醒 → 添加机器人 → 自定义
2. 安全设置选择 **加签**, 复制密钥填入 `MEOW_SECRET`
3. 复制 Webhook 地址填入 `MEOW_WEBHOOK`

### Server酱配置

1. 访问 [sct.ftqq.com](https://sct.ftqq.com), 微信扫码登录
2. 复制 SendKey 填入 `SERVERCHAN_KEY`
3. 可在 Server酱后台绑定 QQ 推送通道

## bot.py 用法

```bash
# 发送构建通知 (Actions 中自动调用)
python3 bot.py --notify --status success --artifact-url <构建记录URL>

# 检测上游内核更新
python3 bot.py --check-update

# 检测更新并自动触发构建
python3 bot.py --check-update --auto-build

# 检测更新, 提交补丁记录并触发构建
python3 bot.py --check-update --auto-build --commit-patch
```

可配合定时任务 (schedule) 实现每日自动检测上游更新:

```yaml
# 在 Build.yml 中追加
on:
  schedule:
    - cron: '0 0 * * *'  # 每天 UTC 00:00 检测
```

## 本地构建脚本

在本机linux上编译使用的构建脚本，参数与 `.github/workflows/build.yml` 的 `workflow_dispatch`
输入一一对应。**项目根目录 = 脚本所在目录**，不含任何硬编码绝对路径，整个目录拷到哪都能跑。

### 用法

```bash
# 交互式：不带参数直接跑（推荐）
./build-mainline.sh              # 构建 boot 镜像（内核 + initramfs + 打包）
sudo ./build-rootfs.sh           # 构建 rootfs（要 root：loop 挂载 + chroot）

# 非交互：命令行参数覆盖（写了参数就不再问答）
./build-mainline.sh --branch 6.18-mt6895-xiaomi-xaga --no-modules
sudo ./build-rootfs.sh --distro ubuntu --size 10 --hostname xaga --ssid MyWifi

# SSH 容易断：加 --tmux，脚本把自己丢进后台会话，跑完推通知
./build-mainline.sh -i --tmux
tmux attach -t xaga-build        # 看进度；Ctrl-b d 安全脱离（不会中断构建）
```

**交互规则**（与 GitHub 表单一一对应）：

| 表单控件         | 怎么输                                                         |
| ---------------- | -------------------------------------------------------------- |
| 打勾（boolean）  | `y` / `n`，直接回车用默认值                                |
| 文本框（string） | 直接输入，直接回车用默认值                                     |
| 下拉（choice）   | 输序号 `1` / `2` / `3`…，直接回车用带 `<默认>` 的那项 |

### 脚本编译时的项目结构

```
xaga-mt6895-mainline-build/        # 根目录 = 脚本所在目录（没有硬编码路径）
├── build-mainline.sh              # 内核 + initramfs + boot.img
├── build-rootfs.sh                # rootfs 镜像（要 root 权限）
├── .github/
│   ├── bot-offline.py             # 本地通知（宏定义在文件顶部）
│   └── workflows/
│       ├── build.yml              # CI 主编译工作流
│       └── clean.yml              # 缓存清理工作流
├── linux/                         # 内核源码（有 .git 就不重复 clone）
├── initramfs/                     # MT6895-Mainline/initramfs（同上）
├── mktools/                       # mkbootimg 打包器，没有就装到这里
│   ├── bin/mkbootimg              # C 版（osm0sis，只有 v3，冒烟会拦下）
│   └── aosp/mkbootimg.py          # AOSP 官方版（自动 clone 到这里）
├── cache/                         # Arch tarball / debootstrap 包缓存
├── build-rootfs/<distro>/         # rootfs 工作目录（文件树 + 中间镜像）
│   └── rootfs/.xaga-ready         # 有这个标记就跳过重新构建
├── rootfs/                        # rootfs 最终产物
│   ├── Arch Linux/
│   ├── Debian 13/
│   └── Ubuntu 26.04 LTS/
├── out/                           # boot 产物：boot-<ts>.img / Image-<ts>.gz
│                                  # initramfs-<ts>.cpio.lz4 / modules-<ts>.tar.gz
│                                  # reuse-<RUNS ID>/  (复用 GH 产物时下载到这里)
└── logs/                          # 构建日志（通知会附末尾 40 行）
```

### build-mainline.sh 构建（内核 + 打包boot 镜像）

| build.yml 参数                 | 脚本宏定义 / 命令行                      | 交互提问                                | 默认           |
| ------------------------------ | ---------------------------------------- | --------------------------------------- | -------------- |
| `kernel_branch`（下拉）      | `KERNEL_BRANCH` / `--branch`         | 1→ 7.2 功能最新 <br />2→ 6.18 更保守 | 1              |
| `initramfs_userdata`（文本） | `INITRAMFS_USERDATA` / `--userdata`  | 文本框                                  | `/dev/sdc86` |
| `initramfs_nvdata`（文本）   | `INITRAMFS_NVDATA` / `--nvdata`      | 文本框                                  | `/dev/sdc13` |
| `build_kernel`（打勾）       | `BUILD_KERNEL` / `--no-kernel`       | y/n                                     | y              |
| `build_initramfs`（打勾）    | `BUILD_INITRAMFS` / `--no-initramfs` | y/n                                     | y              |
| `build_modules`（打勾）      | `BUILD_MODULES` / `--no-modules`     | y/n                                     | y              |
| `reuse_run_id`（文本）       | `REUSE_RUN_ID` / `--reuse-run-id`    | 文本框（留空=复用本地 `./out`）       | 空             |
| `send_notification`（打勾）  | `NOTIFY` / `--no-notify`             | y/n                                     | y              |

本地附加项（CI 上没有）：`--tmux`（后台会话）/ `--session NAME` / `-j N` /
`--update`（强制 fetch 上游）/ `--clean` / `--out DIR` / `--root DIR` / `--repo OWNER/REPO`（配合复用 RUNS ID）。

- **不重复下载**：`linux/`、`initramfs/` 有 `.git` 就只切分支不 clone，只有 `--update` 才 fetch；
  关掉 `build_kernel` 时连源码都不拉
- **打包器**：优先 `./mktools/bin/mkbootimg` → `./mktools/**/mkbootimg.py` → 有 Makefile 就 `make`
  → 都没有就 `git clone` AOSP 官方版到 **`./mktools/aosp`**（并补一个 `gki.py` stub）。
  每个候选都**先真打一个最小包冒烟验头部**，不是 `header_version=4` + `header_size=1584` 就换下一个，
  全都不行才报错 —— 避免编完 20 分钟才发现 osm0sis 的 C 版只到 v3（恒 1580）
- 打包参数照 wiki 硬编码（`--base 0x3fff8000` … `--os_patch_level 2026-08`），**不传 `--dtb`**
  （DTB 已 objcopy 链进 vmlinux）
- 打完强制跑 `bot-offline.py --verify-bootimg`，头部不合法直接判死
- `--tmux`：`tmux new-session -d` 自举（`XAGA_IN_TMUX` 防套娃）+ `tee` 落日志，
  跑完调 bot-offline.py 推通知到手机；ERR trap 在失败时也会推通知

### build-rootfs.sh 构建（rootfs 镜像，并只有 root用户）

| build.yml 参数                    | 脚本宏定义 / 命令行            | 交互提问                                                                     | 默认     |
| --------------------------------- | ------------------------------ | ---------------------------------------------------------------------------- | -------- |
| `rootfs_distro`（下拉）         | `DISTRO` / `--distro`      | 1→Arch Linux <br />2→Debian 13 <br />3→ Ubuntu 26.04 LTS                  | 3        |
| `arch_desktop`（下拉）          | `DESKTOP` / `--desktop`    | 1→ KDE <br />2→不装桌面<br /> 3→Phosh<br /> 4→Sway（选 arch linux 才有） | 1        |
| `rootfs_size`（文本）           | `SIZE` / `--size`          | 文本框（纯数字 GB）                                                          | `6`    |
| `rootfs_hostname`（文本）       | `HOSTNAME` / `--hostname`  | 文本框                                                                       | `xaga` |
| `rootfs_root_password`（文本）  | `ROOTPASS` / `--password`  | 文本框                                                                       | `root` |
| `rootfs_extra_packages`（文本） | `EXTRA_PKGS` / `--extra`   | 文本框（空格分隔）                                                           | 空       |
| `wifi_ssid`（文本）             | `SSID` / `--ssid`          | 文本框（留空不预置）                                                         | 空       |
| `wifi_password`（文本）         | `WIFI_PSK` / `--wifi-pass` | 填了 SSID 才问                                                               | 空       |
| `send_notification`（打勾）     | `NOTIFY` / `--no-notify`   | y/n                                                                          | y        |

本地附加项：`--tmux` / `--session NAME` / `--force`（忽略缓存重下重建）/ `--out DIR` / `--root DIR`。

- **不重复下载**：Arch tarball 缓存在 `./cache`；debootstrap 走 `--cache-dir=./cache/deb-<suite>`
  （装不上缓存就退化重试）；文件树有 `.xaga-ready` 标记就跳过（`--force` 强制重建）
- 只有 **root 用户**，不创建普通用户；主机名 / root 密码 / WiFi / 额外包 / mediatek 固件都在 chroot 里装
- `img2simg` 转 sparse → `pigz -9 -k` → 单文件超 2GB 自动 `split` 成 `.gz.part-00`
- 产物输出到 `./rootfs/'Arch Linux'`、`'Debian 13'`、`'Ubuntu 26.04 LTS'`

### 只在 CI 上有的参数怎么对应

| build.yml 参数                                | 本地对应                                                                                             |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `build_target`<br />（boot / rootfs / all） | 本地是两个脚本：只跑 `build-mainline.sh` = boot，只跑 `build-rootfs.sh` = rootfs，两个都跑 = all |
| `collect_artifacts`                         | 本地产物本来就在 `./out` 和 `./rootfs/<发行版>` 下，不需要汇总                                   |
| `publish_release`                           | 本地不发 Release；要发就自己 `gh release create build-<ts> ./out/*`                                |

### .github/bot-offline.py（本地通知，不查上游）

通知配置就是文件顶部那块**宏定义**，改完直接生效（环境变量可临时覆盖，方便测试）

```python
MEOW_ENABLED = True
MEOW_WEBHOOK = ""      # 喵提醒 webhook
MEOW_SECRET  = ""      # 加签密钥
SERVERCHAN_ENABLED = True
SERVERCHAN_KEY = ""    # sct 开头
TITLE_PREFIX = "[xaga 本地编译]"; LOG_TAIL_LINES = 40
TMUX_SESSION = "xaga-build"; TMUX_POLL_INTERVAL = 10
```

子命令：

- notify（带 --log 时自动附末尾 40 行日志）
- watch-tmux <会话>（轮询到会话没了就推，可用 --status-file 读真实成败）
- verify-bootimg
- test 没填密钥只 warn，不影响构建

```bash
python3 .github/bot-offline.py --test                         # 验证配置
python3 .github/bot-offline.py --verify-bootimg out/boot-*.img
python3 .github/bot-offline.py --watch-tmux xaga-build --log logs/build-mainline-<ts>.log
```

### 本地编译的前置依赖

```bash
sudo apt-get update
sudo apt-get install -y clang llvm lld gcc-aarch64-linux-gnu lz4 git tmux \
     qemu-user-static debootstrap libarchive-tools android-sdk-libsparse-utils \
     pigz rsync e2fsprogs wget python3
```

## 注意事项

1. **必须解锁 Bootloader** 才能刷入自定义 boot.img
2. `fastboot flash userdata` 会彻底清除安卓用户数据, 操作前务必备份
3. 官方 initramfs 当前原生仅支持物理分区挂载, Loop 双系统需自行修改 init.c
4. 救砖: fastboot 刷回原厂 boot.img; 若 userdata 已覆盖需 MiFlash 线刷整机
5. **卡第一 logo 不停重启**: 先查内核 `.config` 里的 `CONFIG_INITRAMFS_FORCE`为 `y` 时内核会**直接跳过 boot.img 里的 initramfs**
   (`init/initramfs.c`: `if (!initrd_start || IS_ENABLED(CONFIG_INITRAMFS_FORCE)) goto done;`),而 xaga 的 `CONFIG_CMDLINE_FORCE=y` 内置 cmdline 里又没有 `root=`,结果必然是 `VFS: Unable to mount root fs` -> panic -> 重启, 与 rootfs 新旧无关。上游在 09-20 的 VCP merge (`b311b740b3`) 里误开了这一项, 09-22 由 `1bd83bb58a` 关掉。build.yml 在 `olddefconfig` 之后加了断言: 检测到就 `::error::` 直接 fail, 不会把砖编出来。与 6+128 / 8+256 版本无关, 所有配置都会中。

## 技术栈

- 编译: Clang-18 / LLVM / LLD (全 LLVM 工具链)
- 打包: osm0sis mkbootimg (兼容 MTK 原厂 LK)
- 通知: 喵提醒 / Server酱
- 缓存: actions/cache (内核 obj + 编译缓存)
