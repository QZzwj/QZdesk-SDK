#!/usr/bin/env bash
#
# 统一固件编译脚本（RV1106 update.img）：一个入口，两条产线。
#
#   tools/build/build_image.sh --cam    摄像头端固件（QZcam，不含 QZdesk 桌面）
#   tools/build/build_image.sh --desk   桌面端固件（QZdesk，不含 QZcam 相机）
#
# 两个目标各自决定：构建哪个 app、保留哪套自启脚本、装哪些依赖（相机模块 /
# WiFi 模块 / 字体 / 运维脚本）、剔除哪些东西、产物叫什么名字与标签。
#
# ── 硬隔离（Hard Isolation）─────────────────────────────────────────────
# 镜像里**只能有一套界面程序**。两套都在 → 两个进程抢同一个 framebuffer，
# 屏幕就在两者之间来回跳。为此在五个层面做隔离，任何一层不过就停机：
#   ① 构建入口：把"不要的那套"的 Makefile 移出 wildcard（退出时自动还原）
#   ② app 暂存：删掉它的二进制 / 自启脚本（project/app/out + output/out/app_out）
#   ③ rootfs 打包目录：删掉它的自启脚本与二进制 —— 最容易漏的一步：打包只是
#      cp -a 追加/覆盖，从不删除，上一版固件的残留会一直被打进 rootfs.img
#   ④ 依赖裁剪：按目标剔除不属于它那一套的依赖目录（见下）
#   ⑤ 打包后断言：自启脚本计数、按名字扫残留、被裁剪目录确已消失、
#      产物新鲜度、发布副本 md5 —— 任一不满足直接报错，不产出镜像
#
# ── 用法 ────────────────────────────────────────────────────────────────
#   tools/build/build_image.sh --cam                 完整重编 + 打包（第一次用这个）
#   tools/build/build_image.sh --cam --skip-sysdrv   跳过 uboot/kernel/rootfs，只重编
#                                              app 再打包（日常最快，1-2 分钟）
#   tools/build/build_image.sh --cam --app-only      只编译 + 安装到 oem 树，不打包
#   tools/build/build_image.sh --desk                出桌面端固件
#   tools/build/build_image.sh --cam --dry-run       只打印计划与校验，不动任何文件
#   tools/build/build_image.sh --cam -j 8            指定并行度
#   tools/build/build_image.sh --cam --keep-wifi     摄像头端保留 WiFi 依赖（默认剔除）
#   tools/build/build_image.sh --cam --keep-rkipc    摄像头端保留 rkipc（默认剔除，
#                                              它会和 QZcam 抢 /dev/video*）
#   tools/build/build_image.sh --camera-demo         相机 demo 固件：额外编进 rkipc(RTSP)
#                                              与 UVC（临时给 RK_APP_TYPE 加 UVC_TINY，
#                                              退出时还原），三条出图路径都能演示
#   tools/build/build_image.sh --sdk-target kernel   原样透传给 SDK 的 ./build.sh
#                                              （lunch/kernel/rootfs/media/app/…），跑完退出
#
# 环境变量（脚本会自动净化环境，不引用 Windows / WSL 注入的变量与路径）：
#   QZCAM_SDK               SDK 根目录（默认 = 脚本所在位置的上两级）
#   QZCAM_LOG               日志文件（默认 /tmp/qzdesk-image.log）
#   QZCAM_REBUILD_CORE=1    桌面端强制重编 Rust 核心（平时产物在就不编）
#   QZCAM_ALLOW_STALE_CORE=1 核心编失败时沿用旧产物（默认直接报错）
#
# 产物：
#   $SDK/output/image/update.img            SDK 原始产物
#   $SDK/output/image/update-cam.img        带类型标签的发布副本 + update-cam.txt
#   $SDK/output/image/update-desk.img       同上（桌面端）
#
set -euo pipefail

# 解析软链：本脚本是唯一来源（住在 SDK 里），开发仓库里那份是指向它的软链
self=$(readlink -f -- "$0" 2>/dev/null || echo "$0")
script_dir=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)
SDK=${QZCAM_SDK:-$(CDPATH= cd -- "$script_dir/../.." && pwd)}   # SDK/tools/build → SDK
LOG=${QZCAM_LOG:-/tmp/qzdesk-image.log}

TARGET=cam
JOBS=$(nproc 2>/dev/null || echo 4)
skip_sysdrv=0
dry_run=0
keep_wifi=0
keep_rkipc=0
sdk_target=""       # --sdk-target <目标>：原样透传给 SDK 的 ./build.sh
app_only=0          # --app-only：只编译 + 安装到 oem 树，不打包镜像
camera_demo=0       # --camera-demo：cam 固件额外带上 rkipc(RTSP) 与 UVC
BOARD_MK_BAK=""     # 相机 demo 临时改过板级配置时的备份，退出还原

