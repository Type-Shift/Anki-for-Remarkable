#!/bin/sh
# Launch the offline Anki app on the reMarkable 1.
#
# Installed to /home/root/run-anki.sh
#
# Stops xochitl so the Qt epaper app can own the framebuffer, and holds a
# systemd inhibitor so nothing suspends the device mid-session.
#
# Measured on this device: /sys/power/autosleep is "off" and no power daemon
# runs, so idle suspend is driven by xochitl itself -- which we stop anyway.
# The inhibitor is belt-and-braces in case a future firmware adds one.
#
# To get the normal reMarkable UI back:  systemctl start xochitl

set -e

APP=/home/root/anki-offline
LOG=/home/root/anki-offline.log

if [ ! -x "$APP" ]; then
    echo "$APP is missing or not executable" >&2
    exit 1
fi

systemctl stop xochitl 2>/dev/null || true
sleep 1

# Keep only the previous run. The log was appended to forever, so a grep for
# errors returned dozens of historical hits and said nothing about whether
# THIS run was healthy.
if [ -f "$LOG" ]; then
    mv -f "$LOG" "${LOG}.prev"
fi

cd /home/root

# systemd services inherit no HOME, so QDir::homePath() resolves to "/" and
# the app looks for /anki-batch.json instead of /home/root/anki-batch.json --
# reporting "no cards on the device yet" while the batch sits there unread.
# Works over SSH (where HOME is set) but not under the launcher.
HOME=/home/root
export HOME

# reMarkable 1 needs the touchscreen rotated; rM2 additionally inverts X.
QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS="rotate=180"
QT_QUICK_BACKEND=epaper
export QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS QT_QUICK_BACKEND

exec systemd-inhibit \
    --what=sleep:idle \
    --who=anki \
    --why="Reviewing flashcards" \
    "$APP" -platform epaper >>"$LOG" 2>&1
