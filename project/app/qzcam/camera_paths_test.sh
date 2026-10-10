#!/bin/sh
#
# 三条出图路径的实机验证（**互斥**：同一时刻 /dev/video* 只能被一个进程打开，
# 所以逐条测、测完恢复 LCD）。
#
#   lcd   QZcam 在 LCD 上取景（默认模式）
#   v4l2  用 v4l2-ctl 直接抓 NV12 原始帧（拉到电脑用 ffplay 播）
#   rtsp  rkipc 推流 rtsp://<ip>/live/0（VLC 拉流）
#   uvc   UVC 模拟，主机识别成摄像头（PotPlayer 看）
#
# 用法（设备上）：
#   sh /oem/usr/share/qzcam/camera_paths_test.sh             依次测 v4l2 → rtsp → uvc → 恢复 lcd
#   sh /oem/usr/share/qzcam/camera_paths_test.sh rtsp        只测一条
#   sh /oem/usr/share/qzcam/camera_paths_test.sh all
#   CAP_SECS=5 sh /oem/usr/share/qzcam/camera_paths_test.sh v4l2
#
# 环境变量：
#   CAP_SECS   每段抓几秒（默认 3）
#   V4L2_SIZE  抓帧尺寸（默认 640x480）
#
CAP_SECS=${CAP_SECS:-3}
V4L2_SIZE=${V4L2_SIZE:-640x480}
INIT=/oem/usr/etc/init.d/S30qzcam
MODE_FILE=/oem/usr/etc/qzcam-mode
OUT_YUV=/tmp/qzcam-v4l2.yuv
PASS=0
FAIL=0

step() { printf '\n\033[36;1m=== %s ===\033[0m\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  \033[32;1m[PASS]\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31;1m[FAIL]\033[0m %s\n' "$*"; }
info() { printf '         %s\n' "$*"; }
hint() { printf '         \033[33m%s\033[0m\n' "$*"; }

proc_running() {
	first=$(printf '%s' "$1" | cut -c1)
	rest=$(printf '%s' "$1" | cut -c2-)
	[ -n "$(ps | grep "[$first]$rest")" ]
}

stop_all() {
	killall qzcam uvc_app rk_mpi_uvc 2>/dev/null
	killall rkipc 2>/dev/null
	sleep 1
}

mode_set() {   # 切换出图模式并重启（rtsp/uvc 模式下 QZcam 不启动）
	echo "$1" >"$MODE_FILE" 2>/dev/null
	[ -x "$INIT" ] && "$INIT" restart >/dev/null 2>&1
	sleep 2
}

find_mainpath() {
	for n in /sys/class/video4linux/video*; do
		[ -e "$n/name" ] || continue
		case "$(cat "$n/name" 2>/dev/null)" in
			*rkisp_mainpath*) echo "/dev/$(basename "$n")"; return 0 ;;
		esac
	done
	return 1
}

