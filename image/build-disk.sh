#!/bin/bash
# Build a bootable DDE-on-Debian image.
#
#   sudo ./build-disk.sh [output-dir]
#
# Produces <output-dir>/dde-forky.img (raw) and .qcow2 if qemu-img exists.
# Needs root (loop devices + chroot). Safe to run in a container/CI runner;
# it only writes inside $WORK and $OUT.
#
# Layout: GPT -> ESP 512M (vfat) + root ext4. GRUB is installed for both
# UEFI (--removable, so no NVRAM entry needed) and BIOS from inside the image.
set -euo pipefail

SUITE="${SUITE:-forky}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
OUR_REPO="${OUR_REPO:-https://tensortensor666.github.io/dde-debian-repo}"
IMGSIZE="${IMGSIZE:-10G}"
OUT="${1:-$PWD/out}"

DESKTOP_PKGS="
dde-session dde-shell dde-launchpad dde-application-manager
dde-tray-loader dde-daemon dde-control-center dde-polkit-agent
dde-services deepin-desktop-schemas deepin-icon-theme dde-api
ddm treeland treeland-wayland-session
"

BASE_PKGS="
ca-certificates curl gnupg apt-transport-https
systemd-sysv dbus udev kmod
linux-image-amd64
grub-efi-amd64 grub-pc-bin grub2-common
initramfs-tools e2fsprogs e2fsprogs-l10n
locales console-setup keyboard-configuration tzdata
network-manager sudo passwd
accountsservice polkitd upower rtkit
seatd dbus-user-session
fonts-noto-cjk fonts-dejavu-core
bash-completion nano less
"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root（loop 设备 + chroot）"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d /var/tmp/ddeimg.XXXXXX)"
ROOTFS="$WORK/rootfs"
MNT="$WORK/mnt"
LOOP=""
mkdir -p "$ROOTFS" "$MNT" "$OUT"

cleanup() {
  set +e
  # mountpoint -q 对 --rbind 出来的子挂载不可靠，直接 umount -R 并忽略失败；
  # 否则残留的 $MNT/sys 会让后面的 rm -rf 报
  # "Operation not permitted" 并把整个脚本的退出码变成 32。
  for d in "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/boot/efi" "$MNT"; do
    umount -R "$d" 2>/dev/null
  done
  for d in "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys"; do
    umount -R "$d" 2>/dev/null
  done
  [[ -n "$LOOP" ]] && { losetup -d "$LOOP" 2>/dev/null; sleep 1; }
  # 先尝试干净删除，失败就留给系统 tmp 清理，绝不因为清理失败而让构建算失败
  rm -rf "$WORK" 2>/dev/null
  return 0
}
trap cleanup EXIT

log "1/10 debootstrap $SUITE ($ARCH)"
apt-get update -qq
apt-get install -y --no-install-recommends \
  debootstrap dosfstools e2fsprogs parted util-linux rsync >/dev/null
debootstrap --variant=minbase --arch="$ARCH" \
  --include=ca-certificates,apt-utils,systemd-sysv \
  "$SUITE" "$ROOTFS" "$MIRROR"

log "2/10 挂载 /proc /sys /dev"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
mount --rbind /dev "$ROOTFS/dev"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
EOF

log "3/10 装 gpgv（验证我们仓库签名必需）"
# minbase 没有 gpgv，apt 会因无法验证 InRelease 而报
# "does not have a Release file"，很容易误判成仓库有问题。
chroot "$ROOTFS" /bin/bash -c "
  set -e
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gpgv gnupg
"

log "4/10 注入我们的仓库并装内核/固件"
curl -fsSL "$OUR_REPO/dde-repo.key" -o "$ROOTFS/usr/share/keyrings/dde-repo.gpg"
cat > "$ROOTFS/etc/apt/sources.list.d/dde.list" <<EOF
deb [signed-by=/usr/share/keyrings/dde-repo.gpg] $OUR_REPO dde26 main
EOF
# 注意：$BASE_PKGS 是多行字符串，直接塞进 bash -c "..." 会让每一行变成
# 独立命令（"systemd-sysv: command not found"）。先压成一行。
BASE_ONE="$(echo $BASE_PKGS)"
chroot "$ROOTFS" /bin/bash -c "
  set -e
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $BASE_ONE
"

log "5/10 安装 DDE 桌面（最耗时）"
DESKTOP_ONE="$(echo $DESKTOP_PKGS)"
chroot "$ROOTFS" /bin/bash -c "
  set -e
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $DESKTOP_ONE
"

log "6/10 镜像内配置"
install -m 0755 "$HERE/in-target.sh" "$ROOTFS/tmp/in-target.sh"
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  IMAGE_USER="${IMAGE_USER:-deepin}" IMAGE_PASS="${IMAGE_PASS:-deepin}" \
  IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-dde}" \
  /bin/bash /tmp/in-target.sh

log "7/10 清理"
chroot "$ROOTFS" /bin/bash -c "
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /root/.bash_history
" || true
rm -f "$ROOTFS/tmp/in-target.sh"
umount -R "$ROOTFS/dev" 2>/dev/null || true
umount "$ROOTFS/proc" "$ROOTFS/sys" 2>/dev/null || true
ROOTFS_SIZE="$(du -sh "$ROOTFS" | cut -f1)"
log "     rootfs 大小: $ROOTFS_SIZE"

