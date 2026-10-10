# QZdesk SDK (RV1106)

Based on the Luckfox Pico **RV1106** SDK. This is the SDK that **QZdesk** (desktop) and
**QZcam** (camera) depend on: board config, driver patches, media libraries, and a
one-command firmware pipeline.

[简体中文](./README_CN.md) · Upstream docs: [LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico)

## Board

| Item | Value |
|---|---|
| SoC | RV1106G (Cortex-A7 + NPU), 66 MB CMA |
| Flash | SPI NAND — `ubifs` for `oem` / `userdata` / `rootfs` |
| Kernel DTS | `rv1106g-qzdesk.dts` |
| WiFi | RTL8723BS |
| Camera | SC3336 / SC4336 (IQ files ship inside the image) |

Board config lives in `project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_QZdesk-DeskMate.mk`
(a second SD-card variant exists next to it).

## Get the code

```bash
git clone --recursive https://github.com/QZzwj/QZSDK.git
cd QZSDK
git submodule update --init        # tools/ = cross toolchain + flashing tools
```

`.BoardConfig.mk` is not tracked, so pick the board once after cloning:

```bash
ln -s project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_QZdesk-DeskMate.mk .BoardConfig.mk
# or interactively:  ./build.sh lunch
```

> **QZdesk** (desktop) and **QZcam** (camera) are separate repos, linked in as
> `project/app/*/src` — this SDK provides their cross toolchain, kernel/rootfs and the `oem`
> tree they install into. Without them only the SDK-side apps (`rkipc`, `uvc_app_tiny`, …) build.

## Build

```bash
# 1) cross toolchain on PATH
cd tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf && source env_install_toolchain.sh

# 2) one-shot build (u-boot + kernel + rootfs + media + apps)
./build.sh

# rebuild a single layer, then repackage
./build.sh clean app && ./build.sh app && ./build.sh firmware
```

Host deps (Ubuntu 22.04): `git ssh make gcc gcc-multilib g++-multilib module-assistant expect g++ gawk texinfo libssl-dev bison flex fakeroot cmake unzip gperf autoconf device-tree-compiler libncurses5-dev pkg-config bc python-is-python3 passwd openssl openssh-server openssh-client vim file cpio rsync`

## Firmware

`tools/build/build_image.sh` is the single entry point for release images — it builds,
installs into the `oem` tree, packages and verifies `update.img`:

```bash
tools/build/build_image.sh --cam              # camera image: QZcam, no QZdesk desktop
tools/build/build_image.sh --desk             # desktop image: QZdesk, no QZcam
tools/build/build_image.sh --cam --app-only   # compile + install into oem, don't package
tools/build/build_image.sh --cam --skip-sysdrv
```

Output: `output/image/update-cam.img` / `output/image/update-desk.img`.

Only **one** UI app may live in an image — two of them fight over the framebuffer. The
script enforces that in five layers (build entry, app staging, rootfs packaging, dependency
pruning, final check) and stops on the first violation.

## Iterate on a live board

```bash
tools/build/deploy_qzcam.sh            # adb-push binary + init script + modules, then reboot
tools/build/deploy_qzcam.sh --build    # run ./build.sh app first
tools/build/deploy_qzcam.sh --doctor   # camera self-check on the device
tools/build/deploy_qzcam.sh --status   # or: --log [seconds]
```

## Flash

| Host | Tool |
|---|---|
| Windows | `tools/windows/` — DriverAssitant (driver) + SocToolKit / FactoryTool |
| Linux | `tools/linux/Linux_Upgrade_Tool` |

Past release images are archived under `IMAGE/`.

## Layout

| Path | What |
|---|---|
| `project/build.sh` | top-level build driver |
| `project/app/` | apps: `qzcam`, `qzdesk`, `rkipc`, `rk_smart_door`, `uvc_app_tiny`, `wifi_app` |
| `project/cfg/` | board configs |
| `media/` | Rockchip media libs and samples (rockit / rkadk / mpp) |
| `sysdrv/` | u-boot, kernel, buildroot rootfs |
| `tools/` | toolchain + flashing tools (git submodule) |
| `output/out/` | build staging (`app_out`, `media_out`, `oem`, `rootfs_*`) |
| `IMAGE/` | archived release images |

## Docs

- Build / flash / debug in depth: upstream [LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico)
- Changelog: [UPDATE_LOG.md](./UPDATE_LOG.md) · [中文更新日志](./UPDATE_LOG_CN.md)
