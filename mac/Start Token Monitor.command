#!/bin/sh
# Starts Token Monitor for Mac in the background.
# You can close this Terminal window once the monitor appears.
DIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$HOME/Library/Application Support/ClaudeTokenMonitor"
mkdir -p "$LOGDIR"
nohup /usr/bin/osascript -l JavaScript "$DIR/TokenMonitor.js" >"$LOGDIR/launch-log.txt" 2>&1 &
echo ""
echo "  Token Monitor is starting. You can close this window."
echo "  If nothing appears, any error is saved in:"
echo "  $LOGDIR/launch-log.txt"
echo ""
