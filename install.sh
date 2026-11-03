#!/bin/sh
# Runs FLS now and at every login. Options are passed to FLS, e.g. ./install.sh --total 80
set -e

source_dir=$(cd "$(dirname "$0")" && pwd)
install_dir="$HOME/Library/Application Support/FLS"
plist="$HOME/Library/LaunchAgents/com.fls.monitor.plist"
domain="gui/$(id -u)"

# Stop here on a bad option, before anything is installed.
"$source_dir/FLS" "$@" --list > /dev/null

launchctl bootout "$domain/com.fls.monitor" 2>/dev/null || true

# macOS privacy protection can stop launchd running programs from ~/Desktop, so run a copy.
mkdir -p "$install_dir" "$(dirname "$plist")"
cp "$source_dir/FLS" "$install_dir/FLS"

rm -f "$plist"
plutil -create xml1 "$plist"
plutil -insert Label -string com.fls.monitor "$plist"
plutil -insert RunAtLoad -bool true "$plist"
plutil -insert KeepAlive -bool true "$plist"
# Interactive keeps launchd from throttling FLS when the machine is under pressure.
plutil -insert ProcessType -string Interactive "$plist"
plutil -insert ProgramArguments -array "$plist"
plutil -insert ProgramArguments -string "$install_dir/FLS" -append "$plist"
for arg in "$@"; do
    plutil -insert ProgramArguments -string "$arg" -append "$plist"
done

launchctl bootstrap "$domain" "$plist"
echo "FLS is running and will start at every login. Log: ~/Library/Logs/FLS.log"