board_ip() {
	for iface in usb0 eth0 wlan0; do
		ip=$(ifconfig "$iface" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1)
		[ -n "$ip" ] && { echo "$ip"; return 0; }
	done
	echo "172.32.0.93"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ 前置检查
prereq() {
	step "前置检查：驱动 / 设备节点 / rkipc 配置"

	miss=0
	for m in rk_dvbm phy-rockchip-csi2-dphy-hw phy-rockchip-csi2-dphy video_rkcif video_rkisp sc3336; do
		grep -q "^$m " /proc/modules 2>/dev/null || { info "缺模块 $m"; miss=$((miss + 1)); }
	done
	[ "$miss" = 0 ] && ok "相机驱动模块 6 个都在" || bad "缺 $miss 个驱动模块（insmod /oem/usr/lib/camera/*.ko）"

	NODE=$(find_mainpath)
	if [ -n "$NODE" ]; then
		ok "取景节点 $NODE（rkisp_mainpath）"
	else
		bad "没找到 rkisp_mainpath（/dev/video* 在吗：$(ls /dev/video* 2>/dev/null | tr '\n' ' ')）"
		hint "先 sh /oem/usr/share/qzcam/camera_doctor.sh --free 看看"
	fi

	# /userdata/video0..2 与 rkipc.ini 只在"rkipc 起来过"之后才存在
	if [ -f /userdata/rkipc.ini ]; then
		ok "存在 /userdata/rkipc.ini（rkipc 已初始化过）"
	else
		hint "/userdata/rkipc.ini 还没有 —— 跑一次 rkipc 模式后会出现（: > $MODE_FILE rtsp 模式）"
	fi
	[ -e /userdata/video0 ] && ok "/userdata/video0 存在" || info "/userdata/video0 未生成（同上，rkipc 首启后生成）"
}

# ---------------------------------------------------------------- V4L2 原始帧
test_v4l2() {
	step "路径 1/3：V4L2 原始采集（$V4L2_SIZE NV12，${CAP_SECS}s）"
	stop_all

	[ -n "$NODE" ] || NODE=$(find_mainpath)
	if [ -z "$NODE" ]; then bad "没有可用的取景节点"; return 1; fi
	if ! have v4l2-ctl; then bad "镜像里没有 v4l2-ctl（buildroot 的 v4l2-utils 没编进去）"; return 1; fi

	w=${V4L2_SIZE%x*}
	h=${V4L2_SIZE#*x}
	frames=$((CAP_SECS * 25))
	rm -f "$OUT_YUV"
	# 先问驱动支不支持这个尺寸/格式
	formats=$(v4l2-ctl --device="$NODE" --list-formats-ext 2>/dev/null | head -40)
	echo "$formats" | grep -qi "NV12" || hint "驱动列表里没看到 NV12，下面可能自动协商成别的格式"

	if v4l2-ctl --device="$NODE" \
		--set-fmt-video="width=$w,height=$h,pixelformat=NV12" \
		--stream-mmap --stream-count="$frames" --stream-to="$OUT_YUV" > /tmp/qzcam-v4l2.log 2>&1; then
		size=$(wc -c <"$OUT_YUV" 2>/dev/null || echo 0)
		if [ "$size" -gt 0 ]; then
			ok "抓到 $size 字节（$frames 帧 @ $V4L2_SIZE NV12 应为 $((w * h * 3 / 2 * frames)) 字节）"
			ok "帧率行：$(grep -aoE '<<<<<<* [0-9.]+ fps' /tmp/qzcam-v4l2.log | tail -1)"
			info "拉到电脑看："
			hint "adb pull $OUT_YUV /tmp/ && ffplay -video_size $V4L2_SIZE -pixel_format nv12 -framerate 25 /tmp/$(basename $OUT_YUV)"
		else
			bad "抓到的文件是空的（驱动没出流？摄像头没接？）"
			info "看一下 $(v4l2-ctl --device="$NODE" --all 2>/dev/null | grep -m1 -A2 'Format Video' | tr '\n' ' ')"
		fi
	else
		bad "v4l2-ctl 抓帧失败"
		tail -3 /tmp/qzcam-v4l2.log | while read -r l; do info "$l"; done
	fi
}

# ----------------------------------------------------------------- RTSP 推流
test_rtsp() {
	step "路径 2/3：RTSP 推流（rkipc → rtsp://<ip>/live/0）"
	stop_all

	if [ ! -x /oem/usr/bin/rkipc ]; then
		bad "镜像里没有 rkipc"
		hint "用 tools/build/build_image.sh --cam --camera-demo 重新打包（会把 rkipc/UVC 一起编进去）"
		return 1
	fi

	mode_set rtsp
	if proc_running rkipc; then
		ok "rkipc 已启动"
	else
		bad "rkipc 没起来（看 /var/log/qzcam.log）"
		return 1
	fi

	# 等 RTSP 端口（554）监听；板子上可能没有 netstat，退化用 ss / proc
	i=0
	listen=no
	while [ "$i" -lt 20 ]; do
		if have netstat && netstat -lnt 2>/dev/null | grep -q ':554'; then listen=yes; break; fi
		if have ss && ss -lnt 2>/dev/null | grep -q ':554'; then listen=yes; break; fi
		# 没有 netstat/ss 时的兜底：内核里 554 = 0x022A
		if grep -q ':022A' /proc/net/tcp 2>/dev/null; then listen=yes; break; fi
		sleep 1
		i=$((i + 1))
	done
	if [ "$listen" = yes ] || grep -qi "rtsp" /userdata/rkipc.ini 2>/dev/null; then
		ip=$(board_ip)
		ok "RTSP 服务在监听（rkipc 推流中）"
		info "主机上（和板子同一局域网，USB 静态 IP 时主机设 172.32.0.100）"
		hint "VLC → 媒体 → 打开网络串流 → rtsp://$ip/live/0"
		hint "VLC 缓存调到 300ms（工具→偏好→输入/编解码器→网络缓存）平衡延迟与流畅"
		hint "ppc 拉流失败时：先 ping $ip，再确认主机 IP 段和板子一致"
	else
		bad "等不到 554 端口监听（rkipc 起没起？看 /var/log/qzcam.log 里 rkipc 那几行）"
		info "rkipc 日志尾部：$(tail -3 /var/log/qzcam.log 2>/dev/null | tr '\n' ' ')"
	fi
}

# ---------------------------------------------------------------- UVC 模拟输出
test_uvc() {
	step "路径 3/3：UVC 模拟（主机识别成摄像头）"
	stop_all

	if [ ! -x /oem/usr/bin/usb_config.sh ]; then
		bad "镜像里没有 usb_config.sh（UVC 模式切不过去）"
		hint "用 --camera-demo 重新打包（RK_APP_TYPE 会带上 UVC_TINY）"
		return 1
	fi

	mode_set uvc
	started=no
	for bin in /oem/usr/bin/uvc_app /oem/usr/bin/rk_mpi_uvc; do
		[ -x "$bin" ] || continue
		proc_running "$(basename "$bin")" && started=yes
	done

	# gadget 侧证据：UDC 绑定 + uvc function 存在
	udc=$(ls /sys/class/udc 2>/dev/null | head -1)
	gadget=$(ls -d /sys/kernel/config/usb_gadget/*/functions/uvc* 2>/dev/null | head -1)
	if [ "$started" = yes ]; then ok "UVC 程序在跑（$(ps | grep -E '[u]vc_app|[r]k_mpi_uvc' | head -1 | awk '{print $NF}')）"
	else bad "UVC 程序没起来"; fi
	[ -n "$udc" ] && ok "USB 控制器 UDC：$udc" || bad "没有 /sys/class/udc（USB gadget 没配置）"
	[ -n "$gadget" ] && ok "UVC 功能已配置：$gadget" || info "没有 usb_gadget/uvc 节点（部分 SDK 用 /dev/videoX 直出，不等同失败）"

	if [ "$started" = yes ]; then
		info "主机上：Windows 设备管理器 → 照相机 里应出现 UVC Camera"
		hint "PotPlayer：Ctrl+J 看画面；设备设置里可改分辨率"
		hint "若是 WSL/主机看不到：先 usb_config.sh（本脚本已执行），UVC 与 RNDIS 互斥，需重启才能切回"
	else
		hint "没有 uvc_app/rk_mpi_uvc：--camera-demo 打包时会带 UVC_TINY"
	fi
}

# ------------------------------------------------------------------ LCD 取景
test_lcd() {
	step "路径 0：LCD 取景（QZcam，默认模式）"
	stop_all
	mode_set lcd
	if proc_running qzcam; then ok "qzcam 在运行（顶栏应显示后端与 fps）"
	else bad "qzcam 没起来（看 /var/log/qzcam.log）"; fi
	[ -e /dev/fb0 ] && ok "framebuffer /dev/fb0 在" || bad "没有 /dev/fb0"
	grep -a "QZcam:" /var/log/qzcam.log 2>/dev/null | tail -2 | while read -r l; do info "$l"; done
}

# ---------------------------------------------------------------------- 主流程
step "QZcam 出图路径验证（CAP_SECS=$CAP_SECS）"
info "注意：三条路径互斥（同一时刻只有一个进程能开摄像头），逐条测、测完恢复 LCD"
prereq

case "${1:-all}" in
	v4l2) test_v4l2 ;;
	rtsp) test_rtsp ;;
	uvc)  test_uvc ;;
	lcd)  test_lcd ;;
	all)
		test_v4l2
		test_rtsp
		test_uvc
		test_lcd
		;;
	*) echo "用法: $0 [all|v4l2|rtsp|uvc|lcd]"; exit 1 ;;
esac

step "结果"
printf '  PASS %s / FAIL %s\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then
	printf '  \033[32;1m三条路径都通过\033[0m\n'
else
	printf '  \033[31;1m有失败项 —— 上面每条的 [FAIL] 都给了原因和下一步\033[0m\n'
fi
exit 0