usage() {
	# 打印脚本头部的注释块（到 `set -euo pipefail` 为止），去掉每行开头的 "# "
	awk 'NR==1{next} /^set -euo pipefail/{exit} {sub(/^# ?/,""); print}' "$0"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--cam|--cameras)  TARGET=cam ;;
		--desk|--desktop) TARGET=desk ;;
		--only)           TARGET=$2; shift ;;        # 兼容旧写法
		--skip-sysdrv)    skip_sysdrv=1 ;;
		--app-only)       app_only=1; skip_sysdrv=1 ;;
		--dry-run)        dry_run=1 ;;
		--keep-wifi)      keep_wifi=1 ;;
		--keep-rkipc)     keep_rkipc=1 ;;
		--camera-demo|--demo) camera_demo=1; TARGET=cam; keep_wifi=1; keep_rkipc=1 ;;
		--sdk-target)     sdk_target=$2; shift ;;    # 透传：./build.sh <目标>（lunch/kernel/rootfs/media…）
		--sdk)            SDK=$2; shift ;;
		-j|--jobs)        JOBS=$2; shift ;;
		--log)            LOG=$2; shift ;;
		-h|--help)        usage; exit 0 ;;
		*)                echo "未知参数：$1"; echo; usage; exit 1 ;;
	esac
	shift
done

case "$TARGET" in
	cam|desk) ;;
	*) echo "--only/--cam/--desk 只支持 cam 或 desk（收到：$TARGET）"; exit 1 ;;
esac

# ---------------------------------------------------------------- 路径与目标

APP_BASE="$SDK/project/app"
APP_OUT="$APP_BASE/out"                       # app 暂存（各 app 往这装）
PKG_OUT="$SDK/output/out/app_out"             # 打包真正读的目录（build.sh:56）
IMAGE_DIR="$SDK/output/image"
DESKTOP_MK="$APP_BASE/qzdesk/Makefile"
DESKTOP_OFF="$DESKTOP_MK.qzdesk-off"

# 目标档案：所有与"选哪个"有关的差异都集中在这里
setup_profile() {
	case "$TARGET" in
	cam)
		PROFILE_NAME="QZcam（摄像头端）"
		APP_NAME=qzcam
		APP_DIR="$APP_BASE/qzcam"
		APP_BIN=qzcam
		KEEP_INIT=S30qzcam
		DROP_INITS="S30qzdesk S99qzdesk"
		# 桌面本体 + 它的核心 + 它的 4 个 MCP 脚本（留着就是 QZdesk 的残留）
		DROP_BINS="qzdesk_screen xiaozhi_linux_rs xiaozhi-linux-rs
		           pomodoro.py robot_move.sh set_timer.py system_status.sh"
		DROP_DIRS=""                       # 默认保留相机依赖
		[ "$keep_wifi" = 1 ] || DROP_DIRS="lib/wifi lib/firmware"
		[ "$keep_rkipc" = 1 ] || DROP_BINS="$DROP_BINS rkipc rk_mpi_uvc"
		HIDE_DESKTOP=1
		KEEP_DEPS="相机驱动模块 6 个、iqfiles、replace_desktop.sh、camera_doctor.sh、camera_paths_test.sh"
		if [ "$camera_demo" = 1 ]; then
			KEEP_DEPS="$KEEP_DEPS；rkipc（RTSP 推流）、UVC 程序（usb_config.sh + uvc_app/rk_mpi_uvc）"
		fi
		;;
	desk)
		PROFILE_NAME="QZdesk（桌面端）"
		APP_NAME=qzdesk
		APP_DIR="$APP_BASE/qzdesk"
		APP_BIN=qzdesk_screen
		KEEP_INIT=S30qzdesk
		# S99qzdesk 是桌面脚本的旧名字，留着会和 S30qzdesk 各起一个界面
		DROP_INITS="S30qzcam S99qzcam S99qzdesk"
		DROP_BINS="qzcam"
		DROP_DIRS="usr/share/qzcam lib/camera"
		HIDE_DESKTOP=0
		KEEP_DEPS="WiFi 模块与固件、中文字体、Rust 核心（若已交叉编译）"
		;;
	esac
	DIST_IMG="$IMAGE_DIR/update-${TARGET}.img"
	DIST_LABEL="$IMAGE_DIR/update-${TARGET}.txt"
	# 隔离时用于"按名字扫残留"的通配符
	OTHER_PATTERN=$([ "$TARGET" = cam ] && echo '*qzdesk*' || echo '*qzcam*')
}
setup_profile

# ---------------------------------------------------------------- 输出小工具

step()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
info()  { printf '   %s\n' "$*"; }
warn()  { printf '   \033[1;33m注意：%s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2; echo "   日志：$LOG" >&2; exit 1; }

dump_log_tail() {
	echo "--- 日志里的错误（$LOG）---" >&2
	sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -aiE "error|fatal|cannot|failed|失败" | tail -15 >&2 || true
	echo "--- 日志尾部 ---" >&2
	sed 's/\x1b\[[0-9;]*m//g' "$LOG" | tail -10 >&2
}

# 只执行并记录，返回真实状态（调用方自己决定成败怎么处理）
run_cmd() {
	if [ "$dry_run" = 1 ]; then
		info "[预演] $*"
		return 0
	fi
	step "$*"
	"$@" >>"$LOG" 2>&1
}

# 跑构建命令：日志写文件（可 tail -f），失败就报错退出并回显关键行
run_logged() {
	run_cmd "$@" || {
		printf '\033[1;31m失败：%s\033[0m\n' "$*" >&2
		dump_log_tail
		exit 1
	}
}

# 用"干净环境"跑 SDK 的 ./build.sh：env -i 只带必要变量，Windows 注进来的环境
# 一个都传不进去（buildroot 对 PATH 里的空格/换行是硬性拒绝的）。
# 只转发少量下载/编译缓存变量，免得丢掉已有缓存。
sdk_build() {
	local target=$1
	local -a extra=()
	local v
	for v in BR2_DL_DIR DL_DIR CCACHE_DIR CCACHE_MAXSIZE; do
		[ -n "${!v:-}" ] && extra+=("$v=${!v}")
	done

	if [ "$dry_run" = 1 ]; then
		info "[预演] env -i（干净环境，不继承 Windows 变量） ./build.sh $target"
		return 0
	fi
	step "env -i ./build.sh $target（干净环境）"
	env -i -C "$SDK" \
		PATH="$PATH" HOME="$HOME" \
		LANG="${LANG:-C}" LC_ALL=C LC_CTYPE=C \
		TERM="${TERM:-dumb}" TMPDIR="${TMPDIR:-/tmp}" \
		USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" \
		SHELL="${SHELL:-/bin/bash}" \
		"${extra[@]}" \
		"$SDK/build.sh" "$target" >>"$LOG" 2>&1 || {
		printf '\033[1;31m失败：./build.sh %s\033[0m\n' "$target" >&2
		dump_log_tail
		exit 1
	}
}

