#!/usr/bin/env bash
#
# QZcam 部署：用 adb 把交叉编译产物推到设备，省掉每次打包 update.img。
#
# 设备落点（与 SDK/project/app/qzcam/Makefile 的安装规则一一对应）：
#   out/bin/qzcam                              -> /oem/usr/bin/qzcam
#   out/usr/share/fonts/*.ttf                  -> /oem/usr/share/fonts/
#   out/etc/init.d/S30qzcam                    -> /oem/usr/etc/init.d/
#   out/root/etc/init.d/S30qzcam               -> /etc/init.d/（rootfs 可写时）
#   out/lib/camera/*.ko                        -> /oem/usr/lib/camera/
#
# 用法：
#   tools/build/deploy_qzcam.sh                 推程序 + 开机脚本 + （有的）相机模块，然后重启
#   tools/build/deploy_qzcam.sh --build         先让 SDK 交叉编译（./build.sh app）
#   tools/build/deploy_qzcam.sh --no-restart    只推，不重启
#   tools/build/deploy_qzcam.sh --modules       额外推相机驱动模块（第一次上机要）
#   tools/build/deploy_qzcam.sh --no-replace    推完不做"接管桌面"（默认会做：把 QZdesk 停用/换掉）
#   tools/build/deploy_qzcam.sh --replace-only  只做接管桌面，不推文件
#   tools/build/deploy_qzcam.sh --doctor        设备上跑相机体检（节点/格式/占用，还抓 1 帧验证）
#   tools/build/deploy_qzcam.sh --status        只看设备状态（进程、日志、节点）
#   tools/build/deploy_qzcam.sh --log [秒]      部署后盯一段日志（默认 15 秒）
#
# 环境变量：
#   QZCAM_SDK       SDK 根目录（默认 = 脚本所在位置的上两级）
#   QZCAM_DEVICE    adb 目标（多设备时用）
#
set -euo pipefail

# 解析软链：本脚本是唯一来源（住在 SDK 里），开发仓库里那份是指向它的软链
self=$(readlink -f -- "$0" 2>/dev/null || echo "$0")
script_dir=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)
SDK=${QZCAM_SDK:-$(CDPATH= cd -- "$script_dir/../.." && pwd)}   # SDK/tools/build → SDK
ADB=${ADB:-adb}
DEVICE=${QZCAM_DEVICE:-}

OUT="$SDK/project/app/qzcam/out"     # 与 oem 分区 /oem/usr 同构
STAGE=/tmp/qzcam-deploy

push=1 do_build=0 do_restart=1 modules=0 log_secs=0 status_only=0
do_replace=1 replace_only=0 doctor_only=0
paths_only=0 paths_arg=all

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--build)      do_build=1 ;;
		--no-restart) do_restart=0 ;;
		--modules)    modules=1 ;;
		--status)     status_only=1 ;;
		--no-replace) do_replace=0 ;;
		--replace-only) replace_only=1; do_build=0 ;;
		--doctor)     doctor_only=1 ;;
		--paths)      paths_only=1; paths_arg=${2:-all}; shift ;;
		--log)        log_secs=${2:-15}; shift ;;
		-h|--help)    usage; exit 0 ;;
		*)            echo "未知参数：$1"; usage; exit 1 ;;
	esac
	shift
done

adb_cmd() {
	if [ -n "$DEVICE" ]; then "$ADB" -s "$DEVICE" "$@"; else "$ADB" "$@"; fi
}

need_device() {
	adb_cmd get-state >/dev/null 2>&1 || {
		echo "连不上设备（adb devices 看一眼，或设 QZCAM_DEVICE=ip:port）"
		exit 1
	}
}

if [ "$do_build" = 1 ]; then
	echo "== 交叉编译（$SDK: ./build.sh app）=="
	( cd "$SDK" && ./build.sh app ) || { echo "编译失败"; exit 1; }
fi

# 三路径出图验证：LCD / V4L2 / RTSP / UVC（互斥，脚本内部逐条切换并恢复）
if [ "$paths_only" = 1 ]; then
	need_device
	adb_cmd shell "sh /oem/usr/share/qzcam/camera_paths_test.sh $paths_arg"
	exit 0
fi

# 相机体检：设备上一条命令看清节点/格式/占用（--free 会先让出摄像头，--capture 抓 1 帧）
if [ "${doctor_only:-0}" = 1 ]; then
	need_device
	adb_cmd shell "sh /oem/usr/share/qzcam/camera_doctor.sh --free --capture" || \
		adb_cmd shell "sh /oem/usr/share/qzcam/camera_doctor.sh"
	exit 0
fi

if [ "$status_only" = 1 ]; then
	need_device
	echo "== 进程 =="
	adb_cmd shell "ps | grep '[q]zcam' || echo '  没有 qzcam 在跑'"
	echo "== 视频节点 =="
	adb_cmd shell "ls /dev/video* 2>/dev/null || echo '  没有 /dev/video*（相机模块没加载？）'"
	echo "== 日志尾部 =="
	adb_cmd shell "tail -20 /var/log/qzcam.log 2>/dev/null || echo '  还没有日志'"
	exit 0
