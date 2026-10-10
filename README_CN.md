<!-- 📦 本段由 sync-to-gitee.sh 自动生成，请勿手动编辑 -->

## 📦 Gitee 快照镜像

本仓库是 [LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico) 的国内加速镜像（仅最新代码、无提交历史），同步自上游 `824b817f`（2026-03-22）。

受 Gitee 单仓库容量限制，`tools/`（交叉编译工具链、烧录工具）拆分为独立仓库，并以 git 子模块挂回本仓库。克隆时加 `--recursive`，tools 会自动放到原位：

```bash
git clone --recursive https://gitee.com/LuckfoxTECH/luckfox-pico.git
```

已克隆过的仓库，补一次子模块：

```bash
cd luckfox-pico
git submodule update --init
```

> 完整原始仓库请访问上游 GitHub。

---

# QZdesk SDK (RV1106)

基于 Luckfox 的 **RV1106** SDK。它是 **QZdesk**（桌面）和 **QZcam**（相机）的依赖：
板级配置、驱动补丁、媒体库，以及一条命令出固件。

[English](./README.md) · 上游文档：[LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico)

## 板级

| 项 | 值 |
|---|---|
| 芯片 | RV1106G（Cortex-A7 + NPU），66 MB CMA |
| 存储 | SPI NAND —— `oem` / `userdata` / `rootfs` 都是 `ubifs` |
| 内核 DTS | `rv1106g-qzdesk.dts` |
| WiFi | RTL8723BS |
| 相机 | SC3336 / SC4336（IQ 文件随固件打进去） |

板级配置在 `project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_QZdesk-DeskMate.mk`，
同目录另有一份 SD 卡变体。

## 取代码

```bash
git clone --recursive https://github.com/QZzwj/QZSDK.git
cd QZSDK
git submodule update --init        # tools/ = 交叉工具链 + 烧录工具
```

`.BoardConfig.mk` 不入库，克隆后先选一次板级：

```bash
ln -s project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_QZdesk-DeskMate.mk .BoardConfig.mk
# 或者交互式选：./build.sh lunch
```

> **QZdesk**（桌面）和 **QZcam**（相机）是各自独立的仓库，通过 `project/app/*/src` 软链挂进来；
> 这个 SDK 给它们提供交叉工具链、内核/rootfs，以及装进去的 `oem` 树。没有它们时，只有 SDK
> 自带的那几个 app（`rkipc`、`uvc_app_tiny` 等）能编。

## 编译

```bash
# 1) 交叉工具链进 PATH
cd tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf && source env_install_toolchain.sh

# 2) 一键编译（u-boot + kernel + rootfs + media + apps）
./build.sh

# 只重编某一层，然后重新打包
./build.sh clean app && ./build.sh app && ./build.sh firmware
```

主机依赖（Ubuntu 22.04）：`git ssh make gcc gcc-multilib g++-multilib module-assistant expect g++ gawk texinfo libssl-dev bison flex fakeroot cmake unzip gperf autoconf device-tree-compiler libncurses5-dev pkg-config bc python-is-python3 passwd openssl openssh-server openssh-client vim file cpio rsync`

## 固件

`tools/build/build_image.sh` 是发布固件的唯一入口 —— 编译、装进 `oem` 树、打包并校验 `update.img`：

```bash
tools/build/build_image.sh --cam              # 摄像头端：QZcam，不含 QZdesk 桌面
tools/build/build_image.sh --desk             # 桌面端：QZdesk，不含 QZcam
tools/build/build_image.sh --cam --app-only   # 只编译+装进 oem 树，不打包
tools/build/build_image.sh --cam --skip-sysdrv
```

产物：`output/image/update-cam.img` / `output/image/update-desk.img`。

一个镜像里**只能有一套界面程序** —— 两套都在会抢同一个 framebuffer。脚本在五层做硬隔离
（构建入口、app 暂存、rootfs 打包、依赖裁剪、最终校验），任何一层不过就停机。

## 推送到板子上调试

```bash
tools/build/deploy_qzcam.sh            # adb 推程序+自启脚本+模块，然后重启
tools/build/deploy_qzcam.sh --build    # 先跑 ./build.sh app
tools/build/deploy_qzcam.sh --doctor   # 板上相机体检
tools/build/deploy_qzcam.sh --status   # 或 --log [秒] 盯日志
```

## 烧录

| 主机 | 工具 |
|---|---|
| Windows | `tools/windows/` —— DriverAssitant（装驱动）+ SocToolKit / FactoryTool |
| Linux | `tools/linux/Linux_Upgrade_Tool` |

历史发布镜像归档在 `IMAGE/`。

## 目录

| 路径 | 说明 |
|---|---|
| `project/build.sh` | 顶层编译入口 |
| `project/app/` | 应用：`qzcam`、`qzdesk`、`rkipc`、`rk_smart_door`、`uvc_app_tiny`、`wifi_app` |
| `project/cfg/` | 板级配置 |
| `media/` | Rockchip 媒体库与样例（rockit / rkadk / mpp） |
| `sysdrv/` | u-boot、kernel、buildroot rootfs |
| `tools/` | 工具链与烧录工具（git 子模块） |
| `output/out/` | 编译中间产物（`app_out`、`media_out`、`oem`、`rootfs_*`） |
| `IMAGE/` | 历史发布镜像归档 |

## 文档

- 编译 / 烧录 / 调试细节：上游 [LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico)
- 更新日志：[UPDATE_LOG_CN.md](./UPDATE_LOG_CN.md) · [English](./UPDATE_LOG.md)