log "8/10 建分区镜像 ($IMGSIZE)"
IMG="$OUT/dde-$SUITE.img"
rm -f "$IMG"
truncate -s "$IMGSIZE" "$IMG"
# GPT + BIOS 启动需要一个 1MiB 的 bios_grub 分区来放 core.img，
# 否则 grub-install --target=i386-pc 会报 "will not proceed with blocklists"。
parted -s "$IMG" mklabel gpt \
  mkpart bios_grub 1MiB 2MiB \
  set 1 bios_grub on \
  mkpart ESP fat32 2MiB 514MiB \
  set 2 esp on \
  mkpart root ext4 514MiB 100%
LOOP="$(losetup --show -fP "$IMG")"
sleep 2
[[ -b "${LOOP}p3" ]] || die "loop 分区节点没出现：${LOOP}p3"
mkfs.vfat -F32 -n DDEESP "${LOOP}p2" >/dev/null
mkfs.ext4 -L dderoot -q "${LOOP}p3"

log "9/10 灌入 rootfs 并装 bootloader"
mount "${LOOP}p3" "$MNT"
rsync -aHAX --numeric-ids "$ROOTFS/" "$MNT/"

# initramfs 的 run-init 在 udev 启动之前就要 /dev/console 和 /sbin/init。
# debootstrap 的 minbase 不保证有静态设备节点，chroot 里 rbind 的 /dev
# 也不会落盘；缺了它们会报
#   run-init: opening console: No such file or directory
#   Target filesystem doesn't have requested /sbin/init.
#   No init found. Try passing init= bootarg.
log "     检查/修复 rootfs 的 init 与 /dev 节点"
ls -l "$MNT/sbin/init" "$MNT/usr/lib/systemd/systemd" "$MNT/lib/systemd/systemd" 2>&1 || true
if [[ ! -e "$MNT/sbin/init" ]]; then
  if [[ -x "$MNT/lib/systemd/systemd" ]]; then
    ln -sfn ../lib/systemd/systemd "$MNT/sbin/init"
  elif [[ -x "$MNT/usr/lib/systemd/systemd" ]]; then
    ln -sfn ../usr/lib/systemd/systemd "$MNT/sbin/init"
  else
    die "rootfs 里找不到 systemd 二进制，无法建 /sbin/init"
  fi
fi
mkdir -p "$MNT/dev"
mknod -m 622 "$MNT/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "$MNT/dev/null" c 1 3 2>/dev/null || true
mknod -m 666 "$MNT/dev/zero" c 1 5 2>/dev/null || true
mknod -m 666 "$MNT/dev/tty" c 5 0 2>/dev/null || true
ls -l "$MNT/sbin/init" "$MNT/dev/console" 2>&1 || true

echo "--- 内核命令行（grub 前）---"
grep -E "^(GRUB_CMDLINE|GRUB_TERMINAL|GRUB_SERIAL)" "$MNT/etc/default/grub" || echo "(无 /etc/default/grub)"
mkdir -p "$MNT/boot/efi"
mount "${LOOP}p2" "$MNT/boot/efi"
for d in dev proc sys; do mount --rbind "/$d" "$MNT/$d"; done
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p3")"
ESP_UUID="$(blkid -s UUID -o value "${LOOP}p2")"
cat > "$MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID /          ext4 errors=remount-ro 0 1
UUID=$ESP_UUID  /boot/efi  vfat umask=0077        0 1
EOF

install -m 0755 "$HERE/in-target-boot.sh" "$MNT/tmp/in-target-boot.sh"
chroot "$MNT" /bin/bash /tmp/in-target-boot.sh "$LOOP" "$ROOT_UUID" "$ESP_UUID"
rm -f "$MNT/tmp/in-target-boot.sh"
echo "--- grub.cfg 里的内核命令行 ---"
grep -m2 -E "^[[:space:]]*linux" "$MNT/boot/grub/grub.cfg" || echo "(没找到 linux 行)"

log "10/10 收尾"
# 同样别用 mountpoint 判断（--rbind 出来的子挂载识别不了），直接卸。
for d in "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/boot/efi" "$MNT"; do
  umount -R "$d" 2>/dev/null || true
done
# 卸载后复查一次：rbind /dev 期间看到的 /dev/console 可能是宿主机的，
# 这里才是最终镜像里真正存在的文件。
echo "--- 卸载后镜像内的 init/console ---"
ls -l "$MNT/sbin/init" "$MNT/usr/lib/systemd/systemd" "$MNT/dev/console" 2>&1 || true
ls -ld "$MNT/sbin" "$MNT/usr" "$MNT/lib" "$MNT/dev" 2>&1 || true
sync
losetup -d "$LOOP" 2>/dev/null || true
sleep 1
LOOP=""
if command -v qemu-img >/dev/null; then
  qemu-img convert -f raw -O qcow2 "$IMG" "$OUT/dde-$SUITE.qcow2" || warn "qcow2 转换失败（raw 仍可用）"
fi

ls -lh "$OUT"
log "完成: $IMG"
