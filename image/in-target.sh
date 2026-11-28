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

echo ">> DDE 锁屏服务用户"
getent group lightdm >/dev/null || groupadd --system lightdm
id lightdm >/dev/null 2>&1 || useradd --system --gid lightdm \
  --home-dir /var/lib/lightdm --shell /usr/sbin/nologin lightdm
install -d -o lightdm -g lightdm -m 0750 /var/lib/lightdm

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

echo ">> 图标主题与 hicolor 回退"
APPEARANCE_CFG=/etc/dsg/configs/overrides/org.deepin.dde.appearance/org.deepin.dde.appearance
mkdir -p "$APPEARANCE_CFG"
cat > "$APPEARANCE_CFG/icon_theme.json" <<'EOF'
{
  "magic": "dsg.config.override",
  "version": "1.0",
  "contents": {
    "Icon_Theme": { "value": "Sea", "serial": 1 }
  }
}
EOF
# Sea 的上游继承链指向本镜像未安装的 deepin/Papirus，改用已安装的主题。
SEA_INDEX=/usr/share/icons/Sea/index.theme
if [ -f "$SEA_INDEX" ]; then
  sed -i 's/^Inherits=.*/Inherits=bloom,Adwaita,hicolor/' "$SEA_INDEX"
fi
for gtk_dir in /etc/gtk-3.0 /etc/gtk-4.0; do
  mkdir -p "$gtk_dir"
  cat > "$gtk_dir/settings.ini" <<'EOF'
[Settings]
gtk-icon-theme-name=Sea
gtk-theme-name=deepin
EOF
done

# DTK 的 DCI provider 固定回落到 hicolor，需要预先放入 Dock 必需图标。
install -d /usr/share/icons/hicolor/48x48/apps /usr/share/icons/hicolor/48x48/places
cp -f /usr/share/icons/Sea/apps/scalable/preferences-system.svg \
  /usr/share/icons/hicolor/48x48/apps/
cp -f /usr/share/icons/Sea/places/scalable/deepin-launcher.svg \
  /usr/share/icons/hicolor/48x48/places/
cp -f /usr/share/icons/bloom/apps/48/deepin-multitasking-view.svg \
  /usr/share/icons/hicolor/48x48/apps/
cp -f /usr/share/icons/Adwaita/scalable/places/user-trash.svg \
  /usr/share/icons/hicolor/48x48/places/
cp -f /usr/share/icons/Sea/apps/scalable/dde-file-manager.svg \
  /usr/share/icons/hicolor/48x48/apps/

# 文件管理器侧栏使用 *-symbolic 名称；Sea 提供的是普通彩色 SVG。
for size in 16 48; do
  install -d "/usr/share/icons/hicolor/${size}x${size}/places"
  for pair in \
    user-home:user-home-symbolic \
    folder-desktop:user-desktop-symbolic \
    folder-videos:folder-videos-symbolic \
    folder-music:folder-music-symbolic \
    folder-pictures:folder-pictures-symbolic \
    folder-documents:folder-documents-symbolic \
    folder-downloads:folder-downloads-symbolic \
    network-server:network-server-symbolic; do
    src="${pair%%:*}"
    dst="${pair#*:}"
    cp -f "/usr/share/icons/Sea/places/scalable/${src}.svg" \
      "/usr/share/icons/hicolor/${size}x${size}/places/${dst}.svg"
  done
done

for icon in document-open-recent-symbolic user-trash-symbolic computer-symbolic; do
  src="$(find /usr/share/icons/bloom -type f -name "${icon}.svg" -print -quit)"
  [ -n "$src" ] || continue
  for size in 16 48; do
    cp -f "$src" "/usr/share/icons/hicolor/${size}x${size}/places/${icon}.svg"
  done
done

# DFM6 内置 SVG 未由上游软件包安装到图标主题。
install -d /usr/share/icons/hicolor/16x16/actions /usr/share/icons/hicolor/scalable/actions
for icon in /tmp/file-manager-icons/*.svg; do
  [ -f "$icon" ] || continue
  install -m 0644 "$icon" /usr/share/icons/hicolor/16x16/actions/
  install -m 0644 "$icon" /usr/share/icons/hicolor/scalable/actions/
done
if [ -f "$SEA_INDEX" ]; then
  install -d /usr/share/icons/Sea/actions/16 /usr/share/icons/Sea/actions/scalable
  for icon in /tmp/file-manager-icons/*.svg; do
    [ -f "$icon" ] || continue
    install -m 0644 "$icon" /usr/share/icons/Sea/actions/16/
    install -m 0644 "$icon" /usr/share/icons/Sea/actions/scalable/
  done
  for dir in actions/16 actions/scalable; do
    case ",$(sed -n 's/^Directories=//p' "$SEA_INDEX")," in
      *",$dir,"*) ;;
      *) sed -i "s#^Directories=.*#&,$dir#" "$SEA_INDEX" ;;
    esac
  done
  gtk-update-icon-cache -f -t /usr/share/icons/Sea
fi
gtk-update-icon-cache -f -t /usr/share/icons/hicolor

echo ">> Deepin 文件管理器：默认关联、搜索与主题"
cat > /etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
inode/directory=dde-file-manager.desktop;

[Added Associations]
inode/directory=dde-file-manager.desktop;
EOF
update-desktop-database /usr/share/applications

# Deepin Anything 索引服务不在本镜像中；禁用依赖它的全文/智能搜索，
# 保留文件管理器自身的普通文件名搜索。
FM_SEARCH_CFG=/etc/dsg/configs/overrides/org.deepin.dde.file-manager.search/org.deepin.dde.file-manager.search
mkdir -p "$FM_SEARCH_CFG"
cat > "$FM_SEARCH_CFG/debian-defaults.json" <<'EOF'
{
  "magic": "dsg.config.override",
  "version": "1.0",
  "contents": {
    "enableFileIndexSearch": { "value": false, "serial": 1 },
    "enableFullTextSearch": { "value": false, "serial": 1 },
    "enableSemanticSearch": { "value": false, "serial": 1 }
  }
}
EOF

echo ">> 会话环境变量"
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-dde.conf <<'EOF'
QT_QPA_PLATFORM=wayland
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=DDE
XDG_SESSION_DESKTOP=Treeland
EOF

echo ">> Deepin 官方默认壁纸"
mkdir -p /usr/share/wallpapers/deepin
cp -f /usr/share/wallpapers/deepin/platform/deepin/deepin-default.jpg \
  /usr/share/wallpapers/deepin/deepin-default.jpg
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
