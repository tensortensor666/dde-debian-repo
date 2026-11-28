#!/bin/bash
set -u

USER_NAME="${IMAGE_USER:-deepin}"
USER_UID="$(id -u "$USER_NAME")"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SESSION_OK=0
SHELL_OK=0
PLUGIN_OK=0
FILE_MANAGER_OK=0
WALLPAPER_OK=0
APPEARANCE_OK=0
AUDIO_OK=0

as_user() {
  runuser -u "$USER_NAME" -- env \
    HOME="$HOME_DIR" \
    XDG_RUNTIME_DIR="/run/user/$USER_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
    "$@"
}

if dpkg-query -W -f='${Status}' dde-desktop 2>/dev/null | grep -q 'install ok installed' \
    && compgen -G '/usr/lib/*/dde-shell/org.deepin.ds.desktop.so' >/dev/null; then
  PLUGIN_OK=1
fi

exec >>/dev/console 2>&1

echo "=== DDE_SESSION_CHECK_BEGIN ==="
date -Is
id "$USER_NAME" || true

if command -v dde-dconfig >/dev/null 2>&1; then
  echo "--- DDM autologin configuration ---"
  timeout 5 dde-dconfig -u 0 get -a org.deepin.dde.ddm -r org.deepin.dde.ddm -k autologinUser || true
  timeout 5 dde-dconfig -u 0 get -a org.deepin.dde.ddm -r org.deepin.dde.ddm -k autologinSession || true
fi

deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  if pgrep -u "$USER_NAME" -x dde-session >/dev/null 2>&1 \
      && pgrep -u "$USER_NAME" -x dde-shell >/dev/null 2>&1 \
      && systemctl is-active --quiet treeland.service; then
    SESSION_OK=1
    break
  fi
  sleep 2
done

deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if (( APPEARANCE_OK == 0 )) \
      && as_user busctl --user list 2>/dev/null \
        | grep -q '^org\.deepin\.dde\.Appearance1[[:space:]]'; then
    APPEARANCE_OK=1
  fi
  if (( AUDIO_OK == 0 )) \
      && as_user wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1 \
      && as_user wpctl inspect @DEFAULT_AUDIO_SOURCE@ >/dev/null 2>&1; then
    AUDIO_OK=1
  fi
  if (( SHELL_OK == 0 )) \
      && as_user busctl --user list 2>/dev/null \
        | grep -q '^org\.deepin\.dde\.Launcher1[[:space:]]' \
      && as_user busctl --user list 2>/dev/null \
        | grep -q '^org\.deepin\.dde\.Dock1[[:space:]]'; then
    SHELL_OK=1
  fi
  if (( APPEARANCE_OK == 1 && AUDIO_OK == 1 && SHELL_OK == 1 )); then
    break
  fi
  sleep 2
done

if (( AUDIO_OK == 1 )); then
  if ! as_user timeout 15 pw-play /usr/share/sounds/deepin/stereo/desktop-login.wav; then
    AUDIO_OK=0
  fi
fi

if ! journalctl -b _UID="$USER_UID" --no-pager 2>/dev/null \
    | grep -q 'Init applet org\.deepin\.ds\.desktop'; then
  PLUGIN_OK=0
fi
if journalctl -b _UID="$USER_UID" --no-pager 2>/dev/null \
    | grep -q 'Loading plugin failed: "org\.deepin\.ds\.desktop"'; then
  PLUGIN_OK=0
fi

if dpkg-query -W -f='${Status}' dde-file-manager 2>/dev/null | grep -q 'install ok installed' \
    && [ -x /usr/bin/dde-file-manager ] \
    && [ -f /usr/share/applications/dde-file-manager.desktop ] \
    && xdg-mime query default inode/directory 2>/dev/null | grep -qx 'dde-file-manager.desktop'; then
  FILE_MANAGER_OK=1
  for icon in \
    user-home-symbolic user-desktop-symbolic folder-videos-symbolic \
    folder-music-symbolic folder-pictures-symbolic folder-documents-symbolic \
    folder-downloads-symbolic document-open-recent-symbolic user-trash-symbolic \
    computer-symbolic network-server-symbolic dfm_viewlist_icons \
    dfm_viewlist_details dfm_viewlist_tree dfm_viewoption dfm_sortby_arrange \
    dfm_view_filter dfm_search_button; do
    if ! find /usr/share/icons/hicolor -type f -name "${icon}.svg" -print -quit \
        | grep -q .; then
      echo "Missing file manager icon: $icon"
      FILE_MANAGER_OK=0
      break
    fi
  done
  for icon in \
    dfm_viewlist_icons dfm_viewlist_details dfm_viewlist_tree dfm_viewoption \
    dfm_sortby_arrange dfm_view_filter dfm_search_button dfm_pin dfm_close \
    dfm_close_round_normal dfm_vault dfm_recent dfm_success dfm_fail \
    dfm_task_start dfm_task_pause dfm_task_stop; do
    for path in \
      "/usr/share/icons/hicolor/scalable/actions/${icon}.svg" \
      "/usr/share/icons/Sea/actions/scalable/${icon}.svg"; do
      if [ ! -s "$path" ]; then
        echo "Missing file manager toolbar icon: $path"
        FILE_MANAGER_OK=0
        break
      fi
    done
  done
  if ! grep -q 'actions/scalable' /usr/share/icons/Sea/index.theme 2>/dev/null; then
    echo "Sea icon theme does not index scalable actions"
    FILE_MANAGER_OK=0
  fi
  if ! grep -qE '^Inherits=([^,]*,)*bloom(,|$)' /usr/share/icons/Sea/index.theme 2>/dev/null; then
    echo "Sea icon theme does not inherit bloom"
    FILE_MANAGER_OK=0
  fi
