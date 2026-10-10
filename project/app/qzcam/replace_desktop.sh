#!/bin/sh
#
# 把设备上的桌面（QZdesk）替换成相机（QZcam）。
#
# 这个脚本会随镜像装到 /oem/usr/share/qzcam/replace_desktop.sh：
#   - 开机时由 /oem/usr/etc/init.d/S30qzcam 调用（--boot）
#   - 烧录后也能手动跑一次（不带参数），不必重刷，也不依赖改 SDK
#
# 为什么需要它：整包烧录没擦 Flash、只补烧了 oem、或设备上还是上一版固件时，
# 老固件的桌面自启脚本（S30qzdesk）与桌面进程仍会在，和相机一起抢同一个
# framebuffer，屏幕就在 QZcam 与 QZdesk 之间来回跳。这个脚本负责"接管"：
#   1. 停用桌面的自启脚本（改名 .disabled，可逆）
#   2. 杀掉在跑的 qzdesk_screen（以及它拉起的 xiaozhi_linux_rs 核心）
#   3. 把桌面二进制挪走，放一个同名软链指向 qzcam（兜底：别处若按名字拉起它，
#      跑起来的也会是相机）
#   4. 保证 /oem/usr/etc/init.d/S30qzcam 在位可执行
#   5. 重启相机（--boot 模式跳过，开机时相机正在被 S30qzcam 拉起）
#
# 用法：
#   replace_desktop.sh            执行替换
#   replace_desktop.sh --boot     开机调用：只干必要的事，不重启相机
#   replace_desktop.sh --check    只报告现状，什么都不改
#   replace_desktop.sh --restore  还原成桌面（.disabled 改回、删软链）
#
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# 设备上都是绝对路径；本机自测时用 QZCAM_ROOT 指一个假根目录模拟整个文件树
# （真机上这个变量为空，路径就是原样）。
PREFIX=${QZCAM_ROOT:-}

BIN="$PREFIX/oem/usr/bin"
OEM_INIT="$PREFIX/oem/usr/etc/init.d"
ROOT_INIT="$PREFIX/etc/init.d"
CAM_INIT="$OEM_INIT/S30qzcam"
QZCAM_BIN="$BIN/qzcam"
DESKTOP_BIN="$BIN/qzdesk_screen"
LOG="$PREFIX/var/log/qzcam.log"
MODE=replace

mkdir -p "$(dirname "$LOG")" 2>/dev/null

for arg in "$@"; do
	case "$arg" in
		--boot)    MODE=boot ;;
		--check)   MODE=check ;;
		--restore) MODE=restore ;;
		-h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	esac
done

say() {
	# --boot 模式安静些：只往日志写关键行
	if [ "$MODE" = boot ]; then
		echo "qzcam: $*" >>"$LOG" 2>/dev/null
	else
		echo "qzcam: $*"
		echo "qzcam: $*" >>"$LOG" 2>/dev/null
	fi
}

desktop_running() {
	[ -n "$(ps | grep '[q]zdesk_screen')" ]
}

core_running() {
	[ -n "$(ps | grep '[x]iaozhi_linux_rs')" ]
}

remount_rw_if_needed() {
	# rootfs 可能是只读挂载，写 /etc/init.d 之前先试一次重挂。
	# 本机自测（QZCAM_ROOT）时不动真实挂载。
	[ -n "$PREFIX" ] && return 0
	mount -o remount,rw / 2>/dev/null
}

# 1) 停用桌面自启（两边都要，rcS 与 RkLunch 各跑一套）
disable_desktop_init() {
	for f in "$OEM_INIT/S30qzdesk" "$ROOT_INIT/S30qzdesk" \
	         "$OEM_INIT/S99qzdesk" "$ROOT_INIT/S99qzdesk"; do
		[ -f "$f" ] || continue
		if mv "$f" "$f.disabled" 2>/dev/null; then
			say "已停用桌面自启 $f"
			continue
		fi
		[ "$f" = "$ROOT_INIT/S30qzdesk" ] || [ "$f" = "$ROOT_INIT/S99qzdesk" ] && remount_rw_if_needed
		if mv "$f" "$f.disabled" 2>/dev/null; then
			say "已停用桌面自启 $f（重挂 rw 后）"
		else
			say "停用 $f 失败（只读？），靠进程看护兜底"
		fi
	done
}

# 2) 杀掉在跑的桌面与它的核心
kill_desktop() {
	if desktop_running; then
		killall qzdesk_screen 2>/dev/null
		say "已杀掉在跑的桌面进程 qzdesk_screen"
	fi
	# 核心是桌面拉起来的（界面自己去找同目录的二进制）。桌面不起了，它留着
	# 白占 CPU/音频设备，顺手停掉；QZcam 不用它。
	if core_running; then
		killall xiaozhi_linux_rs 2>/dev/null
		say "已停掉桌面核心 xiaozhi_linux_rs"
	fi
}

