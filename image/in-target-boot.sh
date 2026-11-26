#!/bin/bash
# Runs inside the image (chroot) to install GRUB and rebuild the initramfs.
#   in-target-boot.sh <loop-device> <root-uuid> [esp-uuid]
#
# Kept as a separate file on purpose: inline `bash -c "..."` from the outer
# script means every $var gets expanded by the *outer* shell (and `set -u`
# then aborts with "t: unbound variable").
set -e

LOOP_DEV="${1:?需要 loop 设备路径}"
ROOT_UUID="${2:-}"
ESP_UUID="${3:-}"
DDIR=/boot/grub
KVER="$(ls /lib/modules | head -1)"
KERNEL="/boot/vmlinuz-$KVER"
INITRD="/boot/initrd.img-$KVER"
KERNEL_CMDLINE="ro console=ttyS0,115200 console=tty0 loglevel=7"

# GRUB 不需要读 ext4 根分区：把内核和 initrd 放到 ESP（FAT32）上，
# 从 bootloader 所在分区直接加载。这样即使 search/UUID/分区探测失灵，
# 只要固件能找到 BOOTX64.EFI 就能进内核；根分区仍由 initramfs 按 UUID 挂载。
[[ -f "$KERNEL" ]] || { echo "!! 缺少 $KERNEL" >&2; exit 1; }
[[ -f "$INITRD" ]] || { echo "!! 缺少 $INITRD" >&2; exit 1; }
mkdir -p /boot/efi
cp -f "$KERNEL" /boot/efi/vmlinuz
cp -f "$INITRD" /boot/efi/initrd.img
echo "--- ESP 引导文件 ---"
ls -lh /boot/efi/vmlinuz /boot/efi/initrd.img /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true

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

# 自己写 grub.cfg：内核/initrd 已复制到 ESP，这里只依赖 FAT32 驱动。
# 之前从 ext4 根分区读 /boot/vmlinuz-* 时，即使 fallback 固定到
# (hd0,gpt3) 也报 "file ... not found" + "you need to load the kernel first"。
# 现在第一项按 ESP UUID 搜索，第二项固定 (hd0,gpt2)，两者读同一份文件。
cat > "$DDIR/grub.cfg" <<EOF
set timeout=3
set default=0
set fallback="1"

menuentry 'DDE on Debian forky' --class debian --class gnu-linux {
    insmod part_gpt
    insmod fat
    insmod gzio
    search --no-floppy --fs-uuid --set=root $ESP_UUID
    echo 'Loading Linux $KVER from ESP ...'
    linux /vmlinuz root=UUID=$ROOT_UUID $KERNEL_CMDLINE
    echo 'Loading initial ramdisk from ESP ...'
    initrd /initrd.img
}

menuentry 'DDE on Debian forky (fixed partition)' --class debian {
    insmod part_gpt
    insmod fat
    insmod gzio
    set root=(hd0,gpt2)
    echo 'Loading Linux $KVER from ESP (fixed hd0,gpt2) ...'
    linux /vmlinuz root=UUID=$ROOT_UUID $KERNEL_CMDLINE
    echo 'Loading initial ramdisk from ESP ...'
    initrd /initrd.img
}
EOF
echo "  grub.cfg 已写入（UUID=$(echo "$ROOT_UUID")）"

# UEFI：生成"自包含"的 BOOTX64.EFI。
# grub-install --removable 只放一个瘦引导器，运行时仍要按 prefix 去磁盘上找
# /boot/grub/x86_64-efi/*.mod；而它跑在 ESP 上，prefix 指向 ESP，root 分区里
# 那 308 个模块它根本看不到，于是启动必报
#   error: file /boot/grub/x86_64-efi/linux.mod not found
# grub-mkstandalone 把 grub.cfg 和所需模块全部内嵌进单个 .efi，彻底摆脱
# 外部文件依赖（live 镜像的标准做法）。
if command -v grub-mkstandalone >/dev/null 2>&1; then
  mkdir -p /boot/efi/EFI/BOOT /boot/efi/EFI/DDE
  grub-mkstandalone -O x86_64-efi \
    -o /boot/efi/EFI/BOOT/BOOTX64.EFI \
    --modules="part_gpt part_msdos fat ext2 normal linux echo search \
search_fs_uuid search_label configfile all_video gzio gfxterm font" \
    "boot/grub/grub.cfg=$DDIR/grub.cfg"
  cp -f /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/DDE/BOOTX64.EFI
  echo "  BOOTX64.EFI(standalone): $(stat -c%s /boot/efi/EFI/BOOT/BOOTX64.EFI) 字节"
else
  echo "  !! 没有 grub-mkstandalone"
fi

# virtio / AHCI / IDE 磁盘都要能启动。MODULES=most 理论上够，但 forky 默认
# 可能是 MODULES=dep（只收当前机器探测到的控制器），那样打出来的 initramfs
# 换个接口就起不来：内核会报
#   VFS: Cannot open root device "UUID=..." or unknown-block(0,0): error -19
# 所以这里既设 most，又在 /etc/initramfs-tools/modules 里点名关键驱动。
mkdir -p /etc/initramfs-tools
if grep -q '^MODULES=' /etc/initramfs-tools/initramfs.conf 2>/dev/null; then
  sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
else
  echo 'MODULES=most' >> /etc/initramfs-tools/initramfs.conf
fi
cat > /etc/initramfs-tools/modules <<'MODS'
ata_piix
ahci
sd_mod
virtio_blk
virtio_pci
virtio_net
scsi_mod
ext4
MODS
update-initramfs -u -k all

echo "--- initramfs 中的存储驱动 ---"
if command -v lsinitramfs >/dev/null 2>&1; then
  lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null \
    | grep -oE '(ata_piix|ahci|sd_mod|virtio_blk|virtio_pci|scsi_mod|ext4)\.ko[.a-z]*' \
    | sed 's/\.ko.*//' | sort -u | tr '\n' ' '
  echo
else
  echo "(没有 lsinitramfs)"
fi
