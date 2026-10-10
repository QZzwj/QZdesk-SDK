#
# QZdesk 桌面（LVGL 界面 + QZdesk 核心服务）
#
# 与 SDK 里其它 app 的一处差别：源码不复制进 SDK，而是用软链接指回开发目录
#   src/       -> /home/jn/QZdesk/QZdesk-Demo      界面 + 核心源码
#   lvgl_test/ -> /home/jn/QZdesk/lvgl_test        LVGL 9.2（含 lv_conf.h）
#   fonts/     -> 中文字体
# 这样在开发目录里改完代码，直接 ./build.sh app 就是最新代码，不存在两份。
#
# 产物落点（由 SDK 的打包流程决定）：
#   out/bin/                    -> oem 分区 /oem/usr/bin
#   out/usr/share/fonts/        -> oem 分区 /oem/usr/share/fonts
#   out/etc/init.d/S30qzdesk    -> oem 分区 /oem/usr/etc/init.d（RkLunch 的 rcS 会跑）
#   out/root/etc/init.d/S30qzdesk -> rootfs /etc/init.d（rcS 直接跑，最可靠）
#
ifeq ($(APP_PARAM), )
    APP_PARAM:=../Makefile.param
    include $(APP_PARAM)
endif

export LC_ALL=C
SHELL:=/bin/bash

CURRENT_DIR := $(shell pwd)

PKG_NAME := qzdesk
PKG_BIN ?= out
PKG_BUILD ?= build