fi

if dpkg-query -W -f='${Status}' deepin-wallpapers 2>/dev/null | grep -q 'install ok installed' \
    && [ -s /usr/share/wallpapers/deepin/deepin-default.jpg ] \
    && [ -s /usr/share/wallpapers/deepin/deepin-theme-3.jpg ]; then
  WALLPAPER_OK=1
fi

echo "--- file manager ---"
dpkg-query -W -f='${Package} ${Version} ${Status}\n' dde-file-manager 2>/dev/null || true
xdg-mime query default inode/directory 2>/dev/null || true

echo "--- wallpapers ---"
dpkg-query -W -f='${Package} ${Version} ${Status}\n' deepin-wallpapers 2>/dev/null || true
find /usr/share/wallpapers/deepin -maxdepth 1 -type f -name '*.jpg' -printf '%f\n' 2>/dev/null | sort | head -20 || true

echo "--- systemd units ---"
systemctl is-active ddm.service treeland.service accounts-daemon.service || true

echo "--- logind sessions ---"
loginctl list-sessions --no-legend || true

echo "--- user processes ---"
ps -u "$USER_NAME" -o user,pid,ppid,stat,comm,args || true

echo "--- DDM journal ---"
journalctl -b -u ddm.service --no-pager -o short-precise || true

echo "--- Treeland journal ---"
journalctl -b -u treeland.service --no-pager -o short-precise || true

echo "--- DDE user units ---"
journalctl -b _UID="$USER_UID" _SYSTEMD_USER_UNIT='dde-session*' \
  --no-pager -o short-precise 2>/dev/null | tail -300 || true
journalctl -b _UID="$USER_UID" _SYSTEMD_USER_UNIT='dde-shell*' \
  --no-pager -o short-precise 2>/dev/null | tail -200 || true
journalctl -b _UID="$USER_UID" _SYSTEMD_USER_UNIT='treeland*' \
  --no-pager -o short-precise 2>/dev/null | tail -200 || true

echo "--- Appearance D-Bus ---"
as_user busctl --user list 2>/dev/null \
  | grep -E '^org\.deepin\.dde\.Appearance1[[:space:]]' || true

echo "--- PipeWire status ---"
as_user wpctl status 2>&1 || true

echo "--- user warnings and errors ---"
journalctl -b _UID="$USER_UID" -p warning --no-pager -o short-precise 2>/dev/null | tail -300 || true

echo "--- user session stderr ---"
tail -200 "$HOME_DIR/.local/share/ddm/wayland-session.log" 2>/dev/null || true

if (( SHELL_OK == 1 )); then
  echo "DDE_SHELL_CHECK_RESULT=PASS"
else
  echo "DDE_SHELL_CHECK_RESULT=FAIL"
fi
if (( PLUGIN_OK == 1 )); then
  echo "DDE_DESKTOP_PLUGIN_CHECK_RESULT=PASS"
else
  echo "DDE_DESKTOP_PLUGIN_CHECK_RESULT=FAIL"
fi
if (( FILE_MANAGER_OK == 1 )); then
  echo "DDE_FILE_MANAGER_CHECK_RESULT=PASS"
else
  echo "DDE_FILE_MANAGER_CHECK_RESULT=FAIL"
fi
if (( WALLPAPER_OK == 1 )); then
  echo "DDE_WALLPAPER_CHECK_RESULT=PASS"
else
  echo "DDE_WALLPAPER_CHECK_RESULT=FAIL"
fi
if (( APPEARANCE_OK == 1 )); then
  echo "DDE_APPEARANCE_CHECK_RESULT=PASS"
else
  echo "DDE_APPEARANCE_CHECK_RESULT=FAIL"
fi
if (( AUDIO_OK == 1 )); then
  echo "DDE_AUDIO_CHECK_RESULT=PASS"
else
  echo "DDE_AUDIO_CHECK_RESULT=FAIL"
fi
if (( SESSION_OK == 1 && SHELL_OK == 1 && PLUGIN_OK == 1 && FILE_MANAGER_OK == 1 && WALLPAPER_OK == 1 && APPEARANCE_OK == 1 && AUDIO_OK == 1 )); then
  echo "DDE_SESSION_CHECK_RESULT=PASS"
else
  echo "DDE_SESSION_CHECK_RESULT=FAIL"
fi
echo "=== DDE_SESSION_CHECK_END ==="

(( SESSION_OK == 1 && SHELL_OK == 1 && PLUGIN_OK == 1 && FILE_MANAGER_OK == 1 && WALLPAPER_OK == 1 && APPEARANCE_OK == 1 && AUDIO_OK == 1 ))
