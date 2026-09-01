`your-repo/
├── .github/
│   └── workflows/
│       └── full-build.yml    # 主构建工作流
└── README.md`

# xaga 主线内核 + postmarketOS 一键构建项目（GitHub Actions）

基于 `MT6895-Mainline/linux` 7.2 分支 + 官方定制 initramfs，实现 **Clang 全链路编译、缓存加速、双系统 Loop 模式（不擦除安卓）** 完整自动化构建。

工作流会自动完成：

1. 拉取内核源码 + 项目专用 initramfs 源码
2. 使用 Clang-18 / LLVM 完整编译主线内核（作者强制要求）
3. 拼接 Image + DTB（绕过 dtbo 限制）
4. 编译 MT6895 专用 initramfs（输出物理分区版 + Loop 双系统版）
5. 下载并处理 postmarketOS generic-aarch64 根文件系统
6. 全程编译缓存加速，大幅缩短二次构建时间
7. 输出两种模式的完整刷机包

## 使用方法

### 部署到你的 GitHub

1. 新建一个空白仓库
2. 创建 `.github/workflows/full-build.yml`，粘贴上面的代码
3. 提交到 main 分支

### 触发构建

1. 仓库页面 → Actions → 选择 `Xaga Mainline + postmarketOS Full Build`
2. 点击 **Run workflow**，选择界面类型（phosh /none/plasma-mobile）
3. 等待构建完成

### 下载产物

构建成功后，在任务页面底部 `Artifacts` 下载 `xaga-mainline-pmos-full.zip`，包含：

表格

| 文件                  | 用途                                        |
| --------------------- | ------------------------------------------- |
| `boot-physical.img` | 覆盖 userdata 模式用，直接刷 boot 分区      |
| `boot-loop.img`     | 双系统 Loop 模式用，刷 boot 分区            |
| `pmos-rootfs.ext4`  | 纯 rootfs 镜像，可直接 fastboot 刷 userdata |
| `rootfs.img`        | Loop 模式用，放到安卓 userdata 目录         |

---

## 两种刷机方案

### 方案 A：覆盖 userdata（简单直接，会清空安卓数据）

```
fastboot flash boot boot-physical.img
fastboot flash userdata pmos-rootfs.ext4
fastboot reboot
```

### 方案 B：Loop 双系统（不擦除安卓，推荐）

1. 安卓下保留系统，root 后在内部存储创建 `pmos` 文件夹
2. 把 `rootfs.img` 放到 `/sdcard/pmos/` 路径下
3. 刷入双系统版 boot：

```
fastboot flash boot boot-loop.img
fastboot reboot
```

4. 开机自动进入 postmarketOS；想切回安卓，直接 fastboot 刷回原厂 boot.img

---

## 注意事项

1. **必须解锁 Bootloader**，否则无法刷入自定义 boot
2. Loop 模式依赖内核 F2FS 驱动，工作流已强制开启
3. 官方 initramfs 若不支持 Loop 参数，需自行修改 `init.c` 增加挂载逻辑
4. 首次进入 pmOS 后执行 `sudo apk add linux-firmware-mediatek` 补全固件
5. 救砖：fastboot 刷回原厂 boot.img；若 userdata 已被覆盖，需 MiFlash 线刷整机
