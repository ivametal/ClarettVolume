#!/bin/bash
# Builds ClarettVolume, puts it in ~/Applications and starts it at every login.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=local.clarettvolume
DEST="$HOME/Applications/ClarettVolume.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

# A rebuild changes the ad-hoc signature, and with it the Accessibility
# grant, so an existing build is installed as is; run ./build.sh to update.
[ -d build/ClarettVolume.app ] || ./build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClarettVolume 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R build/ClarettVolume.app "$DEST"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/ClarettVolume</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/ClarettVolume.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "installed to $DEST, starts at login"
