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

chroot "$MNT" /bin/bash -c "
  set -e
  echo '--- grub 模块源 ---'
  ls /usr/lib/grub/i386-pc 2>/dev/null | wc -l
  grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=DDE --removable --no-nvram --no-floppy --recheck
  grub-install --target=i386-pc --no-floppy --recheck $LOOP
  # grub-install 只保证生成 core.img，模块文件（all_video.mod/linux.mod…）
  # 需要落在 /boot/grub/i386-pc/ 供运行时加载。某些环境下它没复制过去，
  # 表现为启动时 'error: file /boot/grub/i386-pc/linux.mod not found'。
  if [ ! -e /boot/grub/i386-pc/linux.mod ] && [ -d /usr/lib/grub/i386-pc ]; then
      echo '--- 模块缺失，手动补齐 ---'
      mkdir -p /boot/grub/i386-pc
      cp -a /usr/lib/grub/i386-pc/. /boot/grub/i386-pc/
  fi
  echo '--- 装完后的模块数 ---'
  ls /boot/grub/i386-pc 2>/dev/null | wc -l
  grub-mkconfig -o /boot/grub/grub.cfg
  # GRUB 的 boot 镜像只是"引导器"，运行时还要从 /boot/grub/<target>/ 加载
  # linux.mod / efi_gop.mod 等模块。grub-install 在本环境里没有把模块复制
  # 过去（只生成 core.img / BOOTX64.EFI），于是启动时一路
  #   error: file /boot/grub/x86_64-efi/linux.mod not found
  # 最后 "Failed to boot both default and fallback entries"。
  # 两个 target 都显式补齐，别指望 grub-install。
  for t in i386-pc x86_64-efi; do
    if [ -d "/usr/lib/grub/$t" ]; then
      mkdir -p "/boot/grub/$t"
      cp -a "/usr/lib/grub/$t/." "/boot/grub/$t/"
      echo "  $t modules: $(ls /boot/grub/$t 2>/dev/null | wc -l)"
    else
      echo "  !! /usr/lib/grub/$t 不存在"
    fi
  done
  # 用 virtio / AHCI 磁盘都能启动：MODULES=most 会把 virtio_blk 等打进去，
  # 否则在虚拟机上会卡在 initramfs 找不到根设备。
  mkdir -p /etc/initramfs-tools
  grep -q '^MODULES=' /etc/initramfs-tools/initramfs.conf 2>/dev/null \
      && sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf \
      || echo 'MODULES=most' >> /etc/initramfs-tools/initramfs.conf
  update-initramfs -u -k all
  echo '--- initramfs 里的 virtio/ahci ---'
  lsinitramfs /boot/initrd.img-\$(ls /lib/modules | head -1) 2>/dev/null \
      | grep -cE 'virtio_blk|ahci|sd_mod' || true
"
echo "--- grub.cfg 里的内核命令行 ---"
grep -m2 -E "^[[:space:]]*linux" "$MNT/boot/grub/grub.cfg" || echo "(没找到 linux 行)"

log "10/10 收尾"
# 同样别用 mountpoint 判断（--rbind 出来的子挂载识别不了），直接卸。
for d in "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/boot/efi" "$MNT"; do
  umount -R "$d" 2>/dev/null || true
done
losetup -d "$LOOP" 2>/dev/null || true
sleep 1
LOOP=""
if command -v qemu-img >/dev/null; then
  qemu-img convert -f raw -O qcow2 "$IMG" "$OUT/dde-$SUITE.qcow2" || warn "qcow2 转换失败（raw 仍可用）"
fi

ls -lh "$OUT"
log "完成: $IMG"