# ── 环境净化：不引用 Windows 的环境变量 ─────────────────────────────────
# WSL 默认把 Windows 的环境整套注进来，会踩两脚：
#   1. PATH 里有带空格的目录（/mnt/d/Microsoft VS Code/bin 这种），buildroot 的
#      dependencies.mk 会直接报 "Your PATH contains spaces, TABs, and/or newline" 挂掉；
#   2. TEMP/INCLUDE/LIB/PKG_CONFIG_PATH 之类指向 /mnt/c，工具会往 Windows 目录写东西。
# 所以：先把指向 Windows 的变量清掉，再把 PATH 里的脏项摘掉；真正跑 SDK 构建时
# 还会用 env -i 只带必要的几个变量（见 sdk_build），做到"一个 Windows 变量都不引用"。

scrub_windows_env() {
	local name value dropped=""
	while IFS='=' read -r name value; do
		case "$name" in
			PATH|HOME|PWD|OLDPWD|SHELL|SHLVL|_|TERM|LANG|LC_ALL|TMPDIR|USER|LOGNAME|HOSTNAME|MAIL)
				continue ;;
		esac
		case "$value" in
			*/mnt/[a-z]/*|*/mnt/[a-z]|*[A-Za-z]:\\*|*WindowsApps*|*"Program Files"*)
				unset "$name" 2>/dev/null || true
				dropped="$dropped $name"
				;;
		esac
	done < <(env)
	# WSL / Windows 终端 / VS Code 注入的变量：即使值看着正常也一律清掉
	local v
	for v in WSLENV WSL_DISTRO_NAME WSL_INTEROP WT_SESSION WT_PROFILE_ID \
	         ProgramData PROGRAMDATA ProgramFiles PROGRAMFILES APPDATA LOCALAPPDATA \
	         SystemRoot SYSTEMROOT windir USERPROFILE HOMEPATH PATHEXT ComSpec \
	         PSModulePath VSCODE_CWD VSCODE_IPC_HOOK VSCODE_NLS_CONFIG VSCODE_PID \
	         INCLUDE LIB LIBPATH CPATH C_INCLUDE_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH; do
		[ -n "${!v:-}" ] && { unset "$v" 2>/dev/null || true; dropped="$dropped $v"; }
	done
	[ -n "$dropped" ] && warn "已清除指向 Windows 的环境变量：$dropped"
	return 0
}

