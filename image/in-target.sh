#!/bin/bash
# Runs *inside* the image (chroot). Configures locale, user, and autologin.
set -e

export DEBIAN_FRONTEND=noninteractive

USER_NAME="${IMAGE_USER:-deepin}"
USER_PASS="${IMAGE_PASS:-deepin}"
HOSTNAME="${IMAGE_HOSTNAME:-dde}"

echo ">> locale + 时区 + 键盘"
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=zh_CN.UTF-8" > /etc/default/locale
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

echo ">> 主机名"
echo "$HOSTNAME" > /etc/hostname
grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1 $HOSTNAME" >> /etc/hosts

echo ">> 用户 $USER_NAME"
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,video,render,audio,plugdev,netdev "$USER_NAME"
fi
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$USER_PASS" | chpasswd
# 免密 sudo，方便镜像调试
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-image
chmod 440 /etc/sudoers.d/90-image

echo ">> getty 自动登录 tty1（开机直接进桌面）"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
Type=idle
EOF

echo ">> 登录后自动拉起 treeland 会话"
cat > "/home/$USER_NAME/.bash_profile" <<'EOF'
# 在 tty1 登录时直接进入 DDE（treeland）会话；已是图形会话或非 tty1 则跳过。
if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec /usr/bin/treeland-user-wrapper
fi
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.bash_profile"

echo ">> 会话环境变量"
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-dde.conf <<'EOF'
QT_QPA_PLATFORM=wayland
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=DDE
XDG_SESSION_DESKTOP=Treeland
EOF

echo ">> 服务"
# ddm 会和 tty1 的 getty 抢终端，默认关掉；用户想用图形登录界面时
# sudo systemctl enable --now ddm 即可。
systemctl disable ddm 2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable accounts-daemon 2>/dev/null || true
systemctl enable polkit 2>/dev/null || true
systemctl enable systemd-timesyncd 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

echo ">> grub: 串口控制台（CI 里用 qemu -nographic 才能看到启动过程）"
if [ -f /etc/default/grub ]; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0,115200 console=tty0"/' /etc/default/grub
  grep -q '^GRUB_TERMINAL' /etc/default/grub || echo 'GRUB_TERMINAL="console serial"' >> /etc/default/grub
  grep -q '^GRUB_SERIAL_COMMAND' /etc/default/grub || echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >> /etc/default/grub
fi

echo ">> 清理首次开机的阻塞项"
systemctl mask systemd-firstboot.service 2>/dev/null || true
rm -f /etc/machine-id

echo ">> 配置完成"