# 3) 桌面二进制换成指向 qzcam 的软链（兜底替换）
swap_desktop_binary() {
	[ -x "$QZCAM_BIN" ] || { say "没有 $QZCAM_BIN，跳过二进制替换"; return 1; }

	if [ -L "$DESKTOP_BIN" ]; then
		if [ "$(readlink "$DESKTOP_BIN")" = "qzcam" ]; then
			say "$DESKTOP_BIN 已经指向 qzcam"
			return 0
		fi
		rm -f "$DESKTOP_BIN"
	elif [ -f "$DESKTOP_BIN" ]; then
		# 保留原件以便还原（.disabled）
		if mv "$DESKTOP_BIN" "$DESKTOP_BIN.disabled" 2>/dev/null; then
			say "桌面二进制已挪走：$DESKTOP_BIN -> $DESKTOP_BIN.disabled"
		else
			rm -f "$DESKTOP_BIN" && say "桌面二进制已删除（挪不动）"
		fi
	fi
	ln -sf qzcam "$DESKTOP_BIN" 2>/dev/null && say "$DESKTOP_BIN -> qzcam（兜底软链）"
}

# 4) 保证相机的自启脚本在位
ensure_camera_init() {
	if [ -f "$CAM_INIT" ]; then
		chmod 755 "$CAM_INIT" 2>/dev/null
		return 0
	fi
	if [ -f "$SELF_DIR/S30qzcam" ]; then
		mkdir -p "$OEM_INIT" 2>/dev/null
		if cp -f "$SELF_DIR/S30qzcam" "$CAM_INIT" 2>/dev/null; then
			chmod 755 "$CAM_INIT"
			say "已装上相机自启脚本 $CAM_INIT"
			return 0
		fi
	fi
	say "警告：$CAM_INIT 不在，也没在 $SELF_DIR 找到可用的 S30qzcam"
	return 1
}

# 5) 重启相机（手动模式才做；--boot 时相机正在由 S30qzcam 拉起，重启会打架）
restart_camera() {
	if [ -n "$PREFIX" ]; then
		say "（自测模式：跳过重启相机）"
		return 0
	fi
	if [ -x "$CAM_INIT" ]; then
		"$CAM_INIT" restart >/dev/null 2>&1 && say "已重启相机（$CAM_INIT restart）"
	elif [ -x "$QZCAM_BIN" ]; then
		killall qzcam 2>/dev/null
		( cd "$BIN" && "$QZCAM_BIN" >>"$LOG" 2>&1 & )
		say "已直接拉起相机（没有自启脚本）"
	fi
}

report() {
	echo "== 现状 =="
	echo "-- oem init --"; ls -l "$OEM_INIT" 2>/dev/null | grep -i qz
	echo "-- rootfs init --"; ls -l "$ROOT_INIT" 2>/dev/null | grep -i qz
	echo "-- 二进制 --"; ls -l "$BIN/qzcam" "$DESKTOP_BIN" 2>/dev/null
	echo "-- 进程 --"; ps | grep -E '[q]zcam|[q]zdesk_screen|[x]iaozhi' || echo "   (无)"
}

case "$MODE" in
	check)
		report
		;;
	restore)
		for f in "$OEM_INIT/S30qzdesk.disabled" "$ROOT_INIT/S30qzdesk.disabled" \
		         "$OEM_INIT/S99qzdesk.disabled" "$ROOT_INIT/S99qzdesk.disabled"; do
			[ -f "$f" ] || continue
			remount_rw_if_needed
			mv "$f" "${f%.disabled}" 2>/dev/null && say "已恢复 ${f%.disabled}"
		done
		if [ -L "$DESKTOP_BIN" ]; then
			rm -f "$DESKTOP_BIN" && say "已删掉 $DESKTOP_BIN 的软链"
		fi
		if [ -f "$DESKTOP_BIN.disabled" ]; then
			mv "$DESKTOP_BIN.disabled" "$DESKTOP_BIN" && say "已还原桌面二进制"
		fi
		[ -x "$OEM_INIT/S30qzdesk" ] && "$OEM_INIT/S30qzdesk" start >/dev/null 2>&1
		killall qzcam 2>/dev/null
		say "还原完成（桌面已恢复自启，相机已停）"
		;;
	boot)
		disable_desktop_init
		kill_desktop
		swap_desktop_binary
		ensure_camera_init
		;;
	*)
		disable_desktop_init
		kill_desktop
		swap_desktop_binary
		ensure_camera_init
		restart_camera
		report
		;;
esac

exit 0