sanitize_path() {
	local entry clean="" dropped="" win=""
	while IFS= read -r entry; do
		entry="${entry%$'\r'}"
		[ -n "$entry" ] || continue
		case "$entry" in
			# 带空格/TAB/换行：buildroot 会直接拒绝，必须摘
			*" "*|*$'\t'*|*$'\n'*) dropped="$dropped $entry" ;;
			# Windows 挂载目录（WSL 注进来的）：脚本里一律不引用
			/mnt/*|//wsl*/*|/run/WSL/*) win="$win $entry" ;;
			*) clean="${clean:+$clean:}$entry" ;;
		esac
	done < <(printf '%s' "$PATH" | tr ':\n\t' '\n\n\n')
	PATH="$clean"
	export PATH
	[ -n "$dropped" ] && warn "PATH 里含空格/TAB 的目录已摘掉（buildroot 会拒绝）：$dropped"
	[ -n "$win" ] && warn "PATH 里的 Windows 挂载目录已摘掉（本脚本不引用它们）：$win"
	return 0
}

scrub_windows_env
sanitize_path

# ---------------------------------------------------------------- 前置校验

preflight() {
	step "前置校验"
	[ -x "$SDK/build.sh" ] || die "找不到 SDK：$SDK（用 --sdk 指定或设 QZCAM_SDK）"
	[ -d "$SDK/sysdrv" ] && [ -d "$APP_BASE" ] || die "$SDK 看起来不是完整的 RV1106 SDK"
	[ -d "$APP_DIR" ] || die "找不到 $PROFILE_NAME 的 SDK 工程：$APP_DIR"
	info "SDK      : $SDK"
	info "目标     : $TARGET —— $PROFILE_NAME"

	if [ -f "$SDK/.BoardConfig.mk" ]; then
		board=$(readlink -f "$SDK/.BoardConfig.mk" 2>/dev/null || echo "$SDK/.BoardConfig.mk")
		chip=$(grep -m1 -oP '(?<=RK_CHIP=).*' "$SDK/.BoardConfig.mk" 2>/dev/null | tr -d '\r' || true)
		dts=$(grep -m1 -oP '(?<=RK_KERNEL_DTS=).*' "$SDK/.BoardConfig.mk" 2>/dev/null | tr -d '\r' || true)
		info "板级配置 : $(basename "$board")"
		info "芯片/DTS : ${chip:-未知} / ${dts:-未知}"
		[ "${chip:-}" = "rv1106" ] || warn "RK_CHIP 不是 rv1106（现在是 ${chip:-未知}），确认板级配置选对了"
	else
		warn "没有 $SDK/.BoardConfig.mk（先跑一次 ./build.sh lunch 选板级配置？）"
	fi

	toolchain=$(ls -d "$SDK"/tools/linux/toolchain/*/bin 2>/dev/null | head -1 || true)
	[ -n "$toolchain" ] || die "找不到交叉工具链（$SDK/tools/linux/toolchain/*/bin）"
	info "工具链   : $toolchain"

	# 中文字体：源码侧是软链（唯一真身在工作目录下，见仓库说明），指错时要到 make
	# 装字体的最后一步才炸，而且淹没在几百行 make 输出里 —— 这里提前判死并回显它指向哪。
	local font_src
	case "$TARGET" in
		cam)  font_src="$APP_DIR/src/assets/NanoTikBazHei-Bold.ttf" ;;
		desk) font_src="$APP_DIR/fonts/NanoTikBazHei-Bold.ttf" ;;
	esac
	if [ -r "$font_src" ]; then
		info "中文字体 : $font_src → $(readlink -f "$font_src" 2>/dev/null || true)"
	else
		die "中文字体读不到：$font_src（指向 $(readlink "$font_src" 2>/dev/null)）—— 修好软链再编，缺了界面中文会退回方框"
	fi

	# 打包（mkfs.ubifs / mkimage）需要 sudo；只编 app 时用不上，所以只警告不拦
	if [ "$dry_run" != 1 ]; then
		command -v sudo >/dev/null 2>&1 || warn "缺 sudo —— 打包镜像需要它"
		sudo -n true 2>/dev/null || warn "sudo 需要密码：打包前先 sudo -v（或配置免密）"
	fi

	if [ -x "$APP_DIR/out/bin/$APP_BIN" ]; then
		info "已有产物 : $(ls -la "$APP_DIR/out/bin/$APP_BIN" | awk '{print $5}') bytes（本次会重编）"
	else
		info "已有产物 : 无（本次会编）"
	fi
}

# ------------------------------------------------------- 硬隔离：构建入口

disabled_desktop=0

restore_desktop() {
	if [ "$disabled_desktop" = 1 ] && [ -f "$DESKTOP_OFF" ] && [ ! -f "$DESKTOP_MK" ]; then
		mv "$DESKTOP_OFF" "$DESKTOP_MK"
		printf '\033[1;36m== 收尾 ==\033[0m\n   已还原桌面 Makefile（%s）\n' "$DESKTOP_MK"
	fi
	# 相机 demo 临时改过板级配置（加 UVC_TINY）也要还原
	if [ -n "$BOARD_MK_BAK" ] && [ -f "$BOARD_MK_BAK" ]; then
		mv -f "$BOARD_MK_BAK" "$(readlink -f "$SDK/.BoardConfig.mk" 2>/dev/null || echo "$SDK/.BoardConfig.mk")"
		printf '   已还原板级配置（RK_APP_TYPE 去掉 UVC_TINY）\n'
	fi
}
trap restore_desktop EXIT INT TERM

# 相机 demo：在板级配置里把 UVC_TINY 追加进 RK_APP_TYPE（官方文档的 UVC 标准模式
# 就是这么配的），这样 make -C project/app 才会编 uvc_app。退出时自动还原。
# 注意 .BoardConfig.mk 是软链，必须改它指向的真实文件，别把软链自己替换掉。
patch_board_for_uvc() {
	local real
	real=$(readlink -f "$SDK/.BoardConfig.mk" 2>/dev/null || echo "$SDK/.BoardConfig.mk")
	[ -f "$real" ] || { warn "没有板级配置，跳过 UVC_TINY"; return 0; }
	if grep -q "UVC_TINY" "$real"; then
		info "RK_APP_TYPE 已含 UVC_TINY，无需修改"
		return 0
	fi
	if [ "$dry_run" = 1 ]; then
		info "[预演] 会在 $(basename "$real") 的 RK_APP_TYPE 里追加 UVC_TINY（退出时还原）"
		return 0
	fi
	BOARD_MK_BAK="${real}.before-camera-demo"
	cp -f "$real" "$BOARD_MK_BAK"
	sed -i 's/^\(export RK_APP_TYPE="\)\(.*\)"$/\1\2 UVC_TINY"/' "$real"
	info "已追加 UVC_TINY：$(grep -m1 '^export RK_APP_TYPE' "$real")"
}

