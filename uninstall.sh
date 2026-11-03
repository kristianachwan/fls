#!/bin/sh
# Stops FLS and removes it from login. Keeps this folder and ~/Library/Logs/FLS.log.
launchctl bootout "gui/$(id -u)/com.fls.monitor" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.fls.monitor.plist"
rm -rf "$HOME/Library/Application Support/FLS"
echo "FLS stopped and removed from login."
