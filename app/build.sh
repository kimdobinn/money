#!/bin/zsh
# Regenerates the Xcode project, builds Release, installs to /Applications and relaunches.
set -euo pipefail
cd "${0:A:h}"
xcodegen generate -q
xcodebuild -project Brokers.xcodeproj -scheme Brokers -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
pkill -x Brokers 2>/dev/null || true
sleep 1
ditto build/Build/Products/Release/Brokers.app /Applications/Brokers.app
open /Applications/Brokers.app
echo "Installed /Applications/Brokers.app"
