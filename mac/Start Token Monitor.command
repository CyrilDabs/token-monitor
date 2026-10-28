#!/bin/sh
# Starts Token Monitor for Mac in the background.
# You can close this Terminal window once the monitor appears.
DIR="$(cd "$(dirname "$0")" && pwd)"
nohup /usr/bin/osascript -l JavaScript "$DIR/TokenMonitor.js" >/dev/null 2>&1 &
echo ""
echo "  Token Monitor is starting. You can close this window."
echo ""