isolate_build_entry() {
	step "① 构建入口隔离"
	if [ "$HIDE_DESKTOP" = 1 ]; then
		if [ -f "$DESKTOP_MK" ]; then
			if [ "$dry_run" = 1 ]; then
				info "[预演] 把 qzdesk/Makefile 改名为 Makefile.qzdesk-off（退出时还原）"
			else
				mv "$DESKTOP_MK" "$DESKTOP_OFF"
				disabled_desktop=1
				info "已排除桌面构建：qzdesk/Makefile → Makefile.qzdesk-off"
			fi
		else
			info "桌面构建已在排除状态"
		fi
	else
		if [ -f "$DESKTOP_OFF" ] && [ ! -f "$DESKTOP_MK" ]; then
			if [ "$dry_run" = 1 ]; then
				info "[预演] 把 Makefile.qzdesk-off 放回（桌面端要编它）"
			else
				mv "$DESKTOP_OFF" "$DESKTOP_MK"
				disabled_desktop=0
				info "已恢复桌面构建：Makefile.qzdesk-off → Makefile"
			fi
		else
			info "桌面构建在位，无需处理"
		fi
	fi
}

# --------------------------------------------- 硬隔离：暂存 / rootfs / 依赖

isolate_staging() {
	step "②③ 暂存与 rootfs 隔离（删掉另一套）"
	local cleaned=0 d f b sub
	for d in "$APP_OUT" "$PKG_OUT"; do
		for f in $DROP_INITS; do
			for sub in etc/init.d root/etc/init.d; do
				if [ -e "$d/$sub/$f" ]; then
					[ "$dry_run" = 1 ] || rm -f "$d/$sub/$f" "$d/$sub/$f.disabled"
					info "清 $d/$sub/$f"; cleaned=$((cleaned + 1))
				fi
			done
		done
		for b in $DROP_BINS; do
			if [ -e "$d/bin/$b" ]; then
				[ "$dry_run" = 1 ] || rm -f "$d/bin/$b" "$d/bin/$b.disabled"
				info "清 $d/bin/$b"; cleaned=$((cleaned + 1))
			fi
		done
		if [ -f "$d/.qzdesk-manifest" ]; then
			[ "$dry_run" = 1 ] || rm -f "$d/.qzdesk-manifest"
			info "清 $d/.qzdesk-manifest"; cleaned=$((cleaned + 1))
		fi
	done
	# rootfs 打包目录：上一版固件留下的自启脚本与二进制，必须显式删
	for d in "$SDK"/output/out/rootfs_* "$SDK"/sysdrv/out/rootfs_*; do
		for f in $DROP_INITS; do
			if [ -e "$d/etc/init.d/$f" ]; then
				[ "$dry_run" = 1 ] || rm -f "$d/etc/init.d/$f" "$d/etc/init.d/$f.disabled"
				info "清 $d/etc/init.d/$f（rootfs 里上一版固件留下的）"; cleaned=$((cleaned + 1))
			fi
		done
		for b in $DROP_BINS; do
			if [ -e "$d/usr/bin/$b" ]; then
				[ "$dry_run" = 1 ] || rm -f "$d/usr/bin/$b"
				info "清 $d/usr/bin/$b"; cleaned=$((cleaned + 1))
			fi
		done
	done
	[ "$cleaned" = 0 ] && info "暂存本来就干净（没有要清的东西）"

	step "④ 依赖裁剪（不属于本目标的依赖剔除）"
	if [ -z "$DROP_DIRS" ]; then
		info "本目标无需裁剪依赖目录"
	else
		for d in "$APP_OUT" "$PKG_OUT"; do
			for sub in $DROP_DIRS; do
				if [ -e "$d/$sub" ]; then
					[ "$dry_run" = 1 ] || rm -rf "$d/$sub"
					info "裁掉 $d/$sub"
				fi
			done
		done
		info "已裁剪：$DROP_DIRS"
	fi
	info "保留：$KEEP_DEPS"
	return 0
}

# ---------------------------------------------------------------- 构建步骤

# rootfs_prepare 第一步是 rm -rf sysdrv/out/rootfs_*（几千个文件）。有些环境装了
# "批量删除确认"保护（大目录 rm 直接失败），会让 make 报 rootfs_prepare Error 1。
# 提前把目录删掉，那次 rm 就成了空操作。
preclean_rootfs() {
	local found=0 d
	for d in "$SDK"/sysdrv/out/rootfs_*; do
		[ -d "$d" ] || continue
		found=1
		if [ "$dry_run" = 1 ]; then
			info "[预演] 会预清 $d"
			continue
		fi
		rm -rf "$d" 2>/dev/null || {
			warn "删不掉 $d（被批量删除保护拦了？）请手动执行： rm -rf $d"
		}
	done
	[ "$found" = 0 ] && info "rootfs 暂存目录本来就干净"
	return 0
}

build_sysdrv() {
	if [ "$skip_sysdrv" = 1 ]; then
		step "跳过 sysdrv（--skip-sysdrv）：沿用已有的 uboot / kernel / rootfs"
		return 0
	fi
	preclean_rootfs
	step "编 uboot + kernel + rootfs（相机驱动 .ko 也在这一步产出）"
	sdk_build sysdrv
}

build_app() {
	if [ "$TARGET" = desk ]; then
		build_core
	fi
	step "编 $PROFILE_NAME（ARM 交叉编译）"
	# 注意：不用 ./build.sh app —— 那个入口在 LF_WIFI_PSK/LF_WIFI_SSID 没配时
	# 会整段跳过（日志里 "Skipping build_app"），编出来的就是空包。
	run_logged make -C "$APP_DIR" -j"$JOBS"
	sync_app_out
}