fi

# 只做"接管桌面"：设备上已经有 qzcam 了，只想把 QZdesk 换掉/停用
if [ "$replace_only" = 1 ]; then
	need_device
	echo "== 只做接管桌面（不推文件）=="
	adb_cmd shell "sh /oem/usr/share/qzcam/replace_desktop.sh"
	exit 0
fi

[ -x "$OUT/bin/qzcam" ] || { echo "还没有交叉编译产物：$OUT/bin/qzcam（先跑 --build）"; exit 1; }
if file "$OUT/bin/qzcam" | grep -q "x86-64"; then
	echo "$OUT/bin/qzcam 是 x86 模拟器产物，推上去跑不了 —— 先 --build 交叉编译"
	exit 1
fi

need_device
rm -rf "$STAGE"; mkdir -p "$STAGE"
adb_cmd push "$OUT/bin/qzcam" "$STAGE/qzcam" >/dev/null
if [ -d "$OUT/usr/share/fonts" ]; then
	mkdir -p "$STAGE/fonts"; cp -a "$OUT/usr/share/fonts/." "$STAGE/fonts/" 2>/dev/null || true
fi
if [ "$modules" = 1 ] && [ -d "$OUT/lib/camera" ]; then
	mkdir -p "$STAGE/camera"; cp -a "$OUT/lib/camera/." "$STAGE/camera/" 2>/dev/null || true
fi
[ -f "$OUT/etc/init.d/S30qzcam" ] && { mkdir -p "$STAGE/init"; cp "$OUT/etc/init.d/S30qzcam" "$STAGE/init/"; }
# 桌面接管脚本（替换 QZdesk 用，也随镜像装在同一个位置）
[ -d "$OUT/usr/share/qzcam" ] && { mkdir -p "$STAGE/share"; cp -a "$OUT/usr/share/qzcam/." "$STAGE/share/" 2>/dev/null || true; }
[ -d "$STAGE/fonts" ] && adb_cmd push "$STAGE/fonts" /tmp/qzcam-deploy-fonts >/dev/null
[ -d "$STAGE/camera" ] && adb_cmd push "$STAGE/camera" /tmp/qzcam-deploy-camera >/dev/null
[ -d "$STAGE/init" ] && adb_cmd push "$STAGE/init" /tmp/qzcam-deploy-init >/dev/null
[ -d "$STAGE/share" ] && adb_cmd push "$STAGE/share" /tmp/qzcam-deploy-share >/dev/null

echo "== 安装到设备 =="
adb_cmd shell "set -e
mkdir -p /oem/usr/bin /oem/usr/share/fonts /oem/usr/etc/init.d /oem/usr/lib/camera /userdata/qzcam
cp -f /tmp/qzcam-deploy/qzcam /oem/usr/bin/qzcam
chmod 755 /oem/usr/bin/qzcam
[ -d /tmp/qzcam-deploy-fonts ] && cp -f /tmp/qzcam-deploy-fonts/*.ttf /oem/usr/share/fonts/ 2>/dev/null || true
[ -d /tmp/qzcam-deploy-camera ] && cp -f /tmp/qzcam-deploy-camera/*.ko /oem/usr/lib/camera/ 2>/dev/null || true
if [ -f /tmp/qzcam-deploy-init/S30qzcam ]; then
  cp -f /tmp/qzcam-deploy-init/S30qzcam /oem/usr/etc/init.d/S30qzcam
  chmod 755 /oem/usr/etc/init.d/S30qzcam
  cp -f /tmp/qzcam-deploy-init/S30qzcam /etc/init.d/S30qzcam 2>/dev/null && chmod 755 /etc/init.d/S30qzcam || true
fi
mkdir -p /oem/usr/share/qzcam
if [ -d /tmp/qzcam-deploy-share ]; then
  cp -f /tmp/qzcam-deploy-share/* /oem/usr/share/qzcam/ 2>/dev/null || true
  chmod 755 /oem/usr/share/qzcam/*.sh 2>/dev/null || true
fi
rm -rf /tmp/qzcam-deploy /tmp/qzcam-deploy-fonts /tmp/qzcam-deploy-camera /tmp/qzcam-deploy-init /tmp/qzcam-deploy-share
echo '安装完成'"

if [ "$do_replace" = 1 ]; then
	echo "== 接管桌面（停用/替换 QZdesk，相机独占屏幕）=="
	adb_cmd shell "sh /oem/usr/share/qzcam/replace_desktop.sh" || true
	do_restart=0     # 接管脚本内部会重启相机，避免重复重启
fi

if [ "$do_restart" = 1 ]; then
	echo "== 重启相机 =="
	adb_cmd shell "/oem/usr/etc/init.d/S30qzcam stop || true"
	adb_cmd shell "/oem/usr/etc/init.d/S30qzcam start"
fi

if [ "$log_secs" -gt 0 ]; then
	echo "== 日志（$log_secs 秒）=="
	adb_cmd shell "timeout $log_secs tail -f /var/log/qzcam.log" || true
fi

echo
echo "完成。看状态：tools/build/deploy_qzcam.sh --status"
