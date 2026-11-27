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

echo ">> DDM 自动登录（必须走真正的图形会话，否则 graphical-session.target 起不来）"
# tty1 + agetty --autologin 只能拿到 CLASS=user 的会话；logind 不会激活
# graphical-session.target，dde-shell 的桌面插件永远不启动，屏幕只有光标。
DDM_CFG=/etc/dsg/configs/overrides/org.deepin.dde.ddm/org.deepin.dde.ddm
mkdir -p "$DDM_CFG"
# 复用 DDM 的 Treeland，避免用户合成器无法访问归 dde 所有的 0600 AuthInfo 套接字。
cat > "$DDM_CFG/autologin.json" <<EOF
{
  "magic": "dsg.config.override",
  "version": "1.0",
  "contents": {
    "autologinUser": { "value": "$USER_NAME" },
    "autologinSession": { "value": "treeland.desktop" }
  }
}
EOF
# DDM 0.5.0 的 ddm-autologin PAM 栈第一行引用了本镜像里不存在的
# pam_inhibit_autologin.so；requisite 缺模块会直接判认证失败，自动登录进不去。
sed -i 's|^auth[[:space:]]*requisite[[:space:]]*pam_inhibit_autologin\.so|#auth requisite pam_inhibit_autologin.so|' /etc/pam.d/ddm-autologin 2>/dev/null || true
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf

echo ">> 会话环境变量"
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-dde.conf <<'EOF'
QT_QPA_PLATFORM=wayland
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=DDE
XDG_SESSION_DESKTOP=Treeland
EOF

echo ">> 默认壁纸（dde-wallpapers 未打包，补一个占位 jpg 避免 wallpaper-factory 报错）"
mkdir -p /usr/share/wallpapers/deepin
printf '%s' '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMQD/2wBDAAgGBgcGBwgICAgICAkJCQoKCgkJCQkKCgoKCgoMDAwKCgoKCgoKDAwMDA0ODQ0NDA0ODg8PDxISEREVFRUZGR//xABMAAEBAAAAAAAAAAAAAAAAAAAABwEBAQAAAAAAAAAAAAAAAAAAAAUQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCAAkAEADASIAAhEAAxEA/9oADAMBAAIRAxEAPwCagKyaAAAAAAAAAAAAAAAAAAAAAA//2Q==' \
  | base64 -d > /usr/share/wallpapers/deepin/deepin-default.jpg
chmod 644 /usr/share/wallpapers/deepin/deepin-default.jpg

echo ">> 服务"
systemctl enable ddm 2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable accounts-daemon 2>/dev/null || true
systemctl enable polkit 2>/dev/null || true
systemctl enable systemd-timesyncd 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

if [ "${IMAGE_SESSION_CHECK:-0}" = "1" ]; then
  echo ">> 启用 CI 会话自检（收集 DDM 日志并验证 dde-session/dde-shell）"
  install -d -m 0755 /usr/lib/dde-image
  install -m 0755 /tmp/check-session.sh /usr/lib/dde-image/check-session.sh
  install -m 0644 /tmp/dde-image-session-check.service \
    /etc/systemd/system/dde-image-session-check.service
  systemctl enable dde-image-session-check.service
fi

echo ">> grub: 串口控制台（CI 里用 qemu -nographic 才能看到启动过程）"
if [ -f /etc/default/grub ]; then
  # 不要 quiet：它把 loglevel 压到 4，内核的 "Linux version" 之类 INFO
  # 全被丢掉，串口就只有 GRUB 菜单、看着像内核没启动。
  # 只保留 ttyS0：headless QEMU 没有真正的 tty0，混进 console= 会让
  # initramfs 的 run-init 打不开 /dev/console。
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200 loglevel=7 systemd.show_status=yes"/' /etc/default/grub
  grep -q '^GRUB_TERMINAL' /etc/default/grub || echo 'GRUB_TERMINAL="console serial"' >> /etc/default/grub
  grep -q '^GRUB_SERIAL_COMMAND' /etc/default/grub || echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >> /etc/default/grub
fi

echo ">> machine-id：必须真实存在，否则 accounts-daemon 直接 abort，"
echo ">> treeland 拿不到 org.freedesktop.Accounts 会 Fatal，桌面就起不来。"
# systemd-firstboot 已 mask，指望首启自动生成会落空；这里直接落盘一个。
if [[ ! -s /etc/machine-id ]]; then
  systemd-machine-id-setup 2>/dev/null || true
fi
if [[ ! -s /etc/machine-id ]]; then
  tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
fi
chmod 444 /etc/machine-id
mkdir -p /var/lib/dbus
ln -sfn /etc/machine-id /var/lib/dbus/machine-id
systemctl mask systemd-firstboot.service 2>/dev/null || true

echo ">> 配置完成"
