#!/bin/bash
# Runs inside the image (chroot) to install GRUB and rebuild the initramfs.
#   in-target-boot.sh <loop-device>
#
# Kept as a separate file on purpose: inline `bash -c "..."` from the outer
# script means every $var gets expanded by the *outer* shell (and `set -u`
# then aborts with "t: unbound variable").
set -e

LOOP_DEV="${1:?需要 loop 设备路径}"
DDIR=/boot/grub

echo "--- grub 模块源 ---"
for t in i386-pc x86_64-efi; do
  echo "  /usr/lib/grub/$t: $(ls "/usr/lib/grub/$t" 2>/dev/null | wc -l) 个模块"
done

grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=DDE --removable --no-nvram --no-floppy --recheck
grub-install --target=i386-pc --no-floppy --recheck "$LOOP_DEV"

# GRUB 的引导镜像（core.img / BOOTX64.EFI）只有最小模块，运行时要靠
# /boot/grub/<target>/*.mod 补齐。本环境里 grub-install 没复制这些文件，
# 启动会一路报
#   error: file /boot/grub/x86_64-efi/linux.mod not found
# 最后 "Failed to boot both default and fallback entries"。
for t in i386-pc x86_64-efi; do
  if [ -d "/usr/lib/grub/$t" ]; then
    mkdir -p "$DDIR/$t"
    cp -a "/usr/lib/grub/$t/." "$DDIR/$t/"
    echo "  $t 已安装模块: $(ls "$DDIR/$t" 2>/dev/null | wc -l)"
  else
    echo "  !! /usr/lib/grub/$t 不存在"
  fi
done

grub-mkconfig -o "$DDIR/grub.cfg"

# virtio / AHCI 磁盘都要能启动：MODULES=most 会把 virtio_blk 等打进 initramfs，
# 否则虚拟机里会卡在 initramfs 找不到根设备。
mkdir -p /etc/initramfs-tools
if grep -q '^MODULES=' /etc/initramfs-tools/initramfs.conf 2>/dev/null; then
  sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
else
  echo 'MODULES=most' >> /etc/initramfs-tools/initramfs.conf
fi
update-initramfs -u -k all

echo "--- initramfs 中的存储驱动 ---"
KVER="$(ls /lib/modules | head -1)"
if command -v lsinitramfs >/dev/null 2>&1; then
  lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null \
    | grep -cE 'virtio_blk|ahci|sd_mod' || echo "0"
else
  echo "(没有 lsinitramfs)"
fi