ifeq ($(PKG_BIN),)
$(error ### $(CURRENT_DIR): PKG_BIN is NULL, Please Check !!!)
endif

PKG_TOOLCHAIN_SYSROOT := $(shell $(RK_APP_CROSS)-gcc -print-sysroot)

# -mfpu/-mfloat-abi 由 Makefile.param 按工具链给（RV1106 是 neon + hard float）
QZDESK_CFLAGS := -O2 $(RK_APP_CROSS_CFLAGS) $(RK_APP_OPTS)
# WiFi 固件源（RTL8723BS）：随 qzdesk 装进 oem，由 S30qzdesk 开机补到 /lib/firmware。
# 注意必须用 make 变量：recipe 的每一行都是独立 shell，跨行 shell 变量传不出去。
WIFIBT_FW_DIR := $(CURRENT_DIR)/../../../project/cfg/BoardConfig_IPC/overlay/overlay-luckfox-wifibt-firmware/lib/firmware
# ISP 调参文件源（media 构建产出）。同样必须是 make 变量 —— recipe 每行独立 shell。
IQ_SRC := $(CURRENT_DIR)/../../../output/out/media_out/isp_iqfiles

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
PKG_CONF_OPTS += -DCMAKE_C_FLAGS="$(QZDESK_CFLAGS)"
PKG_CONF_OPTS += -DCMAKE_CXX_FLAGS="$(QZDESK_CFLAGS)"
# 设备上没有 SDL；核心是独立交叉编译出来的，不让 cargo 在本机再编一个 x86 版
PKG_CONF_OPTS += -DQZDESK_SIMULATOR=OFF
PKG_CONF_OPTS += -DQZDESK_BUILD_CORE=OFF

all: qzdesk-build
	@echo "build $(PKG_NAME) done"

qzdesk-build:
	@echo "RK_APP_TYPE is $(RK_APP_TYPE)  toolchain: $(RK_APP_CROSS)"
	mkdir -p $(PKG_BUILD) \
	         $(PKG_BIN)/bin \
	         $(PKG_BIN)/usr/share/fonts \
	         $(PKG_BIN)/etc/init.d \
	         $(PKG_BIN)/root/etc/init.d
	@# 不整目录删：一是让 cmake 增量编译（快得多），二是环境里的删文件保护会拦
	@# 大规模 rm。只在源码路径变了时丢掉缓存，避免用旧的 CMake 配置。
	@if [ -f $(PKG_BUILD)/CMakeCache.txt ] && ! grep -q "$(CURRENT_DIR)/src" $(PKG_BUILD)/CMakeCache.txt; then \
		rm -f $(PKG_BUILD)/CMakeCache.txt; \
	fi
	pushd $(PKG_BUILD)/; \
		cmake $(CURRENT_DIR)/src $(PKG_CONF_OPTS) || exit -1; \
		make -j$(RK_APP_JOBS) || exit -1; \
	popd;
	$(RK_APP_CROSS)-strip -s $(PKG_BUILD)/qzdesk_screen
	install -m 0755 $(PKG_BUILD)/qzdesk_screen $(PKG_BIN)/bin/
	install -m 0644 $(CURRENT_DIR)/fonts/NanoTikBazHei-Bold.ttf $(PKG_BIN)/usr/share/fonts/
	install -m 0755 $(CURRENT_DIR)/S30qzdesk $(PKG_BIN)/etc/init.d/
	install -m 0755 $(CURRENT_DIR)/S30qzdesk $(PKG_BIN)/root/etc/init.d/
	# RTL8723BS（SDIO WiFi+BT）驱动模块：镜像内核里编译成了模块，但 SDK 的打包流程
	# 不会把它放进 rootfs，所以随 qzdesk 一起装到 oem，由 S30qzdesk 在起界面前 insmod。
	# 固件由 overlay-luckfox-wifibt-firmware 提供（板级配置已引用）。
	install -d $(PKG_BIN)/lib/wifi
	for ko in cfg80211 mac80211 r8723bs; do \
		install -m 0644 $$(ls $(RK_PROJECT_PATH_SYSDRV)/kernel_drv_ko/$$ko.ko 2>/dev/null || \
			echo $(CURRENT_DIR)/../../../sysdrv/out/kernel_drv_ko/$$ko.ko) $(PKG_BIN)/lib/wifi/ 2>/dev/null || true; \
	done
	# 相机 / ISP 驱动模块（SC3336 + rkcif + rkisp）：镜像里同样没带，随包装上，
	# 由界面或 S30qzdesk 在需要时 insmod（默认不自动加载，见 S30qzdesk 的注释）。
	install -d $(PKG_BIN)/lib/camera
	for ko in rk_dvbm video_rkcif video_rkisp phy-rockchip-csi2-dphy-hw \
			phy-rockchip-csi2-dphy sc3336; do \
		install -m 0644 $$(ls $(RK_PROJECT_PATH_SYSDRV)/kernel_drv_ko/$$ko.ko 2>/dev/null || \
			echo $(CURRENT_DIR)/../../../sysdrv/out/kernel_drv_ko/$$ko.ko) $(PKG_BIN)/lib/camera/ 2>/dev/null || true; \
	done
	# WiFi 固件（RTL8723BS）：驱动从 /lib/firmware 读，rootfs 里没有，先随包带上，
	# 由 S30qzdesk 开机时从 oem 拷进 /lib/firmware。
	install -d $(PKG_BIN)/lib/firmware/rtlwifi $(PKG_BIN)/lib/firmware/rtlbt
	for f in $(WIFIBT_FW_DIR)/rtlwifi/*; do [ -f "$$f" ] && install -m 0644 "$$f" $(PKG_BIN)/lib/firmware/rtlwifi/; done
	for f in $(WIFIBT_FW_DIR)/rtlbt/*; do [ -f "$$f" ] && install -m 0644 "$$f" $(PKG_BIN)/lib/firmware/rtlbt/; done
	# ISP 调参（IQ）：rkaiq/驱动按 /etc/iqfiles 找 sensor_module_lens 命名的 json，
	# 镜像里这份是空的（板级 RK_CAMERA_SENSOR_IQFILES 没配），从 media 产出里拿。
	# 注意：rootfs 里 /etc/iqfiles 是指向 ../oem/usr/share/iqfiles 的软链，
	# 所以只装到 usr/share/iqfiles（= 设备 /oem/usr/share/iqfiles），别去写 root/etc。
	install -d $(PKG_BIN)/usr/share/iqfiles
	for f in $(IQ_SRC)/sc3336_*.json $(IQ_SRC)/sc3336_*.bin; do \
		[ -f "$$f" ] && install -m 0644 "$$f" $(PKG_BIN)/usr/share/iqfiles/; \
	done; true
	for d in $(IQ_SRC)/CAC_sc3336_*; do \
		[ -d "$$d" ] && install -m 0644 "$$d"/* $(PKG_BIN)/usr/share/iqfiles/; \
	done; true
	$(MAKE) core-install PKG_BIN=$(PKG_BIN)
	$(MAKE) kws-install PKG_BIN=$(PKG_BIN)
	$(call MAROC_COPY_PKG_TO_APP_OUTPUT, $(RK_APP_OUTPUT), $(PKG_BIN))
	@echo "界面已就绪：$(PKG_BIN)/bin/qzdesk_screen"

# 本地唤醒词进程（离线 KWS，跑在 NPU 上）。
#
# 为什么是独立进程：核心是静态 musl 二进制，**不能 dlopen**；Rockchip 这套音频库是
# uclibc 动态库（libaec_bf_process.so → librknnmrt.so / librkaudio_common.so）。
# 单独一个进程既满足了链接约束，也不会拖慢核心的 ALSA 采集线程。
#
# 关键点一：链接用的就是 vendor 里的 **mode2_nn** 变体（含唤醒词模型 "小和小和"），
# 它的 SONAME 本来就是 libaec_bf_process.so，所以链接期与运行期都对得上。
#
# 关键点二：**装在 lib/qzdesk/ 子目录**，而不是直接盖 lib/ 下同名文件。因为打包时
# media 的资源是在 app 之后合并进 output/out/oem 的，会把同名文件覆盖回基础版
# （329KB，不带 NN 唤醒）——实测确认过。放子目录 + 开机脚本里把该目录排在
# LD_LIBRARY_PATH 最前面，加载的才一定是带唤醒的这版。
KWS_DIR      := $(CURRENT_DIR)/src/tools/kws
KWS_BIN_NAME := qzdesk-kws
KWS_INC      := $(CURRENT_DIR)/../../../output/out/media_out/include
KWS_LIBDIR   := $(CURRENT_DIR)/../../../output/out/oem/usr/lib
KWS_RA_DIR   := $(CURRENT_DIR)/../../../media/common_algorithm/common_algorithm/audio/rkaudio_algorithms/uclibc
KWS_MODE1_LIB := $(KWS_RA_DIR)/libaec_bf_process_wakeup_mode1_nn.so
KWS_MODE2_LIB := $(KWS_RA_DIR)/libaec_bf_process_wakeup_mode2_nn.so

kws-install:
	@if [ ! -f "$(KWS_DIR)/qzdesk_kws.cpp" ]; then \
		echo "跳过唤醒词进程：找不到 $(KWS_DIR)/qzdesk_kws.cpp"; \
	elif [ ! -f "$(KWS_MODE2_LIB)" ] || [ ! -f "$(KWS_MODE1_LIB)" ]; then \
		echo "跳过唤醒词进程：找不到 $(KWS_RA_DIR)/libaec_bf_process_wakeup_mode*_nn.so"; \
	elif [ ! -f "$(KWS_INC)/rkaudio_preprocess.h" ]; then \
		echo "跳过唤醒词进程：先跑一次 ./build.sh media（缺 $(KWS_INC)/rkaudio_preprocess.h）"; \
	else \
		$(RK_APP_CROSS)-g++ -O2 -Wall -I$(KWS_INC) $(KWS_DIR)/qzdesk_kws.cpp -ldl \
			-Wl,-rpath,/oem/usr/lib -o $(PKG_BUILD)/$(KWS_BIN_NAME) && \
		install -d $(PKG_BIN)/lib/qzdesk && \
		install -m 0755 $(KWS_MODE1_LIB) $(PKG_BIN)/lib/qzdesk/libaec_bf_process_mode1.so && \
		install -m 0755 $(KWS_MODE2_LIB) $(PKG_BIN)/lib/qzdesk/libaec_bf_process_mode2.so && \
		install -m 0755 $(PKG_BUILD)/$(KWS_BIN_NAME) $(PKG_BIN)/bin/ && \
		echo "已装入唤醒词进程与两套 NPU 唤醒库：$(PKG_BIN)/bin/$(KWS_BIN_NAME)"; \
	fi

# 核心服务（Rust，静态 musl）与它的 MCP 脚本。
# 脚本必须和二进制放在同一个目录：核心运行时会以自身目录为工作目录去找它们。
# 单独一步、单独报错，这样界面能编过，核心没编出来时也看得清楚缺什么。
CORE_SRC := $(CURRENT_DIR)/src/xiaozhi_core
CORE_BIN := $(CORE_SRC)/target/armv7-unknown-linux-musleabihf/release/xiaozhi-linux-rs

core-install:
	@if [ ! -f "$(CORE_BIN)" ]; then \
		echo "提示：还没有核心的 armv7 产物，本次只打包界面："; \
		echo "      $(CORE_BIN)"; \
		echo "      先交叉编译：cd $(CORE_SRC) && ./build_armv7.sh"; \
	else \
		install -m 0755 $(CORE_BIN) $(PKG_BIN)/bin/xiaozhi_linux_rs; \
		install -m 0755 $(CORE_SRC)/system_status.sh $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/robot_move.sh $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/set_timer.py $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/pomodoro.py $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/set_brightness.sh $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/set_volume.sh $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/speak.sh $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/screenshot.sh $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/power_action.sh $(PKG_BIN)/bin/; \
		install -m 0755 $(CORE_SRC)/gpio_set.sh $(PKG_BIN)/bin/; \
		echo "已装入核心与 MCP 脚本：$(PKG_BIN)/bin/"; \
	fi

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
