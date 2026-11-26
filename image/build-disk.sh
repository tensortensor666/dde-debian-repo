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
initramfs-tools
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
  for d in "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/boot/efi"; do
    mountpoint -q "$d" && umount -R "$d"
  done
  mountpoint -q "$MNT" && umount -R "$MNT"
  for d in "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys"; do
    mountpoint -q "$d" && umount -R "$d"
  done
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

log "1/9 debootstrap $SUITE ($ARCH)"
apt-get update -qq
apt-get install -y --no-install-recommends \
  debootstrap dosfstools e2fsprogs parted util-linux rsync >/dev/null
debootstrap --variant=minbase --arch="$ARCH" \
  --include=ca-certificates,apt-utils,systemd-sysv \
  "$SUITE" "$ROOTFS" "$MIRROR"

log "2/9 挂载 /proc /sys /dev 并注入我们的仓库"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
mount --rbind /dev "$ROOTFS/dev"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true

curl -fsSL "$OUR_REPO/dde-repo.key" -o "$ROOTFS/usr/share/keyrings/dde-repo.gpg"
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
EOF
cat > "$ROOTFS/etc/apt/sources.list.d/dde.list" <<EOF
deb [signed-by=/usr/share/keyrings/dde-repo.gpg] $OUR_REPO dde26 main
EOF

log "3/9 安装内核/固件（base）"
# 注意：$BASE_PKGS 是多行字符串，直接塞进 bash -c "..." 会让每一行变成
# 独立命令（"systemd-sysv: command not found"）。先压成一行。
BASE_ONE="$(echo $BASE_PKGS)"
chroot "$ROOTFS" /bin/bash -c "
  set -e
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $BASE_ONE
"

log "4/9 安装 DDE 桌面（最耗时）"
DESKTOP_ONE="$(echo $DESKTOP_PKGS)"
chroot "$ROOTFS" /bin/bash -c "
  set -e
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $DESKTOP_ONE
"

log "5/9 镜像内配置"
install -m 0755 "$HERE/in-target.sh" "$ROOTFS/tmp/in-target.sh"
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  IMAGE_USER="${IMAGE_USER:-deepin}" IMAGE_PASS="${IMAGE_PASS:-deepin}" \
  IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-dde}" \
  /bin/bash /tmp/in-target.sh

log "6/9 清理"
chroot "$ROOTFS" /bin/bash -c "
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /root/.bash_history
" || true
rm -f "$ROOTFS/tmp/in-target.sh"
umount -R "$ROOTFS/dev" 2>/dev/null || true
umount "$ROOTFS/proc" "$ROOTFS/sys" 2>/dev/null || true
ROOTFS_SIZE="$(du -sh "$ROOTFS" | cut -f1)"
log "     rootfs 大小: $ROOTFS_SIZE"

log "7/9 建分区镜像 ($IMGSIZE)"
IMG="$OUT/dde-$SUITE.img"
rm -f "$IMG"
truncate -s "$IMGSIZE" "$IMG"
parted -s "$IMG" mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB \
  set 1 esp on \
  mkpart root ext4 513MiB 100%
LOOP="$(losetup --show -fP "$IMG")"
sleep 2
[[ -b "${LOOP}p1" ]] || die "loop 分区节点没出现：${LOOP}p1"
mkfs.vfat -F32 -n DDEESP "${LOOP}p1" >/dev/null
mkfs.ext4 -L dderoot -q "${LOOP}p2"

log "8/9 灌入 rootfs 并装 bootloader"
mount "${LOOP}p2" "$MNT"
rsync -aHAX --numeric-ids "$ROOTFS/" "$MNT/"
mkdir -p "$MNT/boot/efi"
mount "${LOOP}p1" "$MNT/boot/efi"
for d in dev proc sys; do mount --rbind "/$d" "$MNT/$d"; done
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p2")"
ESP_UUID="$(blkid -s UUID -o value "${LOOP}p1")"
cat > "$MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID /          ext4 errors=remount-ro 0 1
UUID=$ESP_UUID  /boot/efi  vfat umask=0077        0 1
EOF

chroot "$MNT" /bin/bash -c "
  set -e
  grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=DDE --removable --no-nvram --recheck
  grub-install --target=i386-pc --recheck $LOOP
  grub-mkconfig -o /boot/grub/grub.cfg
  update-initramfs -u -k all
"

log "9/9 收尾"
for d in "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/boot/efi"; do
  mountpoint -q "$d" && umount -R "$d"
done
umount "$MNT"
losetup -d "$LOOP"; LOOP=""
if command -v qemu-img >/dev/null; then
  qemu-img convert -f raw -O qcow2 "$IMG" "$OUT/dde-$SUITE.qcow2"
fi

ls -lh "$OUT"
log "完成: $IMG"
