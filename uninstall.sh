#!/bin/bash
# Stops ClarettVolume and removes it and its login agent.
set -uo pipefail

LABEL=local.clarettvolume
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x ClarettVolume 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ClarettVolume.app"
echo "ClarettVolume removed (Accessibility entry can be deleted in System Settings)"
