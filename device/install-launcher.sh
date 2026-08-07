#!/bin/sh
# Install (or remove) the boot-time Anki launcher on the reMarkable.
#
#   ./install-launcher.sh install     enable launching Anki at boot
#   ./install-launcher.sh uninstall   go back to a stock reMarkable
#   ./install-launcher.sh status      show what is currently set up
#
# Safe by design: the unit starts AFTER xochitl, so if the Anki binary is
# broken or missing the tablet still boots normally as a reMarkable.
#
# Escape hatch if anything ever goes wrong:
#   ssh root@<tablet-ip> "systemctl disable --now anki-launcher; systemctl start xochitl"

set -e

UNIT=/etc/systemd/system/anki-launcher.service
SRC_UNIT=/home/root/anki-launcher.service
APP=/home/root/anki-offline
RUNNER=/home/root/run-anki.sh

action="${1:-status}"

case "$action" in
    install)
        if [ ! -x "$APP" ]; then
            echo "ERROR: $APP is missing or not executable." >&2
            echo "Deploy the app first, then re-run this." >&2
            exit 1
        fi
        if [ ! -f "$SRC_UNIT" ]; then
            echo "ERROR: $SRC_UNIT not found." >&2
            exit 1
        fi

        chmod +x "$RUNNER"
        cp "$SRC_UNIT" "$UNIT"
        systemctl daemon-reload
        systemctl enable anki-launcher.service

        echo "Installed. Anki will start at boot."
        echo "The tablet still boots xochitl first, so a broken build cannot lock you out."
        ;;

    uninstall)
        systemctl disable anki-launcher.service 2>/dev/null || true
        systemctl stop anki-launcher.service 2>/dev/null || true
        rm -f "$UNIT"
        systemctl daemon-reload
        systemctl start xochitl 2>/dev/null || true
        echo "Removed. The tablet is a stock reMarkable again."
        ;;

    status)
        # is-enabled/is-active print a value AND exit non-zero when not
        # enabled/active, so a plain `|| echo` prints twice. Take first line.
        echo "unit file : $([ -f "$UNIT" ] && echo present || echo absent)"
        echo "enabled   : $(systemctl is-enabled anki-launcher.service 2>/dev/null | head -n1)"
        echo "active    : $(systemctl is-active anki-launcher.service 2>/dev/null | head -n1)"
        echo "xochitl   : $(systemctl is-active xochitl 2>/dev/null | head -n1)"
        echo "app       : $([ -x "$APP" ] && echo ok || echo MISSING)"
        ;;

    *)
        echo "usage: $0 [install|uninstall|status]" >&2
        exit 2
        ;;
esac
