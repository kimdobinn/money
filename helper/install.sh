#!/bin/zsh
# Installs/updates the brokerd helper as a per-user LaunchAgent (auto-start at login, auto-restart).
set -euo pipefail

HERE="${0:A:h}"
LABEL="com.brokers.helper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/Brokers"
PY="$HERE/.venv/bin/python"

mkdir -p "$LOGDIR" "$HOME/Library/LaunchAgents"

if [[ ! -x "$PY" ]]; then
  echo "Creating virtualenv…"
  /usr/bin/env python3 -m venv "$HERE/.venv"
fi
"$HERE/.venv/bin/pip" install -q --upgrade pip
"$HERE/.venv/bin/pip" install -q -r "$HERE/requirements.txt"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$PY</string><string>-m</string><string>brokerd</string></array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOGDIR/brokerd.stdout.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/brokerd.stdout.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for i in {1..30}; do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
# stop any manually started copy holding the port
pkill -f -- "[Pp]ython -m brokerd$" 2>/dev/null || true
for i in {1..20}; do lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.5; done
launchctl bootstrap "gui/$(id -u)" "$PLIST"

for i in {1..60}; do
  if curl -fs -m 1 http://127.0.0.1:8765/v1/status >/dev/null; then
    echo "brokerd running on http://127.0.0.1:8765"
    exit 0
  fi
  sleep 0.5
done
echo "brokerd did not start — see $LOGDIR/brokerd.stdout.log" >&2
exit 1