# 相机 demo：除了 QZcam 还要把 rkipc（RTSP）与 uvc_app（UVC）一起编出来。
# 这两个在 SDK 里属于其它 app 目录，所以这里直接编整个 app 目录。
build_demo_apps() {
	step "编相机 demo 的全套 app（QZcam + rkipc + uvc_app …）"
	if ! run_cmd make -C "$APP_BASE" -j"$JOBS"; then
		warn "整体 app 构建有失败，退化成只编 rkipc 与 uvc_app_tiny"
		run_cmd make -C "$APP_BASE/rkipc" -j"$JOBS" || \
			warn "rkipc 编译失败（可能要先跑 tools/build/build_image.sh --sdk-target media）"
		run_cmd make -C "$APP_BASE/uvc_app_tiny" -j"$JOBS" || \
			warn "uvc_app_tiny 编译失败（同上）"
	fi
	sync_app_out
}

# 桌面端的 Rust 核心（语音/天气靠它）：产物是 armv7-musl 静态二进制，随 oem 装。
# 桌面 app 的 Makefile 只负责"有就装"，交叉编译这一步在这里做。
#   QZCAM_REBUILD_CORE=1        强制重编（平时产物在就不再编）
#   QZCAM_ALLOW_STALE_CORE=1    编失败时沿用旧产物（默认直接报错）
build_core() {
	local script="$APP_DIR/src/xiaozhi_core/build_armv7.sh"
	local bin="$APP_DIR/src/xiaozhi_core/target/armv7-unknown-linux-musleabihf/release/xiaozhi-linux-rs"

	[ -f "$script" ] || { warn "没有 $script —— 桌面端将缺少核心（语音/天气不可用）"; return 0; }
	if [ -f "$bin" ] && [ "${QZCAM_REBUILD_CORE:-0}" != 1 ]; then
		info "核心产物已存在（重编请设 QZCAM_REBUILD_CORE=1）：$(du -h "$bin" | cut -f1)"
		return 0
	fi
	step "交叉编译 Rust 核心（armv7-musl）"
	if ! run_cmd env -C "$APP_DIR/src/xiaozhi_core" ./build_armv7.sh; then
		if [ "${QZCAM_ALLOW_STALE_CORE:-0}" = 1 ] && [ -f "$bin" ]; then
			warn "核心编译失败，按 QZCAM_ALLOW_STALE_CORE=1 沿用旧产物"
			return 0
		fi
		printf '\033[1;31m失败：核心交叉编译\033[0m\n' >&2
		dump_log_tail
		exit 1
	fi
}

# 关键一步：make -C project/app/<app> 只装到 project/app/out，而打包读的是
# output/out/app_out（build.sh:56 的 RK_PROJECT_PATH_APP）。不同步 = 空包，
# 设备上看到的还是上一版固件（"烧了没变化"的根因）。
sync_app_out() {
	step "同步 app 产物 → 打包目录（output/out/app_out）"
	if [ "$dry_run" = 1 ]; then
		info "[预演] cp -a $APP_OUT/. $PKG_OUT/"
		return 0
	fi
	mkdir -p "$PKG_OUT"
	cp -a "$APP_OUT/." "$PKG_OUT/" || die "同步 app 产物失败"
	info "已同步：$(ls "$PKG_OUT/bin" 2>/dev/null | tr '\n' ' ')"

	# oem 树是"只增不减"的：上次装进去、这次不再产出的文件会一直留在镜像里。
	# 用一份清单（上次的产出）比对，把对不上的从 oem 树删掉，再写新清单。
	local manifest="$SDK/output/out/.image-manifest"
	if [ -f "$manifest" ]; then
		local rel removed=0
		while IFS= read -r rel; do
			[ -n "$rel" ] || continue
			if [ ! -e "$APP_OUT/$rel" ] && [ -e "$PKG_OUT/$rel" ]; then
				rm -f "$PKG_OUT/$rel"
				info "清理上次装、这次不产出的：$rel"
				removed=$((removed + 1))
			fi
		done <"$manifest"
		[ "$removed" = 0 ] && info "清单比对：没有需要清理的旧文件"
	fi
	( cd "$APP_OUT" && find . \( -type f -o -type l \) -printf '%P\n' | sort ) >"$manifest"
	info "已更新安装清单：${manifest#"$SDK"/}"

	# firmware 阶段的坑：rootfs 里 /etc/iqfiles 是指向 ../oem/usr/share/iqfiles 的
	# 软链（build.sh 自建），若 app 的 root/etc/iqfiles 是**目录**，那句 cp -rfa
	# 会报 "cannot overwrite non-directory ... with directory" 直接失败。
	for d in "$PKG_OUT/root/etc/iqfiles" "$APP_OUT/root/etc/iqfiles"; do
		if [ -d "$d" ] && [ ! -L "$d" ]; then
			rm -rf "$d"
			info "清掉与 rootfs 软链冲突的 ${d#"$SDK"/}（IQ 文件保留在 usr/share/iqfiles）"
		fi
	done
}

build_pack() {
	step "打包 oem / rootfs / boot 等分区镜像"
	sdk_build firmware
	step "合成 update.img"
	sdk_build updateimg
}

# ---------------------------------------------------------------- 校验

