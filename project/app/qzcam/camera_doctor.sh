#!/bin/sh
#
# 相机体检：板子上一条命令看清"摄像头能不能用、卡在哪"。
#
# 用法（设备上）：
#   sh /oem/usr/share/qzcam/camera_doctor.sh                只检查、不改东西
#   sh /oem/usr/share/qzcam/camera_doctor.sh --capture      额外抓 1 帧 NV12 到 /tmp 验证真出图
#   sh /oem/usr/share/qzcam/camera_doctor.sh --free         停掉占用摄像头的 rkipc/uvc（QZcam 启动会自动做）
#
# 它会报：驱动模块在不在、视频节点、rkisp_mainpath 是哪个、支持哪些格式、
# 谁占着摄像头、以及 QZcam 该用哪个节点（直接给出 QZCAM_DEV=... 的写法）。
#
QZCAM_HOGS="rkipc rk_mpi_uvc"
CAPTURE=0
FREE=0

for arg in "$@"; do
	case "$arg" in
		--capture) CAPTURE=1 ;;
		--free)    FREE=1 ;;
		-h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	esac
done

proc_running() {
	first=$(printf '%s' "$1" | cut -c1)
	rest=$(printf '%s' "$1" | cut -c2-)
	[ -n "$(ps | grep "[$first]$rest")" ]
}

echo "=========== QZcam 相机体检 ==========="

echo
echo "--- 1) 内核驱动模块 ---"
for m in rk_dvbm phy-rockchip-csi2-dphy-hw phy-rockchip-csi2-dphy video_rkcif video_rkisp sc3336; do
	if grep -q "^$m " /proc/modules 2>/dev/null; then
		echo "  [在] $m"
	else
		echo "  [缺] $m    （insmod /oem/usr/lib/camera/$m.ko）"
	fi
done

echo
echo "--- 2) 摄像头节点 ---"
if ! ls /dev/video* >/dev/null 2>&1; then
	echo "  没有 /dev/video* —— 摄像头可能没插好，或模块未加载"
else
	# rkisp_mainpath 的名字是最权威的线索（节点编号不固定）
	FOUND_MAIN=""
	for n in /sys/class/video4linux/video*; do
		[ -e "$n/name" ] || continue
		name=$(cat "$n/name" 2>/dev/null)
		dev=/dev/$(basename "$n")
		case "$name" in
			*rkisp_mainpath*)
				echo "  $dev  <- rkisp_mainpath（CSI 预览就用它）"
				FOUND_MAIN="$dev"
				;;
			*rkcif*|*rkisp*)
				echo "  $dev  $name"
				;;
			*)
				echo "  $dev  $name"
				;;
		esac
	done
	[ -n "$FOUND_MAIN" ] || echo "  !! 没找到 rkisp_mainpath：ISP 没起来？先 insmod 相机模块"
fi

echo
echo "--- 3) 谁占着摄像头 ---"
any=0
for p in $QZCAM_HOGS; do
	if proc_running "$p"; then
		echo "  [占用] $p  ← 会独占 /dev/video*，QZcam 打不开"
		any=1
	fi
done
proc_running qzcam && { echo "  [运行] qzcam（我们的相机）"; any=1; }
[ "$any" = 0 ] && echo "  没有占用者"

if [ "$FREE" = 1 ]; then
	echo "  -- 释放摄像头 --"
	for p in $QZCAM_HOGS; do
		proc_running "$p" && { killall "$p" 2>/dev/null; echo "  已停 $p"; }
	done
	[ -x /oem/usr/bin/RkLunch-stop.sh ] && /oem/usr/bin/RkLunch-stop.sh >/dev/null 2>&1 && echo "  已执行 RkLunch-stop.sh"
	sleep 1
fi

echo
echo "--- 4) 可用工具 ---"
for t in v4l2-ctl media-ctl ffmpeg; do
	p=$(command -v $t 2>/dev/null)
	[ -n "$p" ] && echo "  [有] $t  ($p)" || echo "  [无] $t"
done

if [ -n "$FOUND_MAIN" ] && command -v v4l2-ctl >/dev/null 2>&1; then
	echo
	echo "--- 5) $FOUND_MAIN 支持的格式 ---"
	v4l2-ctl --device="$FOUND_MAIN" --list-formats-ext 2>&1 | sed -n '1,40p' | sed 's/^/  /'

	echo
	echo "--- 6) $FOUND_MAIN 的参数（曝光/增益/镜像等）---"
	v4l2-ctl --device="$FOUND_MAIN" --list-ctrls 2>&1 | sed -n '1,30p' | sed 's/^/  /'
fi

if [ "$CAPTURE" = 1 ] && [ -n "$FOUND_MAIN" ] && command -v v4l2-ctl >/dev/null 2>&1; then
	echo
	echo "--- 7) 抓 1 帧 NV12 验证真出图 ---"
	rm -f /tmp/qzcam-doctor.yuv
	v4l2-ctl --device="$FOUND_MAIN" \
		--set-fmt-video=width=640,height=480,pixelformat=NV12 \
		--stream-mmap --stream-count=1 --stream-to=/tmp/qzcam-doctor.yuv 2>&1 | sed 's/^/  /'
	if [ -s /tmp/qzcam-doctor.yuv ]; then
		echo "  OK：抓到 $(wc -c </tmp/qzcam-doctor.yuv) 字节（640x480 NV12 应为 460800）"
		echo "  想看画面：拉到电脑上 ffplay -video_size 640x480 -pixel_format nv12 /tmp/qzcam-doctor.yuv"
	else
		echo "  失败：一帧都没抓到（摄像头没出流 / 被占用 / 格式不支持）"
	fi
fi

echo
echo "--- 结论与怎么用 ---"
if [ -n "$FOUND_MAIN" ]; then
	echo "  取景节点：$FOUND_MAIN"
	echo "  固定写法（跳过自动探测）："
	echo "    export QZCAM_DEV=$FOUND_MAIN"
	echo "    export QZCAM_CAPTURE=640x480      # 或 1280x720 / 2304x1296"
	echo "  重启相机：/oem/usr/etc/init.d/S30qzcam restart"
else
	echo "  没找到 rkisp_mainpath：先 sudo sh /oem/usr/share/qzcam/camera_doctor.sh --free，"
	echo "  再 insmod /oem/usr/lib/camera/*.ko（顺序见 S30qzcam 的 load_camera）"
fi
echo "  提示：官方文档说 V4L2 直取可能偏暗/偏绿（缺 ISP 3A），"
echo "        QZcam 现在的取景就是这条路径；要 ISP 调好的图需接 rkaiq/RKMPI。"
echo "======================================"
