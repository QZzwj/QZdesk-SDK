#
# QZcam 相机固件（LVGL 界面 + V4L2 取景）
#
# 与 SDK 里其它 app 的差别：源码不复制进 SDK，而是用软链接指回开发目录
#   src/ -> /home/jn/QZdesk/QZcam
# 所以在开发目录改完代码，直接 ./build.sh app 就是最新代码，不存在两份。
#
# 产物落点：
#   out/bin/qzcam                    -> oem 分区 /oem/usr/bin
#   out/usr/share/fonts/             -> oem 分区 /oem/usr/share/fonts
#   out/lib/camera/*.ko              -> oem 分区 /oem/usr/lib/camera
#   out/etc/init.d/S30qzcam          -> oem 分区 /oem/usr/etc/init.d（RkLunch 跑）
#   out/root/etc/init.d/S30qzcam     -> rootfs /etc/init.d（rcS 直接跑）
#
ifeq ($(APP_PARAM), )
    APP_PARAM:=../Makefile.param
    include $(APP_PARAM)
endif

export LC_ALL=C
SHELL:=/bin/bash

CURRENT_DIR := $(shell pwd)

PKG_NAME := qzcam
PKG_BIN ?= out
PKG_BUILD ?= build

ifeq ($(PKG_BIN),)
$(error ### $(CURRENT_DIR): PKG_BIN is NULL, Please Check !!!)
endif

PKG_TOOLCHAIN_SYSROOT := $(shell $(RK_APP_CROSS)-gcc -print-sysroot)

# Rockchip 媒体库与 ISP 的 IQ 文件（SDK media 的产物，即 xxx/output/out/media_out）：
#   - 编译期：cam_isp.c 需要 rk_mpi_vi.h / rkaiq uAPI 头，并链 librkaiq/librockit
#   - 运行期：这些 .so 与 IQ 文件都必须进镜像，否则板上的 rkaiq 起不来（或拿
#     默认参数跑 → 偏色、偏绿）。所以下面既传给 cmake，也 install 到 oem/rootfs。
QZCAM_MEDIA ?= $(RK_PROJECT_PATH_MEDIA)

# -mfpu/-mfloat-abi 由 Makefile.param 按工具链给（RV1106 是 neon + hard float）
QZCAM_CFLAGS := -O2 $(RK_APP_CROSS_CFLAGS) $(RK_APP_OPTS)

PKG_CONF_OPTS += -DCMAKE_BUILD_TYPE=Release
PKG_CONF_OPTS += -DCMAKE_SYSTEM_NAME=Linux
PKG_CONF_OPTS += -DCMAKE_C_COMPILER=$(RK_APP_CROSS)-gcc
PKG_CONF_OPTS += -DCMAKE_CXX_COMPILER=$(RK_APP_CROSS)-g++
PKG_CONF_OPTS += -DCMAKE_SYSROOT="$(PKG_TOOLCHAIN_SYSROOT)"
PKG_CONF_OPTS += -DCMAKE_FIND_ROOT_PATH="$(PKG_TOOLCHAIN_SYSROOT)"
PKG_CONF_OPTS += -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
PKG_CONF_OPTS += -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
PKG_CONF_OPTS += -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
PKG_CONF_OPTS += -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
PKG_CONF_OPTS += -DCMAKE_C_FLAGS="$(QZCAM_CFLAGS)"
PKG_CONF_OPTS += -DCMAKE_CXX_FLAGS="$(QZCAM_CFLAGS)"
# 真机没有 SDL，走 fbdev + evdev
PKG_CONF_OPTS += -DQZCAM_SIMULATOR=OFF
# ISP 取景（rkaiq + RKMPI）：给 cmake 头文件与库的位置，并打开 QZCAM_HAVE_MEDIA
PKG_CONF_OPTS += -DQZCAM_MEDIA_DIR="$(QZCAM_MEDIA)"

all: qzcam-build
	@echo "build $(PKG_NAME) done"

qzcam-build:
	@echo "RK_APP_TYPE is $(RK_APP_TYPE)  toolchain: $(RK_APP_CROSS)"
	mkdir -p $(PKG_BUILD) \
	         $(PKG_BIN)/bin \
	         $(PKG_BIN)/usr/share/fonts \
	         $(PKG_BIN)/etc/init.d \
	         $(PKG_BIN)/root/etc/init.d \
	         $(PKG_BIN)/lib/camera
	@# 不整目录删：一是让 cmake 增量编译（快得多），二是环境里的删文件保护会拦
	@# 大规模 rm。只在源码路径变了时丢掉缓存，避免用旧的 CMake 配置。
	@if [ -f $(PKG_BUILD)/CMakeCache.txt ] && ! grep -q "$(CURRENT_DIR)/src" $(PKG_BUILD)/CMakeCache.txt; then \
		rm -f $(PKG_BUILD)/CMakeCache.txt; \
	fi
	pushd $(PKG_BUILD)/; \
		cmake $(CURRENT_DIR)/src $(PKG_CONF_OPTS) || exit -1; \
		make -j$(RK_APP_JOBS) || exit -1; \
	popd;
	$(RK_APP_CROSS)-strip -s $(PKG_BUILD)/qzcam
	install -m 0755 $(PKG_BUILD)/qzcam $(PKG_BIN)/bin/
	# 中文字体：界面文案全靠它（缺了会退回 ASCII，中文变方框）
	install -m 0644 $(CURRENT_DIR)/src/assets/NanoTikBazHei-Bold.ttf $(PKG_BIN)/usr/share/fonts/ 2>/dev/null || \
		install -m 0644 /home/jn/QZdesk/NanoTikBazHei-Bold.ttf $(PKG_BIN)/usr/share/fonts/
	# 设备脚本就放在本 app 目录里（与 SDK/project/app/qzdesk/S30qzdesk 同一约定），
	# 不再依赖开发仓库 —— 脚本是唯一来源，仓库侧只有软链。
	install -m 0755 $(CURRENT_DIR)/S30qzcam $(PKG_BIN)/etc/init.d/
	install -m 0755 $(CURRENT_DIR)/S30qzcam $(PKG_BIN)/root/etc/init.d/
	@# uitap：虚拟触摸屏守护（远程桌面/自动化测试的注入通道，必须进固件 ——
	@# 之前只放板子 /tmp，一刷机就丢，症状是"点了没反应"）。
	install -d $(PKG_BIN)/usr/bin
	$(RK_APP_CROSS)-gcc $(QZCAM_CFLAGS) -o $(PKG_BIN)/usr/bin/uitap \
		$(CURRENT_DIR)/src/tools/device/uitap.c
	$(RK_APP_CROSS)-strip -s $(PKG_BIN)/usr/bin/uitap
	@# uinput 内核模块：uitap 的依赖（打包流程不带它，与相机模块同理）
	install -m 0644 $(CURRENT_DIR)/files/uinput.ko $(PKG_BIN)/lib/camera/ 2>/dev/null || true
	# 桌面接管脚本：随镜像装到 oem，开机由 S30qzcam 调用（--boot），
	# 烧录后也能手动跑一次把 QZdesk 替换成 QZcam，不必重刷。
	install -d $(PKG_BIN)/usr/share/qzcam
	install -m 0755 $(CURRENT_DIR)/replace_desktop.sh $(PKG_BIN)/usr/share/qzcam/
	install -m 0755 $(CURRENT_DIR)/camera_doctor.sh $(PKG_BIN)/usr/share/qzcam/
	# 三条出图路径的实机验证（LCD / V4L2 / RTSP / UVC）
	install -m 0755 $(CURRENT_DIR)/camera_paths_test.sh $(PKG_BIN)/usr/share/qzcam/
	# 相机 / ISP 驱动模块（SC3336 + rkcif + rkisp）：镜像内核编成了模块，但打包流程
	# 不带进 rootfs，所以随 QZcam 装到 oem，由 S30qzcam 在起相机前 insmod。
	install -d $(PKG_BIN)/lib/camera
	for ko in rk_dvbm video_rkcif video_rkisp phy-rockchip-csi2-dphy-hw \
			phy-rockchip-csi2-dphy sc3336 rockit mpp_vcodec rga3; do \
		install -m 0644 $$(ls $(RK_PROJECT_PATH_SYSDRV)/kernel_drv_ko/$$ko.ko 2>/dev/null || \
			echo $(CURRENT_DIR)/../../../sysdrv/out/kernel_drv_ko/$$ko.ko) $(PKG_BIN)/lib/camera/ 2>/dev/null || true; \
	done
	@# rockit.ko 要按路径加载 MCU 固件，缺了它 insmod 会失败
	install -m 0644 $$(ls $(RK_PROJECT_PATH_SYSDRV)/kernel_drv_ko/hpmcu_wrap.bin 2>/dev/null || \
		echo $(CURRENT_DIR)/../../../sysdrv/out/kernel_drv_ko/hpmcu_wrap.bin) $(PKG_BIN)/lib/camera/ 2>/dev/null || true
	@# Rockchip 运行库：rkaiq(ISP 3A) / rockit(MPI) / rga —— cam_isp 取景全靠它们；
	@# rockit 用 full 版（多出回放要的 VDEC）；rkmuxer/rkdemuxer 是硬编码录像的
	@# MP4 封装与回放拆包。libdrm.so.2 是 rockit_full 的依赖（libz.so.1 是
	@# rkdemuxer 的依赖，rootfs 已带，不用重复装）。
	install -d $(PKG_BIN)/usr/lib
	for so in librkaiq.so librockit_full.so librga.so librkmuxer.so librkdemuxer.so \
			libdrm.so.2; do \
		install -m 0755 $(QZCAM_MEDIA)/lib/$$so $(PKG_BIN)/usr/lib/ 2>/dev/null || true; \
	done
	@# librockchip_mpp 是软链套（.so -> .so.1 -> .so.0），整套拷，别拷成断链
	cp -a $(QZCAM_MEDIA)/lib/librockchip_mpp.so* $(PKG_BIN)/usr/lib/ 2>/dev/null || true
	@# libjpeg：拍照编码 + 看图缩放解码（QZCAM_HAVE_JPEG）都靠它。它不在 media_out
	@# 里，在上层 component 的 third_libs —— 少了它 qzcam 连启动都过不去（动态链接
	@# 期就找不到 libjpeg.so.9），所以这个包必须自带，别指望别的 app 带。
	for d in $(QZCAM_MEDIA)/lib $(CURRENT_DIR)/../component/third_libs/lib/arm-rockchip830-linux-uclibcgnueabihf; do \
		install -m 0755 $$d/libjpeg.so.9 $(PKG_BIN)/usr/lib/ 2>/dev/null && break; \
	done
	@# ISP 的 IQ 文件：rkaiq 按 sensor 名在 /etc/iqfiles 里找 json/bin（+CAC 标定）。
	@# 少了它 3A 会退回默认参数跑 —— 现象就是"出图但偏色/偏绿"。
	@# 注意：/etc/iqfiles 在 rootfs 里是指向 ../oem/usr/share/iqfiles 的软链，
	@# 所以只往 oem 装（往 rootfs 再装一份会与软链打架，没有意义）。
	install -d $(PKG_BIN)/usr/share/iqfiles
	install -m 0644 $(QZCAM_MEDIA)/isp_iqfiles/sc3336_CMK-OT2119-PC1_30IRC-F16.json $(PKG_BIN)/usr/share/iqfiles/ 2>/dev/null || true
	install -m 0644 $(QZCAM_MEDIA)/isp_iqfiles/sc3336_CMK-OT2119-PC1_30IRC-F16.bin $(PKG_BIN)/usr/share/iqfiles/ 2>/dev/null || true
	cp -a $(QZCAM_MEDIA)/isp_iqfiles/CAC_sc3336_CMK-OT2119-PC1_30IRC-F16 $(PKG_BIN)/usr/share/iqfiles/ 2>/dev/null || true
	@# 高速模式（640x480@75fps，LuckfoxTECH/luckfox-pico#67 的社区驱动）：
	@# sc3336_75.ko 与 stock sc3336.ko 同名同接口，二选一加载；两份 IQ 都装，
	@# S30qzcam 开机按 /oem/usr/etc/qzcam-hispeed 标记把对应那份摆到标准名。
	install -m 0644 $(CURRENT_DIR)/files/sc3336_hispeed.ko $(PKG_BIN)/lib/camera/sc3336_75.ko 2>/dev/null || true
	install -m 0644 $(CURRENT_DIR)/files/sc3336_CMK-OT2119-PC1_30IRC-F16.hispeed.json $(PKG_BIN)/usr/share/iqfiles/ 2>/dev/null || true
	install -m 0644 $(QZCAM_MEDIA)/isp_iqfiles/sc3336_CMK-OT2119-PC1_30IRC-F16.json \
		$(PKG_BIN)/usr/share/iqfiles/sc3336_30fps.json 2>/dev/null || true
	$(call MAROC_COPY_PKG_TO_APP_OUTPUT, $(RK_APP_OUTPUT), $(PKG_BIN))
	@echo "QZcam 已就绪：$(PKG_BIN)/bin/qzcam"

clean:
	@find $(PKG_BIN) $(PKG_BUILD) -mindepth 1 -delete 2>/dev/null || true
	@echo "已清理 $(PKG_BIN) 与 $(PKG_BUILD)"

distclean: clean

info:
	@echo "RK_APP_TYPE=$(RK_APP_TYPE)"
	@echo "cross      = $(RK_APP_CROSS)"
	@echo "crossflags = $(RK_APP_CROSS_CFLAGS)"
	@echo "sysroot    = $(PKG_TOOLCHAIN_SYSROOT)"
	@echo "app output = $(RK_APP_OUTPUT)"