# ⑤ 打包后断言：任何一条不过就停机，不产出镜像
verify_isolation() {
	step "⑤ 隔离断言（$TARGET）"
	local ok=1 d f

	# 1) 本目标的界面程序在位（打包读的那份）
	if [ -x "$PKG_OUT/bin/$APP_BIN" ]; then
		info "界面程序 : bin/$APP_BIN $(ls -la "$PKG_OUT/bin/$APP_BIN" | awk '{print $5}') bytes"
		# 防呆：必须是 ARM 交叉编译产物，编成宿主版本推上去只会 "cannot execute"
		if command -v file >/dev/null 2>&1; then
			if file -b "$PKG_OUT/bin/$APP_BIN" | grep -qi ARM; then
				info "架构     : $(file -b "$PKG_OUT/bin/$APP_BIN" | cut -c1-46)"
			else
				echo "   × $APP_BIN 不是 ARM 产物（编成宿主版本了？）"; ok=0
			fi
		fi
	else
		echo "   × 缺 $PKG_OUT/bin/$APP_BIN"; ok=0
	fi

	# 2) 自启脚本：三处（app 暂存 ×2 + rootfs 打包目录）只能有本目标那一份
	local keep_hits=0 drop_hits=0
	for d in "$PKG_OUT/etc/init.d" "$APP_OUT/etc/init.d" "$SDK"/output/out/rootfs_*/etc/init.d; do
		[ -d "$d" ] || continue
		[ -e "$d/$KEEP_INIT" ] && keep_hits=$((keep_hits + 1))
		for f in $DROP_INITS; do
			[ -e "$d/$f" ] && drop_hits=$((drop_hits + 1))
		done
	done
	info "自启脚本 : $KEEP_INIT $keep_hits 处 / 另一套 $drop_hits 处"
	[ "$drop_hits" = 0 ] || { echo "   × 还有 $drop_hits 处 ${DROP_INITS%% *} 残留 —— 两套都在就会抢屏跳界面"; ok=0; }
	[ "$keep_hits" -ge 2 ] || { echo "   × $KEEP_INIT 只有 $keep_hits 处（app 暂存 + rootfs 打包目录都该有）"; ok=0; }

	# 3) 按名字扫另一套的残留文件
	local left
	left=$(find "$APP_OUT" "$PKG_OUT" "$SDK"/output/out/rootfs_* -maxdepth 4 -iname "$OTHER_PATTERN" 2>/dev/null | head -5)
	if [ -z "$left" ]; then
		info "另一套残留 : 0 个文件"
	else
		echo "   × 还残留另一套的文件："
		echo "$left" | sed 's/^/       /'
		ok=0
	fi

	# 4) 被裁剪的依赖目录确实不在了（预演不真删，跳过断言）
	if [ -n "$DROP_DIRS" ]; then
		if [ "$dry_run" = 1 ]; then
			info "已裁剪依赖 : $DROP_DIRS（预演：未真正删除）"
		else
			for d in $DROP_DIRS; do
				if [ -e "$PKG_OUT/$d" ]; then
					echo "   × 依赖没裁干净：$PKG_OUT/$d 还在"; ok=0
				fi
			done
			info "已裁剪依赖 : $DROP_DIRS（确认不存在）"
		fi
	fi

	# 5) 相机端特有：驱动模块与运维脚本
	if [ "$TARGET" = cam ]; then
		local ko_count
		ko_count=$(ls "$PKG_OUT/lib/camera/"*.ko 2>/dev/null | wc -l)
		info "相机模块 : $ko_count 个"
		[ "$ko_count" -ge 5 ] || { echo "   × 相机模块偏少（应含 rk_dvbm/rkcif/rkisp/dphy/sc3336）"; ok=0; }
		for s in replace_desktop.sh camera_doctor.sh camera_paths_test.sh; do
			[ -f "$PKG_OUT/usr/share/qzcam/$s" ] && info "oem: usr/share/qzcam/$s" || { echo "   × 缺 usr/share/qzcam/$s"; ok=0; }
		done
		if [ "$camera_demo" = 1 ]; then
			# 相机 demo：RTSP 与 UVC 两条路径的程序必须真的在包里
			[ -x "$PKG_OUT/bin/rkipc" ] && info "RTSP : bin/rkipc" || { echo "   × 相机 demo 缺 rkipc（RTSP 路径不可用）"; ok=0; }
			if [ -x "$PKG_OUT/bin/uvc_app" ] || [ -x "$PKG_OUT/bin/rk_mpi_uvc" ]; then
				info "UVC  : $(ls "$PKG_OUT/bin" 2>/dev/null | grep -iE 'uvc' | tr '\n' ' ')"
			else
				warn "没看到 uvc_app/rk_mpi_uvc —— UVC 路径可能要先跑 --sdk-target media 再打"
			fi
			[ -f "$PKG_OUT/bin/usb_config.sh" ] && info "UVC  : bin/usb_config.sh" || warn "没有 usb_config.sh"
		fi
	fi

	if [ "$ok" != 1 ]; then
		if [ "$dry_run" = 1 ]; then
			# 预演不改任何文件，所以"将要被清掉的东西"还在，不该判失败
			warn "预演：以上问题在真正执行时会由 ②③④ 三步清掉"
		else
			die "隔离断言未通过（镜像里只能有一套界面：$TARGET），已停止打包"
		fi
	fi
}

verify_image() {
	step "校验 update.img"
	local img="$IMAGE_DIR/update.img"
	[ -f "$img" ] || die "没有生成 $img"
	local bin="$APP_OUT/bin/$APP_BIN"
	if [ -x "$bin" ] && [ "$img" -ot "$bin" ]; then
		die "update.img 比 $APP_BIN 还旧，说明没重新打包"
	fi
	info "原始产物 : $img（$(du -h "$img" | cut -f1)，$(date -r "$img" '+%m-%d %H:%M:%S')）"
}

