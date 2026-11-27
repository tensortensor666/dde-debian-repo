#!/bin/bash
set -u

USER_NAME="${IMAGE_USER:-deepin}"
SESSION_OK=0

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
      && pgrep -u "$USER_NAME" -x dde-shell >/dev/null 2>&1; then
    SESSION_OK=1
    break
  fi
  sleep 2
done

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

echo "--- user session journal (tail) ---"
journalctl -b _UID="$(id -u "$USER_NAME")" --no-pager -o short-precise 2>/dev/null | tail -200 || true

if (( SESSION_OK == 1 )); then
  echo "DDE_SESSION_CHECK_RESULT=PASS"
else
  echo "DDE_SESSION_CHECK_RESULT=FAIL"
fi
echo "=== DDE_SESSION_CHECK_END ==="

(( SESSION_OK == 1 ))