# 带类型标签的发布副本 + 标签文件
make_dist() {
	step "输出带标签的发布副本"
	if [ "$dry_run" = 1 ]; then
		info "[预演] cp $IMAGE_DIR/update.img → $DIST_IMG"
		info "[预演] 写标签 → $DIST_LABEL"
		return 0
	fi
	cp -f "$IMAGE_DIR/update.img" "$DIST_IMG" || die "复制发布副本失败"
	local md5
	md5=$(md5sum "$DIST_IMG" | cut -d' ' -f1)
	local ko_count=0
	[ "$TARGET" = cam ] && ko_count=$(ls "$PKG_OUT/lib/camera/"*.ko 2>/dev/null | wc -l)

	cat >"$DIST_LABEL" <<EOF
# $PROFILE_NAME 固件
target       : $TARGET
profile      : $PROFILE_NAME
编译时间     : $(date '+%Y-%m-%d %H:%M:%S')
镜像         : $(basename "$DIST_IMG")
大小         : $(stat -c%s "$DIST_IMG") bytes
md5          : $md5
板级配置     : $(basename "$(readlink -f "$SDK/.BoardConfig.mk" 2>/dev/null)" 2>/dev/null || echo 未知)
芯片         : $(grep -m1 -oP '(?<=RK_CHIP=).*' "$SDK/.BoardConfig.mk" 2>/dev/null | tr -d '\r' || echo 未知)
DTS          : $(grep -m1 -oP '(?<=RK_KERNEL_DTS=).*' "$SDK/.BoardConfig.mk" 2>/dev/null | tr -d '\r' || echo 未知)

界面程序     : $APP_BIN
自启脚本     : $KEEP_INIT（oem + rootfs）
包含依赖     : $KEEP_DEPS
隔离剔除     : $( [ "$TARGET" = cam ] && echo "QZdesk 桌面（qzdesk_screen / S30qzdesk / MCP 脚本）" || echo "QZcam 相机（qzcam / S30qzcam）" )$( [ -n "$DROP_DIRS" ] && echo "；依赖目录 $DROP_DIRS" )

烧录         : upgrade_tool uf $(basename "$DIST_IMG")   （或 RKDevTool 选它，勾"擦除 Flash"）
EOF
	info "发布副本 : $DIST_IMG"
	info "标签文件 : $DIST_LABEL"
	info "md5      : $md5"
}

print_flash() {
	step "烧录"
	cat <<EOF
   全量升级（板子进 loader/maskrom，务必勾"擦除 Flash"；插着可引导 SD 卡请先拔掉）：
     cd $SDK/tools/linux/Linux_Upgrade_Tool
     sudo ./upgrade_tool uf $DIST_IMG

   Windows：RKDevTool → 固件 → 选 $(basename "$DIST_IMG") → 升级 + 擦除

   只改界面不烧整包（设备已烧过同版本固件时）：
     $script_dir/deploy_qzcam.sh --log 20
   设备自查：
     adb shell "ls /oem/usr/etc/init.d/ /etc/init.d/ | grep -i qz"
     adb shell "ps | grep -E 'qzcam|qzdesk'"
EOF
}

# ---------------------------------------------------------------- 主流程

step "统一固件编译（RV1106 update.img）"
SRC_DIR=$(readlink -f "$SDK/project/app/$([ "$TARGET" = cam ] && echo qzcam || echo qzdesk)/src" 2>/dev/null || echo "未知")
info "脚本位置 : $script_dir"
info "源码目录 : $SRC_DIR"
info "目标     : $TARGET —— $PROFILE_NAME"
info "日志     : $LOG    （另开终端：tail -f $LOG）"
info "并行度   : $JOBS"
[ "$skip_sysdrv" = 1 ] && info "模式     : --skip-sysdrv（只重编 app 再打包）"
[ "$dry_run" = 1 ] && info "模式     : --dry-run（只看计划，不动文件、不编译）"

# 纯粹透传给 SDK 的目标（lunch / kernel / rootfs / media / app / firmware / clean…），
# 跑完就退出 —— 保留一个"什么都能从这一个入口做"的通道。
if [ -n "$sdk_target" ]; then
	step "透传给 SDK：./build.sh $sdk_target"
	sdk_build "$sdk_target"
	step "完成：./build.sh $sdk_target"
	exit 0
fi

preflight
isolate_build_entry
isolate_staging
build_sysdrv
if [ "$camera_demo" = 1 ]; then
	patch_board_for_uvc    # 临时把 UVC_TINY 加进 RK_APP_TYPE（退出时还原）
	build_sysdrv           # 让 rootfs/app 用上新板级配置
	build_demo_apps
else
	build_app
fi
isolate_staging          # app 编完可能又把另一套的东西带回来，再清一次
verify_isolation
if [ "$app_only" = 1 ]; then
	step "只编译 + 安装（--app-only）：不打包镜像"
	restore_desktop
	disabled_desktop=0
	exit 0
fi
build_pack
if [ "$dry_run" = 1 ]; then
	info "[预演] 跳过成品校验与发布副本"
else
	verify_image
	make_dist
fi

restore_desktop
disabled_desktop=0

if [ "$dry_run" = 1 ]; then
	step "预演结束（没有编任何东西）"
else
	print_flash
	step "完成：$PROFILE_NAME → $DIST_IMG"
fi
